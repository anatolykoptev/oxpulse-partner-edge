#!/bin/bash
# tests/test_surgical_restart_lib.sh — RED-first direct-source coverage for
# lib/surgical-restart-lib.sh's `_docker_restart_if_sha_changed` (P2 of the
# 2026-07-08 refresh-lib-extraction-strangler plan, ADR-8/ADR-9).
#
# Pre-extraction, the ONLY test exercising the real `_restart_if_changed` was
# a single sed-range source in test_refresh_surgical_restart.sh, and the SFU
# caller's `skip_channel_status` branch had ZERO direct coverage — the
# council's finding this file closes. Covers, sourcing the REAL lib directly:
#   1. apply_mode=restart (default) uses `docker compose restart`
#   2. apply_mode=recreate uses `docker compose up -d --no-deps --force-recreate`
#   3. docker-inspect liveness gate: State.Running=true → sha advances
#   4. docker-inspect liveness gate: State.Running=false → sha does NOT advance
#   5. unchanged config sha → no docker call at all
#   6. ADR-9 fitness (behavioral): the pure function restarts even with a
#      channels-status.env file present marking the kind inactive — proving
#      zero channels-status.env coupling (the "caller skips the gate" shape
#      the SFU key-apply caller now relies on, replacing the old 8th
#      skip_channel_status bypass-flag arg).
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/surgical-restart-lib.sh"

[[ -f "$LIB" ]] || { echo "FAIL: $LIB not found"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== lib/surgical-restart-lib.sh direct-source tests ==="

# shellcheck source=lib/surgical-restart-lib.sh
source "$LIB"

# ---------------------------------------------------------------------------
# 1. apply_mode=restart (default) → `docker compose restart CONTAINER`
# ---------------------------------------------------------------------------
t1() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"; : > "$docker_log"
    mkdir -p "$tmp/shims"
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" ]]; then echo "true"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    printf 'new-config\n' > "$tmp/cfg"
    printf 'old-sha\n' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed xray "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" myctr

    if grep -qE 'compose .*restart myctr' "$docker_log" && ! grep -qE 'force-recreate' "$docker_log"; then
        pass "t1: apply_mode=restart (default) calls 'docker compose restart', not force-recreate"
    else
        fail "t1: apply_mode=restart did not call plain restart — docker.log: $(cat "$docker_log")"
    fi
    rm -rf "$tmp"
}
t1

# ---------------------------------------------------------------------------
# 2. apply_mode=recreate → `docker compose up -d --no-deps --force-recreate`
# ---------------------------------------------------------------------------
t2() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"; : > "$docker_log"
    mkdir -p "$tmp/shims"
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" ]]; then echo "true"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    printf 'new-config\n' > "$tmp/cfg"
    printf 'old-sha\n' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed sfu "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" sfu recreate

    if grep -qE 'compose .*up -d --no-deps --force-recreate sfu' "$docker_log" \
        && ! grep -qE 'compose .*restart sfu' "$docker_log"; then
        pass "t2: apply_mode=recreate calls 'docker compose up -d --no-deps --force-recreate', not restart"
    else
        fail "t2: apply_mode=recreate did not call force-recreate — docker.log: $(cat "$docker_log")"
    fi
    rm -rf "$tmp"
}
t2

# ---------------------------------------------------------------------------
# 3. liveness gate: State.Running=true → sha advances
# ---------------------------------------------------------------------------
t3() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/shims"
    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$1" == "inspect" ]]; then echo "true"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    printf 'new-config\n' > "$tmp/cfg"
    local want_sha; want_sha=$(sha256sum "$tmp/cfg" | awk '{print $1}')
    printf 'old-sha\n' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed xray "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" myctr

    if [[ "$(cat "$tmp/sha")" == "$want_sha" ]]; then
        pass "t3: State.Running=true after apply → sha advances to the new config hash"
    else
        fail "t3: sha did not advance despite State.Running=true (got '$(cat "$tmp/sha")', want '$want_sha')"
    fi
    rm -rf "$tmp"
}
t3

