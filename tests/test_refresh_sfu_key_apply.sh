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
#   C4 refresh (REAL _docker_restart_if_sha_changed + REAL docker, self-skips
#      w/o daemon): the effective container env actually flips PubKeyA →
#      PubKeyB within one apply cycle. This is the "effective env resolves to
#      PubKeyB" proof.
#
# Real-code mandate: C3/C4 source the actual _docker_restart_if_sha_changed
# from lib/surgical-restart-lib.sh (not a hand-copy; P2 of the 2026-07-08
# refresh-lib-extraction-strangler plan moved the mechanism there — see
# ADR-9); reverting the recreate wiring turns them RED.
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

    # A compose file must exist AND be env_file-wired for the SFU apply block to
    # recreate (Review HIGH gate: an unwired live compose is skipped, not recreated
    # — see C6). Mirrors the real template's long-form env_file stanza.
    cat > "$etc/docker-compose.yml" <<'YML'
services:
  sfu:
    image: x
    env_file:
      - path: ./sfu-keys.env
        required: false
  hysteria2-client:
    image: y
YML
    # Simulate the PRIOR applied key: file=PubKeyA and a matching persisted sha.
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$lib/sfu-keys.env"
    sha256sum "$lib/sfu-keys.env" | awk '{print $1}' > "$lib/sfu-keys.sha"

    # docker spy: log every call; answer the inspect liveness-probe and the gauge probes.
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" && "\$*" == *"{{.State.Running}}"* ]]; then echo "true"; exit 0; fi
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
    # Format: refresh.sh now single-quotes the value (matches opec's
    # write_env_file — see the CWE-116/943 fix in oxpulse-partner-edge-refresh.sh's
    # SFU-key write block), not the old bare KEY=VALUE.
    local want_sha; want_sha=$(printf "SFU_SIGNING_PUBLIC_KEY='PubKeyB'\n" | sha256sum | awk '{print $1}')
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
    # Capture the apply's diagnostics (docker force-recreate stderr goes to
    # `2>>"$LOG_FILE"` inside _docker_restart_if_sha_changed; the helper's
    # WARNING lines go through log()). Route both to a real file so a FAILURE
    # below can surface the underlying docker error instead of swallowing it
    # to /dev/null.
    #
    # P2 strangler extraction (2026-07-08 plan, ADR-9): the pure mechanism now
    # lives in lib/surgical-restart-lib.sh as `_docker_restart_if_sha_changed`
    # — source the lib directly instead of sed-range-extracting
    # `_restart_if_changed` from refresh.sh (the function no longer lives
    # there; that sed range would now silently source nothing). This call
    # also proves the SFU caller's new shape: no channels-status.env gate is
    # consulted at all (the pure fn has zero knowledge of that file — see the
    # lib's own header), matching the production call site's
    # caller-omits-the-check posture.
    local apply_log="$tmp/c4-apply.log"; : > "$apply_log"
    (
        set +e
        log() { printf '%s\n' "$*" >> "$apply_log"; }
        # Both are consumed by the sourced production _docker_restart_if_sha_changed.
        # shellcheck disable=SC2034
        PREFIX_LIB="$lib"
        # shellcheck disable=SC2034
        LOG_FILE="$apply_log"
        # shellcheck disable=SC1090
        source "$REPO_ROOT/lib/surgical-restart-lib.sh"
        # 7th arg = the real container_name so the post-recreate `docker inspect
        # --format {{.State.Running}}` liveness check resolves and the sha advances.
        _docker_restart_if_sha_changed sfu "$etc/sfu-keys.env" "$lib/sfu-keys.sha" "$etc/docker-compose.yml" sfu recreate sfu-apply-c4-sfu
    )
    local after; after=$(docker exec sfu-apply-c4-sfu printenv SFU_SIGNING_PUBLIC_KEY 2>/dev/null)
    ( cd "$etc" && docker compose down >/dev/null 2>&1 )

    local want_sha; want_sha=$(printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyB\n' | sha256sum | awk '{print $1}')
    local got_sha; got_sha=$(cat "$lib/sfu-keys.sha" 2>/dev/null || printf '')
    if [[ "$before" == "PubKeyA" && "$after" == "PubKeyB" && "$got_sha" == "$want_sha" ]]; then
        pass "C4: real recreate flipped the container env PubKeyA → PubKeyB and docker-inspect liveness advanced the sha"
    else
        local _diag; _diag=$(tr '\n' '|' < "$apply_log" 2>/dev/null)
        fail "C4: recreate/inspect path broken (before='$before' after='$after' sha_ok=$([[ "$got_sha" == "$want_sha" ]] && echo 1 || echo 0)) — apply log: ${_diag:-<empty>}"
    fi
    rm -rf "$tmp"
}
c4

