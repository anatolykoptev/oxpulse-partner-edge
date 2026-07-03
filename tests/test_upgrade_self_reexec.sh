#!/bin/bash
# tests/test_upgrade_self_reexec.sh
#
# FIX 2 (self-update re-exec) test.
#
# Problem under test:
#   The running upgrade process is the OLD on-disk upgrade.sh; sync_host_scripts
#   installs the NEW upgrade.sh to disk but the current run keeps executing the
#   OLD bytes, so an in-upgrade.sh fix (e.g. the settle cold-start gate) only
#   takes effect on the operator's SECOND run - and a settle false-rollback even
#   restores the old upgrade.sh, so a box can loop forever on the buggy version.
#
# Fix under test:
#   _maybe_self_update_reexec fetches the NEW upgrade.sh for RELEASE_TAG to a
#   SHA-verified temp file and, if it differs from the running script, re-execs
#   it exactly ONCE (sentinel-guarded) so the fix converges in ONE invocation.
#   It is gated to the INSTALLED sbin copy (never a dev/CI/manual `bash upgrade.sh`)
#   and has an opt-out env; both are asserted here.
#
# Rollback safety is verified structurally: the re-exec execs a TEMP copy and
# touches nothing on disk, so the apply path's snapshot/backup still run against
# the pristine OLD state in the child (see T5).
#
# Falsification (anti-vacuous):
#   T1 requires the sentinel-guarded exec to fire AND the child to NOT loop.
#   T2/T3 require it to NOT fire (opt-out / non-installed path). T4 requires an
#   unverified fetch to be REFUSED. Removing any guard flips one of these.
#
# REAL-CODE MANDATE: the running (parent) and released (child) scripts both inline
# the REAL _maybe_self_update_reexec awk-extracted from upgrade.sh. Only curl is
# stubbed (serve from a local dir) so the test needs no network - the real code
# keeps its TLS-pinned curl.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== FIX 2: stale upgrade.sh re-execs into the released one once (converges in one run) ==="

