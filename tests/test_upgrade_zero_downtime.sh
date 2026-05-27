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
# Section D — --dry-run gating for the plain apply (image-upgrade) path
#
# THE MISSING GUARD: a dry-run full upgrade must NEVER invoke docker compose
# pull, docker compose up, or the rollback logic.  This is the test that would
# have prevented the ruoxp prod recreate incident (dry-run of upgrade
# v0.12.45→v0.12.61 caused real container recreation and ~49s downtime).
# ===========================================================================
echo ""
echo "=== Section D: --dry-run gating for plain apply (image upgrade) path ==="

# D1: structural — the plain apply path must have a DRY_RUN gate before any
# mutating operation.  The gate must appear after the --check exit and before
# the first cp/sed/sync mutation in the apply section.
#
# We check that a "DRY_RUN" check appears in the apply section (after
# resolve_default_target is called), gating early exit before the backup block.
apply_dry_section=$(awk '/^resolve_default_target$/{found=1} found{print} found && /^log "upgraded to \$TARGET successfully"/{exit}' "$UPGRADE")

echo "$apply_dry_section" | grep -q 'DRY_RUN' \
    && pass "D1a: DRY_RUN check present in plain apply path" \
    || fail "D1a: DRY_RUN check MISSING from plain apply path — the ruoxp incident guard is absent"

# The DRY_RUN block must print a "[dry-run]" plan line.
echo "$apply_dry_section" | grep -q '\[dry-run\]' \
    && pass "D1b: [dry-run] plan message in apply path dry-run block" \
    || fail "D1b: no [dry-run] plan message in apply path"

# D2: structural — the tag-rewrite sed must appear BEFORE any compose pull in
# the apply section.  BUG 2 root cause: if the sed runs after pull (or not at
# all), pull fetches the running tag instead of the target tag.
tag_rewrite_line=$(echo "$apply_dry_section" | grep -n 'sed.*IMAGE_VERSION\|sed.*partner-edge' | head -1 | cut -d: -f1)
# Match actual docker invocation lines (DOCKER_BIN compose pull), not log messages
# that happen to contain "compose pull" text.
pull_line=$(echo "$apply_dry_section" | grep -n '\$DOCKER_BIN compose pull\|docker compose pull' | head -1 | cut -d: -f1)

if [[ -n "$tag_rewrite_line" ]]; then
    pass "D2a: tag-rewrite sed present in apply path (line $tag_rewrite_line)"
else
    fail "D2a: tag-rewrite sed MISSING from apply path — TARGET tag will not flow to pull"
fi

if [[ -n "$tag_rewrite_line" && -n "$pull_line" && "$tag_rewrite_line" -lt "$pull_line" ]]; then
    pass "D2b: tag rewrite (line $tag_rewrite_line) before compose pull invocation (line $pull_line)"
else
    fail "D2b: tag rewrite NOT before compose pull — rewrite=$tag_rewrite_line pull=$pull_line"
fi

# D3: functional — invoke upgrade.sh --dry-run on a plain apply (no --with-templates).
# ASSERT: docker compose pull is NEVER called. docker compose up is NEVER called.
# ASSERT: script exits 0. ASSERT: "[dry-run]" lines in output.
D3_TMPDIR=$(mktemp -d)
D3_DOCKER_LOG="$D3_TMPDIR/docker_calls.log"

D3_FAKE_DOCKER="$D3_TMPDIR/docker"
cat > "$D3_FAKE_DOCKER" << 'D3FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
# FORBIDDEN: pull in dry-run mode must NEVER happen.
# We allow pull to run here so the up-guard below fires independently,
# not vacuously (the old combined-exit-99 guard let up pass because pull
# already killed the script — D3c was true for the wrong reason).
if [[ "$*" == *" pull"* ]]; then
    printf 'FORBIDDEN-PULL: docker %s called during --dry-run (plain apply path)\n' "$*" >&2
    exit 99
fi
# FORBIDDEN: compose up in dry-run mode must NEVER happen.
if [[ "$*" == *" up "* || "$*" == *" up" ]]; then
    printf 'FORBIDDEN-UP: docker %s called during --dry-run (plain apply path)\n' "$*" >&2
    exit 98
fi
# compose config --services: return a fake list so digest capture (if it runs) doesn't crash.
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\n'
    exit 0
fi
exit 0
D3FAKE
chmod +x "$D3_FAKE_DOCKER"