# ---------------------------------------------------------------------------
# 4. liveness gate: State.Running=false → sha does NOT advance (MAJOR 3)
# ---------------------------------------------------------------------------
t4() {
    local tmp; tmp=$(mktemp -d)
    mkdir -p "$tmp/shims"
    cat > "$tmp/shims/docker" <<'DOCK'
#!/usr/bin/env bash
if [[ "$1" == "inspect" ]]; then echo "false"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    printf 'new-config\n' > "$tmp/cfg"
    printf 'old-sha\n' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed xray "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" myctr

    if [[ "$(cat "$tmp/sha")" == "old-sha" ]]; then
        pass "t4: State.Running=false after apply → sha NOT advanced (next cycle retries)"
    else
        fail "t4: sha advanced despite State.Running=false — got '$(cat "$tmp/sha")'"
    fi
    rm -rf "$tmp"
}
t4

# ---------------------------------------------------------------------------
# 5. unchanged config sha → no docker call at all
# ---------------------------------------------------------------------------
t5() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"; : > "$docker_log"
    mkdir -p "$tmp/shims"
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    printf 'stable-config\n' > "$tmp/cfg"
    sha256sum "$tmp/cfg" | awk '{print $1}' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed xray "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" myctr

    if [[ ! -s "$docker_log" ]]; then
        pass "t5: unchanged config sha → docker never invoked"
    else
        fail "t5: docker was invoked despite an unchanged sha — docker.log: $(cat "$docker_log")"
    fi
    rm -rf "$tmp"
}
t5

# ---------------------------------------------------------------------------
# 6. ADR-9 fitness (behavioral): zero channels-status.env coupling — the pure
#    function restarts even with an inactive status line present for `kind`.
#    This is the direct-source proof backing the SFU caller's new
#    caller-omits-the-gate shape (replacing the old 8th skip_channel_status
#    bypass-flag arg).
# ---------------------------------------------------------------------------
t6() {
    local tmp; tmp=$(mktemp -d)
    local docker_log="$tmp/docker.log"; : > "$docker_log"
    mkdir -p "$tmp/shims" "$tmp/prefix_lib"
    cat > "$tmp/shims/docker" <<DOCK
#!/usr/bin/env bash
echo "docker \$*" >> "$docker_log"
if [[ "\$1" == "inspect" ]]; then echo "true"; exit 0; fi
exit 0
DOCK
    chmod +x "$tmp/shims/docker"

    # A channels-status.env marks `sfu` inactive — the pure lib function must
    # not even look at this file (fitness: rg 'channels-status.env'
    # lib/surgical-restart-lib.sh returns zero matches), so this must have NO
    # effect on the direct call below.
    printf 'sfu=inactive\n' > "$tmp/prefix_lib/channels-status.env"
    PREFIX_LIB="$tmp/prefix_lib"

    printf 'new-config\n' > "$tmp/cfg"
    printf 'old-sha\n' > "$tmp/sha"
    touch "$tmp/compose.yml"
    log() { :; }
    LOG_FILE="$tmp/log"

    PATH="$tmp/shims:$PATH" _docker_restart_if_sha_changed sfu "$tmp/cfg" "$tmp/sha" "$tmp/compose.yml" sfu recreate

    if grep -qE 'compose .*up -d --no-deps --force-recreate sfu' "$docker_log"; then
        pass "t6 (ADR-9): pure fn recreates even with channels-status.env sfu=inactive present — zero coupling proven"
    else
        fail "t6 (ADR-9): pure fn was suppressed by channels-status.env — a coupling regression, docker.log: $(cat "$docker_log")"
    fi
    rm -rf "$tmp"
}
t6

# ── Fitness: zero channels-status.env textual reference in the lib itself ──
if ! grep -q 'channels-status.env' "$LIB"; then
    pass "fitness: lib/surgical-restart-lib.sh has zero 'channels-status.env' references (ADR-9)"
else
    fail "fitness: lib/surgical-restart-lib.sh references 'channels-status.env' — domain policy leaked into the pure mechanism"
fi

# ── Syntax check ──────────────────────────────────────────────────────────
bash -n "$LIB" || fail "lib/surgical-restart-lib.sh has syntax errors"
pass "syntax check clean"

echo ""
echo "=== lib/surgical-restart-lib.sh: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
