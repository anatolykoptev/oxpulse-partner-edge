//! opec — OxPulse Partner Edge Controller
//!
//! Sub-phase 4.0: read-only tenant subcommands (list, validate, diff).
//! No Caddy admin API calls. No mutations. No async runtime.

mod tenant;

use std::{
    collections::{HashMap, HashSet},
    path::PathBuf,
    process,
};

use anyhow::{Context, Result};
use clap::{Parser, Subcommand, ValueEnum};
use serde::Serialize;

use tenant::schema::{parse, TenantsFile};
use tenant::validate::validate;

const DEFAULT_YAML_PATH: &str = "/etc/oxpulse-partner-edge/tenants.yaml";

// ---------------------------------------------------------------------------
// CLI structure
// ---------------------------------------------------------------------------

#[derive(Parser)]
#[command(
    name = "opec",
    version,
    about = "OxPulse Partner Edge Controller",
    long_about = "opec manages tenant configuration on an OxPulse partner edge node.\n\
                  Sub-phase 4.0: read-only (list, validate, diff). Mutations arrive in 4.3+."
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    /// Tenant management (4.0: list, validate, diff)
    Tenant {
        #[command(subcommand)]
        action: TenantCommands,
    },
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
    /// Show per-tenant diff between two yaml files (4.0: tenant-level only)
    Diff {
        /// Left (old) tenants.yaml
        left: PathBuf,
        /// Right (new) tenants.yaml
        right: PathBuf,
        /// Output format
        #[arg(long, value_enum, default_value = "table")]
        format: Format,
    },
}

#[derive(Clone, ValueEnum)]
enum Format {
    Table,
    Json,
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

fn main() {
    let cli = Cli::parse();

    let result = match cli.command {
        Commands::Tenant { action } => run_tenant(action),
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
        TenantCommands::Diff { left, right, format } => cmd_diff(&left, &right, &format),
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
                    let out = ValidateOutput { ok: true, errors: vec![] };
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
                            .map(|e| ValidateError { message: e.to_string() })
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

        // Also check existing paths for changes
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

    let diff = DiffOutput { added, removed, changed };

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
// helpers
// ---------------------------------------------------------------------------

fn load(path: &PathBuf) -> Result<TenantsFile> {
    let src = std::fs::read_to_string(path)
        .with_context(|| format!("reading {}", path.display()))?;
    parse(&src).with_context(|| format!("parsing {}", path.display()))
}
