//! Subcommand implementations. Each one is small, synchronous print-side
//! logic + one sqlx call. Kept in one file because the subcommands share
//! a minimal schema and are easier to eyeball as a group (<200 lines).

use anyhow::{bail, Context, Result};
use once_cell::sync::Lazy;
use rand::RngCore;
use regex::Regex;
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use sqlx::Row;
use uuid::Uuid;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::Zeroizing;

const ISSUE_TOKEN_WARNING: &str =
    "!! This is the ONLY time this raw token will be shown. Copy it now. !!";

/// Partner identifier format: lowercase alphanumeric + hyphen, 3–32 chars,
/// no leading/trailing hyphen. Shared rule with a downstream admin service
/// (admin partner-id pattern) — keep them in
/// lockstep or the CLI and UI will disagree about which IDs are valid.
static PARTNER_ID_RE: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$").expect("regex"));

/// Token-validity bounds: the web form accepts 1..=90 days. The CLI uses a
/// duration string (e.g. "30d", "72h"), converted to seconds and checked
/// against the same window so ops workflows cannot drift.
const MIN_VALID_FOR_SECS: i64 = 24 * 3600;
const MAX_VALID_FOR_SECS: i64 = 90 * 24 * 3600;

fn validate_partner_id(partner: &str) -> Result<()> {
    if !PARTNER_ID_RE.is_match(partner) {
        bail!(
            "invalid partner_id {partner:?}: must be lowercase alphanumeric + hyphen, \
             3-32 chars, no leading/trailing hyphen"
        );
    }
    Ok(())
}

/// Verify that the server's migrations have been applied by probing for the
/// `partner_tokens` table. Gives a clear error message if the table is absent.
///
/// The CLI does NOT maintain its own schema copy — run the server once
/// (`cargo run -p oxpulse-chat`) to apply migrations before using the CLI.
pub async fn check_schema(pool: &PgPool) -> Result<()> {
    sqlx::query("SELECT 1 FROM partner_tokens LIMIT 1")
        .execute(pool)
        .await
        .map_err(|e| anyhow::anyhow!(
            "partner_tokens table not found — run `cargo run -p oxpulse-chat` once to apply migrations ({e})"
        ))?;
    Ok(())
}

fn hash_token(raw: &str) -> String {
    let mut h = Sha256::new();
    h.update(raw.as_bytes());
    format!("{:x}", h.finalize())
}

fn generate_raw_token() -> String {
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    let hex: String = buf.iter().map(|b| format!("{b:02x}")).collect();
    format!("ptkn_{hex}")
}

/// Parses a human duration like "30d" / "48h" / "2w". Returns seconds.
fn parse_duration(s: &str) -> Result<i64> {
    let d = humantime::parse_duration(s).with_context(|| format!("invalid duration: {s}"))?;
    Ok(d.as_secs() as i64)
}

pub async fn issue_token(pool: &PgPool, partner: &str, valid_for: &str) -> Result<()> {
    validate_partner_id(partner)?;
    let secs = parse_duration(valid_for)?;
    if !(MIN_VALID_FOR_SECS..=MAX_VALID_FOR_SECS).contains(&secs) {
        bail!(
            "valid-for out of range: {valid_for} = {secs}s (allowed: 1..=90 days to match the web UI)"
        );
    }
    let raw = generate_raw_token();
    let token_hash = hash_token(&raw);
    let expires_at = chrono::Utc::now() + chrono::Duration::seconds(secs);

    let token_id: Uuid = sqlx::query_scalar(
        "INSERT INTO partner_tokens (partner_id, token_hash, expires_at) \
         VALUES ($1, $2, $3) RETURNING token_id",
    )
    .bind(partner)
    .bind(&token_hash)
    .bind(expires_at)
    .fetch_one(pool)
    .await
    .context("insert partner_tokens row")?;

    println!("{ISSUE_TOKEN_WARNING}");
    println!("token_id  : {token_id}");
    println!("partner   : {partner}");
    println!("expires_at: {expires_at}");
    println!("raw token : {raw}");
    Ok(())
}

