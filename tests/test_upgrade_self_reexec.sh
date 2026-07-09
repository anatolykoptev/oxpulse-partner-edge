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
# Non-vacuous guard: an empty file trivially passes `bash -n`, so a drifted awk
# pattern (fn renamed / moved) would GREEN a test that never exercised the code.
# Assert the extraction actually captured the fn signature before parsing.
if [[ -s "$FN" ]] && grep -q '^_maybe_self_update_reexec()' "$FN"; then
    pass "S0: extraction captured _maybe_self_update_reexec (non-empty, has signature)"
else
    fail "S0: extraction empty or signature-less — awk pattern drifted from upgrade.sh"; exit 1
fi
if bash -n "$FN"; then
    pass "S1: extracted _maybe_self_update_reexec parses (self-contained)"
else
    fail "S1: extracted _maybe_self_update_reexec has syntax errors"; exit 1
fi

# --- Extract the shared _lookup_expected_hash helper the fn now calls (review HIGH:
# reuse the "./"-prefix-tolerant resolver instead of an inline bare-name awk). Same
# awk-extract seam test_install_lib_checksum.sh / test_upgrade_stages_firewall_lib.sh
# use for the _source_lib / _stage_lib callers. Inlined into BOTH wrappers below so
# the extracted _maybe_self_update_reexec resolves it (else: `command not found` ->
# empty _expected -> silent no re-exec, which T1 would catch as a FAIL). ---
LOOKUP_FN="$TMP/lookup_fn.sh"
awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$LOOKUP_FN"
if [[ -s "$LOOKUP_FN" ]] && grep -q '^_lookup_expected_hash()' "$LOOKUP_FN"; then
    pass "S2: extraction captured _lookup_expected_hash (the shared resolver the fn reuses)"
else
    fail "S2: _lookup_expected_hash extraction empty/signature-less — awk pattern drifted"; exit 1
fi

# --- Extract the shared _should_self_update applicability predicate (PR4). The real
# _maybe_self_update_reexec now opens with `_should_self_update || return 0`, so both
# wrappers below MUST inline it or the extracted fn returns early (command not found ->
# non-zero -> no re-exec, which T1 would catch as a FAIL). Same single-copy predicate
# _assert_self_update_converged reuses. ---
SHOULD_FN="$TMP/should_fn.sh"
awk '/^_should_self_update\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$SHOULD_FN"
if [[ -s "$SHOULD_FN" ]] && grep -q '^_should_self_update()' "$SHOULD_FN"; then
    pass "S3: extraction captured _should_self_update (the single-copy applicability predicate)"
else
    fail "S3: _should_self_update extraction empty/signature-less — awk pattern drifted"; exit 1
fi