# ---------------------------------------------------------------------------
# C5: the applied-vs-written gauge (REAL _emit_sfu_applied_gauge) must treat an
#     opec-authored single-quoted sfu-keys.env as EQUAL to the bare live env.
#     opec (crates/opec/src/secrets/sfu_key.rs::write_env_file) writes the key
#     single-quoted; docker compose env_file strips the quotes, so the container's
#     live env is bare. This branch is reachable in production whenever a daily
#     refresh does NOT rewrite sfu-keys.env (e.g. the /api/partner/keys response
#     omits sfu_signing_public_key), leaving opec's single-quoted file in place
#     while _emit_sfu_applied_gauge still runs. Removing the quote-stripping turns
#     this RED (written='PubKeyA' != live PubKeyA → gauge=0).
# ---------------------------------------------------------------------------
c5() {
    local tmp; tmp=$(mktemp -d)
    local lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$lib" "$tmp/textfile"
    # opec representation: single-quoted value.
    printf "SFU_SIGNING_PUBLIC_KEY='PubKeyA'\n" > "$lib/sfu-keys.env"

    # docker spy: container present; printenv returns the BARE value (compose
    # env_file strips the surrounding quotes at injection time).
    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$1" == "ps" && "$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
if [[ "$*" == *"printenv"* ]]; then echo "PubKeyA"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    (
        set +e
        # shellcheck disable=SC2034
        NODE_ID="test-node"
        # shellcheck disable=SC2034
        SFU_KEYS_ENV="$lib/sfu-keys.env"
        # emit_gauge (now lib/metric-sink-lib.sh) resolves its textfile dir via
        # PARTNER_EDGE_TEXTFILE_DIR directly (not the caller's $TEXTFILE_DIR
        # local), matching lib/reconcile.sh's _reconcile_emit_prom_gauge.
        # shellcheck disable=SC2034
        PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile"
        # _emit_sfu_applied_gauge reads SFU_CONTAINER_NAME (top-level const in refresh.sh)
        # for its `docker ps` filter + `docker exec` target; define it here because we
        # source the function in isolation, without the script's top-level constants.
        # shellcheck disable=SC2034
        SFU_CONTAINER_NAME="oxpulse-partner-sfu"
        log() { :; }
        export PATH="$tmp/shims:$PATH"
        # Source the REAL gauge helpers. emit_gauge moved to
        # lib/metric-sink-lib.sh (P1 of the 2026-07-08 refresh-lib-
        # extraction-strangler plan); _emit_sfu_applied_gauge stays inline in
        # refresh.sh (ADR-4) and is still sed-extracted from there.
        # shellcheck disable=SC1090
        source "$REPO_ROOT/lib/metric-sink-lib.sh"
        # shellcheck disable=SC1090
        source <(sed -n '/^_emit_sfu_applied_gauge()/,/^}/p' "$REFRESH")
        _emit_sfu_applied_gauge
    )

    local g="$tmp/textfile/partner_edge_sfu_pubkey_applied.prom"
    if [[ -f "$g" ]] && grep -qE 'partner_edge_sfu_pubkey_applied\{[^}]*\} 1' "$g"; then
        pass "C5: single-quoted (opec) sfu-keys.env compares equal to the bare live env → gauge=1"
    else
        fail "C5: single-quoted opec key mis-compared against the bare live env (quote-stripping broken) — gauge not =1"
    fi
    rm -rf "$tmp"
}
c5