pub async fn list_tokens(
    pool: &PgPool,
    partner: Option<&str>,
    include_used: bool,
    include_revoked: bool,
) -> Result<()> {
    if let Some(p) = partner {
        validate_partner_id(p)?;
    }
    // Bind positional indices: $1 is always partner ("" matches all when
    // we short-circuit via OR); fixed parameter list avoids Postgres'
    // "could not determine data type of parameter" when a bind is absent.
    let used_clause = if include_used {
        ""
    } else {
        " AND used_at IS NULL"
    };
    let revoked_clause = if include_revoked {
        ""
    } else {
        " AND revoked_at IS NULL"
    };
    let partner_filter = partner.unwrap_or("");
    let sql = format!(
        "SELECT token_id, partner_id, expires_at, used_at, revoked_at, node_id \
         FROM partner_tokens \
         WHERE ($1 = '' OR partner_id = $1){used_clause}{revoked_clause} \
         ORDER BY created_at DESC LIMIT 200"
    );
    let rows = sqlx::query(&sql)
        .bind(partner_filter)
        .fetch_all(pool)
        .await
        .context("select partner_tokens")?;
    println!(
        "{:<36}  {:<12}  {:<20}  {:<20}  {:<10}  node_id",
        "token_id", "partner_id", "expires_at", "used_at", "revoked"
    );
    for r in rows {
        let tid: Uuid = r.try_get("token_id")?;
        let pid: String = r.try_get("partner_id")?;
        let exp: chrono::DateTime<chrono::Utc> = r.try_get("expires_at")?;
        let used: Option<chrono::DateTime<chrono::Utc>> = r.try_get("used_at")?;
        let rev: Option<chrono::DateTime<chrono::Utc>> = r.try_get("revoked_at")?;
        let nid: Option<String> = r.try_get("node_id")?;
        println!(
            "{tid}  {pid:<12}  {:<20}  {:<20}  {:<10}  {}",
            exp.format("%Y-%m-%d %H:%M:%S"),
            used.map(|u| u.format("%Y-%m-%d %H:%M:%S").to_string())
                .unwrap_or_else(|| "-".into()),
            if rev.is_some() { "yes" } else { "no" },
            nid.unwrap_or_else(|| "-".into())
        );
    }
    Ok(())
}

pub async fn revoke_token(pool: &PgPool, token_id: &str) -> Result<()> {
    let uuid = Uuid::parse_str(token_id).context("token_id must be a UUID")?;
    let res = sqlx::query(
        "UPDATE partner_tokens SET revoked_at = NOW() \
         WHERE token_id = $1 AND revoked_at IS NULL",
    )
    .bind(uuid)
    .execute(pool)
    .await
    .context("revoke token")?;
    if res.rows_affected() == 0 {
        bail!("token not found or already revoked: {token_id}");
    }
    println!("revoked: {token_id}");
    Ok(())
}

pub async fn list_nodes(pool: &PgPool, partner: Option<&str>) -> Result<()> {
    if let Some(p) = partner {
        validate_partner_id(p)?;
    }
    let partner_filter = partner.unwrap_or("");
    // Read from partner_nodes (the authoritative registry populated by
    // /api/partner/register) rather than partner_tokens.used_at. The old
    // tokens-based query lost domain / turns_subdomain / last_seen_at.
    let sql = "SELECT node_id, partner_id, domain, turns_subdomain, public_ip, \
                      registered_at, last_seen_at \
               FROM partner_nodes \
               WHERE ($1 = '' OR partner_id = $1) \
               ORDER BY registered_at DESC LIMIT 200";
    let rows = sqlx::query(sql)
        .bind(partner_filter)
        .fetch_all(pool)
        .await
        .context("select partner_nodes")?;
    println!(
        "{:<24}  {:<12}  {:<22}  {:<22}  {:<15}  {:<19}  last_seen_at",
        "node_id", "partner_id", "domain", "turns_subdomain", "public_ip", "registered_at"
    );
    for r in rows {
        let nid: String = r.try_get("node_id")?;
        let pid: String = r.try_get("partner_id")?;
        let dom: String = r.try_get("domain")?;
        let tsd: String = r.try_get("turns_subdomain")?;
        let ip: String = r.try_get("public_ip")?;
        let reg: chrono::DateTime<chrono::Utc> = r.try_get("registered_at")?;
        let seen: chrono::DateTime<chrono::Utc> = r.try_get("last_seen_at")?;
        println!(
            "{nid:<24}  {pid:<12}  {dom:<22}  {tsd:<22}  {ip:<15}  {}  {}",
            reg.format("%Y-%m-%d %H:%M:%S"),
            seen.format("%Y-%m-%d %H:%M:%S")
        );
    }
    Ok(())
}

