//! Admin CLI for issuing / listing / revoking partner bootstrap tokens.
//!
//! Wraps the same `partner_tokens` table the server reads. No HTTP — the
//! CLI is intended to run on the OxPulse-backend host with DATABASE_URL
//! pointing at the same postgres as the server.
//!
//! Subcommands:
//! - `issue-token --partner <id> --valid-for <duration>`
//! - `list-tokens [--partner <id>] [--include-used] [--include-revoked]`
//! - `revoke-token <token-id>`
//! - `list-nodes [--partner <id>]`
//! - `deactivate-node <node-id>`  (MVP placeholder)
//! - `rotate-service-token --node-id <id> [--force]`
//! - `keygen` — print x25519 keypair to stdout (no DB interaction)
//! - `set-pubkey --node-id <id> --pubkey <base64url>` — store edge x25519 pubkey

mod commands;

use anyhow::{Context, Result};
use clap::{Parser, Subcommand};
use sqlx::postgres::PgPoolOptions;

#[derive(Parser)]
#[command(
    name = "partner-cli",
    version,
    about = "OxPulse partner token admin CLI"
)]
struct Cli {
    #[command(subcommand)]
    cmd: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Issue a new bootstrap token. Prints the raw value ONCE.
    IssueToken {
        /// Partner identifier (e.g. `rvpn`, `piter`).
        #[arg(long)]
        partner: String,
        /// Token validity window (e.g. `30d`, `7d`, `48h`).
        #[arg(long, default_value = "30d")]
        valid_for: String,
    },
    /// List tokens. By default only unused, non-revoked tokens.
    ListTokens {
        #[arg(long)]
        partner: Option<String>,
        #[arg(long)]
        include_used: bool,
        #[arg(long)]
        include_revoked: bool,
    },
    /// Revoke a token by its token_id.
    RevokeToken { token_id: String },
    /// List registered nodes (tokens whose used_at is set).
    ListNodes {
        #[arg(long)]
        partner: Option<String>,
    },
    /// Deactivate a node. MVP placeholder — see TODO in handler.
    DeactivateNode { node_id: String },
    /// Provision or rotate the long-lived service token for a partner-edge node.
    ///
    /// Generates a fresh 32-byte random token, stores SHA-256(token) in
    /// `partner_nodes.service_token_hash`, and prints the plaintext token
    /// ONCE to stdout. The operator must deliver it to the edge VM via a
    /// secure channel and place it at `/etc/oxpulse-partner-edge/token` (0600).
    RotateServiceToken {
        /// Node identifier as returned by `list-nodes` or the registration response.
        #[arg(long)]
        node_id: String,
        /// Overwrite an existing token without a confirmation prompt.
        ///
        /// Required when the node already has a service token — safety guard
        /// to prevent accidental rotation. Rotating invalidates the token
        /// currently on the edge VM; the operator must re-place the new one.
        #[arg(long)]
        force: bool,
    },
    /// Generate a fresh x25519 keypair for a partner-edge Reality connection.
    ///
    /// Prints private_key and public_key to stdout (base64url, no padding, 43 chars each).
    /// No database interaction — purely local. Operator delivers private_key to the edge
    /// VM via a secure channel; public_key is registered via `set-pubkey` or the
    /// `reality_pubkey` field in `/api/partner/register`.
    Keygen,
    /// Store a partner-edge x25519 public key in the central database.
    ///
    /// Validates the pubkey format (43-char base64url, decodes to 32 bytes) then
    /// updates `partner_nodes.reality_pubkey` and `reality_pubkey_set_at = NOW()`.
    /// Returns exit code 0 on success, 1 if the node_id is not found or format is invalid.
    SetPubkey {
        /// Node identifier as returned by `list-nodes` or the registration response.
        #[arg(long)]
        node_id: String,
        /// x25519 public key — 43-char base64url-no-pad string (output of `keygen`).
        #[arg(long)]
        pubkey: String,
    },
}

#[tokio::main]
async fn main() -> Result<()> {
    let cli = Cli::parse();

    // `keygen` is a pure local operation — no DB needed.
    if let Command::Keygen = &cli.cmd {
        let (private_key, public_key) = commands::keygen_x25519();
        // Deref Zeroizing<String>; the format macro borrows it (no intermediate
        // String copy) so the base64 encoding is wiped when private_key drops.
        println!("private_key: {}", *private_key);
        println!("public_key:  {public_key}");
        return Ok(());
    }

    let db_url = std::env::var("DATABASE_URL")
        .context("DATABASE_URL env var must be set (set it in your operator environment)")?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await
        .context("connecting to DATABASE_URL")?;

    // The server auto-applies migrations at boot. Probe that the table exists
    // and give a clear error if not (instead of a confusing sqlx error).
    commands::check_schema(&pool).await?;

    match cli.cmd {
        Command::IssueToken { partner, valid_for } => {
            commands::issue_token(&pool, &partner, &valid_for).await
        }
        Command::ListTokens {
            partner,
            include_used,
            include_revoked,
        } => commands::list_tokens(&pool, partner.as_deref(), include_used, include_revoked).await,
        Command::RevokeToken { token_id } => commands::revoke_token(&pool, &token_id).await,
        Command::ListNodes { partner } => commands::list_nodes(&pool, partner.as_deref()).await,
        Command::DeactivateNode { node_id } => commands::deactivate_node(&pool, &node_id).await,
        Command::Keygen => unreachable!("handled above before DB connect"),
        Command::SetPubkey { node_id, pubkey } => {
            commands::set_pubkey(&pool, &node_id, &pubkey).await?;
            println!("pubkey set: {node_id}");
            Ok(())
        }
        Command::RotateServiceToken { node_id, force } => {
            let token = commands::rotate_service_token(&pool, &node_id, force).await?;
            // Fetch edge_id for the output banner (best-effort; not fatal if missing).
            // edge_id is nullable in the DB, so the scalar may itself be NULL;
            // we use query_as with a single-element tuple to preserve that.
            let edge_id: Option<String> = sqlx::query_as::<_, (Option<String>,)>(
                "SELECT edge_id FROM partner_nodes WHERE node_id = $1",
            )
            .bind(&node_id)
            .fetch_optional(&pool)
            .await
            .ok()
            .flatten()
            .and_then(|(eid,)| eid);
            println!("node_id: {node_id}");
            println!("edge_id: {}", edge_id.as_deref().unwrap_or("<not set>"));
            println!("token:   {token}");
            println!();
            println!(
                "PLACE THE TOKEN AT /etc/oxpulse-partner-edge/token (mode 0600) ON THE PARTNER NODE."
            );
            Ok(())
        }
    }
}