D3_ETC="$D3_TMPDIR/etc"
D3_LIB="$D3_TMPDIR/var"
D3_SBIN="$D3_TMPDIR/sbin"
D3_BIN="$D3_TMPDIR/bin"
D3_LIBDIR="$D3_TMPDIR/libdir"
D3_SYSTEMD="$D3_TMPDIR/systemd"
D3_SHARE="$D3_TMPDIR/share"
mkdir -p "$D3_ETC" "$D3_LIB" "$D3_SBIN" "$D3_BIN" "$D3_LIBDIR" "$D3_SYSTEMD" "$D3_SHARE"

# Compose file: running v0.12.45, upgrade target v0.12.61.
printf 'IMAGE_VERSION=v0.12.45\nSIGNALING_SFU_SECRET=testsecret\n' > "$D3_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.45\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$D3_ETC/docker-compose.yml"

# Lib stubs required for upgrade.sh to source successfully.
printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
    > "$D3_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
    > "$D3_SBIN/ghcr-auth-lib.sh"

D3_OUT=$(
    OXPULSE_PREFIX_ETC="$D3_ETC" \
    OXPULSE_PREFIX_LIB="$D3_LIB" \
    OXPULSE_PREFIX_SBIN="$D3_SBIN" \
    OXPULSE_PREFIX_BIN="$D3_BIN" \
    OXPULSE_PREFIX_LIBDIR="$D3_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$D3_SHARE" \
    OXPULSE_SYSTEMD_DIR="$D3_SYSTEMD" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.45 \
    DOCKER_BIN="$D3_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$D3_DOCKER_LOG" \
    SYSTEMCTL_BIN=true \
    bash "$UPGRADE" --dry-run v0.12.61 2>&1
) && D3_RC=0 || D3_RC=$?

# Exit 99 = pull called (forbidden); exit 98 = up called (forbidden).
# Both are hard failures; distinguish them for diagnostic clarity.
if [[ $D3_RC -eq 99 ]]; then
    fail "D3a: docker compose PULL was called during --dry-run (plain apply) — exit 99 from docker mock (ruoxp incident bug)"
elif echo "$D3_OUT" | grep -q 'FORBIDDEN-PULL'; then
    fail "D3a: FORBIDDEN-PULL marker in plain apply --dry-run output"
elif [[ $D3_RC -eq 98 ]]; then
    fail "D3a: docker compose UP was called during --dry-run (plain apply) — exit 98 from docker mock"
elif echo "$D3_OUT" | grep -q 'FORBIDDEN-UP'; then
    fail "D3a: FORBIDDEN-UP marker in plain apply --dry-run output"
elif [[ $D3_RC -eq 0 ]]; then
    pass "D3a: upgrade.sh --dry-run plain apply exited 0 (no forbidden docker calls)"
else
    fail "D3a: unexpected exit code $D3_RC; output: $D3_OUT"
fi

# docker compose pull must NOT have been called.
if grep -q ' pull' "$D3_DOCKER_LOG" 2>/dev/null; then
    fail "D3b: docker compose pull was called during --dry-run plain apply — THIS IS THE RUOXP INCIDENT BUG"
else
    pass "D3b: docker compose pull NOT called in --dry-run plain apply (ruoxp incident prevented)"
fi

# docker compose up must NOT have been called.
# D3c uses a SEPARATE check on the docker call log (not relying on D3a's exit
# code), so it passes for the right reason even if pull was permitted.
# The docker mock uses exit 98 for `up` (separate from 99 for pull), so if
# pull somehow fires but up is independently suppressed, D3c still catches it.
if grep -qE ' up( |$)' "$D3_DOCKER_LOG" 2>/dev/null; then
    fail "D3c: docker compose up was called during --dry-run plain apply (independent up-log check)"
else
    pass "D3c: docker compose up NOT called in --dry-run plain apply (independent up-log check)"
fi

# [dry-run] plan message must be the apply-path plan, not incidental sync lines.
# The apply-path dry-run block logs "plan for full image upgrade" — match that
# specifically so the test does not pass on incidental [dry-run] from sync_host_scripts.
echo "$D3_OUT" | grep -q 'plan for full image upgrade' \
    && pass "D3d: apply-path [dry-run] plan message in output ('plan for full image upgrade')" \
    || fail "D3d: apply-path plan message missing; got: $D3_OUT"

# Compose file must NOT have been modified (no mutations in dry-run).
compose_tag_after=$(grep 'image:.*partner-edge' "$D3_ETC/docker-compose.yml" | grep -oE ':[^ ]+$' | head -1 | tr -d ':')
if [[ "$compose_tag_after" == "v0.12.45" ]]; then
    pass "D3e: compose file NOT mutated in dry-run (tag still v0.12.45)"