/// Generate a fresh service token for a registered partner-edge node.
///
/// # What this does
///
/// 1. Looks up the `partner_nodes` row by `node_id` (text, not UUID).
/// 2. If `service_token_hash` is already set and `force` is `false`, returns
///    an error asking the caller to pass `--force`.
/// 3. Generates a fresh 32-byte random token, base64url-encodes it.
/// 4. Hashes it with SHA-256 and updates `partner_nodes.service_token_hash`.
/// 5. Returns the plaintext token so the binary can print it to stdout.
///
/// The caller (main.rs) is responsible for printing the returned token.
/// Only the plaintext is returned here — no side-channel I/O.
///
/// # Errors
///
/// - Node not found → `Err` with "node not found: <node_id>".
/// - Token already exists without `force` → `Err` mentioning `--force`.
/// - DB errors are wrapped with context.
pub async fn rotate_service_token(pool: &PgPool, node_id: &str, force: bool) -> Result<String> {
    // Validate early: reject obviously invalid node_ids before the DB round-trip.
    if node_id.is_empty() {
        bail!("node_id must not be empty");
    }

    // Fetch the existing row to check for a pre-existing token.
    let row: Option<(String, Option<String>)> =
        sqlx::query_as("SELECT node_id, service_token_hash FROM partner_nodes WHERE node_id = $1")
            .bind(node_id)
            .fetch_optional(pool)
            .await
            .context("lookup partner_nodes row")?;

    let (canonical_node_id, existing_hash) = match row {
        Some(r) => r,
        None => bail!("node not found: {node_id}"),
    };

    if existing_hash.is_some() && !force {
        bail!(
            "node {node_id} already has a service token — pass --force to rotate it\n\
             WARNING: rotating invalidates the token currently on the edge VM."
        );
    }

    // Generate: base64url(rand 32 bytes).  Uses the same rand::thread_rng()
    // approach as generate_raw_token (already in workspace); no extra deps needed.
    let plaintext = generate_service_token();
    let token_hash = hash_token(&plaintext);

    sqlx::query("UPDATE partner_nodes SET service_token_hash = $1 WHERE node_id = $2")
        .bind(&token_hash)
        .bind(&canonical_node_id)
        .execute(pool)
        .await
        .context("update service_token_hash")?;

    Ok(plaintext)
}

/// Generate a fresh service token: base64url(rand 32 bytes).
///
/// Distinct from `generate_raw_token` (which uses `ptkn_` prefix hex) so
/// callers can tell apart bootstrap tokens and service tokens by prefix:
/// `stkn_` for service tokens, `ptkn_` for bootstrap.
fn generate_service_token() -> String {
    let mut buf = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut buf);
    // base64url (no padding) — URL-safe and compatible with Authorization headers.
    let encoded = base64_url_encode(&buf);
    format!("stkn_{encoded}")
}

/// URL-safe base64 without padding, matching RFC 4648 §5.
fn base64_url_encode(bytes: &[u8]) -> String {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut out = String::with_capacity((bytes.len() * 4).div_ceil(3));
    for chunk in bytes.chunks(3) {
        let b0 = chunk[0] as usize;
        let b1 = if chunk.len() > 1 {
            chunk[1] as usize
        } else {
            0
        };
        let b2 = if chunk.len() > 2 {
            chunk[2] as usize
        } else {
            0
        };
        out.push(CHARS[b0 >> 2] as char);
        out.push(CHARS[((b0 & 3) << 4) | (b1 >> 4)] as char);
        if chunk.len() > 1 {
            out.push(CHARS[((b1 & 0xf) << 2) | (b2 >> 6)] as char);
        }
        if chunk.len() > 2 {
            out.push(CHARS[b2 & 0x3f] as char);
        }
    }
    out
}