# --- Common cumulative-cleanup registry preamble (faithful minimal copy of
# upgrade.sh's _CLEANUP_PATHS + single EXIT trap + the self-update re-exec tmpdir
# registration line). Inlined into both wrappers so the re-exec tmpdir is swept
# exactly as in production (HIGH-2). ---
REGISTRY_PRE="$TMP/registry_pre.sh"
cat > "$REGISTRY_PRE" <<'REG'
_CLEANUP_PATHS=()
_run_cleanup() { local p; [[ ${#_CLEANUP_PATHS[@]} -eq 0 ]] && return 0; for p in "${_CLEANUP_PATHS[@]}"; do [[ -n "$p" ]] && rm -rf "$p"; done; }
trap _run_cleanup EXIT
[[ -n "${OXPULSE_UPGRADE_REEXEC_TMPDIR:-}" ]] && _CLEANUP_PATHS+=("$OXPULSE_UPGRADE_REEXEC_TMPDIR")
REG

# --- The released ("new") upgrade.sh = stub preamble + real fn + marker. When
# re-exec'd by the parent the sentinel is set, so its own _maybe_self_update_reexec
# must return immediately (no re-fetch, no loop). ---
SERVED="$TMP/served"; mkdir -p "$SERVED"
{
    # RETRY_OPTS=(): curl is stubbed here, so the retry flags are inert, but the real
    # _maybe_self_update_reexec now splices "${RETRY_OPTS[@]}" into its fetches — define
    # it (empty) so the array expansion is not an unbound-variable error under set -u.
    printf '#!/bin/bash\nset -uo pipefail\nlog(){ :; }\nwarn(){ :; }\nRETRY_OPTS=()\n'
    cat "$REGISTRY_PRE"
    cat "$LOOKUP_FN"
    cat "$SHOULD_FN"
    cat "$FN"
    printf '_maybe_self_update_reexec "$@"\n'
    printf 'echo "CHILD_RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} reexec_tmpdir=${OXPULSE_UPGRADE_REEXEC_TMPDIR:-} args=$*"\n'
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
RETRY_OPTS=()   # curl stubbed below; define (empty) so "${RETRY_OPTS[@]}" is set -u safe
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
    cat "$REGISTRY_PRE"
    cat "$LOOKUP_FN"
    cat "$SHOULD_FN"
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
# T1c (HIGH-2): the fetched re-exec tmpdir must NOT leak after a real self-update.
# The child re-registers the parent's tmpdir at top level and its EXIT trap sweeps
# it once bash is done reading the script from inside it. Capture the path the child
# echoed and assert the dir is gone after the run (before the fix it survived every
# self-update, one dir per version bump fleet-wide).
T1_REEXEC_TMP=$(printf '%s\n' "$T1_OUT" | sed -n 's/.*reexec_tmpdir=\([^ ]*\).*/\1/p' | head -1)
if [[ -n "$T1_REEXEC_TMP" && ! -d "$T1_REEXEC_TMP" ]]; then
    pass "T1c: child swept the re-exec tmpdir at EXIT (no per-self-update temp-dir leak)"
else
    fail "T1c: re-exec tmpdir leaked (path='$T1_REEXEC_TMP', exists=$([[ -d "$T1_REEXEC_TMP" ]] && echo yes || echo no))"
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
# T4b (negative KAT): SHA256SUMS itself fails to fetch (captive portal / truncated
#     mirror) => warn + SKIP, parent CONTINUES, no re-exec. This is distinct from a
#     mismatch (T4): here the manifest is unreachable, not wrong. Converges next run.
# ---------------------------------------------------------------------------
SERVED_NOSUMS="$TMP/served_nosums"; mkdir -p "$SERVED_NOSUMS"
cp "$SERVED/partner-edge-upgrade.sh" "$SERVED_NOSUMS/partner-edge-upgrade.sh"   # binary present, NO SHA256SUMS
T4B_OUT=$(run_wrap "$SERVED_NOSUMS" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP")
if printf '%s\n' "$T4B_OUT" | grep -q 'PARENT_CONTINUED' && ! printf '%s\n' "$T4B_OUT" | grep -q 'CHILD_RAN'; then
    pass "T4b: an unfetchable SHA256SUMS is treated as skip (parent continues, no unverified re-exec)"
else
    fail "T4b: unfetchable SHA256SUMS did not skip cleanly; got: $T4B_OUT"
fi

# ---------------------------------------------------------------------------
# T6 (escape hatch, scoped): ALLOW_UNVERIFIED=1 + mismatched bytes => re-exec
#     PROCEEDS (verification deliberately bypassed for the fork/dev/restricted-network
#     operator). ALLOW_UNVERIFIED is seeded at upgrade.sh top level from
#     OXPULSE_UPGRADE_NO_INTEGRITY / --allow-unverified / --no-integrity (the awk
#     extraction omits that top-level seeding, so the resolved guard is injected
#     directly here). Same SERVED_BAD as T4: only the flag flips REFUSE -> PROCEED,
#     which is exactly the intended, opt-in scope of the hatch.
# ---------------------------------------------------------------------------
T6_OUT=$(run_wrap "$SERVED_BAD" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP" ALLOW_UNVERIFIED=1)
if printf '%s\n' "$T6_OUT" | grep -q 'CHILD_RAN sentinel=1' && ! printf '%s\n' "$T6_OUT" | grep -q 'PARENT_CONTINUED'; then
    pass "T6: ALLOW_UNVERIFIED=1 bypasses SHA verification and re-execs (escape hatch intentionally scoped)"
else
    fail "T6: escape hatch did not proceed on a mismatched release; got: $T6_OUT"
fi

# ---------------------------------------------------------------------------
# T7 (HIGH-1 KAT): a SHA256SUMS whose column-2 carries the common `find`-generated
#     "./partner-edge-upgrade.sh" prefix MUST still verify + re-exec. The pre-fix
#     inline bare-name awk (`$2=="partner-edge-upgrade.sh"`) missed the "./" form,
#     left _expected empty, and silently fail-closed the self-update forever; routing
#     through the shared _lookup_expected_hash ($2==n || $2=="./"n) fixes it. This KAT
#     goes RED against the old inline awk and GREEN against the reuse.
# ---------------------------------------------------------------------------
SERVED_DOTSLASH="$TMP/served_dotslash"; mkdir -p "$SERVED_DOTSLASH"
cp "$SERVED/partner-edge-upgrade.sh" "$SERVED_DOTSLASH/partner-edge-upgrade.sh"
DOTSHA=$(sha256sum "$SERVED_DOTSLASH/partner-edge-upgrade.sh" | awk '{print $1}')
printf '%s  ./partner-edge-upgrade.sh\n' "$DOTSHA" > "$SERVED_DOTSLASH/SHA256SUMS"  # note the ./ prefix
T7_OUT=$(run_wrap "$SERVED_DOTSLASH" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP")
if printf '%s\n' "$T7_OUT" | grep -q 'CHILD_RAN sentinel=1' && ! printf '%s\n' "$T7_OUT" | grep -q 'PARENT_CONTINUED'; then
    pass "T7: a './'-prefixed SHA256SUMS entry still verifies + re-execs (shared resolver, no silent skip)"
else
    fail "T7: './'-prefixed checksum silently skipped the self-update (bare-name awk regression); got: $T7_OUT"
fi

# ---------------------------------------------------------------------------
# T4c (HIGH-2, failure path): if exec() itself FAILS (bad interpreter), a non-
#     interactive shell would abort AND skip the EXIT trap; `shopt -s execfail` makes
#     it CONTINUE into the recovery block instead, which degrades to two-run
#     convergence (parent continues) AND removes the throwaway tmpdir. Verified in an
#     isolated TMPDIR so any leftover dir is unambiguously this run's.
# ---------------------------------------------------------------------------
SERVED_BROKEN="$TMP/served_broken"; mkdir -p "$SERVED_BROKEN"
printf '#!/nonexistent-interp-xyzzy\necho SHOULD_NOT_RUN\n' > "$SERVED_BROKEN/partner-edge-upgrade.sh"
chmod +x "$SERVED_BROKEN/partner-edge-upgrade.sh"
BROKENSHA=$(sha256sum "$SERVED_BROKEN/partner-edge-upgrade.sh" | awk '{print $1}')
printf '%s  partner-edge-upgrade.sh\n' "$BROKENSHA" > "$SERVED_BROKEN/SHA256SUMS"
FB_TMPDIR="$TMP/fb"; mkdir -p "$FB_TMPDIR"
# `|| true`: belt-and-suspenders in case execfail is ever removed and the parent
# aborts non-zero — the assertion is about the swept tmpdir + graceful continue.
T4C_OUT=$(env TMPDIR="$FB_TMPDIR" SERVED_DIR="$SERVED_BROKEN" \
    RELEASES_BASE="https://example.invalid/releases" RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 \
    PREFIX_SBIN="$TMP" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP" \
    bash "$WRAP" v9.9.9 2>/dev/null) || true
T4C_LEAK=$(find "$FB_TMPDIR" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1 || true)
if [[ -z "$T4C_LEAK" ]] \
    && printf '%s\n' "$T4C_OUT" | grep -q 'PARENT_CONTINUED' \
    && ! printf '%s\n' "$T4C_OUT" | grep -q 'SHOULD_NOT_RUN'; then
    pass "T4c: a failed exec degrades gracefully (parent continues) AND sweeps its tmpdir (no leak)"
else
    fail "T4c: exec-fail leaked a tmpdir ('$T4C_LEAK'), aborted, or ran the broken interp; out: $T4C_OUT"
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