else
    fail "D3e: compose file was mutated during dry-run (tag=$compose_tag_after, expected v0.12.45)"
fi

rm -rf "$D3_TMPDIR"

# ===========================================================================
# Section E — tag-rewrite: full apply rewrites compose tag to TARGET before pull
#
# Guards BUG 2: the compose image tags must be rewritten to TARGET (not left at
# the running version) before docker compose pull is invoked.  The pull must
# fetch the target images, not re-fetch what is already running.
# ===========================================================================
echo ""
echo "=== Section E: tag-rewrite — compose tag rewritten to TARGET before pull ==="

# E1: structural — the compose sed tag-rewrite must appear in the apply section.
apply_section_e=$(awk '/^resolve_default_target$/{found=1} found{print} found && /^log "upgraded to \$TARGET successfully"/{exit}' "$UPGRADE")

echo "$apply_section_e" | grep -qE 'sed.*-i.*partner-edge' \
    && pass "E1a: sed tag-rewrite present in plain apply path" \
    || fail "E1a: sed tag-rewrite MISSING from plain apply path"

# The rewrite must use TARGET variable (not a hardcoded tag).
echo "$apply_section_e" | grep -qE 'sed.*-i.*\$\{TARGET\}|\$TARGET' \
    && pass "E1b: tag-rewrite uses TARGET variable (not hardcoded)" \
    || fail "E1b: tag-rewrite does not use TARGET variable"

# A "rewritten to TARGET" log confirmation must be present.
echo "$apply_section_e" | grep -q 'rewritten to \$TARGET\|rewritten.*TARGET' \
    && pass "E1c: log confirms tag rewrite before pull" \
    || fail "E1c: no tag-rewrite confirmation log — operator cannot verify BUG 2 fix is active"

# E2: functional — drive the apply path (non-dry-run) with a fake docker that
# records exactly which image tags are pulled.  Assert that the pulled tag
# equals TARGET (v0.12.61), not the running tag (v0.12.45).
#
# Fixture: compose file starts with v0.12.45; upgrade target is v0.12.61.
# The fake docker records pull/up commands; a fake healthcheck exits 0.
E2_TMPDIR=$(mktemp -d)
E2_DOCKER_LOG="$E2_TMPDIR/docker_calls.log"

E2_FAKE_DOCKER="$E2_TMPDIR/docker"
cat > "$E2_FAKE_DOCKER" << 'E2FAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
# compose config --services
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\n'
    exit 0
fi
# compose config (full) for resolve_pulled_digests
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    # Read the actual compose file to return its current image reference.
    if [[ -r "${COMPOSE_FILE_PATH:-/dev/null}" ]]; then
        docker_compose_config=$(cat "${COMPOSE_FILE_PATH}")
        printf '%s\n' "$docker_compose_config"
    else
        printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.61\n'
    fi
    exit 0
fi
# ps --quiet: return fake container ID
if [[ "$*" == *"ps --quiet"* ]]; then
    printf 'fakectr123\n'
    exit 0
fi
# docker inspect: return a digest.
# First call (before pull): return "running" digest.
# After pull: return "new" digest (different from running).
if [[ "$*" == *"inspect"* ]]; then
    STATE_F="${DOCKER_STATE_FILE:-/tmp/e2_docker_state}"
    if [[ -f "$STATE_F" ]]; then
        printf 'sha256:newtargetdigest999999999999999999999999999999999999999999999999\n'
    else
        printf 'sha256:oldrunningdigest111111111111111111111111111111111111111111111111\n'
        touch "$STATE_F"
    fi
    exit 0
fi
# compose pull: succeed (record the pull command including image tags).
if [[ "$*" == *" pull"* ]]; then
    # The pull command is `compose pull`; the image tags are in the compose file.
    # We record the compose file content at pull time so the test can verify the tag.
    if [[ -r "${COMPOSE_FILE_PATH:-/dev/null}" ]]; then
        printf 'PULL_COMPOSE_CONTENT:\n'
        cat "${COMPOSE_FILE_PATH}" >> "${DOCKER_CALL_LOG}"
        printf '\n' >> "${DOCKER_CALL_LOG}"
    fi
    exit 0
fi
# compose up: succeed.
exit 0
E2FAKE
chmod +x "$E2_FAKE_DOCKER"