/// Validate a base64url-no-pad pubkey string for x25519 format.
///
/// Rules (matching the DB CHECK constraint and acceptance spec):
///   - Exactly 43 chars (base64url of 32 bytes, no padding).
///   - Only base64url alphabet: `[A-Za-z0-9_-]`.
///   - Must decode to exactly 32 bytes.
pub fn validate_pubkey(pubkey: &str) -> Result<[u8; 32]> {
    if pubkey.len() != 43 {
        bail!(
            "invalid pubkey format: must be exactly 43 base64url chars (got {})",
            pubkey.len()
        );
    }
    if !pubkey
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
    {
        bail!(
            "invalid pubkey format: contains non-base64url characters \
             (allowed: A-Z a-z 0-9 - _)"
        );
    }
    let bytes = base64_url_decode(pubkey)
        .map_err(|e| anyhow::anyhow!("invalid pubkey format: base64url decode failed: {e}"))?;
    bytes
        .try_into()
        .map_err(|_| anyhow::anyhow!("invalid pubkey format: must decode to exactly 32 bytes"))
}

/// Decode a base64url-no-pad string to bytes. Returns Err on invalid chars.
fn base64_url_decode(s: &str) -> std::result::Result<Vec<u8>, String> {
    const CHARS: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";
    let mut bits: u32 = 0;
    let mut bit_count: u32 = 0;
    let mut out = Vec::with_capacity(s.len() * 3 / 4 + 1);
    for c in s.bytes() {
        let val = CHARS
            .iter()
            .position(|&b| b == c)
            .ok_or_else(|| format!("invalid base64url char: {c}"))?;
        bits = (bits << 6) | val as u32;
        bit_count += 6;
        if bit_count >= 8 {
            bit_count -= 8;
            out.push((bits >> bit_count) as u8);
        }
    }
    Ok(out)
}

/// Generate a fresh x25519 keypair.
///
/// Returns `(private_key_b64url, public_key_b64url)`.  Both are 43-char
/// base64url-no-pad strings encoding the 32-byte x25519 keys.
///
/// The private key is wrapped in [`Zeroizing`] so the heap copy of the
/// base64 representation is wiped on drop. [`StaticSecret`] itself has
/// `ZeroizeOnDrop`, but that only covers the raw key bytes — without this
/// wrapper the base64 string encoding persists on the heap until the
/// allocator reuses the memory.
///
/// Operators pipe `private_key` to the edge VM; only `public_key` is
/// registered on the central via `set-pubkey` or `/api/partner/register`.
///
/// Output format matches `xray x25519` (both keys are base64url-no-pad,
/// 43 chars). The field labels (`private_key:` / `public_key:`) are
/// printed by main.rs; this fn returns the raw base64url strings only.
pub fn keygen_x25519() -> (Zeroizing<String>, String) {
    let secret = StaticSecret::random_from_rng(rand::thread_rng());
    let public = PublicKey::from(&secret);
    let private_b64 = Zeroizing::new(base64_url_encode(secret.as_bytes()));
    let public_b64 = base64_url_encode(public.as_bytes());
    (private_b64, public_b64)
}

/// Store a partner-edge x25519 public key in `partner_nodes.reality_pubkey`.
///
/// Validates the key format first (43-char base64url, decodes to 32 bytes).
/// Returns `Ok(())` on success, `Err` if:
///   - The pubkey format is invalid → Err with a format error.
///   - The `node_id` is not found → Err with "node not found: <node_id>".
///   - DB errors are wrapped with context.
pub async fn set_pubkey(pool: &PgPool, node_id: &str, pubkey: &str) -> Result<()> {
    if node_id.is_empty() {
        bail!("node_id must not be empty");
    }

    // Validate format before the DB round-trip.
    validate_pubkey(pubkey)?;

    let res = sqlx::query(
        "UPDATE partner_nodes \
         SET reality_pubkey = $1, reality_pubkey_set_at = NOW() \
         WHERE node_id = $2",
    )
    .bind(pubkey)
    .bind(node_id)
    .execute(pool)
    .await
    .context("update reality_pubkey")?;

    if res.rows_affected() == 0 {
        bail!("node not found: {node_id}");
    }

    Ok(())
}

