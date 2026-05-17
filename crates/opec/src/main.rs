//! opec — OxPulse Partner Edge Controller
//!
//! Sub-phase 4.0: read-only tenant subcommands (list, validate, diff).
//! Sub-phase 4.1: Caddy JSON renderer + `reconcile --dry-run`.
//! No Caddy admin API calls at runtime. No mutations. No async runtime.

mod caddy;
mod tenant;

use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    process,
};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;

use caddy::render::render_tenant_routes;
use tenant::schema::{parse, TenantsFile};
use tenant::validate::validate;

const DEFAULT_YAML_PATH: &str = "/etc/oxpulse-partner-edge/tenants.yaml";
const DEFAULT_ADMIN_URL: &str = "http://localhost:2019";

// ---------------------------------------------------------------------------
// CLI structure
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(
    name = "opec",
    version,
    about = "OxPulse Partner Edge Controller",
    long_about = "opec manages tenant configuration on an OxPulse partner edge node.\n\
                  Sub-phase 4.1: Caddy JSON renderer + dry-run reconcile."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Tenant management
    Tenant {
        #[command(subcommand)]
        action: TenantCommands,
    },
    /// Render a partner-edge config template (xray | coturn | naive).
    ///
    /// Substitutes {{NAME}} placeholders from env vars (NAME = [A-Z][A-Z0-9_]*),
    /// writes atomically, and validates the rendered file per-kind. Mirrors
    /// channel-render-lib.sh::render_template semantics for the three template
    /// kinds it owns; the bash function stays in place for callers that don't
    /// have opec on PATH (Phase 2 fallback in install.sh — Task 6).
    Render {
        /// Template kind. Each kind has its own post-substitution validation.
        #[arg(value_enum)]
        kind: RenderKind,
        /// Path to the template file.
        #[arg(long)]
        tpl: PathBuf,
        /// Path to the rendered output file.
        #[arg(long)]
        out: PathBuf,
    },
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum RenderKind {
    Xray,
    Coturn,
    Naive,
}

#[derive(Subcommand)]
enum TenantCommands {
    /// List all tenants from the yaml file
    List {
        /// Path to tenants.yaml
        #[arg(long, default_value = DEFAULT_YAML_PATH)]
        yaml: PathBuf,
        /// Output format
        #[arg(long, value_enum, default_value = "table")]
        format: Format,
    },
    /// Validate tenants.yaml, exit 0 on success, exit 1 with errors
    Validate {
        /// Path to tenants.yaml
        #[arg(long, default_value = DEFAULT_YAML_PATH)]
        yaml: PathBuf,
        /// Output format
        #[arg(long, value_enum, default_value = "table")]
        format: Format,
    },
    /// Show per-tenant diff between two yaml files
    Diff {
        /// Left (old) tenants.yaml
        left: PathBuf,
        /// Right (new) tenants.yaml
        right: PathBuf,
        /// Output format
        #[arg(long, value_enum, default_value = "table")]
        format: Format,
    },
    /// Reconcile tenants.yaml with Caddy admin API.
    /// In 4.1, only --dry-run is implemented (prints proposed PATCH payload without sending).
    Reconcile {
        /// Path to tenants.yaml
        #[arg(long, default_value = DEFAULT_YAML_PATH)]
        yaml: PathBuf,
        /// Caddy admin API base URL
        #[arg(long, default_value = DEFAULT_ADMIN_URL)]
        admin_url: String,
        /// Preview the PATCH payload without sending it. Required in sub-phase 4.1.
        #[arg(long)]
        dry_run: bool,
        /// Output format
        #[arg(long, value_enum, default_value = "text")]
        format: ReconcileFormat,
    },
}

#[derive(Clone, ValueEnum)]
enum Format {
    Table,
    Json,
}

#[derive(Clone, ValueEnum)]
enum ReconcileFormat {
    Text,
    Json,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Tenant { action } => run_tenant(action),
        Commands::Render { kind, tpl, out } => match kind {
            RenderKind::Xray => opec::render::xray::render(&tpl, &out),
            RenderKind::Coturn => opec::render::coturn::render(&tpl, &out),
            RenderKind::Naive => opec::render::naive::render(&tpl, &out),
        },
    };

    if let Err(e) = result {
        eprintln!("opec error: {e:#}");
        process::exit(2);
    }
}