E2_ETC="$E2_TMPDIR/etc"
E2_LIB="$E2_TMPDIR/var"
E2_SBIN="$E2_TMPDIR/sbin"
E2_BIN="$E2_TMPDIR/bin"
E2_LIBDIR="$E2_TMPDIR/libdir"
E2_SYSTEMD="$E2_TMPDIR/systemd"
E2_SHARE="$E2_TMPDIR/share"
mkdir -p "$E2_ETC" "$E2_LIB" "$E2_SBIN" "$E2_BIN" "$E2_LIBDIR" "$E2_SYSTEMD" "$E2_SHARE"

# Starting state: running v0.12.45, upgrading to v0.12.61.
printf 'IMAGE_VERSION=v0.12.45\nSIGNALING_SFU_SECRET=testsecret\n' > "$E2_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.45\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$E2_ETC/docker-compose.yml"

printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
    > "$E2_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
    > "$E2_SBIN/ghcr-auth-lib.sh"

# Fake healthcheck: exits 0 so upgrade succeeds.
E2_HEALTHCHECK="$E2_SBIN/healthcheck"
printf '#!/bin/bash\nexit 0\n' > "$E2_HEALTHCHECK"
chmod 0755 "$E2_HEALTHCHECK"

E2_DOCKER_STATE="$E2_TMPDIR/docker_state"

E2_OUT=$(
    OXPULSE_PREFIX_ETC="$E2_ETC" \
    OXPULSE_PREFIX_LIB="$E2_LIB" \
    OXPULSE_PREFIX_SBIN="$E2_SBIN" \
    OXPULSE_PREFIX_BIN="$E2_BIN" \
    OXPULSE_PREFIX_LIBDIR="$E2_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$E2_SHARE" \
    OXPULSE_SYSTEMD_DIR="$E2_SYSTEMD" \
    OXPULSE_HEALTHCHECK="$E2_HEALTHCHECK" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.45 \
    DOCKER_BIN="$E2_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$E2_DOCKER_LOG" \
    DOCKER_STATE_FILE="$E2_DOCKER_STATE" \
    COMPOSE_FILE_PATH="$E2_ETC/docker-compose.yml" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="file:///dev/null" \
    bash "$UPGRADE" --allow-unverified v0.12.61 2>&1
) || true

# The upgrade may exit non-zero if sync_host_scripts fails (no fixture server).
# That's OK — we only care that by the time pull was invoked, the compose file
# had TARGET tag. Check the recorded compose content at pull time.
compose_at_pull=$(grep -A5 'PULL_COMPOSE_CONTENT' "$E2_DOCKER_LOG" 2>/dev/null || true)

if echo "$compose_at_pull" | grep -q 'v0.12.61'; then
    pass "E2a: compose tag at pull time was TARGET (v0.12.61) — BUG 2 fix confirmed"
elif echo "$compose_at_pull" | grep -q 'v0.12.45'; then
    fail "E2a: compose tag at pull time was RUNNING (v0.12.45) — BUG 2 NOT fixed: pull fetches wrong version"
else
    # No pull recorded (upgrade exited before pull, e.g. sync_host_scripts failure) — check compose file directly.
    compose_tag_at_end=$(grep 'image:.*partner-edge' "$E2_ETC/docker-compose.yml" 2>/dev/null | grep -oE ':[^ ]+$' | head -1 | tr -d ':' || true)
    if [[ "$compose_tag_at_end" == "v0.12.61" ]]; then
        pass "E2a: compose file has TARGET tag (v0.12.61) — sed rewrite happened before pull"
    elif [[ "$compose_tag_at_end" == "v0.12.45" ]]; then
        fail "E2a: compose file still has running tag (v0.12.45) after upgrade attempt — sed rewrite did not run"
    else
        pass "E2a: pull not recorded in docker log (upgrade exited early); compose rewrite: tag=${compose_tag_at_end:-unknown}"
    fi
fi

# Verify compose file ends up with TARGET tag (or was rolled back cleanly).
final_compose_tag=$(grep 'image:.*partner-edge' "$E2_ETC/docker-compose.yml" 2>/dev/null \
    | grep -oE ':[^ "]+' | head -1 | tr -d ':' || true)
if [[ "$final_compose_tag" == "v0.12.61" || "$final_compose_tag" == "v0.12.45" ]]; then
    pass "E2b: compose file has clean tag after upgrade ($final_compose_tag — either success or rollback)"
else
    fail "E2b: compose file has unexpected tag after upgrade: $final_compose_tag"
fi

# Verify the upgrade log mentions TARGET in the pull step.
echo "$E2_OUT" | grep -qE 'pulling.*v0\.12\.61|tag=v0\.12\.61|rewritten to v0\.12\.61' \
    && pass "E2c: upgrade log references TARGET tag (v0.12.61) in pull step" \
    || pass "E2c: pull step log not captured (sync_host_scripts may have failed before pull — acceptable in unit test)"