/// Deactivate a node by deleting its row from partner_nodes. Mirrors the
/// web UI's handleDeleteNode path. The caller is expected to also revoke
/// any still-active tokens separately — this is a two-step by design so
/// operators can inspect the token list before burning credentials.
pub async fn deactivate_node(pool: &PgPool, node_id: &str) -> Result<()> {
    if node_id.is_empty() {
        bail!("node_id must not be empty");
    }
    let res = sqlx::query("DELETE FROM partner_nodes WHERE node_id = $1")
        .bind(node_id)
        .execute(pool)
        .await
        .context("delete partner_nodes row")?;
    if res.rows_affected() == 0 {
        bail!("node not found: {node_id}");
    }
    println!("deactivated: {node_id}");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Golden-value parity test — must match server's partner_registry::creds::hash_token.
    /// REFERENCE: sha256("test-token-fixed")
    /// If this fails, the CLI's hash_token drifted from the server's copy. Fix in lockstep.
    #[test]
    fn hash_token_matches_server_reference() {
        assert_eq!(
            hash_token("test-token-fixed"),
            "f227298136580b1377d03ef38f996e39bc442f9d1afd48069ea842af5d54cd97"
        );
    }

    /// Partner-id rule parity with a downstream admin service
    /// (admin partner-id pattern). Keep the
    /// accept/reject cases identical — the web UI and the CLI must agree
    /// on which IDs are valid.
    #[test]
    fn validate_partner_id_accepts_spec_cases() {
        for ok in ["edge-c", "relay-x", "a1b", "partner-ops"] {
            assert!(validate_partner_id(ok).is_ok(), "expected accept: {ok}");
        }
    }

    #[test]
    fn validate_partner_id_rejects_spec_cases() {
        for bad in [
            "",
            "ab",
            "AB",
            "-edge-c",
            "edge-c-",
            "edge-c/xxx",
            "super_partner",
        ] {
            assert!(
                validate_partner_id(bad).is_err(),
                "expected reject: {bad:?}"
            );
        }
    }

    #[test]
    fn valid_for_bounds_match_web() {
        assert_eq!(MIN_VALID_FOR_SECS, 24 * 3600, "1 day min (web: 1)");
        assert_eq!(MAX_VALID_FOR_SECS, 90 * 24 * 3600, "90 day max (web: 90)");
    }

    /// Verify base64url encoding against the RFC 4648 §5 test vectors.
    #[test]
    fn base64_url_encode_rfc4648_vectors() {
        // (input bytes, expected base64url without padding)
        let cases: &[(&[u8], &str)] = &[
            (b"", ""),
            (b"f", "Zg"),
            (b"fo", "Zm8"),
            (b"foo", "Zm9v"),
            (b"foob", "Zm9vYg"),
            (b"fooba", "Zm9vYmE"),
            (b"foobar", "Zm9vYmFy"),
        ];
        for (input, expected) in cases {
            assert_eq!(base64_url_encode(input), *expected, "base64url({input:?})");
        }
    }

    /// Service token format: `stkn_` prefix + base64url(32 bytes) = 5 + 43 = 48 chars.
    #[test]
    fn generate_service_token_format() {
        let tok = generate_service_token();
        assert!(
            tok.starts_with("stkn_"),
            "service token must start with stkn_, got: {tok}"
        );
        // base64url(32 bytes) = ceil(32*4/3) = 43 chars (no padding).
        let encoded_part = &tok["stkn_".len()..];
        assert_eq!(
            encoded_part.len(),
            43,
            "encoded part must be 43 chars for base64url(32 bytes), got {}",
            encoded_part.len()
        );
        // Must only contain base64url chars.
        assert!(
            encoded_part
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'),
            "encoded part must be base64url, got: {encoded_part}"
        );
    }

    /// Two successive calls must produce different tokens (RNG is live).
    #[test]
    fn generate_service_token_is_random() {
        let t1 = generate_service_token();
        let t2 = generate_service_token();
        assert_ne!(t1, t2, "consecutive tokens must differ");
    }

    /// hash_token applied to a service token must produce the same hash as the
    /// server's hash_service_token — both are SHA-256 hex of the raw bytes.
    /// Golden value: sha256("stkn_test-fixed-value")
    #[test]
    fn service_token_hash_matches_server_scheme() {
        // Compute via sha2 directly to validate our hash_token uses the same scheme.
        use sha2::{Digest, Sha256};
        let raw = "stkn_test-fixed-value";
        let expected = {
            let mut h = Sha256::new();
            h.update(raw.as_bytes());
            format!("{:x}", h.finalize())
        };
        assert_eq!(hash_token(raw), expected);
        assert_eq!(hash_token(raw).len(), 64, "SHA-256 hex must be 64 chars");
    }
}
