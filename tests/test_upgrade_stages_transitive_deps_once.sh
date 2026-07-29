#!/bin/bash
# tests/test_upgrade_stages_transitive_deps_once.sh
#
# PR2 finding 4a test — deferred, stage-once transitive-dep staging.
#
# Problem under test (live v0.14.4 fleet rollout evidence):
#   upgrade.sh's staging of reconcile.sh's 5 transitive deps (install-firewall.sh,
#   telegram-alert-lib.sh, healthcheck-lib.sh, compose-lib.sh, host-scripts-lib.sh)
#   used to run UNCONDITIONALLY at top level, before _maybe_self_update_reexec's
#   decision. Whenever that self-update fired, the pre-reexec parent staged all 5
#   files (about to be discarded — the process gets exec-replaced), then the
#   re-exec'd child staged the SAME 5 files again: 10 raw.githubusercontent.com
#   requests instead of 5 for one upgrade invocation, contributing to a 429 on
#   2 of 5 relays.
#
# Fix under test:
#   _stage_reconcile_transitive_deps() is now a lazy, idempotent function, called
#   from 4 call sites — each positioned AFTER that path's _maybe_self_update_reexec
#   call (for the 2 self-update-guarded apply paths) so a process about to be
#   exec-replaced never reaches its own staging call, and only the SURVIVING
#   process (re-exec'd child, or the single process when no reexec fires) stages.
#
# Falsification (anti-vacuous):
#   T1 drives a REAL self-update re-exec (same technique as
#   tests/test_upgrade_self_reexec.sh — only curl is stubbed, the extracted
#   functions are the REAL awk-extracted upgrade.sh code) and counts fetches of
#   the 5 lib files in a log shared across the exec boundary (a real file, so
#   it survives the process image being replaced). Exactly 5 required, not 10 —
#   this test goes RED against the pre-fix "stage unconditionally at top level"
#   shape (which would show 10) and GREEN against the fix.
#   T2 proves the idempotency guard: calling the function twice in the SAME
#   process does not re-fetch.
#   T3 proves the no-reexec path (self-update fetch fails/skips) still stages
#   exactly once, not zero (staging must still happen when nobody re-execs).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== PR2 finding 4a: transitive-dep staging is deferred + stage-once across self-update reexec ==="

