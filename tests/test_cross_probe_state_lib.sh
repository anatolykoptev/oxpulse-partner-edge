#!/usr/bin/env bash
# tests/test_cross_probe_state_lib.sh — direct-source unit tests for the
# cross-probe token/roster/offset/state read+write surface extracted into
# lib/cross-probe-lib.sh (strangler-fig from oxpulse-channels-health-report.sh).
#
# NO prior function-level coverage existed for these four functions; the
# black-box loop oracle (tests/test_cross_probe_loop.sh) only exercised them
# transitively. This suite pins their contract directly and is RED-first by
# construction: at the pre-extraction commit lib/cross-probe-lib.sh does not
# exist, so `source` below fails and every case fails. (Verified by temporarily
# moving the lib aside → whole suite RED, restore → GREEN.)
#
# Covers:
#   1. lib sources cleanly + all 8 functions defined (extraction completeness)
#   2. _read_cross_probe_token   — env override / file fallback / none→exit1
#   3. _peer_roster_file         — STATE_DIR default / _PEER_ROSTER_FILE override
#   4. _read_peer_probe_offset   — env override / state-file / missing+malformed→0
#   5. _write_peer_probe_state   — field-exact marker, 0640 mode, atomic (no temp leak)
#   6. SECRET NON-LEAK fitness   — no log/warn/echo of the token; secret var absent;
#                                  the only bearer print is the CURL_TRACE debug seam
#
# House style: plain bash, ok()/fail(), mktemp -d, no bats/shunit.

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/cross-probe-lib.sh"

