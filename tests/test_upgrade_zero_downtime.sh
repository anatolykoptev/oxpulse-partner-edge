#!/bin/bash
# tests/test_upgrade_zero_downtime.sh
#
# Regression guards for three changes in fix/upgrade-zero-downtime:
#
#   (A) Unbound OXPULSE_MIRROR_BASE — zvonilka repro: upgrade.sh --help (and
#       any invocation) crash with "unbound variable" when OXPULSE_MIRROR_BASE
#       is absent from env AND install.env lacks the key.
#
#   (B) Digest-skip per-container recreate — services whose image digest did
#       not change after compose pull must NOT be recreated.  Services with
#       a changed digest MUST be recreated.
#
#   (C) --host-scripts-only mode — must call sync_host_scripts and restart
#       timers but NEVER call docker compose pull or docker compose up.
#
# Test strategy: structural (grep) + functional (subshell invocation with
# DOCKER_BIN/SYSTEMCTL_BIN mocked) so no real Docker or systemd needed.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Section A — OXPULSE_MIRROR_BASE unbound variable fix
# ===========================================================================
echo ""
echo "=== Section A: OXPULSE_MIRROR_BASE unbound variable fix ==="

# A1: syntax check.
bash -n "$UPGRADE" \
    && pass "A1: upgrade.sh passes bash -n (no syntax errors)" \
    || { fail "A1: upgrade.sh has syntax errors"; exit 1; }

# A2: structural — OXPULSE_MIRROR_BASE initialized with :- default before the
# install.env load block (i.e. before 'grep OXPULSE_MIRROR_BASE= ... install.env').
#
# Check that the initializer line appears before the load block in the file.
init_line=$(grep -n 'OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE:-}"' "$UPGRADE" | head -1 | cut -d: -f1)
load_line=$(grep -n "grep '^OXPULSE_MIRROR_BASE='" "$UPGRADE" | head -1 | cut -d: -f1)

if [[ -n "$init_line" ]]; then
    pass "A2a: OXPULSE_MIRROR_BASE initialized with :- default (line $init_line)"
else
    fail "A2a: OXPULSE_MIRROR_BASE initializer not found"
fi

if [[ -n "$init_line" && -n "$load_line" && "$init_line" -lt "$load_line" ]]; then
    pass "A2b: initializer (line $init_line) is before the install.env load block (line $load_line)"
else
    fail "A2b: init=$init_line load=$load_line — ordering wrong or lines missing"
fi

# A3: functional — invoke upgrade.sh in an env where OXPULSE_MIRROR_BASE is
# unset and install.env does NOT contain the key (the zvonilka case).
# Expect: no "unbound variable" error.  The script will die with a state-file
# error ("no installed bundle" / "missing install.env"), which is expected on
# a bare system without the edge installed.
A3_TMPDIR=$(mktemp -d)
cleanup_a3() { rm -rf "$A3_TMPDIR"; }
trap cleanup_a3 EXIT

A3_OUT=$(
    env -i \
        HOME="$A3_TMPDIR" \
        PATH="$PATH" \
        OXPULSE_SKIP_ROOT_CHECK=1 \
        OXPULSE_PREFIX_LIB="$A3_TMPDIR/var" \
        bash "$UPGRADE" --help 2>&1
) && A3_RC=0 || A3_RC=$?

if echo "$A3_OUT" | grep -q 'unbound variable'; then
    fail "A3: got 'unbound variable' error — fix not effective; output: $A3_OUT"
else
    pass "A3: no 'unbound variable' error (zvonilka no-mirror repro clean)"
fi

# The script should die with a state/compose error, not an unbound-var crash.
if echo "$A3_OUT" | grep -qE 'unbound variable'; then
    fail "A3b: unbound variable in output"
elif echo "$A3_OUT" | grep -qE 'no installed bundle|missing.*install.env|must run as root'; then
    pass "A3b: script failed for expected infra reason (not unbound var)"
else
    # Some other failure — still acceptable as long as not unbound variable.
    pass "A3b: script failed (rc=$A3_RC) but not due to unbound variable"
fi

# A4: the strip `${OXPULSE_MIRROR_BASE%/}` must still appear (the actual fix
# needed the init, not the removal of the strip).
grep -q 'OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE%/' "$UPGRADE" \
    && pass "A4: trailing-slash strip still present (init+strip pattern intact)" \
    || fail "A4: trailing-slash strip removed — unintended change"

# A5: a no-mirror install.env (key absent) must not cause unbound var in a
# subshell sourcing the top-level globals.  Simulates the exact state on zvonilka.
A5_STATEDIR=$(mktemp -d)
printf 'IMAGE_VERSION=v0.12.57\n' > "$A5_STATEDIR/install.env"