[[ -f "$UPGRADE" ]] || { fail "P0: upgrade.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Structural: the 5 _stage_lib calls must live INSIDE _stage_reconcile_transitive_deps
# (a function), not at column-0 top level — the pre-fix shape had them unindented
# and unconditional. An idempotency guard must exist.
# ---------------------------------------------------------------------------
bash -n "$UPGRADE" && pass "S0: upgrade.sh passes bash -n" || { fail "S0: syntax error"; exit 1; }

grep -qE '^_stage_reconcile_transitive_deps\(\)' "$UPGRADE" \
    && pass "S1: _stage_reconcile_transitive_deps() defined" \
    || fail "S1: _stage_reconcile_transitive_deps() not defined"

# No _stage_lib call may sit at column 0 (unindented = top-level unconditional,
# the pre-fix shape). Every real call site is indented inside the function body.
if grep -nE '^_stage_lib "' "$UPGRADE" | grep -v '^\s*#' >/dev/null; then
    fail "S2: found a column-0 (top-level, unconditional) _stage_lib call — staging was not fully moved into the lazy function"
else
    pass "S2: no _stage_lib call sits at column 0 — all 5 are inside the lazy function"
fi

grep -qE '_TRANSITIVE_DEPS_STAGED' "$UPGRADE" \
    && pass "S3: an idempotency guard variable (_TRANSITIVE_DEPS_STAGED) exists" \
    || fail "S3: no idempotency guard found"

# S4: exactly 4 call sites for _stage_reconcile_transitive_deps (the definition
# itself does not count — anchor on the invocation form with no trailing paren-args).
CALL_COUNT=$(grep -cE '^\s*_stage_reconcile_transitive_deps\s*$' "$UPGRADE")
[[ "$CALL_COUNT" -eq 4 ]] \
    && pass "S4: _stage_reconcile_transitive_deps is called from exactly 4 sites" \
    || fail "S4: expected 4 call sites, found $CALL_COUNT"

# S5: each apply-path call site (with-templates, plain) must come AFTER that
# path's _maybe_self_update_reexec call — the crux of the fix (staged after the
# reexec decision, not before).
mapfile -t reexec_lines < <(grep -nE '^\s*_maybe_self_update_reexec "\$@"' "$UPGRADE" | cut -d: -f1)
mapfile -t stage_call_lines < <(grep -nE '^\s*_stage_reconcile_transitive_deps\s*$' "$UPGRADE" | cut -d: -f1)
if [[ "${#reexec_lines[@]}" -eq 2 && "${#stage_call_lines[@]}" -eq 4 ]]; then
    ok=1
    for rl in "${reexec_lines[@]}"; do
        found_after=0
        for sl in "${stage_call_lines[@]}"; do
            # A staging call within 20 lines after a reexec call counts as "for this path".
            if [[ "$sl" -gt "$rl" && $((sl - rl)) -le 20 ]]; then found_after=1; break; fi
        done
        [[ "$found_after" -eq 1 ]] || ok=0
    done
    if [[ "$ok" -eq 1 ]]; then
        pass "S5: both _maybe_self_update_reexec call sites are followed within 20 lines by a staging call"
    else
        fail "S5: at least one _maybe_self_update_reexec call site has no nearby staging call after it"
    fi
else
    fail "S5: expected 2 reexec call sites + 4 staging call sites, got ${#reexec_lines[@]}/${#stage_call_lines[@]}"
fi

# ---------------------------------------------------------------------------
# Extract the REAL functions this fix touches (same awk-extraction convention
# as tests/test_upgrade_self_reexec.sh and tests/test_upgrade_stages_firewall_lib.sh).
# ---------------------------------------------------------------------------
LOOKUP_FN="$TMP/lookup_fn.sh"
awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$LOOKUP_FN"
STAGE_LIB_FN="$TMP/stage_lib_fn.sh"
awk '/^_stage_lib\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$STAGE_LIB_FN"
STAGE_DEPS_FN="$TMP/stage_deps_fn.sh"
awk '/^_TRANSITIVE_DEPS_STAGED=0$/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$STAGE_DEPS_FN"
REEXEC_FN="$TMP/reexec_fn.sh"
awk '/^_maybe_self_update_reexec\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$REEXEC_FN"
# PR4: _maybe_self_update_reexec now opens with `_should_self_update || return 0`, so
# the extracted fn needs the predicate inlined too (else it returns early -> no re-exec).
SHOULD_FN="$TMP/should_fn.sh"
awk '/^_should_self_update\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$SHOULD_FN"

for f in "$LOOKUP_FN:_lookup_expected_hash" "$STAGE_LIB_FN:_stage_lib" \
         "$STAGE_DEPS_FN:_stage_reconcile_transitive_deps" "$REEXEC_FN:_maybe_self_update_reexec" \
         "$SHOULD_FN:_should_self_update"; do
    path="${f%%:*}"; sym="${f##*:}"
    if [[ -s "$path" ]] && grep -q "$sym" "$path"; then
        pass "X0($sym): extraction non-empty and captured the real symbol"
    else
        fail "X0($sym): extraction empty — awk anchor drifted from upgrade.sh"; exit 1
    fi
done
bash -n "$STAGE_DEPS_FN" || { fail "X1: _stage_reconcile_transitive_deps extraction has a syntax error"; exit 1; }
pass "X1: extracted _stage_reconcile_transitive_deps parses (self-contained)"

# ---------------------------------------------------------------------------
# Common preamble: cumulative-cleanup registry (same minimal copy as
# test_upgrade_self_reexec.sh), plus the REAL extracted functions this test
# exercises. Shared by both the "running" (WRAP) and "new" (SERVED child) scripts.
# ---------------------------------------------------------------------------
REGISTRY_PRE="$TMP/registry_pre.sh"
cat > "$REGISTRY_PRE" <<'REG'
_CLEANUP_PATHS=()
_run_cleanup() { local p; [[ ${#_CLEANUP_PATHS[@]} -eq 0 ]] && return 0; for p in "${_CLEANUP_PATHS[@]}"; do [[ -n "$p" ]] && rm -rf "$p"; done; }
trap _run_cleanup EXIT
[[ -n "${OXPULSE_UPGRADE_REEXEC_TMPDIR:-}" ]] && _CLEANUP_PATHS+=("$OXPULSE_UPGRADE_REEXEC_TMPDIR")
REG

COMMON_BODY="$TMP/common_body.sh"
{
    cat "$REGISTRY_PRE"
    cat "$LOOKUP_FN"
    cat "$SHOULD_FN"
    cat "$STAGE_LIB_FN"
    cat "$STAGE_DEPS_FN"
    cat "$REEXEC_FN"
} > "$COMMON_BODY"

# ---------------------------------------------------------------------------
# Fixtures: the 5 staged libs + lib-checksums.txt + the "new" self-update binary
# + its SHA256SUMS, all served from one dir (curl stub resolves by basename,
# same convention as test_upgrade_self_reexec.sh's SERVED_DIR).
# ---------------------------------------------------------------------------
SERVED="$TMP/served"; mkdir -p "$SERVED"
for lib in install-firewall.sh telegram-alert-lib.sh healthcheck-lib.sh compose-lib.sh host-scripts-lib.sh; do
    printf '#!/usr/bin/env bash\n# fixture stub for %s\n' "$lib" > "$SERVED/$lib"
done
: > "$SERVED/lib-checksums.txt"
for lib in install-firewall.sh telegram-alert-lib.sh healthcheck-lib.sh compose-lib.sh host-scripts-lib.sh; do
    sha=$(sha256sum "$SERVED/$lib" | awk '{print $1}')
    printf '%s  %s\n' "$sha" "$lib" >> "$SERVED/lib-checksums.txt"
done

# run_wrap SELFUPDATE(0/1) CURL_LOG_PATH -> stdout captured. CURL_LOG_PATH is
# caller-provided (not returned): $(run_wrap ...) runs in a subshell, so a
# variable set INSIDE this function would not propagate back to the caller.
run_wrap() {
    local do_selfupdate="$1" curl_log="$2"

    # The "new" released copy (child target of a real self-update re-exec).
    # Body = preamble + common functions + the real call-site ORDER this fix
    # depends on: _maybe_self_update_reexec then _stage_reconcile_transitive_deps.
    {
        printf '#!/bin/bash\nset -uo pipefail\nlog(){ :; }\nwarn(){ :; }\nRETRY_OPTS=()\n'
        cat "$COMMON_BODY"
        printf '_UPGRADE_SH_DIR="%s"\n' "$TMP"
        printf '_maybe_self_update_reexec "$@"\n'
        printf '_stage_reconcile_transitive_deps\n'
        printf 'echo "RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} staged=${_TRANSITIVE_DEPS_STAGED:-0} libdir=${LIB_DIR:-}"\n'
    } > "$SERVED/partner-edge-upgrade.sh"
    chmod +x "$SERVED/partner-edge-upgrade.sh"

    if [[ "$do_selfupdate" -eq 1 ]]; then
        NEWSHA=$(sha256sum "$SERVED/partner-edge-upgrade.sh" | awk '{print $1}')
        printf '%s  partner-edge-upgrade.sh\n' "$NEWSHA" > "$SERVED/SHA256SUMS"
    else
        # No SHA256SUMS resolvable => _maybe_self_update_reexec skips the reexec
        # (T4b behaviour in test_upgrade_self_reexec.sh) => the running process
        # itself continues on to stage (single-process, no-reexec path).
        rm -f "$SERVED/SHA256SUMS"
    fi

    WRAP="$TMP/wrap_$$_$RANDOM"
    {
        cat <<PRE
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ :; }
CURL_LOG="$curl_log"
SERVED_DIR="$SERVED"
curl() {
    local out="" url="" a=("\$@") i
    for ((i=0; i<\${#a[@]}; i++)); do
        case "\${a[i]}" in
            -o) out="\${a[i+1]}" ;;
            *"://"*) url="\${a[i]}" ;;
        esac
    done
    echo "\$url" >> "\$CURL_LOG"
    local base; base=\$(basename "\$url")
    if [[ -f "\${SERVED_DIR:-}/\$base" ]]; then cp -f "\$SERVED_DIR/\$base" "\$out"; return 0; fi
    return 1
}
export -f curl
export CURL_LOG SERVED_DIR
PRE
        cat "$COMMON_BODY"
        printf '_UPGRADE_SH_DIR="%s"\n' "$TMP"
        printf '_maybe_self_update_reexec "$@"\n'
        printf '_stage_reconcile_transitive_deps\n'
        printf 'echo "RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} staged=${_TRANSITIVE_DEPS_STAGED:-0} libdir=${LIB_DIR:-}"\n'
    } > "$WRAP"
    chmod +x "$WRAP"

    env TMPDIR="$TMP" REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
        RELEASES_BASE="https://example.invalid/releases" \
        INSTALL_LIB_DIR="$TMP/nonexistent-installdir" \
        RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 \
        PREFIX_SBIN="$TMP" OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP" \
        bash "$WRAP" v9.9.9 2>/dev/null
}

count_lib_fetches() {
    # Count fetches of the 5 tracked lib files (basename match), excluding
    # lib-checksums.txt / SHA256SUMS / the self-update binary itself.
    grep -ocE '(install-firewall|telegram-alert-lib|healthcheck-lib|compose-lib|host-scripts-lib)\.sh$' "$1" 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# T1: self-update reexec FIRES (SHA256SUMS resolves + bytes differ) => exactly
#     5 lib fetches total (parent replaced by exec before its own staging call;
#     only the child stages). Pre-fix (unconditional top-level staging before
#     the reexec decision) would show 10.
# ---------------------------------------------------------------------------
T1_LOG=$(mktemp -p "$TMP")
T1_OUT=$(run_wrap 1 "$T1_LOG")
T1_CHILD=$(printf '%s\n' "$T1_OUT" | grep -c 'RAN sentinel=1 staged=1' || true)
T1_FETCHES=$(count_lib_fetches "$T1_LOG")
if [[ "$T1_CHILD" -eq 1 ]]; then
    pass "T1a: self-update fired, child ran with sentinel=1 and staged=1"
else
    fail "T1a: expected exactly one 'RAN sentinel=1 staged=1' line; got: $T1_OUT"
fi
if [[ "$T1_FETCHES" -eq 5 ]]; then
    pass "T1b: exactly 5 lib fetches logged across the WHOLE invocation (parent+child) — not 10 (the pre-fix double-fetch)"
else
    fail "T1b: expected exactly 5 lib fetches, got $T1_FETCHES (log: $(cat "$T1_LOG" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# T1c (anti-vacuous negative control): the SAME counting mechanism, against a
# deliberately-reconstructed PRE-FIX call ORDER (stage BEFORE the self-update
# decision, unconditionally — the exact shape this fix replaced), must show 10
# fetches, not 5. This proves T1b's "not 10" claim is a real property of the
# ordering fix, not an artifact of how count_lib_fetches counts.
# ---------------------------------------------------------------------------
T1C_LOG=$(mktemp -p "$TMP")
{
    printf '#!/bin/bash\nset -uo pipefail\nlog(){ :; }\nwarn(){ :; }\nRETRY_OPTS=()\n'
    cat "$COMMON_BODY"
    printf '_UPGRADE_SH_DIR="%s"\n' "$TMP"
    # PRE-FIX order: stage FIRST (unconditional top-level shape), THEN decide
    # on self-update — a process about to be exec-replaced has already paid for
    # its own fetch, and the re-exec'd child pays again.
    printf '_stage_reconcile_transitive_deps\n'
    printf '_maybe_self_update_reexec "$@"\n'
    printf '_stage_reconcile_transitive_deps\n'
    printf 'echo "RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} staged=${_TRANSITIVE_DEPS_STAGED:-0} libdir=${LIB_DIR:-}"\n'
} > "$SERVED/partner-edge-upgrade.sh"
chmod +x "$SERVED/partner-edge-upgrade.sh"
NEWSHA=$(sha256sum "$SERVED/partner-edge-upgrade.sh" | awk '{print $1}')
printf '%s  partner-edge-upgrade.sh\n' "$NEWSHA" > "$SERVED/SHA256SUMS"

T1C_WRAP="$TMP/wrap_prefix_shape"
{
    cat <<PRE
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ :; }
CURL_LOG="$T1C_LOG"
SERVED_DIR="$SERVED"
curl() {
    local out="" url="" a=("\$@") i
    for ((i=0; i<\${#a[@]}; i++)); do
        case "\${a[i]}" in
            -o) out="\${a[i+1]}" ;;
            *"://"*) url="\${a[i]}" ;;
        esac
    done
    echo "\$url" >> "\$CURL_LOG"
    local base; base=\$(basename "\$url")
    if [[ -f "\${SERVED_DIR:-}/\$base" ]]; then cp -f "\$SERVED_DIR/\$base" "\$out"; return 0; fi
    return 1
}
export -f curl
export CURL_LOG SERVED_DIR
PRE
    cat "$COMMON_BODY"
    printf '_UPGRADE_SH_DIR="%s"\n' "$TMP"
    printf '_stage_reconcile_transitive_deps\n'
    printf '_maybe_self_update_reexec "$@"\n'
    printf '_stage_reconcile_transitive_deps\n'
    printf 'echo "RAN sentinel=${OXPULSE_UPGRADE_REEXECED:-0} staged=${_TRANSITIVE_DEPS_STAGED:-0} libdir=${LIB_DIR:-}"\n'
} > "$T1C_WRAP"
chmod +x "$T1C_WRAP"
env TMPDIR="$TMP" REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main" \
    RELEASES_BASE="https://example.invalid/releases" \
    INSTALL_LIB_DIR="$TMP/nonexistent-installdir" \
    RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 \
    PREFIX_SBIN="$TMP" OXPULSE_INSTALLED_UPGRADE_PATH="$T1C_WRAP" \
    bash "$T1C_WRAP" v9.9.9 >/dev/null 2>&1 || true
T1C_FETCHES=$(count_lib_fetches "$T1C_LOG")
if [[ "$T1C_FETCHES" -eq 10 ]]; then
    pass "T1c: negative control — the pre-fix call order (stage-before-reexec-decision) reproduces the 10-fetch double-stage this PR fixes, proving T1b's '5 not 10' is a real ordering property"
else
    fail "T1c: negative control expected 10 fetches (the bug this PR fixes) from the pre-fix ordering, got $T1C_FETCHES — count_lib_fetches or the harness itself may not be exercising a real re-exec"
fi

# ---------------------------------------------------------------------------
# T2: self-update does NOT fire (no SHA256SUMS => _maybe_self_update_reexec
#     skips per its fail-safe) => the SAME single process continues on to stage
#     => still exactly 5 fetches (not 0 — staging must still happen), and
#     staged=1 with sentinel=0 (never re-exec'd).
# ---------------------------------------------------------------------------
T2_LOG=$(mktemp -p "$TMP")
T2_OUT=$(run_wrap 0 "$T2_LOG")
T2_FETCHES=$(count_lib_fetches "$T2_LOG")
if printf '%s\n' "$T2_OUT" | grep 'RAN sentinel=0 staged=1' >/dev/null; then
    pass "T2a: no-reexec path ran once with sentinel=0 staged=1 (single process, no exec)"
else
    fail "T2a: expected 'RAN sentinel=0 staged=1'; got: $T2_OUT"
fi
if [[ "$T2_FETCHES" -eq 5 ]]; then
    pass "T2b: no-reexec path still stages exactly 5 lib files (staging isn't accidentally skipped for every mode)"
else
    fail "T2b: expected exactly 5 lib fetches on the no-reexec path, got $T2_FETCHES"
fi

# ---------------------------------------------------------------------------
# T3: idempotency guard — calling _stage_reconcile_transitive_deps twice in the
#     SAME process must not re-fetch (defensive; not on any real call path
#     today, but a future refactor must not silently double the fetch count).
# ---------------------------------------------------------------------------
T3_LOG=$(mktemp -p "$TMP")
# Written to a real script FILE (not `bash -c`), same as run_wrap's WRAP: with
# `bash -c`, BASH_SOURCE[0] is empty, so _stage_lib's tier-1 "adjacent checkout"
# resolution falls back to `pwd`(dirname("") = ".") — which, from this test's own
# cwd (the repo root), would accidentally resolve the REAL lib/lib-checksums.txt
# instead of exercising the intended tier-3 REPO_RAW fetch of the fixture
# manifest, and fail with a real-vs-fixture checksum mismatch unrelated to what
# this test checks. A real script file gives BASH_SOURCE[0] a path under $TMP
# (no adjacent lib/), forcing the same tier-3 path run_wrap's T1/T2 exercise.
T3_SCRIPT="$TMP/t3_idempotent.sh"
{
    cat <<T3PRE
#!/bin/bash
set -uo pipefail
CURL_LOG="$T3_LOG"
SERVED_DIR="$SERVED"
curl() {
    local out="" url="" a=("\$@") i
    for ((i=0; i<\${#a[@]}; i++)); do
        case "\${a[i]}" in
            -o) out="\${a[i+1]}" ;;
            *"://"*) url="\${a[i]}" ;;
        esac
    done
    echo "\$url" >> "\$CURL_LOG"
    local base; base=\$(basename "\$url")
    if [[ -f "\${SERVED_DIR:-}/\$base" ]]; then cp -f "\$SERVED_DIR/\$base" "\$out"; return 0; fi
    return 1
}
log(){ :; }; warn(){ :; }; die(){ echo "DIED: \$*" >&2; exit 1; }
T3PRE
    cat "$LOOKUP_FN"
    cat "$STAGE_LIB_FN"
    cat "$STAGE_DEPS_FN"
    cat <<T3POST
_CLEANUP_PATHS=()
_UPGRADE_SH_DIR="$TMP"
REPO_RAW="https://raw.example.test/oxpulse-partner-edge/main"
INSTALL_LIB_DIR="$TMP/nonexistent-installdir"
_stage_reconcile_transitive_deps
FIRST_DIR="\$LIB_DIR"
_stage_reconcile_transitive_deps
echo "FIRST=\$FIRST_DIR SECOND=\$LIB_DIR GUARD=\$_TRANSITIVE_DEPS_STAGED"
T3POST
} > "$T3_SCRIPT"
chmod +x "$T3_SCRIPT"
T3_OUT=$(bash "$T3_SCRIPT" 2>&1)
T3_FETCHES=$(count_lib_fetches "$T3_LOG")
if [[ "$T3_FETCHES" -eq 5 ]] && printf '%s\n' "$T3_OUT" | grep 'GUARD=1' >/dev/null; then
    pass "T3: calling _stage_reconcile_transitive_deps twice in one process fetches only once (idempotency guard holds); out: $T3_OUT"
else
    fail "T3: idempotency guard did not prevent a second fetch (fetches=$T3_FETCHES); out: $T3_OUT"
fi

echo ""
echo "=== transitive-dep stage-once tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