PASS=0; FAIL=0
ok()   { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "test_cross_probe_state_lib.sh"
echo

# ── Case 1: lib sources + all functions present ───────────────────────────────
if [[ ! -f "$LIB" ]]; then
    fail "lib/cross-probe-lib.sh not found at $LIB (extraction missing)"
    echo; echo "Cross-probe state lib: PASS=$PASS FAIL=$FAIL"; exit 1
fi
# shellcheck source=lib/cross-probe-lib.sh disable=SC1090
source "$LIB"
for fn in _read_cross_probe_token _peer_roster_file _read_peer_probe_offset \
          _write_peer_probe_state _probe_peer_coturn _probe_peer_udp_stun \
          _post_cross_probe _run_peer_probe_loop; do
    if declare -F "$fn" >/dev/null; then
        ok "case1: $fn defined by the lib"
    else
        fail "case1: $fn NOT defined after sourcing the lib"
    fi
done
# Double-source guard: a second source must be a no-op (guard var set).
# shellcheck source=lib/cross-probe-lib.sh disable=SC1090
source "$LIB"
[[ "${_CROSS_PROBE_LIB_LOADED:-0}" -eq 1 ]] \
    && ok "case1: double-source guard sets _CROSS_PROBE_LIB_LOADED=1" \
    || fail "case1: double-source guard var not set"

# ── Case 2: _read_cross_probe_token ───────────────────────────────────────────
# env override wins
OUT=$(OXPULSE_CROSS_PROBE_TOKEN="xprb_env" _read_cross_probe_token); RC=$?
[[ "$RC" -eq 0 && "$OUT" == "xprb_env" ]] \
    && ok "case2: env OXPULSE_CROSS_PROBE_TOKEN wins (exit0, verbatim)" \
    || fail "case2: env override: rc=$RC out='$OUT'"

# file fallback (env unset)
T2=$(mktemp -d); printf 'xprb_file_body' > "$T2/tok"
OUT=$(unset OXPULSE_CROSS_PROBE_TOKEN; _CROSS_PROBE_TOKEN_FILE="$T2/tok" _read_cross_probe_token); RC=$?
[[ "$RC" -eq 0 && "$OUT" == "xprb_file_body" ]] \
    && ok "case2: token file fallback (0600 file → verbatim, exit0)" \
    || fail "case2: file fallback: rc=$RC out='$OUT'"
rm -rf "$T2"

# none → exit 1, empty
OUT=$(unset OXPULSE_CROSS_PROBE_TOKEN; _CROSS_PROBE_TOKEN_FILE="/nonexistent/tok" _read_cross_probe_token); RC=$?
[[ "$RC" -eq 1 && -z "$OUT" ]] \
    && ok "case2: no env + no file → exit1, empty (loop self-skips)" \
    || fail "case2: none-path: rc=$RC out='$OUT'"

# ── Case 3: _peer_roster_file ─────────────────────────────────────────────────
OUT=$(unset _PEER_ROSTER_FILE; STATE_DIR="/var/lib/xtest" _peer_roster_file)
[[ "$OUT" == "/var/lib/xtest/peer-roster.json" ]] \
    && ok "case3: roster path defaults to \$STATE_DIR/peer-roster.json" \
    || fail "case3: default roster path: '$OUT'"
OUT=$(_PEER_ROSTER_FILE="/custom/roster.json" STATE_DIR="/ignored" _peer_roster_file)
[[ "$OUT" == "/custom/roster.json" ]] \
    && ok "case3: _PEER_ROSTER_FILE override wins" \
    || fail "case3: roster override: '$OUT'"

# ── Case 4: _read_peer_probe_offset ───────────────────────────────────────────
OUT=$(OXPULSE_PEER_PROBE_OFFSET="7" _read_peer_probe_offset)
[[ "$OUT" == "7" ]] \
    && ok "case4: env OXPULSE_PEER_PROBE_OFFSET override wins" \
    || fail "case4: offset env override: '$OUT'"

T4=$(mktemp -d); printf 'PEER_PROBE_OFFSET=3\nPEER_PROBE_MODE=peer\n' > "$T4/peer-probe-mode.env"
OUT=$(unset OXPULSE_PEER_PROBE_OFFSET; STATE_DIR="$T4" _read_peer_probe_offset)
[[ "$OUT" == "3" ]] \
    && ok "case4: offset read from persisted peer-probe-mode.env" \
    || fail "case4: offset from state file: '$OUT'"

OUT=$(unset OXPULSE_PEER_PROBE_OFFSET; STATE_DIR="$T4/missing" _read_peer_probe_offset)
[[ "$OUT" == "0" ]] \
    && ok "case4: missing state file → offset 0" \
    || fail "case4: missing→0: '$OUT'"

printf 'PEER_PROBE_OFFSET=not-a-number\n' > "$T4/peer-probe-mode.env"
OUT=$(unset OXPULSE_PEER_PROBE_OFFSET; STATE_DIR="$T4" _read_peer_probe_offset)
[[ "$OUT" == "0" ]] \
    && ok "case4: malformed offset → 0 (fail-safe)" \
    || fail "case4: malformed→0: '$OUT'"
rm -rf "$T4"

# ── Case 5: _write_peer_probe_state ───────────────────────────────────────────
T5=$(mktemp -d)
STATE_DIR="$T5" _write_peer_probe_state "peer" 2 1 0 0 5 "peerX,peerY"
SF="$T5/peer-probe-mode.env"
if [[ -r "$SF" ]]; then
    ok "case5: peer-probe-mode.env written"
    grep -q '^PEER_PROBE_MODE=peer$'          "$SF" && ok "case5: MODE=peer"        || fail "case5: MODE"
    grep -q '^PEER_PROBE_PROBED=2$'           "$SF" && ok "case5: PROBED=2"          || fail "case5: PROBED"
    grep -q '^PEER_PROBE_OK=1$'               "$SF" && ok "case5: OK=1"              || fail "case5: OK"
    grep -q '^PEER_PROBE_OFFSET=5$'           "$SF" && ok "case5: OFFSET=5"          || fail "case5: OFFSET"
    grep -q '^PEER_PROBE_DROPPED=peerX,peerY$' "$SF" && ok "case5: DROPPED preserved" || fail "case5: DROPPED"
    MODE=$(stat -c '%a' "$SF")
    [[ "$MODE" == "640" ]] && ok "case5: marker mode 0640 (not world-readable)" \
                           || fail "case5: marker mode is $MODE (want 640)"
else
    fail "case5: peer-probe-mode.env not written"
fi
# Atomic: no mktemp remnant left behind in STATE_DIR.
LEFT=$(find "$T5" -maxdepth 1 -name 'peer-probe-mode.??????' 2>/dev/null | wc -l)
[[ "$LEFT" -eq 0 ]] \
    && ok "case5: atomic write leaves no temp file" \
    || fail "case5: $LEFT leftover temp file(s)"
rm -rf "$T5"

# ── Case 6: SECRET NON-LEAK fitness (grep the shipped lib) ─────────────────────
# The server-side HMAC secret var name must never appear in this lib's CODE (the
# lib only ever handles the derived xprb_ bearer, read+forwarded, never the
# secret). Strip full-line comments so documentation prose can't false-positive.
if grep -vE '^[[:space:]]*#' "$LIB" | grep -q 'CROSS_PROBE_TOKEN_SECRET'; then
    fail "case6: CROSS_PROBE_TOKEN_SECRET referenced in lib code (must not be)"
else
    ok "case6: server-side secret var never referenced in lib code"
fi
# No log/warn statement may carry a token value (would land the bearer in journald).
if grep -nE '\b(log|warn)\b[^#]*\$\{?(token|OXPULSE_CROSS_PROBE_TOKEN)' "$LIB"; then
    fail "case6: a log/warn line carries the token (journald leak)"
else
    ok "case6: no log/warn line emits the token"
fi
# The ONLY place the bearer is printed is the DRY_RUN+CURL_TRACE debug seam; that
# printf-to-stderr must stay CURL_TRACE-guarded (regression tripwire).
if grep -B2 "Authorization: Bearer %s" "$LIB" | grep -q 'CURL_TRACE'; then
    ok "case6: bearer print is CURL_TRACE-guarded (debug seam intact)"
else
    fail "case6: bearer print is NOT behind a CURL_TRACE guard"
fi
# _read_cross_probe_token returns the token on stdout (its API) but never logs it.
if grep -A12 '^_read_cross_probe_token()' "$LIB" | grep -qE '\b(log|warn)\b'; then
    fail "case6: _read_cross_probe_token calls log/warn (must be silent)"
else
    ok "case6: _read_cross_probe_token is silent (token only via stdout return)"
fi

echo
echo "Cross-probe state lib: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