# ---------------------------------------------------------------------------
# C6: Review HIGH regression guard — an already-deployed node whose LIVE compose
#     has NO env_file wiring for sfu MUST NOT be force-recreated (that would drop
#     live WebRTC media for zero benefit: upgrade.sh ships the new refresh.sh but
#     never re-renders compose to add env_file, so this pairing is real). The
#     refresh must SKIP + WARN, and the applied gauge must still report 0 so the
#     epoch_apply_gap stays visible. Removing the wiring gate turns this RED.
# ---------------------------------------------------------------------------
c6() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib"
    : > "$docker_log"

    # UNWIRED compose: sfu service with NO env_file (an old on-disk compose that
    # upgrade.sh left untouched — it only sed-patches image tags).
    printf 'services:\n  sfu:\n    image: x\n  hysteria2-client:\n    image: y\n' > "$etc/docker-compose.yml"
    # Prior applied key on disk = PubKeyA + matching sha.
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$lib/sfu-keys.env"
    sha256sum "$lib/sfu-keys.env" | awk '{print $1}' > "$lib/sfu-keys.sha"

    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" && "\$*" == *"{{.State.Running}}"* ]]; then echo "true"; exit 0; fi
if [[ "\$1" == "ps" && "\$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
# live container still carries the STALE key (unwired → env_file never took effect).
if [[ "\$*" == *"printenv"* ]]; then echo "PubKeyA"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

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
    printf 'v1\n' > "$lib/keys-version"

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    local ok=1
    if grep -qE 'compose .*--force-recreate sfu' "$docker_log"; then
        fail "C6: refresh force-recreated an UNWIRED sfu — would drop live media for zero benefit (wiring gate missing)"
        ok=0
    fi
    if ! grep -qE 'no env_file wiring for sfu-keys.env' "$tmp/refresh.log"; then
        fail "C6: refresh did not WARN about the unwired compose — silent skip"
        ok=0
    fi
    local g="$tmp/textfile/partner_edge_sfu_pubkey_applied.prom"
    if [[ ! -f "$g" ]] || ! grep -qE 'partner_edge_sfu_pubkey_applied\{[^}]*\} 0' "$g"; then
        fail "C6: applied gauge not =0 on an unwired node — the epoch_apply_gap is invisible"
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "C6: unwired live compose → recreate SKIPPED + WARN + gauge=0 (no live-media drop)"
    rm -rf "$tmp"
}
c6

# ---------------------------------------------------------------------------
# C7: compose present but sfu-keys.env absent (opec key fetch failed / no key
#     ever returned) MUST surface a WARNING — not a silent no-op invisible to
#     both logs and metrics (review LOW findings 3 & 4).
# ---------------------------------------------------------------------------
c7() {
    local tmp; tmp=$(mktemp -d)
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib"

    # Wired compose present; sfu-keys.env deliberately ABSENT.
    cat > "$etc/docker-compose.yml" <<'YML'
services:
  sfu:
    image: x
    env_file:
      - path: ./sfu-keys.env
        required: false
YML

    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$1" == "ps" && "$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    # keys response WITHOUT sfu_signing_public_key → refresh writes no sfu-keys.env.
    cat > "$tmp/shims/curl" <<'CURL'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/api/partner/heartbeat"* ]]; then printf 'ok\n200'; exit 0; fi
if [[ "$args" == *"/api/partner/keys"* ]]; then
  printf '%s' '{"version":"v1","channels_version":"none","reality_public_key":"rk","reality_encryption":"re","reality_server_names":["a"]}'
  exit 0
fi
exit 0
CURL
    chmod +x "$tmp/shims/curl"

    printf '{"node_id":"test-node"}\n' > "$etc/node-config.json"
    printf 'v1\n' > "$lib/keys-version"

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    if grep -qE 'sfu-keys.env not found' "$tmp/refresh.log"; then
        pass "C7: compose present + sfu-keys.env absent → explicit WARNING (not a silent no-op)"
    else
        fail "C7: missing sfu-keys.env produced no log line — invisible to logs & metrics"
    fi
    rm -rf "$tmp"
}
c7

# ---------------------------------------------------------------------------
# C8: when the recreate command FAILS, the failure log must name the recreate
#     path (up -d --force-recreate), NOT 'restart' — so on-call triage of an
#     apply_mode=recreate failure is not misdirected (review LOW). Drives the
#     REAL _restart_if_changed in recreate mode with a failing docker.
# ---------------------------------------------------------------------------
c8() {
    local tmp; tmp=$(mktemp -d)
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib"
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyB\n' > "$etc/sfu-keys.env"

    # docker spy: FAIL the force-recreate, succeed everything else.
    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$*" == *"--force-recreate"* ]]; then echo "recreate boom" >&2; exit 1; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    # P2 strangler extraction (2026-07-08 plan, ADR-9): source the pure
    # mechanism directly from lib/surgical-restart-lib.sh as
    # `_docker_restart_if_sha_changed` instead of sed-range-extracting
    # `_restart_if_changed` from refresh.sh. PREFIX_LIB is set here only as a
    # harmless leftover ambient var — the pure fn never reads
    # channels-status.env (or any file under PREFIX_LIB) at all.
    (
        set +e
        export PATH="$tmp/shims:$PATH"
        # shellcheck disable=SC2034
        PREFIX_LIB="$lib"
        LOG_FILE="$tmp/refresh.log"
        log() { echo "$*" >> "$LOG_FILE"; }
        # shellcheck disable=SC1090
        source "$REPO_ROOT/lib/surgical-restart-lib.sh"
        _docker_restart_if_sha_changed sfu "$etc/sfu-keys.env" "$lib/sfu-keys.sha" "$etc/docker-compose.yml" sfu recreate oxpulse-partner-sfu
    )

    local ok=1
    if ! grep -qE 'force-recreate sfu failed' "$tmp/refresh.log"; then
        fail "C8: recreate-failure log did not name the force-recreate path"
        ok=0
    fi
    if grep -qE 'compose restart sfu failed' "$tmp/refresh.log"; then
        fail "C8: recreate failure misreported as a 'restart' failure — misleading triage"
        ok=0
    fi
    if [[ -s "$lib/sfu-keys.sha" ]]; then
        fail "C8: sha advanced despite a failed recreate — next cycle would skip the retry"
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "C8: recreate failure logs the force-recreate path (not 'restart') + sha not advanced"
    rm -rf "$tmp"
}
c8

# ---------------------------------------------------------------------------
# C9: decoupling guard — the SFU key-apply must NOT be gated by channels-status.env.
#     That file's status vocabulary is written by the channel-provisioning surface
#     (xray/naive/hysteria2/…) and has no `sfu` notion; a stray/hand-edited
#     `sfu=inactive` line there must NOT silently suppress a signing-key recreate.
#     P2 strangler extraction (2026-07-08 plan, ADR-9): the production call site
#     calls the PURE `_docker_restart_if_sha_changed` (lib/surgical-restart-lib.sh)
#     directly, entirely OMITTING the channels-status.env gate check — rather
#     than the prior `_restart_if_changed`'s 8th `skip_channel_status`
#     bypass-flag arg (a Fowler flag-argument smell the council flagged; see
#     the lib's own header). This drives the REAL refresh with `sfu=inactive`
#     present and asserts the recreate STILL fires. Re-routing the SFU caller
#     through the gated `_channel_restart_if_changed` wrapper re-couples SFU
#     to the channel gate → the recreate would be skipped → this turns RED.
# ---------------------------------------------------------------------------
c9() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib"
    : > "$docker_log"

    # Wired compose (mirrors the real template) so the apply block reaches recreate.
    cat > "$etc/docker-compose.yml" <<'YML'
services:
  sfu:
    image: x
    env_file:
      - path: ./sfu-keys.env
        required: false
  hysteria2-client:
    image: y
YML
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$lib/sfu-keys.env"
    sha256sum "$lib/sfu-keys.env" | awk '{print $1}' > "$lib/sfu-keys.sha"
    # The trap: channels-status.env marks sfu inactive. The gated
    # _channel_restart_if_changed wrapper would skip here; the production SFU
    # call site must bypass it entirely (calls the pure fn directly).
    printf 'sfu=inactive\n' > "$lib/channels-status.env"

    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" && "\$*" == *"{{.State.Running}}"* ]]; then echo "true"; exit 0; fi
if [[ "\$1" == "ps" && "\$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
if [[ "\$*" == *"printenv"* ]]; then echo "PubKeyB"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

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
    printf 'v1\n' > "$lib/keys-version"

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    local ok=1
    if ! grep -qE 'compose .*up -d --no-deps --force-recreate sfu' "$docker_log"; then
        fail "C9: sfu recreate was suppressed by channels-status.env (sfu=inactive) — the key-apply is wrongly coupled to the channel gate"
        ok=0
    fi
    # The channel-status skip line must NOT appear for the sfu apply.
    if grep -qE '\[surgical\] channel sfu status=inactive' "$tmp/refresh.log"; then
        fail "C9: sfu apply went through the gated _channel_restart_if_changed wrapper and hit the inactive skip — must call _docker_restart_if_sha_changed directly"
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "C9: sfu key-apply ignores channels-status.env (sfu=inactive) → recreate still fires"
    rm -rf "$tmp"
}
c9

# ---------------------------------------------------------------------------
# C10: transient-exec guard — when the container is present but `docker exec
#      printenv` returns non-zero (mid-startup after a force-recreate, daemon
#      hiccup), the applied gauge must be SKIPPED, not emitted =0 with a false
#      stale-key WARNING. Drives the REAL _emit_sfu_applied_gauge with a printenv
#      that fails. Reverting to `_live=$(... || true)` emits a false 0 → RED.
# ---------------------------------------------------------------------------
c10() {
    local tmp; tmp=$(mktemp -d)
    local lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$lib" "$tmp/textfile"
    printf 'SFU_SIGNING_PUBLIC_KEY=PubKeyA\n' > "$lib/sfu-keys.env"

    # docker spy: container present, but the exec/printenv FAILS (exit 1, no output).
    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$1" == "ps" && "$*" == *"{{.Names}}"* ]]; then echo "oxpulse-partner-sfu"; exit 0; fi
if [[ "$*" == *"printenv"* ]]; then exit 1; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    (
        set +e
        # shellcheck disable=SC2034
        NODE_ID="test-node"
        # shellcheck disable=SC2034
        SFU_KEYS_ENV="$lib/sfu-keys.env"
        # emit_gauge (now lib/metric-sink-lib.sh) resolves its textfile dir via
        # PARTNER_EDGE_TEXTFILE_DIR directly (not the caller's $TEXTFILE_DIR
        # local), matching lib/reconcile.sh's _reconcile_emit_prom_gauge.
        # shellcheck disable=SC2034
        PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile"
        # _emit_sfu_applied_gauge reads SFU_CONTAINER_NAME (top-level const in refresh.sh);
        # define it here because we source the function without the top-level constants.
        # shellcheck disable=SC2034
        SFU_CONTAINER_NAME="oxpulse-partner-sfu"
        log() { :; }
        export PATH="$tmp/shims:$PATH"
        # shellcheck disable=SC1090
        source <(sed -n '/^emit_gauge()/,/^}/p' "$REFRESH")
        # shellcheck disable=SC1090
        source <(sed -n '/^_emit_sfu_applied_gauge()/,/^}/p' "$REFRESH")
        _emit_sfu_applied_gauge
    )

    local g="$tmp/textfile/partner_edge_sfu_pubkey_applied.prom"
    if [[ -f "$g" ]]; then
        fail "C10: applied gauge emitted on a failed docker-exec read — a transient exec failure was misreported as a stale-key mismatch (gauge=$(grep -oE '[01]$' "$g" | tail -n1))"
    else
        pass "C10: failed docker-exec read → applied gauge SKIPPED (no false stale-key 0)"
    fi
    rm -rf "$tmp"
}
c10

# ---------------------------------------------------------------------------
# C11: _sfu_env_file_wired robustness — the wiring detector must resolve wired=true
#      when `sfu` is the LAST service in the compose file (its block is terminated
#      by EOF, not a following 2-space sibling), AND must NOT false-match a
#      sfu-keys.env reference that lives in a DIFFERENT (later) service's env_file.
#      Drives the REAL _sfu_env_file_wired sourced from refresh.sh. An awk change
#      that resets the found-latch on the wrong boundary turns this RED.
# ---------------------------------------------------------------------------
c11() {
    local tmp; tmp=$(mktemp -d)
    # shellcheck disable=SC1090
    source <(sed -n '/^_sfu_env_file_wired()/,/^}/p' "$REFRESH")

    # Case 1: sfu is the LAST service, env_file wired to sfu-keys.env.
    cat > "$tmp/sfu_last.yml" <<'YML'
services:
  caddy:
    image: c
  sfu:
    image: s
    env_file:
      - path: ./sfu-keys.env
        required: false
YML
    local ok=1
    if ! _sfu_env_file_wired "$tmp/sfu_last.yml"; then
        fail "C11: sfu-last compose reported UNWIRED — env_file detector loses the sfu block at EOF (would skip a legitimate recreate)"
        ok=0
    fi

    # Case 2: sfu has no env_file; a LATER service references sfu-keys.env. Must
    # NOT false-match (the sfu service itself is unwired).
    cat > "$tmp/sfu_mid_falsematch.yml" <<'YML'
services:
  sfu:
    image: s
  xray:
    image: x
    env_file:
      - path: ./sfu-keys.env
        required: false
YML
    if _sfu_env_file_wired "$tmp/sfu_mid_falsematch.yml"; then
        fail "C11: another service's env_file referencing sfu-keys.env false-matched as sfu wired"
        ok=0
    fi

    [[ "$ok" -eq 1 ]] && pass "C11: env_file wiring detector is robust to sfu-last (EOF-terminated) + rejects a sibling's sfu-keys.env reference"
    rm -rf "$tmp"
}
c11

# ---------------------------------------------------------------------------
# C12: injection defense (CWE-116/943) — the /api/partner/keys endpoint is
#      unauthenticated, so its response is untrusted input. A
#      sfu_signing_public_key value carrying an embedded newline that spells out
#      a second `SFU_SIGNING_PUBLIC_KEY=` assignment must NOT be able to inject
#      an extra line into sfu-keys.env: the file must always come out as exactly
#      one physical line, with exactly one line matching the key prefix, and the
#      literal attacker payload must never land as its own assignment. A plain
#      `printf '...%s...' "$val" > file` (the pre-fix code) fails this.
# ---------------------------------------------------------------------------
c12() {
    local tmp; tmp=$(mktemp -d)
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib" "$tmp/textfile"

    # No docker-compose.yml → the apply/recreate block skips harmlessly; this
    # case isolates the extraction+write step itself. The JSON value below
    # decodes (via jq -r) to a real embedded newline followed by a forged
    # second-assignment line.
    cat > "$tmp/shims/curl" <<'CURL'
#!/usr/bin/env bash
args="$*"
if [[ "$args" == *"/api/partner/heartbeat"* ]]; then printf 'ok\n200'; exit 0; fi
if [[ "$args" == *"/api/partner/keys"* ]]; then
  printf '%s' '{"version":"v1","channels_version":"none","sfu_signing_public_key":"PubKeyB\nSFU_SIGNING_PUBLIC_KEY=evil","reality_public_key":"rk","reality_encryption":"re","reality_server_names":["a"]}'
  exit 0
fi
exit 0
CURL
    chmod +x "$tmp/shims/curl"

    printf '{"node_id":"test-node"}\n' > "$etc/node-config.json"
    printf 'v1\n' > "$lib/keys-version"

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    local ok=1
    local f="$lib/sfu-keys.env"
    if [[ ! -f "$f" ]]; then
        fail "C12: sfu-keys.env not written at all"
        ok=0
    else
        local lines matches
        lines=$(wc -l < "$f")
        matches=$(grep -c '^SFU_SIGNING_PUBLIC_KEY=' "$f")
        if [[ "$lines" -ne 1 ]]; then
            fail "C12: sfu-keys.env has $lines physical lines (want 1) — an embedded newline in the untrusted backend value split the file"
            ok=0
        fi
        if [[ "$matches" -ne 1 ]]; then
            fail "C12: sfu-keys.env has $matches lines matching ^SFU_SIGNING_PUBLIC_KEY= (want exactly 1) — attacker-controlled value injected a second key assignment"
            ok=0
        fi
        if grep -qE '^SFU_SIGNING_PUBLIC_KEY=evil' "$f"; then
            fail "C12: attacker-injected 'SFU_SIGNING_PUBLIC_KEY=evil' landed as its own assignment in sfu-keys.env"
            ok=0
        fi
    fi
    [[ "$ok" -eq 1 ]] && pass "C12: embedded-newline pubkey value is safely encoded — exactly one physical line, exactly one SFU_SIGNING_PUBLIC_KEY= assignment, no injected second line"
    rm -rf "$tmp"
}
c12

# ---------------------------------------------------------------------------
# C13: atomicity — a write failure mid-persist (mktemp unable to create the tmp
#      file: disk full, quota, permission) must NEVER leave sfu-keys.env
#      truncated or partially written; the prior good content must survive
#      byte-for-byte, and the failure must be logged (not silent). The pre-fix
#      code (`printf ... > "$SFU_KEYS_ENV"`) does not route through mktemp at
#      all, so stubbing mktemp has no effect on it and the file gets clobbered
#      with the new (unverified) content regardless — this turns RED on that
#      code.
# ---------------------------------------------------------------------------
c13() {
    local tmp; tmp=$(mktemp -d)
    local etc="$tmp/etc" lib="$tmp/lib"
    mkdir -p "$tmp/shims" "$etc" "$lib" "$tmp/textfile"

    printf "SFU_SIGNING_PUBLIC_KEY='PubKeyA'\n" > "$lib/sfu-keys.env"
    local before_sha; before_sha=$(sha256sum "$lib/sfu-keys.env" | awk '{print $1}')

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

    # mktemp stubbed to fail unconditionally — deterministic stand-in for
    # disk-full/permission/quota mid-write.
    cat > "$tmp/shims/mktemp" <<'MKTEMPSTUB'
#!/bin/sh
echo "mktemp: cannot create: Permission denied" >&2
exit 1
MKTEMPSTUB
    chmod +x "$tmp/shims/mktemp"

    printf '{"node_id":"test-node"}\n' > "$etc/node-config.json"
    printf 'v1\n' > "$lib/keys-version"

    PATH="$tmp/shims:$PATH" \
    PARTNER_EDGE_PREFIX_ETC="$etc" \
    PARTNER_EDGE_PREFIX_LIB="$lib" \
    PARTNER_EDGE_TEXTFILE_DIR="$tmp/textfile" \
    LOG_FILE="$tmp/refresh.log" \
    OXPULSE_BACKEND_URL="https://example.test" \
        bash "$REFRESH" >/dev/null 2>&1

    local ok=1
    local after_sha; after_sha=$(sha256sum "$lib/sfu-keys.env" 2>/dev/null | awk '{print $1}')
    if [[ "$after_sha" != "$before_sha" ]]; then
        fail "C13: sfu-keys.env content CHANGED despite a forced mktemp failure — the write is not routed through an atomic mktemp+mv, a mid-write failure can leave a truncated/wrong file"
        ok=0
    fi
    if ! grep -qE 'sfu-keys.env write failed' "$tmp/refresh.log"; then
        fail "C13: forced mktemp failure produced no WARNING in the log — silent write failure"
        ok=0
    fi
    [[ "$ok" -eq 1 ]] && pass "C13: forced mktemp failure leaves sfu-keys.env byte-for-byte unchanged (atomic mktemp+mv, no partial write) + logs a WARNING"
    rm -rf "$tmp"
}
c13

echo ""
echo "=== SFU signing-pubkey apply: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