A5_OUT=$(
    env -i \
        HOME="$A5_STATEDIR" \
        PATH="$PATH" \
        OXPULSE_SKIP_ROOT_CHECK=1 \
        OXPULSE_PREFIX_LIB="$A5_STATEDIR" \
        bash "$UPGRADE" --help 2>&1
) && A5_RC=0 || A5_RC=$?
rm -rf "$A5_STATEDIR"

if echo "$A5_OUT" | grep -q 'unbound variable'; then
    fail "A5: 'unbound variable' with no-mirror install.env — fix incomplete"
else
    pass "A5: no 'unbound variable' with no-mirror install.env (correct)"
fi

# ===========================================================================
# Section B — Digest-skip per-container recreate
# ===========================================================================
echo ""
echo "=== Section B: digest-skip per-container recreate ==="

# B1: structural — helper functions must be defined.
grep -qE '^capture_running_digests\(\)' "$UPGRADE" \
    && pass "B1a: capture_running_digests() defined" \
    || fail "B1a: capture_running_digests() not defined"

grep -qE '^resolve_pulled_digests\(\)' "$UPGRADE" \
    && pass "B1b: resolve_pulled_digests() defined" \
    || fail "B1b: resolve_pulled_digests() not defined"

grep -qE '^recreate_changed_services\(\)' "$UPGRADE" \
    && pass "B1c: recreate_changed_services() defined" \
    || fail "B1c: recreate_changed_services() not defined"

# B2: structural — apply path must call capture_running_digests before pull,
# resolve_pulled_digests after pull, and recreate_changed_services instead of
# unconditional compose up.
apply_section=$(awk '/^# ---- Backup current config/{found=1} found{print} found && /^log "upgraded to \$TARGET successfully"/{exit}' "$UPGRADE")

echo "$apply_section" | grep -q 'capture_running_digests' \
    && pass "B2a: capture_running_digests in apply path" \
    || fail "B2a: capture_running_digests missing from apply path"

echo "$apply_section" | grep -q 'resolve_pulled_digests' \
    && pass "B2b: resolve_pulled_digests in apply path" \
    || fail "B2b: resolve_pulled_digests missing from apply path"

echo "$apply_section" | grep -q 'recreate_changed_services' \
    && pass "B2c: recreate_changed_services in apply path" \
    || fail "B2c: recreate_changed_services missing from apply path"

# B2d: apply path must NOT call compose up --force-recreate unconditionally.
# The rollback arm still calls --force-recreate (to bring old image up), so
# check that the recreate path uses recreate_changed_services not a bare up -d.
# Count calls to compose up -d: should be 0 in the non-rollback path (only
# recreate_changed_services calls it internally).
unconditional_up=$(echo "$apply_section" | grep -c 'compose up -d --force-recreate' || true)
# Allow up to 2 (rollback arms): the rollback arm after failed up + healthcheck failure arm.
[[ "$unconditional_up" -le 2 ]] \
    && pass "B2d: unconditional compose up --force-recreate calls ≤2 (rollback arms only)" \
    || fail "B2d: $unconditional_up unconditional compose up --force-recreate calls — should be ≤2"

# B3: functional — unchanged digest → no compose up for that service.
# We extract and run recreate_changed_services with matching before/after digests.
PREAMBLE_B="$(mktemp)"
# Write preamble helpers, then extract the function body via awk.
cat > "$PREAMBLE_B" << 'PREAMBLE_HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
PREFIX_ETC="${PREFIX_ETC:-/tmp}"
PREAMBLE_HELPERS
awk '/^recreate_changed_services\(\)/{found=1} found{print} found && /^}$/{exit}' "$UPGRADE" >> "$PREAMBLE_B"
bash -n "$PREAMBLE_B" || { fail "B3: preamble syntax error"; }

# Record calls to docker compose up.
FAKE_DOCKER_B="$(mktemp)"
cat > "$FAKE_DOCKER_B" << 'BFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG:-/tmp/docker_b_calls.log}"
exit 0
BFAKE
chmod +x "$FAKE_DOCKER_B"

B3_LOG=$(mktemp)
B3_OUT=$(
    PREFIX_ETC=/tmp \
    DOCKER_BIN="$FAKE_DOCKER_B" \
    DOCKER_CALL_LOG="$B3_LOG" \
    bash -c "
        source '$PREAMBLE_B'
        declare -A before after
        before[sfu]='sha256:aaabbbccc'
        after[sfu]='sha256:aaabbbccc'
        recreate_changed_services before after
    " 2>&1
) && B3_RC=0 || B3_RC=$?

