#!/bin/bash
# tests/test_refresh_sfu_key_apply.sh — SFU signing-pubkey refresh must have a
# LIVE consumer (epoch_apply_gap fix).
#
# Finding: docker-compose.yml.tpl baked SFU_SIGNING_PUBLIC_KEY as a one-time
# `environment:` literal with NO env_file; oxpulse-partner-edge-refresh.sh
# rewrote sfu-keys.env daily but nothing recreated the SFU, so after any central
# key rotation the SFU kept the stale pubkey forever and every relay JWT
# silently fell back to HS256.
#
# This test asserts the fix end-to-end and goes RED if any piece is reverted:
#   C1 template: sfu service reads the key via env_file (sfu-keys.env) …
#   C2 template: … and NO SFU_SIGNING_PUBLIC_KEY literal under `environment:`
#                (environment overrides env_file → would re-pin the stale key).
#   C3 refresh (real code, docker spied): a simulated rotation recreates the sfu
#      service via `up -d --force-recreate sfu` — NOT a plain `restart` (which
#      does not re-read env_file) — and persists the new sha.
#   C4 refresh (REAL _restart_if_changed + REAL docker, self-skips w/o daemon):
#      the effective container env actually flips PubKeyA → PubKeyB within one
#      apply cycle. This is the "effective env resolves to PubKeyB" proof.
#
# Real-code mandate: C3/C4 source the actual _restart_if_changed from
# oxpulse-partner-edge-refresh.sh (not a hand-copy); reverting the recreate wiring
# turns them RED.
set -uo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/docker-compose.yml.tpl"
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== SFU signing-pubkey apply tests ==="

[[ -f "$TPL" ]]     || { fail "C0: $TPL missing"; exit 1; }
[[ -f "$REFRESH" ]] || { fail "C0: $REFRESH missing"; exit 1; }

# Isolate the sfu service block: from `  sfu:` up to the next top-level service.
SFU_BLOCK=$(sed -n '/^  sfu:/,/^  hysteria2-client:/p' "$TPL")

# ---------------------------------------------------------------------------
# C1: sfu service supplies the signing key via env_file (sfu-keys.env).
# ---------------------------------------------------------------------------
if grep -qE 'env_file:' <<<"$SFU_BLOCK" && grep -qE 'sfu-keys\.env' <<<"$SFU_BLOCK"; then
    pass "C1: sfu service reads the signing key via env_file (sfu-keys.env)"
else
    fail "C1: sfu service has no env_file: referencing sfu-keys.env — the daily key refresh has no consumer"
fi

# ---------------------------------------------------------------------------
# C2: NO SFU_SIGNING_PUBLIC_KEY literal under environment: (it would override
#     env_file in compose precedence and re-pin the stale key).
# ---------------------------------------------------------------------------
if grep -qE '^[[:space:]]+SFU_SIGNING_PUBLIC_KEY:' <<<"$SFU_BLOCK"; then
    fail "C2: SFU_SIGNING_PUBLIC_KEY still declared under environment: — overrides env_file, re-introduces the stale-key bug"
else
    pass "C2: no SFU_SIGNING_PUBLIC_KEY literal under environment: (env_file is the sole source)"
fi