[[ -f "$UPGRADE" ]] || { fail "P0: upgrade.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# --- Extract the real _maybe_self_update_reexec (self-contained fn). ---
FN="$TMP/reexec_fn.sh"
awk '/^_maybe_self_update_reexec\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$FN"
if bash -n "$FN"; then
    pass "S1: extracted _maybe_self_update_reexec parses (self-contained)"
else
    fail "S1: extracted _maybe_self_update_reexec has syntax errors"; exit 1
fi

# --- The released ("new") upgrade.sh = stub preamble + real fn + marker. When
# re-exec'd by the parent the sentinel is set, so its own _maybe_self_update_reexec
# must return immediately (no re-fetch, no loop). ---
SERVED="$TMP/served"; mkdir -p "$SERVED"
{
    printf '#!/bin/bash\nset -uo pipefail\nlog(){ :; }\nwarn(){ :; }\n'
    cat "$FN"
    printf '_maybe_self_update_reexec "$@"\n'
    printf 'echo "CHILD_RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} args=$*"\n'
} > "$SERVED/partner-edge-upgrade.sh"
chmod +x "$SERVED/partner-edge-upgrade.sh"
NEWSHA=$(sha256sum "$SERVED/partner-edge-upgrade.sh" | awk '{print $1}')
printf '%s  partner-edge-upgrade.sh\n' "$NEWSHA" > "$SERVED/SHA256SUMS"

# --- A "bad" served dir: correct binary, WRONG SHA256SUMS (verification fail-safe). ---
SERVED_BAD="$TMP/served_bad"; mkdir -p "$SERVED_BAD"
cp "$SERVED/partner-edge-upgrade.sh" "$SERVED_BAD/partner-edge-upgrade.sh"
printf '%s  partner-edge-upgrade.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    > "$SERVED_BAD/SHA256SUMS"

# --- The running (stale, installed) upgrade.sh = curl stub + real fn + marker.
# Inlining the fn makes BASH_SOURCE[0] inside it resolve to THIS wrapper, exactly
# as in production (fn defined in upgrade.sh, running as upgrade.sh). ---
WRAP="$TMP/oxpulse-partner-edge-upgrade"
{
    cat <<'PRE'
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ :; }
# Offline curl stub: serve $SERVED_DIR/<basename(url)> -> the -o target.
curl() {
    local out="" url="" i
    local a=("$@")
    for ((i=0; i<${#a[@]}; i++)); do
        case "${a[i]}" in
            -o) out="${a[i+1]}" ;;
            *"://"*) url="${a[i]}" ;;
        esac
    done
    local base; base=$(basename "$url")
    if [[ -f "${SERVED_DIR:-}/$base" ]]; then cp -f "$SERVED_DIR/$base" "$out"; return 0; fi
    return 1
}
PRE
    cat "$FN"
    printf '_maybe_self_update_reexec "$@"\n'
    printf 'echo "PARENT_CONTINUED sentinel=${OXPULSE_UPGRADE_REEXECED:-0}"\n'
} > "$WRAP"
chmod +x "$WRAP"

# run_wrap SERVED_DIR EXTRA_ENV... — invoke the wrapper as a real apply.
run_wrap() {
    local served="$1"; shift
    env TMPDIR="$TMP" SERVED_DIR="$served" \
        RELEASES_BASE="https://example.invalid/releases" \
        RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 \
        PREFIX_SBIN="$TMP" \
        "$@" \
        bash "$WRAP" v9.9.9 2>/dev/null
}

# ---------------------------------------------------------------------------
# T1: installed copy + stale bytes + verified release => re-exec ONCE, child runs
#     with the sentinel set and does NOT loop; parent never continues.
# ---------------------------------------------------------------------------
T1_OUT=$(run_wrap "$SERVED" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP")
T1_CHILD=$(printf '%s\n' "$T1_OUT" | grep -c 'CHILD_RAN sentinel=1' || true)
if [[ "$T1_CHILD" -eq 1 ]] && ! printf '%s\n' "$T1_OUT" | grep -q 'PARENT_CONTINUED'; then
    pass "T1: stale installed upgrade.sh re-execs into the verified release once (child ran, parent replaced)"
else
    fail "T1: expected exactly one CHILD_RAN sentinel=1 and no PARENT_CONTINUED; got: $T1_OUT"
fi
if [[ "$T1_CHILD" -eq 1 ]]; then
    pass "T1b: sentinel makes the child NOT re-sync/re-exec (converges in ONE invocation, no loop)"
else
    fail "T1b: child looped or did not run exactly once (CHILD_RAN count=$T1_CHILD)"
fi

# ---------------------------------------------------------------------------
# T2: opt-out env => NO re-exec (parent continues).
# ---------------------------------------------------------------------------
T2_OUT=$(run_wrap "$SERVED" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP" OXPULSE_UPGRADE_NO_SELF_UPDATE=1)
if printf '%s\n' "$T2_OUT" | grep -q 'PARENT_CONTINUED' && ! printf '%s\n' "$T2_OUT" | grep -q 'CHILD_RAN'; then
    pass "T2: OXPULSE_UPGRADE_NO_SELF_UPDATE=1 disables the re-exec"
else
    fail "T2: opt-out did not disable re-exec; got: $T2_OUT"
fi

# ---------------------------------------------------------------------------
# T3: running copy is NOT the installed path (dev/CI/manual) => NO re-exec.
#     This is the guard that keeps the integration suite off the network path.
# ---------------------------------------------------------------------------
T3_OUT=$(run_wrap "$SERVED" OXPULSE_INSTALLED_UPGRADE_PATH="/nonexistent/installed/upgrade")
if printf '%s\n' "$T3_OUT" | grep -q 'PARENT_CONTINUED' && ! printf '%s\n' "$T3_OUT" | grep -q 'CHILD_RAN'; then
    pass "T3: a non-installed (dev/CI/manual) running copy does NOT self-update"
else
    fail "T3: non-installed running path still re-exec'd; got: $T3_OUT"
fi

# ---------------------------------------------------------------------------
# T4: fetched release fails SHA256SUMS verification => REFUSE re-exec (fail-safe).
# ---------------------------------------------------------------------------
T4_OUT=$(run_wrap "$SERVED_BAD" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP")
if printf '%s\n' "$T4_OUT" | grep -q 'PARENT_CONTINUED' && ! printf '%s\n' "$T4_OUT" | grep -q 'CHILD_RAN'; then
    pass "T4: a SHA256-mismatched release is REFUSED (no unverified re-exec as root)"
else
    fail "T4: unverified release was exec'd (fail-safe broken); got: $T4_OUT"
fi

# ---------------------------------------------------------------------------
# T5 (structural, rollback safety): the re-exec must exec a TEMP copy, never
#     install to disk here, and must run BEFORE the apply-path backup/snapshot so
#     the child snapshots pristine OLD on-disk state.
# ---------------------------------------------------------------------------
if grep -qE 'exec "\$_new" "\$@"' "$UPGRADE"; then
    pass "T5a: re-exec targets the fetched temp copy (\$_new), not an installed path"
else
    fail "T5a: re-exec does not exec the temp copy - rollback-safety property missing"
fi
# The plain-path call site must precede the compose/state backup (cp -a ... .prev).
reexec_line=$(grep -n '^_maybe_self_update_reexec "\$@"' "$UPGRADE" | head -1 | cut -d: -f1 || true)
backup_line=$(grep -n '^cp -a "\$COMPOSE_FILE" "\$PREV_COMPOSE_FILE"' "$UPGRADE" | head -1 | cut -d: -f1 || true)
if [[ -n "$reexec_line" && -n "$backup_line" && "$reexec_line" -lt "$backup_line" ]]; then
    pass "T5b: plain-path re-exec (line $reexec_line) runs BEFORE the compose backup (line $backup_line) - rollback preserved"
else
    fail "T5b: re-exec/backup ordering wrong (reexec=$reexec_line backup=$backup_line)"
fi

echo ""
echo "=== self-update re-exec: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