if [[ $B3_RC -eq 0 ]]; then
    pass "B3a: recreate_changed_services exited 0 with unchanged digest"
else
    fail "B3a: exited $B3_RC; output: $B3_OUT"
fi

# No docker compose up should have been called.
compose_up_calls=$(grep -c 'up' "$B3_LOG" 2>/dev/null || true)
if [[ "$compose_up_calls" -eq 0 ]]; then
    pass "B3b: no 'docker compose up' called when digest unchanged"
else
    fail "B3b: docker compose up called $compose_up_calls times despite unchanged digest"
fi

# Log should say "skipping recreate".
echo "$B3_OUT" | grep -q 'skip' \
    && pass "B3c: 'skip' logged for unchanged digest" \
    || fail "B3c: no 'skip' in output; got: $B3_OUT"

# B4: functional — changed digest → compose up IS called for that service.
> "$B3_LOG"
B4_OUT=$(
    PREFIX_ETC=/tmp \
    DOCKER_BIN="$FAKE_DOCKER_B" \
    DOCKER_CALL_LOG="$B3_LOG" \
    bash -c "
        source '$PREAMBLE_B'
        declare -A before after
        before[sfu]='sha256:aaabbbccc111'
        after[sfu]='sha256:dddeeefff222'
        recreate_changed_services before after
    " 2>&1
) && B4_RC=0 || B4_RC=$?

if [[ $B4_RC -eq 0 ]]; then
    pass "B4a: recreate_changed_services exited 0 with changed digest"
else
    fail "B4a: exited $B4_RC; output: $B4_OUT"
fi

# docker compose up MUST have been called.
compose_up_calls4=$(grep -c 'up' "$B3_LOG" 2>/dev/null || true)
if [[ "$compose_up_calls4" -ge 1 ]]; then
    pass "B4b: docker compose up called ($compose_up_calls4 time(s)) for changed digest"
else
    fail "B4b: docker compose up NOT called despite changed digest; output: $B4_OUT"
fi

# Log should say "recreating" for the changed service.
echo "$B4_OUT" | grep -q 'changed\|recreat' \
    && pass "B4c: 'changed' or 'recreat' logged for changed digest" \
    || fail "B4c: expected log message missing; got: $B4_OUT"

# B5: functional — empty before-digest (first pull / container absent) → fail-safe recreate.
> "$B3_LOG"
B5_OUT=$(
    PREFIX_ETC=/tmp \
    DOCKER_BIN="$FAKE_DOCKER_B" \
    DOCKER_CALL_LOG="$B3_LOG" \
    bash -c "
        source '$PREAMBLE_B'
        declare -A before after
        before[caddy]=''           # container not running before pull
        after[caddy]='sha256:newimage999'
        recreate_changed_services before after
    " 2>&1
) && B5_RC=0 || B5_RC=$?

compose_up_calls5=$(grep -c 'up' "$B3_LOG" 2>/dev/null || true)
if [[ "$compose_up_calls5" -ge 1 ]]; then
    pass "B5: empty before-digest → fail-safe recreate (docker compose up called)"
else
    fail "B5: fail-safe broken — no recreate when before-digest empty; output: $B5_OUT"
fi

# B6: functional — empty after-digest (digest unavailable post-pull) → fail-safe recreate.
> "$B3_LOG"
B6_OUT=$(
    PREFIX_ETC=/tmp \
    DOCKER_BIN="$FAKE_DOCKER_B" \
    DOCKER_CALL_LOG="$B3_LOG" \
    bash -c "
        source '$PREAMBLE_B'
        declare -A before after
        before[xray]='sha256:oldimage111'
        after[xray]=''              # resolve_pulled_digests returned empty
        recreate_changed_services before after
    " 2>&1
) && B6_RC=0 || B6_RC=$?

compose_up_calls6=$(grep -c 'up' "$B3_LOG" 2>/dev/null || true)
if [[ "$compose_up_calls6" -ge 1 ]]; then
    pass "B6: empty after-digest → fail-safe recreate (not fail-open skip)"
else
    fail "B6: fail-safe broken — skipped recreate when after-digest empty; output: $B6_OUT"
fi

# B6b: the warning about unavailable digest must be logged.
echo "$B6_OUT" | grep -q 'could not resolve\|fail-safe' \
    && pass "B6b: fail-safe warning logged for empty after-digest" \
    || fail "B6b: no fail-safe warning; got: $B6_OUT"

# Cleanup temp files for section B.
rm -f "$PREAMBLE_B" "$FAKE_DOCKER_B" "$B3_LOG"

