#!/usr/bin/env bash
# tests/test_sfu_pubkey_gauge.sh — partner_edge_sfu_pubkey_applied must be able
# to reach BOTH values (#550).
#
# Measured on rvpn, zvonilka and ruoxp on 2026-08-07 — identical on all three:
#
#   _written  1 line, 114 chars, sha 20004dd2a6ae   (file: PEM, newlines as \n)
#   _live     3 lines, 112 chars, sha eb29fd8ee039  (printenv: real PEM)
#
# 114 = 112 + 2 across exactly two newlines — the same key in two
# representations. The raw string comparison could therefore never take the `1`
# branch: the gauge was pinned at 0 fleet-wide and its
# "signing-pubkey applied-vs-written MISMATCH" WARNING was a permanent false
# alarm. Nobody saw either, because nothing scrapes the edges' node_exporter.
#
# The two load-bearing cases pull in OPPOSITE directions, which is the point:
#   T1  the real fleet shape (escaped file vs real-newline live) -> 1
#   T2  a genuinely different key                                -> 0
# A fix that normalises too aggressively passes T1 and fails T2 — the same
# defect pointed the other way, and just as silent.
#
# Plain bash, no bats (repo convention).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
[[ -f "$REFRESH" ]] || { echo "FAIL: $REFRESH not found"; exit 1; }
PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_sfu_pubkey_gauge.sh"
echo

TC=$(mktemp -d)
trap 'rm -rf "$TC"' EXIT

_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$REFRESH"; }

PRE="$TC/preamble.sh"
{
    echo 'log(){ printf "LOG: %s\n" "$*" >> "'"$TC"'/logs"; }'
    echo 'emit_gauge(){ printf "%s\n" "$3" > "'"$TC"'/gauge"; }'
    _extract_fn _emit_sfu_applied_gauge
} > "$PRE"

if bash -n "$PRE" 2>/dev/null; then
    ok "T0: _emit_sfu_applied_gauge extracts and parses"
else
    bad "T0: preamble parse failed"
fi

# Two DIFFERENT keys that share their first line, so a fix that compares only
# the first line (an over-normalisation) is caught by T2 rather than sneaking
# through.
REAL_PEM=$'-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAreal000000000000000000000000=\n-----END PUBLIC KEY-----'
OTHER_PEM=$'-----BEGIN PUBLIC KEY-----\nMCowBQYDK2VwAyEAother11111111111111111111111=\n-----END PUBLIC KEY-----'
# The on-disk form: one line, newlines written as the two characters \n.
esc() { printf '%s' "$1" | sed ':a;N;$!ba;s/\n/\\n/g'; }

mkdir -p "$TC/bin"
_make_docker() {  # $1 = the value printenv returns, $2 = exit code
    printf '%s' "$1" > "$TC/live_value"
    cat > "$TC/bin/docker" <<STUB
#!/usr/bin/env bash
if [ "\$1" = "ps" ]; then echo "oxpulse-partner-sfu"; exit 0; fi
if [ "\$1" = "exec" ]; then cat "$TC/live_value"; exit $2; fi
exit 0
STUB
    chmod +x "$TC/bin/docker"
}
export PATH="$TC/bin:$PATH"

# _run FILE_CONTENT LIVE_VALUE [EXEC_RC] -> echoes the emitted gauge, or "none"
_run() {
    rm -f "$TC/gauge"; : > "$TC/logs"
    printf 'SFU_SIGNING_PUBLIC_KEY=%s\n' "$1" > "$TC/sfu-keys.env"
    _make_docker "$2" "${3:-0}"
    bash -c "source '$PRE'
        export SFU_KEYS_ENV='$TC/sfu-keys.env'
        export SFU_CONTAINER_NAME=oxpulse-partner-sfu
        export NODE_ID=test-node
        _emit_sfu_applied_gauge 1" >/dev/null 2>&1 || true
    cat "$TC/gauge" 2>/dev/null || echo none
}

# ── T1 — THE FLEET SHAPE: escaped file vs real-newline live -> 1 ────────────
g=$(_run "$(esc "$REAL_PEM")" "$REAL_PEM")
[[ "$g" == "1" ]] && ok "T1: escaped-newline file vs real-newline live -> 1 (applied)" \
                  || bad "T1: emitted '$g' for the SAME key in two representations — this is #550, the gauge cannot reach 1"

# ── T2 — THE INVERSE: a genuinely different key must still be 0 ─────────────
g=$(_run "$(esc "$REAL_PEM")" "$OTHER_PEM")
[[ "$g" == "0" ]] && ok "T2: a genuinely different key still reports 0 (mismatch)" \
                  || bad "T2: emitted '$g' for two DIFFERENT keys — the fix over-normalises and can no longer detect a real mismatch"

# ── T3 — the bare (unescaped, already-matching) form still works ────────────
# refresh writes bare; opec writes single-quoted. Both predate #550.
g=$(_run "plainkey" "plainkey")
[[ "$g" == "1" ]] && ok "T3: bare identical values -> 1 (pre-existing shape unchanged)" \
                  || bad "T3: emitted '$g' for identical bare values"

g=$(_run "'plainkey'" "plainkey")
[[ "$g" == "1" ]] && ok "T3b: single-quoted file value -> 1 (opec's shape)" \
                  || bad "T3b: emitted '$g' for a single-quoted value"

# ── T4 — skip paths must stay silent, not emit a misleading 0 ───────────────
rm -f "$TC/gauge"; : > "$TC/logs"
rm -f "$TC/sfu-keys.env"
_make_docker "$REAL_PEM" 0
bash -c "source '$PRE'
    export SFU_KEYS_ENV='$TC/sfu-keys.env'
    export SFU_CONTAINER_NAME=oxpulse-partner-sfu
    export NODE_ID=test-node
    _emit_sfu_applied_gauge 1" >/dev/null 2>&1 || true
[[ ! -f "$TC/gauge" ]] && ok "T4: absent env file -> no emission (not a 0)" \
                       || bad "T4: absent env file emitted '$(cat "$TC/gauge")'"

g=$(_run "" "$REAL_PEM")
[[ "$g" == "none" ]] && ok "T4b: empty written value -> no emission" \
                     || bad "T4b: empty written value emitted '$g'"

# A failed docker exec must skip, so a container mid-startup cannot fire a false
# 0 — the function's own stated contract.
g=$(_run "$(esc "$REAL_PEM")" "" 1)
[[ "$g" == "none" ]] && ok "T4c: docker exec failure -> no emission (transient, not a mismatch)" \
                     || bad "T4c: docker exec failure emitted '$g'"

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