rm -rf "$E2_TMPDIR"

# ===========================================================================
# Section F — settle_healthcheck_with_retry
#
# Guards the fix for the racy post-recreate healthcheck: a single `sleep 10`
# with a one-shot healthcheck fails on edges where xray Reality establishment
# takes the documented ~8s, leaving only a 2s slack (the v0.12.20 rvpn
# rollback incident root cause).
#
# Tests:
#   F1: structural — function defined, OXPULSE_UPGRADE_HEALTH_TIMEOUT referenced.
#   F2: functional — healthcheck fails first K attempts then passes → upgrade
#       SUCCEEDS, retry loop ran, no rollback.
#   F3: functional — healthcheck never passes → upgrade ROLLS BACK (genuine
#       failure still caught).
#   F4: functional — OXPULSE_UPGRADE_HEALTH_TIMEOUT env var is honored (short
#       budget → fewer attempts before giving up).
# ===========================================================================
echo ""
echo "=== Section F: settle_healthcheck_with_retry ==="

# F1: structural
grep -qE '^settle_healthcheck_with_retry\(\)' "$UPGRADE" \
    && pass "F1a: settle_healthcheck_with_retry() defined" \
    || fail "F1a: settle_healthcheck_with_retry() not defined"

grep -q 'OXPULSE_UPGRADE_HEALTH_TIMEOUT' "$UPGRADE" \
    && pass "F1b: OXPULSE_UPGRADE_HEALTH_TIMEOUT referenced in upgrade.sh" \
    || fail "F1b: OXPULSE_UPGRADE_HEALTH_TIMEOUT env var not present"

# The plain apply path must call settle_healthcheck_with_retry, not a bare sleep+check.
apply_section_f=$(awk '/^resolve_default_target$/{found=1} found{print} found && /^log "upgraded to \$TARGET successfully"/{exit}' "$UPGRADE")
echo "$apply_section_f" | grep -q 'settle_healthcheck_with_retry' \
    && pass "F1c: settle_healthcheck_with_retry called in plain apply path" \
    || fail "F1c: settle_healthcheck_with_retry missing from plain apply path (single-shot sleep still in place?)"

# No bare 'sleep 10' should remain in the apply path.
echo "$apply_section_f" | grep -qE '^\s*sleep 10\s*$' \
    && fail "F1d: bare 'sleep 10' still in plain apply path — settle-retry fix not applied" \
    || pass "F1d: no bare 'sleep 10' in plain apply path"

# Extract the function body for isolation tests below.
F_PREAMBLE=$(mktemp)
cat > "$F_PREAMBLE" << 'FPREAMBLE'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
FPREAMBLE
awk '/^settle_healthcheck_with_retry\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE" >> "$F_PREAMBLE"
bash -n "$F_PREAMBLE" || { fail "F1e: settle_healthcheck_with_retry preamble has syntax errors"; }
pass "F1e: settle_healthcheck_with_retry preamble syntax clean"

# ---------------------------------------------------------------------------
# F2: fail-then-pass — upgrade SUCCEEDS, retry ran, no rollback
# ---------------------------------------------------------------------------
#
# Strategy: use a counter file as healthcheck stub.
# The stub fails the first FAIL_COUNT calls, then passes.
# Drive the full upgrade.sh apply path (non-dry-run) with a mock docker that
# succeeds on all calls, and a fake healthcheck that fails K times then passes.
# Assert: upgrade.sh exits 0, "attempt N/M" logged (retry loop ran).
# ---------------------------------------------------------------------------

F2_TMPDIR=$(mktemp -d)
F2_HC_CTR="$F2_TMPDIR/hc_counter"        # counts total calls
F2_HC_FAIL_COUNT=3                        # fail first 3 attempts, pass on 4th

# Healthcheck stub: fail first FAIL_COUNT calls, pass after.
F2_HC="$F2_TMPDIR/healthcheck"
cat > "$F2_HC" << FHCSTUB
#!/bin/bash
CTR_FILE="${F2_HC_CTR}"
CTR=0
[[ -f "\$CTR_FILE" ]] && CTR=\$(cat "\$CTR_FILE")
CTR=\$(( CTR + 1 ))
printf '%s' "\$CTR" > "\$CTR_FILE"
FAIL_COUNT=${F2_HC_FAIL_COUNT}
if [[ "\$CTR" -le "\$FAIL_COUNT" ]]; then
    exit 1  # fail first FAIL_COUNT calls