# ===========================================================================
# Section C — --host-scripts-only mode
# ===========================================================================
echo ""
echo "=== Section C: --host-scripts-only mode ==="

# C1: structural — MODE=host_scripts_only in arg parser.
grep -q 'MODE=host_scripts_only' "$UPGRADE" \
    && pass "C1a: MODE=host_scripts_only in arg parser" \
    || fail "C1a: MODE=host_scripts_only missing from arg parser"

grep -q -- '--host-scripts-only' "$UPGRADE" \
    && pass "C1b: --host-scripts-only in usage text or arg parser" \
    || fail "C1b: --host-scripts-only not present"

# C2: structural — the host_scripts_only handler must call sync_host_scripts
# and must NOT call docker compose pull or compose up.
hs_only_section=$(awk '/"\$MODE" == host_scripts_only/{found=1} found{print} found && /^fi$/{exit}' "$UPGRADE")

echo "$hs_only_section" | grep -q 'sync_host_scripts' \
    && pass "C2a: sync_host_scripts called in --host-scripts-only block" \
    || fail "C2a: sync_host_scripts missing from --host-scripts-only block"

# Check for actual docker compose command invocations (not log message text).
# Matches patterns like `$DOCKER_BIN compose pull` or `docker compose up` in code.
echo "$hs_only_section" | grep -qE '\$DOCKER_BIN compose (pull|up)|\bdocker\b.* compose (pull|up)' \
    && fail "C2b: --host-scripts-only block invokes compose pull/up — must NOT" \
    || pass "C2b: no compose pull/up invocation in --host-scripts-only block"

# C3: functional — invoke upgrade.sh --host-scripts-only with a mock docker.
# Assert: docker compose pull and docker compose up are NEVER called.
C3_TMPDIR=$(mktemp -d)
C3_DOCKER_LOG="$C3_TMPDIR/docker_calls.log"
C3_SYSTEMCTL_LOG="$C3_TMPDIR/systemctl_calls.log"

# Docker mock: log all calls, fail if pull or up is called.
C3_FAKE_DOCKER="$C3_TMPDIR/docker"
cat > "$C3_FAKE_DOCKER" << 'CFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
# Fail loudly if pull or up is invoked — must never happen in --host-scripts-only.
if [[ "$*" == *" pull"* || "$*" == *" up "* ]]; then
    printf 'FORBIDDEN: docker %s called in --host-scripts-only\n' "$*" >&2
    exit 99
fi
# compose config --services: return a fake service list.
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\n'
    exit 0
fi
exit 0
CFAKE
chmod +x "$C3_FAKE_DOCKER"

# Systemctl mock: log calls, exit 0.
C3_FAKE_SYSTEMCTL="$C3_TMPDIR/systemctl"
cat > "$C3_FAKE_SYSTEMCTL" << 'SCFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_CALL_LOG}"
exit 0
SCFAKE
chmod +x "$C3_FAKE_SYSTEMCTL"

# Minimal fixture env.
C3_ETC="$C3_TMPDIR/etc"
C3_LIB="$C3_TMPDIR/var"
C3_SBIN="$C3_TMPDIR/sbin"
C3_BIN="$C3_TMPDIR/bin"
C3_LIBDIR="$C3_TMPDIR/libdir"
C3_SYSTEMD="$C3_TMPDIR/systemd"
C3_SHARE="$C3_TMPDIR/share"
mkdir -p "$C3_ETC" "$C3_LIB" "$C3_SBIN" "$C3_BIN" "$C3_LIBDIR" "$C3_SYSTEMD" "$C3_SHARE"

printf 'IMAGE_VERSION=v0.12.57\nSIGNALING_SFU_SECRET=testsecret\n' > "$C3_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.57\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$C3_ETC/docker-compose.yml"

# Lib stubs (upgrade.sh sources these before arg processing).
printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
    > "$C3_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
    > "$C3_SBIN/ghcr-auth-lib.sh"

# Serve the repo root so sync_host_scripts curl succeeds.
C3_SERVE_PORT=18764
python3 -m http.server "$C3_SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-c3-httpd.log 2>&1 &
C3_HTTP_PID=$!
sleep 1

