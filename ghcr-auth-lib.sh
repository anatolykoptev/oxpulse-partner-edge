#!/usr/bin/env bash
# ghcr-auth-lib.sh — shared GHCR (ghcr.io) docker registry auth helpers
# for install.sh / upgrade.sh / oxpulse-partner-edge-refresh.sh.
#
# Why this lib exists:
#   ghcr.io packages (partner-edge-sfu, -caddy, -coturn, -xray) are private
#   by default. Anonymous `docker pull` returns 401. Edges must
#   `docker login ghcr.io` with a Personal Access Token (PAT) holding
#   `read:packages` scope.
#
#   Before this lib: install.sh expected the operator to run
#   `docker login ghcr.io` manually before installing. There was no
#   re-login or rotation path. When the PAT expired (or a new install
#   was performed without prior manual login), pulls silently failed
#   with "denied: denied" and upgrade.sh aborted before recreating
#   containers. Diagnosed 2026-05-15 on rvpn (token expired between
#   v0.12.26 and v0.12.27 release).
#
# After this lib:
#   - operator supplies token via `--ghcr-token=ghp_xxxxx` on install.sh
#     or upgrade.sh (or via env `OXPULSE_GHCR_TOKEN`)
#   - token persisted to /etc/oxpulse-partner-edge/ghcr.token (mode 0600,
#     root-only). NEVER printed back, never echoed in logs.
#   - upgrade.sh / refresh.sh re-login from that file before every pull.
#   - if the token file is absent OR the login fails, pull is attempted
#     anonymously (which works iff the package is public). On 401/denied,
#     a clear error directs the operator to provide --ghcr-token=.
#
# Public functions (called by install.sh / upgrade.sh / refresh.sh):
#   ghcr_save_token <token>      — chmod 600 write to GHCR_TOKEN_FILE.
#                                  Replaces any existing token.
#   ghcr_login_from_file         — if GHCR_TOKEN_FILE exists, `docker login`
#                                  ghcr.io. Returns 0 on success or "no file"
#                                  (no-op), 1 on login failure (caller decides).
#   ghcr_pull_diagnose <output>  — given `docker pull` stderr, recognise
#                                  "denied" / "unauthorized" / "401" patterns
#                                  and print actionable hint pointing at
#                                  --ghcr-token=. Returns 0 if hint printed.
#   ghcr_token_file_exists       — predicate. Returns 0 if file exists.
#
# Security notes:
#   - The token file is mode 0600 and root-owned.
#   - We use `--password-stdin` so the token never appears in `ps aux`.
#   - Errors from `docker login` are filtered to NOT echo the token even
#     if docker decides to print partial credentials.

# Token storage path. Override via env for tests.
GHCR_TOKEN_FILE="${GHCR_TOKEN_FILE:-/etc/oxpulse-partner-edge/ghcr.token}"

# Docker username for ghcr login. We default to the package owner —
# any non-empty string works for token-based auth on ghcr.io but the
# convention is to use the GitHub username the token belongs to.
GHCR_REGISTRY="${GHCR_REGISTRY:-ghcr.io}"
GHCR_USER="${GHCR_USER:-anatolykoptev}"

# --- Internal helpers ---

# Echo helpers that route to stderr so caller can capture stdout cleanly.
_ghcr_log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
_ghcr_warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }

# --- Public API ---

ghcr_token_file_exists() {
    [[ -s "$GHCR_TOKEN_FILE" ]]
}

# Save the supplied token to GHCR_TOKEN_FILE with strict perms.
# Caller MUST have already validated that $1 is non-empty.
ghcr_save_token() {
    local token="$1"
    if [[ -z "$token" ]]; then
        _ghcr_warn "ghcr_save_token: empty token, refusing to write"
        return 1
    fi
    local dir
    dir=$(dirname "$GHCR_TOKEN_FILE")
    mkdir -p "$dir"
    # Atomic write: temp file with strict mode, then rename.
    local tmp="${GHCR_TOKEN_FILE}.tmp"
    umask 077
    printf '%s\n' "$token" > "$tmp"
    chmod 0600 "$tmp"
    mv "$tmp" "$GHCR_TOKEN_FILE"
    _ghcr_log "ghcr: token saved to $GHCR_TOKEN_FILE (mode 0600)"
}

# Read the token file and `docker login` against ghcr.io.
# Returns:
#   0  — login succeeded OR token file absent (caller decides whether
#        anonymous pull is acceptable). Distinguish via ghcr_token_file_exists.
#   1  — token file present but login failed (bad token, network, etc.).
ghcr_login_from_file() {
    if ! ghcr_token_file_exists; then
        return 0
    fi
    # --password-stdin keeps the token out of `ps aux`.
    # Capture stderr for filtered logging (never include the token).
    local login_err
    if ! login_err=$(docker login "$GHCR_REGISTRY" -u "$GHCR_USER" \
        --password-stdin < "$GHCR_TOKEN_FILE" 2>&1 > /dev/null); then
        # Strip anything that might smell like a token (long alnum strings).
        local sanitised
        sanitised=$(printf '%s\n' "$login_err" | sed -E 's/(gh[ps]_)[A-Za-z0-9_]{20,}/\1***REDACTED***/g')
        _ghcr_warn "ghcr: docker login failed: $sanitised"
        return 1
    fi
    _ghcr_log "ghcr: docker login OK ($GHCR_REGISTRY as $GHCR_USER)"
    return 0
}

# Pretty-print an actionable hint when `docker pull` fails with a denied/
# unauthorised error. Caller passes the captured stderr/stdout of pull.
# Returns 0 if a hint was printed (caller should not print a generic error),
# 1 if the output does not match a denied pattern (caller prints own error).
ghcr_pull_diagnose() {
    local out="${1:-}"
    if [[ -z "$out" ]]; then
        return 1
    fi
    if ! grep -qiE 'denied|unauthorized|401|forbidden|requires.*login' <<< "$out"; then
        return 1
    fi
    cat <<HINT >&2

ghcr: docker pull was denied by the registry.

GHCR images (ghcr.io/anatolykoptev/partner-edge-*) are private. The edge
must docker-login with a Personal Access Token that has 'read:packages'
scope. Two ways to provide one:

  1. CLI flag:
       sudo oxpulse-partner-edge-upgrade --ghcr-token=ghp_xxxxx vX.Y.Z
       # token is saved to $GHCR_TOKEN_FILE (mode 0600) for future runs.

  2. Environment variable (one-shot, not persisted):
       sudo OXPULSE_GHCR_TOKEN=ghp_xxxxx oxpulse-partner-edge-upgrade vX.Y.Z

  3. Manual docker login (legacy path):
       echo ghp_xxxxx | sudo docker login ghcr.io -u <username> --password-stdin
       # then re-run upgrade.

Generate a token: https://github.com/settings/tokens with scope read:packages.

HINT
    return 0
}

# Convenience wrapper used by callers that have a token already on hand
# (e.g. --ghcr-token= flag handler). Validates non-empty, saves, logs in.
# Returns 0 on full success, non-zero on save or login failure.
ghcr_configure_token() {
    local token="$1"
    if [[ -z "$token" ]]; then
        _ghcr_warn "ghcr_configure_token: empty token"
        return 1
    fi
    ghcr_save_token "$token" || return 1
    ghcr_login_from_file || return 1
    return 0
}