# ---------------------------------------------------------------------------
# C3: behavioral — a simulated rotation drives the REAL _restart_if_changed via
#     the refresh.sh SFU apply wiring, recreating the sfu SERVICE (env_file
#     re-read), not a plain restart. Docker/jq/curl are spied.
# ---------------------------------------------------------------------------
c3() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib"
    : > "$docker_log"

    # A compose file must exist for the SFU apply block to run.
    printf 'services:\n  sfu:\n    image: x\n' > "$etc/docker-compose.yml"
    # Simulate the PRIOR applied key: file=PubKeyA and a matching persisted sha.
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$lib/sfu-keys.env"
    sha256sum "$lib/sfu-keys.env" | awk '{print $1}' > "$lib/sfu-keys.sha"

    # docker spy: log every call; answer the ps state-probe and the gauge probes.
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$*" == *"compose"*" ps "* ]]; then echo '{"State":"running"}'; exit 0; fi
if [[ "\$1" == "ps" && "\$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
if [[ "\$*" == *"printenv"* ]]; then echo "PubKeyB"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    # curl spy: keys endpoint returns PubKeyB + a non-rotating version;
    # heartbeat returns 200.
    cat > "$tmp/shims/curl" <<'CURL'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/api/partner/heartbeat"* ]]; then printf 'ok\n200'; exit 0; fi
if [[ "$args" == *"/api/partner/keys"* ]]; then
  printf '%s' '{"version":"v1","channels_version":"none","sfu_signing_public_key":"PubKeyB","reality_public_key":"rk","reality_encryption":"re","reality_server_names":["a"]}'
  exit 0
fi
exit 0
CURL
    chmod +x "$tmp/shims/curl"

    printf '{"node_id":"test-node"}\n' > "$etc/node-config.json"
    printf 'v1\n' > "$lib/keys-version"   # NEW_VERSION==CURRENT → no Reality rotation churn

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    local ok=1
    if ! grep -qE 'compose .*up -d --no-deps --force-recreate sfu' "$docker_log"; then
        fail "C3: refresh did NOT recreate the sfu service on key change (up -d --force-recreate sfu absent) — dead producer"
        ok=0
    fi
    # Must NOT use a plain `restart` for sfu (would keep the old baked env).
    if grep -qE 'compose .*restart sfu' "$docker_log"; then
        fail "C3: refresh used 'docker compose restart sfu' — restart does NOT re-read env_file, key never applied"
        ok=0
    fi
    # sha persisted to the NEW key → next cycle won't needlessly recreate.
    local want_sha; want_sha=$(printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyB\n' | sha256sum | awk '{print $1}')
    if [[ "$(cat "$lib/sfu-keys.sha" 2>/dev/null)" != "$want_sha" ]]; then
        fail "C3: sfu-keys.sha not advanced to the new key after successful recreate"
        ok=0
    fi
    # applied-vs-written gauge emitted =1 (live PubKeyB == written PubKeyB).
    local g="$tmp/textfile/partner_edge_sfu_pubkey_applied.prom"
    if [[ ! -f "$g" ]] || ! grep -qE 'partner_edge_sfu_pubkey_applied\{[^}]*\} 1' "$g"; then
        fail "C3: partner_edge_sfu_pubkey_applied gauge not emitted =1 after apply"
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "C3: rotation → real refresh recreates sfu (env_file re-read), sha advanced, gauge=1"
    rm -rf "$tmp"
}
c3

# ---------------------------------------------------------------------------
# C4: end-to-end with REAL docker + REAL _restart_if_changed — the container's
#     effective env flips PubKeyA → PubKeyB. Self-skips without a daemon.
# ---------------------------------------------------------------------------
c4() {
    if ! docker info >/dev/null 2>&1; then
        echo "SKIP: C4 (docker daemon unreachable) — env_file recreate proof not run"
        return 0
    fi
    local tmp; tmp=$(mktemp -d)
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$etc" "$lib"
    # sfu-keys.env co-located with the compose file (sandbox); env_file long-form
    # mirrors the real template. Service name `sfu`, container name distinct.
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$etc/sfu-keys.env"
    cat > "$etc/docker-compose.yml" <<'YML'
name: sfu-apply-c4
services:
  sfu:
    image: busybox:latest
    container_name: sfu-apply-c4-sfu
    env_file:
      - path: ./sfu-keys.env
        required: false
    command: ["sh", "-c", "sleep 300"]
YML
    ( cd "$etc" && docker compose up -d >/dev/null 2>&1 )
    local before; before=$(docker exec sfu-apply-c4-sfu printenv SFU_SIGNING_PUBLIC_KEY 2>/dev/null)

    # Rotate the key on disk, then drive the REAL apply helper from refresh.sh.
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyB\n' > "$etc/sfu-keys.env"
    (
        set +e
        log() { :; }
        # Both are consumed by the sourced production _restart_if_changed.
        # shellcheck disable=SC2034
        PREFIX_LIB="$lib"
        # shellcheck disable=SC2034
        LOG_FILE="/dev/null"
        # shellcheck disable=SC1090
        source <(sed -n '/^_restart_if_changed()/,/^}/p' "$REFRESH")
        _restart_if_changed sfu "$etc/sfu-keys.env" "$lib/sfu-keys.sha" "$etc/docker-compose.yml" sfu recreate
    )
    local after; after=$(docker exec sfu-apply-c4-sfu printenv SFU_SIGNING_PUBLIC_KEY 2>/dev/null)
    ( cd "$etc" && docker compose down >/dev/null 2>&1 )

    if [[ "$before" == "PubKeyA" && "$after" == "PubKeyB" ]]; then
        pass "C4: real recreate flipped the container env PubKeyA → PubKeyB (effective env resolves to PubKeyB)"
    else
        fail "C4: container env did not flip (before='$before' after='$after') — recreate did not re-read env_file"
    fi
    rm -rf "$tmp"
}
c4

echo ""
echo "=== SFU signing-pubkey apply: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