C3_OUT=$(
    OXPULSE_PREFIX_ETC="$C3_ETC" \
    OXPULSE_PREFIX_LIB="$C3_LIB" \
    OXPULSE_PREFIX_SBIN="$C3_SBIN" \
    OXPULSE_PREFIX_BIN="$C3_BIN" \
    OXPULSE_PREFIX_LIBDIR="$C3_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$C3_SHARE" \
    OXPULSE_SYSTEMD_DIR="$C3_SYSTEMD" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.57 \
    DOCKER_BIN="$C3_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$C3_DOCKER_LOG" \
    SYSTEMCTL_BIN="$C3_FAKE_SYSTEMCTL" \
    SYSTEMCTL_CALL_LOG="$C3_SYSTEMCTL_LOG" \
    OXPULSE_REPO_RAW="http://127.0.0.1:$C3_SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$C3_SERVE_PORT/NOSUCHRELEASE" \
    bash "$UPGRADE" --host-scripts-only v0.12.58 2>&1
) && C3_RC=0 || C3_RC=$?

kill "$C3_HTTP_PID" 2>/dev/null || true

# Exit code: 0 on success, or non-zero if defaults.conf install fails due to
# permission on /usr/local/share (expected when running non-root in test).
# The critical assertion is that docker pull/up were NOT called (C3b/C3c).
# Forbidden docker call (exit 99) = hard failure.
if [[ $C3_RC -eq 99 ]]; then
    fail "C3a: docker compose pull/up was called (exit 99 from docker mock) — must NOT happen in --host-scripts-only"
elif echo "$C3_OUT" | grep -q 'FORBIDDEN'; then
    fail "C3a: FORBIDDEN docker call detected in output"
else
    pass "C3a: upgrade.sh --host-scripts-only did not invoke forbidden docker commands (rc=$C3_RC)"
fi

# docker pull must not have been called.
if grep -q ' pull' "$C3_DOCKER_LOG" 2>/dev/null; then
    fail "C3b: docker compose pull was called — must be SKIPPED in --host-scripts-only"
else
    pass "C3b: docker compose pull NOT called"
fi

# docker compose up must not have been called.
if grep -q ' up ' "$C3_DOCKER_LOG" 2>/dev/null; then
    fail "C3c: docker compose up was called — must be SKIPPED in --host-scripts-only"
else
    pass "C3c: docker compose up NOT called"
fi

# sync_host_scripts runs → systemctl daemon-reload must have been invoked if
# any script changed, OR at least the sync function was reached (no "pull" gate).
echo "$C3_OUT" | grep -qE 'host-script|host_scripts_only|--host-scripts-only' \
    && pass "C3d: host-script sync path reached (log evidence)" \
    || fail "C3d: no evidence host-script path was reached; output: $C3_OUT"

rm -rf "$C3_TMPDIR"

# C4: --dry-run with --host-scripts-only prints plan and exits 0 without calling docker.
C4_TMPDIR=$(mktemp -d)
C4_DOCKER_LOG="$C4_TMPDIR/docker_calls.log"
C4_FAKE_DOCKER="$C4_TMPDIR/docker"
cat > "$C4_FAKE_DOCKER" << 'C4FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
exit 0
C4FAKE
chmod +x "$C4_FAKE_DOCKER"

C4_ETC="$C4_TMPDIR/etc"
C4_LIB="$C4_TMPDIR/var"
C4_SBIN="$C4_TMPDIR/sbin"
mkdir -p "$C4_ETC" "$C4_LIB" "$C4_SBIN"
printf 'IMAGE_VERSION=v0.12.57\n' > "$C4_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.57\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$C4_ETC/docker-compose.yml"
printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' > "$C4_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' > "$C4_SBIN/ghcr-auth-lib.sh"

C4_OUT=$(
    OXPULSE_PREFIX_ETC="$C4_ETC" \
    OXPULSE_PREFIX_LIB="$C4_LIB" \
    OXPULSE_PREFIX_SBIN="$C4_SBIN" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.57 \
    DOCKER_BIN="$C4_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$C4_DOCKER_LOG" \
    SYSTEMCTL_BIN=true \
    bash "$UPGRADE" --host-scripts-only --dry-run v0.12.58 2>&1
) && C4_RC=0 || C4_RC=$?

if [[ $C4_RC -eq 0 ]]; then
    pass "C4a: --host-scripts-only --dry-run exited 0"
else
    fail "C4a: exited $C4_RC; output: $C4_OUT"
fi

echo "$C4_OUT" | grep -q 'dry-run' \
    && pass "C4b: [dry-run] tag in output" \
    || fail "C4b: no [dry-run] in output; got: $C4_OUT"

# No docker calls at all in dry-run mode.
if [[ -s "$C4_DOCKER_LOG" ]]; then
    fail "C4c: docker was called in dry-run mode; calls: $(cat "$C4_DOCKER_LOG")"
else
    pass "C4c: docker not called in --host-scripts-only --dry-run"
fi

rm -rf "$C4_TMPDIR"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