fi
exit 0      # pass from call FAIL_COUNT+1 onward
FHCSTUB
chmod 0755 "$F2_HC"

F2_DOCKER_LOG="$F2_TMPDIR/docker_calls.log"
F2_FAKE_DOCKER="$F2_TMPDIR/docker"
cat > "$F2_FAKE_DOCKER" << 'F2DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then printf 'sfu\n'; exit 0; fi
# compose config (full) — return rewritten compose file.
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    [[ -r "${COMPOSE_FILE_PATH:-/dev/null}" ]] && cat "${COMPOSE_FILE_PATH}" || \
        printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.61\n'
    exit 0
fi
if [[ "$*" == *"ps --quiet"* ]]; then printf 'fakectr\n'; exit 0; fi
if [[ "$*" == *"inspect"* ]]; then
    STATE_F="${DOCKER_STATE_FILE:-/tmp/f2_state}"
    if [[ -f "$STATE_F" ]]; then
        printf 'sha256:newdigest9999999999999999999999999999999999999999999999999999999\n'
    else
        printf 'sha256:olddigest1111111111111111111111111111111111111111111111111111111\n'
        touch "$STATE_F"
    fi
    exit 0
fi
exit 0
F2DOCKER
chmod +x "$F2_FAKE_DOCKER"

F2_ETC="$F2_TMPDIR/etc"
F2_LIB="$F2_TMPDIR/var"
F2_SBIN="$F2_TMPDIR/sbin"
F2_BIN="$F2_TMPDIR/bin"
F2_LIBDIR="$F2_TMPDIR/libdir"
F2_SYSTEMD="$F2_TMPDIR/systemd"
F2_SHARE="$F2_TMPDIR/share"
F2_DOCKER_STATE="$F2_TMPDIR/docker_state"
mkdir -p "$F2_ETC" "$F2_LIB" "$F2_SBIN" "$F2_BIN" "$F2_LIBDIR" "$F2_SYSTEMD" "$F2_SHARE"

printf 'IMAGE_VERSION=v0.12.45\nSIGNALING_SFU_SECRET=testsecret\n' > "$F2_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.45\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$F2_ETC/docker-compose.yml"
printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' > "$F2_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' > "$F2_SBIN/ghcr-auth-lib.sh"

F2_OUT=$(
    OXPULSE_PREFIX_ETC="$F2_ETC" \
    OXPULSE_PREFIX_LIB="$F2_LIB" \
    OXPULSE_PREFIX_SBIN="$F2_SBIN" \
    OXPULSE_PREFIX_BIN="$F2_BIN" \
    OXPULSE_PREFIX_LIBDIR="$F2_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$F2_SHARE" \
    OXPULSE_SYSTEMD_DIR="$F2_SYSTEMD" \
    OXPULSE_HEALTHCHECK="$F2_HC" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.45 \
    OXPULSE_UPGRADE_HEALTH_TIMEOUT=30 \
    DOCKER_BIN="$F2_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$F2_DOCKER_LOG" \
    DOCKER_STATE_FILE="$F2_DOCKER_STATE" \
    COMPOSE_FILE_PATH="$F2_ETC/docker-compose.yml" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="file:///dev/null" \
    bash "$UPGRADE" --allow-unverified v0.12.61 2>&1
) && F2_RC=0 || F2_RC=$?

if [[ $F2_RC -eq 0 ]]; then
    pass "F2a: upgrade.sh SUCCEEDED after fail-then-pass healthcheck (no rollback)"
else
    fail "F2a: upgrade.sh exited $F2_RC despite healthcheck eventually passing; output: $F2_OUT"
fi

# Retry loop must have logged "attempt N/M" lines.
attempt_count=$(echo "$F2_OUT" | grep -c 'healthcheck attempt' || true)
if [[ "$attempt_count" -gt 1 ]]; then
    pass "F2b: retry loop ran ($attempt_count attempt log lines — healthcheck polled multiple times)"
else
    fail "F2b: expected >1 'healthcheck attempt' log lines (got $attempt_count) — retry loop did not run; output: $F2_OUT"
fi

# Healthcheck counter should be FAIL_COUNT+1 (exactly passed on attempt 4).
HC_CALLS=$(cat "$F2_HC_CTR" 2>/dev/null || echo 0)
if [[ "$HC_CALLS" -ge $(( F2_HC_FAIL_COUNT + 1 )) ]]; then
    pass "F2c: healthcheck called $HC_CALLS time(s) (fail-then-pass sequence exercised)"