fn run_tenant(action: TenantCommands) -> Result<()> {
    match action {
        TenantCommands::List { yaml, format } => cmd_list(&yaml, &format),
        TenantCommands::Validate { yaml, format } => cmd_validate(&yaml, &format),
        TenantCommands::Diff {
            left,
            right,
            format,
        } => cmd_diff(&left, &right, &format),
        TenantCommands::Reconcile {
            yaml,
            admin_url,
            dry_run,
            format,
        } => cmd_reconcile(&yaml, &admin_url, dry_run, &format),
    }
}

// ---------------------------------------------------------------------------
// list
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ListRow {
    id: String,
    domains: Vec<String>,
    enabled: bool,
    route_count: usize,
}

fn cmd_list(yaml_path: &PathBuf, format: &Format) -> Result<()> {
    let file = load(yaml_path)?;
    let rows: Vec<ListRow> = file
        .tenants
        .iter()
        .map(|t| ListRow {
            id: t.id.clone(),
            domains: t.domains.clone(),
            enabled: t.enabled,
            route_count: t.routes.len(),
        })
        .collect();

    match format {
        Format::Json => {
            println!("{}", serde_json::to_string_pretty(&rows)?);
        }
        Format::Table => {
            println!("{:<20} {:<40} {:<8} ROUTES", "ID", "DOMAINS", "ENABLED");
            println!("{}", "-".repeat(76));
            for r in &rows {
                println!(
                    "{:<20} {:<40} {:<8} {}",
                    r.id,
                    r.domains.join(", "),
                    r.enabled,
                    r.route_count
                );
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// validate
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct ValidateOutput {
    ok: bool,
    errors: Vec<ValidateError>,
}

#[derive(Serialize)]
struct ValidateError {
    message: String,
}

fn cmd_validate(yaml_path: &PathBuf, format: &Format) -> Result<()> {
    let file = load(yaml_path)?;

    match validate(&file) {
        Ok(()) => {
            match format {
                Format::Json => {
                    let out = ValidateOutput {
                        ok: true,
                        errors: vec![],
                    };
                    println!("{}", serde_json::to_string_pretty(&out)?);
                }
                Format::Table => {
                    println!("OK — {} tenant(s) valid", file.tenants.len());
                }
            }
            Ok(())
        }
        Err(errs) => {
            match format {
                Format::Json => {
                    let out = ValidateOutput {
                        ok: false,
                        errors: errs
                            .iter()
                            .map(|e| ValidateError {
                                message: e.to_string(),
                            })
                            .collect(),
                    };
                    println!("{}", serde_json::to_string_pretty(&out)?);
                }
                Format::Table => {
                    eprintln!("Validation failed ({} error(s)):", errs.len());
                    for e in &errs {
                        eprintln!("  - {e}");
                    }
                }
            }
            process::exit(1);
        }
    }
}

// ---------------------------------------------------------------------------
// diff
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct DiffOutput {
    added: Vec<String>,
    removed: Vec<String>,
    changed: Vec<ChangedTenant>,
}

#[derive(Serialize)]
struct ChangedTenant {
    id: String,
    route_paths_changed: Vec<String>,
    domains_changed: bool,
    enabled_changed: bool,
}

fn cmd_diff(left_path: &PathBuf, right_path: &PathBuf, format: &Format) -> Result<()> {
    let left = load(left_path)?;
    let right = load(right_path)?;

    let left_map: HashMap<&str, _> = left.tenants.iter().map(|t| (t.id.as_str(), t)).collect();
    let right_map: HashMap<&str, _> = right.tenants.iter().map(|t| (t.id.as_str(), t)).collect();

    let left_ids: HashSet<&str> = left_map.keys().copied().collect();
    let right_ids: HashSet<&str> = right_map.keys().copied().collect();

    let mut added: Vec<String> = right_ids
        .difference(&left_ids)
        .map(|s| s.to_string())
        .collect();
    added.sort();

    let mut removed: Vec<String> = left_ids
        .difference(&right_ids)
        .map(|s| s.to_string())
        .collect();
    removed.sort();

    let mut changed: Vec<ChangedTenant> = Vec::new();
    let mut common_ids: Vec<&str> = left_ids.intersection(&right_ids).copied().collect();
    common_ids.sort();

    for id in common_ids {
        let lt = left_map[id];
        let rt = right_map[id];

        let left_paths: HashSet<&str> = lt.routes.iter().map(|r| r.path.as_str()).collect();
        let right_paths: HashSet<&str> = rt.routes.iter().map(|r| r.path.as_str()).collect();
        let mut changed_paths: Vec<String> = left_paths
            .symmetric_difference(&right_paths)
            .map(|s| s.to_string())
            .collect();

        for path in left_paths.intersection(&right_paths) {
            let lr = lt.routes.iter().find(|r| r.path == *path);
            let rr = rt.routes.iter().find(|r| r.path == *path);
            if lr != rr {
                changed_paths.push(path.to_string());
            }
        }
        changed_paths.sort();
        changed_paths.dedup();

        let domains_changed = lt.domains != rt.domains;
        let enabled_changed = lt.enabled != rt.enabled;

        if !changed_paths.is_empty() || domains_changed || enabled_changed {
            changed.push(ChangedTenant {
                id: id.to_string(),
                route_paths_changed: changed_paths,
                domains_changed,
                enabled_changed,
            });
        }
    }

    let diff = DiffOutput {
        added,
        removed,
        changed,
    };

    match format {
        Format::Json => {
            println!("{}", serde_json::to_string_pretty(&diff)?);
        }
        Format::Table => {
            if diff.added.is_empty() && diff.removed.is_empty() && diff.changed.is_empty() {
                println!("No differences.");
                return Ok(());
            }
            for id in &diff.added {
                println!("+ {id}  (added)");
            }
            for id in &diff.removed {
                println!("- {id}  (removed)");
            }
            for c in &diff.changed {
                println!("~ {}  (changed)", c.id);
                if c.domains_changed {
                    println!("    domains changed");
                }
                if c.enabled_changed {
                    println!("    enabled changed");
                }
                if !c.route_paths_changed.is_empty() {
                    println!(
                        "    {} changed route(s): {}",
                        c.route_paths_changed.len(),
                        c.route_paths_changed.join(", ")
                    );
                }
            }
        }
    }
    Ok(())
}

// ---------------------------------------------------------------------------
// reconcile (4.1: --dry-run only)
// ---------------------------------------------------------------------------

const PATCH_TARGET: &str = "apps/http/servers/srv0/routes";

#[derive(Serialize)]
struct ReconcileDryRunOutput {
    mode: String,
    admin_url: String,
    tenants_count: usize,
    proposed_routes: Vec<serde_json::Value>,
    patch_target: String,
}

fn cmd_reconcile(
    yaml_path: &PathBuf,
    admin_url: &str,
    dry_run: bool,
    format: &ReconcileFormat,
) -> Result<()> {
    if !dry_run {
        eprintln!(
            "opec error: real PATCH not yet implemented; use --dry-run in sub-phase 4.1.\n\
             Sub-phase 4.2 will implement the actual Caddy admin-API PATCH."
        );
        process::exit(1);
    }

    // Step 1: load + validate yaml. Errors → exit 1.
    let file = load(yaml_path)?;
    if let Err(errs) = validate(&file) {
        eprintln!("Validation failed ({} error(s)):", errs.len());
        for e in &errs {
            eprintln!("  - {e}");
        }
        process::exit(1);
    }

    // Step 2: render.
    let proposed = render_tenant_routes(&file.tenants);

    // Step 3: validate shape of each rendered route (catch renderer bugs).
    for (i, r) in proposed.iter().enumerate() {
        caddy::render::validate_caddy_route_shape(r)
            .with_context(|| format!("rendered route[{i}] failed shape validation"))?;
    }

    let enabled_count = file.tenants.iter().filter(|t| t.enabled).count();

    match format {
        ReconcileFormat::Json => {
            let out = ReconcileDryRunOutput {
                mode: "dry-run".to_string(),
                admin_url: admin_url.to_string(),
                tenants_count: enabled_count,
                proposed_routes: proposed,
                patch_target: PATCH_TARGET.to_string(),
            };
            println!("{}", serde_json::to_string_pretty(&out)?);
        }
        ReconcileFormat::Text => {
            println!("Mode:          dry-run (no changes sent)");
            println!("Admin URL:     {admin_url}");
            println!("Patch target:  {PATCH_TARGET}");
            println!(
                "Tenants:       {} enabled / {} total",
                enabled_count,
                file.tenants.len()
            );
            println!("Routes:        {} route object(s) proposed", proposed.len());
            println!();
            println!("--- Proposed Caddy routes ---");
            println!("{}", serde_json::to_string_pretty(&proposed)?);
        }
    }

    Ok(())
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn load(path: &PathBuf) -> Result<TenantsFile> {
    let src =
        std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
    parse(&src).with_context(|| format!("parsing {}", path.display()))
}