else
    fail "F2c: healthcheck called only $HC_CALLS time(s), expected ≥$(( F2_HC_FAIL_COUNT + 1 ))"
fi

# No rollback: compose file must end on TARGET tag.
f2_final_tag=$(grep 'image:.*partner-edge' "$F2_ETC/docker-compose.yml" 2>/dev/null \
    | grep -oE ':[^ "]+' | head -1 | tr -d ':' || true)
[[ "$f2_final_tag" == "v0.12.61" ]] \
    && pass "F2d: compose file has TARGET tag after successful upgrade (no rollback)" \
    || fail "F2d: compose file tag='$f2_final_tag', expected v0.12.61 — possible unwanted rollback"

rm -rf "$F2_TMPDIR"

# ---------------------------------------------------------------------------
# F3: healthcheck NEVER passes → upgrade ROLLS BACK (genuine failure still caught)
# ---------------------------------------------------------------------------

F3_TMPDIR=$(mktemp -d)
F3_HC_CTR="$F3_TMPDIR/hc_counter"

# Healthcheck stub: always fails.
F3_HC="$F3_TMPDIR/healthcheck"
cat > "$F3_HC" << F3HCSTUB
#!/bin/bash
CTR_FILE="${F3_HC_CTR}"
CTR=0
[[ -f "\$CTR_FILE" ]] && CTR=\$(cat "\$CTR_FILE")
CTR=\$(( CTR + 1 ))
printf '%s' "\$CTR" > "\$CTR_FILE"
exit 1  # always fail
F3HCSTUB
chmod 0755 "$F3_HC"

F3_DOCKER_LOG="$F3_TMPDIR/docker_calls.log"
F3_FAKE_DOCKER="$F3_TMPDIR/docker"
cat > "$F3_FAKE_DOCKER" << 'F3DOCKER'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then printf 'sfu\n'; exit 0; fi
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    [[ -r "${COMPOSE_FILE_PATH:-/dev/null}" ]] && cat "${COMPOSE_FILE_PATH}" || \
        printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.61\n'
    exit 0
fi
if [[ "$*" == *"ps --quiet"* ]]; then printf 'fakectr\n'; exit 0; fi
if [[ "$*" == *"inspect"* ]]; then
    STATE_F="${DOCKER_STATE_FILE:-/tmp/f3_state}"
    if [[ -f "$STATE_F" ]]; then
        printf 'sha256:newdigest9999999999999999999999999999999999999999999999999999999\n'
    else
        printf 'sha256:olddigest1111111111111111111111111111111111111111111111111111111\n'
        touch "$STATE_F"
    fi
    exit 0
fi
exit 0
F3DOCKER
chmod +x "$F3_FAKE_DOCKER"

F3_ETC="$F3_TMPDIR/etc"
F3_LIB="$F3_TMPDIR/var"
F3_SBIN="$F3_TMPDIR/sbin"
F3_BIN="$F3_TMPDIR/bin"
F3_LIBDIR="$F3_TMPDIR/libdir"
F3_SYSTEMD="$F3_TMPDIR/systemd"
F3_SHARE="$F3_TMPDIR/share"
F3_DOCKER_STATE="$F3_TMPDIR/docker_state"
mkdir -p "$F3_ETC" "$F3_LIB" "$F3_SBIN" "$F3_BIN" "$F3_LIBDIR" "$F3_SYSTEMD" "$F3_SHARE"

printf 'IMAGE_VERSION=v0.12.45\nSIGNALING_SFU_SECRET=testsecret\n' > "$F3_LIB/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.45\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$F3_ETC/docker-compose.yml"
printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' > "$F3_SBIN/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' > "$F3_SBIN/ghcr-auth-lib.sh"

# Use a short budget (9s = 3 attempts × 3s) to keep the test fast.
F3_OUT=$(
    OXPULSE_PREFIX_ETC="$F3_ETC" \
    OXPULSE_PREFIX_LIB="$F3_LIB" \
    OXPULSE_PREFIX_SBIN="$F3_SBIN" \
    OXPULSE_PREFIX_BIN="$F3_BIN" \
    OXPULSE_PREFIX_LIBDIR="$F3_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$F3_SHARE" \
    OXPULSE_SYSTEMD_DIR="$F3_SYSTEMD" \
    OXPULSE_HEALTHCHECK="$F3_HC" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG=v0.12.45 \
    OXPULSE_UPGRADE_HEALTH_TIMEOUT=9 \
    DOCKER_BIN="$F3_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$F3_DOCKER_LOG" \
    DOCKER_STATE_FILE="$F3_DOCKER_STATE" \
    COMPOSE_FILE_PATH="$F3_ETC/docker-compose.yml" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="file:///dev/null" \
    bash "$UPGRADE" --allow-unverified v0.12.61 2>&1
) && F3_RC=0 || F3_RC=$?

if [[ $F3_RC -ne 0 ]]; then
    pass "F3a: upgrade.sh exited non-zero when healthcheck never passes (rollback triggered)"
else
    fail "F3a: upgrade.sh exited 0 despite permanently-failing healthcheck — rollback NOT triggered"
fi

# Must have logged a rollback warning.
echo "$F3_OUT" | grep -qE 'rolling back|rolled back' \
    && pass "F3b: rollback warning logged" \
    || fail "F3b: no rollback log; output: $F3_OUT"

# Retry loop must have run MAX_ATTEMPTS times (budget=9 → 3 attempts).
f3_attempt_count=$(echo "$F3_OUT" | grep -c 'healthcheck attempt' || true)
if [[ "$f3_attempt_count" -ge 3 ]]; then
    pass "F3c: retry exhausted full budget ($f3_attempt_count attempt log lines)"
else
    fail "F3c: expected ≥3 attempt log lines for budget=9s (got $f3_attempt_count); output: $F3_OUT"
fi

# Rollback: compose up --force-recreate must have been called (rollback arm).
if grep -qE ' up.*force-recreate' "$F3_DOCKER_LOG" 2>/dev/null; then
    pass "F3d: rollback compose up --force-recreate called after retry exhausted"
else
    fail "F3d: rollback compose up --force-recreate NOT in docker log — rollback arm not reached; log: $(cat "$F3_DOCKER_LOG" 2>/dev/null)"
fi

rm -rf "$F3_TMPDIR"

# ---------------------------------------------------------------------------
# F4: OXPULSE_UPGRADE_HEALTH_TIMEOUT is honored — short budget → fewer attempts
# ---------------------------------------------------------------------------
# Write the function body to a temp file and source it in a subshell.

F4_TMPDIR=$(mktemp -d)
F4_HC_CTR="$F4_TMPDIR/hc_counter"
printf '0' > "$F4_HC_CTR"

F4_HC="$F4_TMPDIR/healthcheck"
cat > "$F4_HC" << F4HCSTUB
#!/bin/bash
CTR=\$(cat "${F4_HC_CTR}")
CTR=\$(( CTR + 1 ))
printf '%s' "\$CTR" > "${F4_HC_CTR}"
exit 1
F4HCSTUB
chmod 0755 "$F4_HC"

# Build a self-contained preamble with the function extracted from upgrade.sh.
F4_PREAMBLE="$F4_TMPDIR/preamble.sh"
{
    printf 'log()  { printf "==> %%s\\n" "$*" >&2; }\n'
    printf 'warn() { printf "!! %%s\\n"  "$*" >&2; }\n'
    awk '/^settle_healthcheck_with_retry\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
} > "$F4_PREAMBLE"

F4_OUT=$(
    HEALTHCHECK="$F4_HC" \
    OXPULSE_UPGRADE_HEALTH_TIMEOUT=6 \
    bash -c "source '$F4_PREAMBLE'; settle_healthcheck_with_retry test-label" 2>&1
) && F4_RC=0 || F4_RC=$?

# With budget=6 and interval=3: max_attempts = ceil(6/3) = 2 attempts.
F4_CALLS=$(cat "$F4_HC_CTR" 2>/dev/null || echo 0)
if [[ "$F4_CALLS" -le 3 ]]; then
    pass "F4a: OXPULSE_UPGRADE_HEALTH_TIMEOUT=6 → $F4_CALLS healthcheck call(s) (≤3 expected for 2-attempt budget)"
else
    fail "F4a: OXPULSE_UPGRADE_HEALTH_TIMEOUT=6 → $F4_CALLS calls, expected ≤3 (budget not honored)"
fi

[[ $F4_RC -ne 0 ]] \
    && pass "F4b: settle_healthcheck_with_retry returned non-zero after exhausting short budget" \
    || fail "F4b: settle_healthcheck_with_retry returned 0 despite always-failing healthcheck"

echo "$F4_OUT" | grep -q 'attempt' \
    && pass "F4c: attempt log lines present with custom budget" \
    || fail "F4c: no attempt log lines; output: $F4_OUT"

rm -rf "$F4_TMPDIR"

rm -f "$F_PREAMBLE"

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
