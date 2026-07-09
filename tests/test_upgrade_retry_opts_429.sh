#!/bin/bash
# tests/test_upgrade_retry_opts_429.sh
#
# PR2 finding 4b test — 429-aware curl retry.
#
# Problem under test:
#   A live v0.14.4 fleet rollout hit GitHub's anonymous rate limit (HTTP 429) on
#   2 of 5 relay nodes while upgrade.sh staged its transitive-dep libs. curl's
#   `-f`/`--fail` treats a 429 as an immediate hard failure — `--retry` alone does
#   NOT retry HTTP error responses (only transport-level failures) unless paired
#   with `--retry-all-errors` (curl >=7.71).
#
# Fix under test:
#   RETRY_OPTS=(--retry 3 --retry-delay 2 --retry-max-time 60 [--retry-all-errors])
#   defined near the top of upgrade.sh/install.sh, with --retry-all-errors gated
#   on a one-time `curl --version` probe (>=7.71) so an older curl is never handed
#   an option it might reject.
#
# Falsification (anti-vacuous):
#   T1 proves a BARE curl -f (no RETRY_OPTS) against a 429-then-200 server FAILS
#   immediately (the pre-fix behaviour) — this is the regression RETRY_OPTS fixes,
#   not a strawman. T2 proves the SAME request WITH the real RETRY_OPTS extracted
#   from upgrade.sh SUCCEEDS. Both use REAL curl against a REAL flaky local HTTP
#   server (no bash-level retry stub) — the property under test is curl's own
#   retry behaviour, which cannot be faithfully simulated by a bash mock.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
INSTALL="$REPO_ROOT/install.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== PR2 finding 4b: RETRY_OPTS makes curl survive a transient 429 ==="

[[ -f "$UPGRADE" ]] || { fail "P0: upgrade.sh not found"; exit 1; }
[[ -f "$INSTALL" ]] || { fail "P0: install.sh not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { fail "P0: python3 not available for the flaky-server fixture"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# S0-S1: RETRY_OPTS is defined in both scripts, before the first curl call
# that needs it (structural — the array must exist before _source_lib/
# _stage_lib/_install_lib_source are ever invoked).
# ---------------------------------------------------------------------------
bash -n "$UPGRADE" && pass "S0: upgrade.sh passes bash -n" || { fail "S0: upgrade.sh syntax error"; exit 1; }
bash -n "$INSTALL" && pass "S0b: install.sh passes bash -n" || { fail "S0b: install.sh syntax error"; exit 1; }

grep -qE '^RETRY_OPTS=\(--retry 3 --retry-delay 2 --retry-max-time 60\)' "$UPGRADE" \
    && pass "S1: upgrade.sh defines RETRY_OPTS=(--retry 3 --retry-delay 2 --retry-max-time 60)" \
    || fail "S1: RETRY_OPTS not defined with the expected base flags in upgrade.sh"

grep -qE '^RETRY_OPTS=\(--retry 3 --retry-delay 2 --retry-max-time 60\)' "$INSTALL" \
    && pass "S1b: install.sh defines the same base RETRY_OPTS" \
    || fail "S1b: RETRY_OPTS not defined with the expected base flags in install.sh"

for f in "$UPGRADE" "$INSTALL"; do
    n=$(basename "$f")
    retry_line=$(grep -nE '^RETRY_OPTS=' "$f" | head -1 | cut -d: -f1 || true)
    first_use_line=$(grep -nE '\$\{RETRY_OPTS\[@\]\}' "$f" | head -1 | cut -d: -f1 || true)
    if [[ -n "$retry_line" && -n "$first_use_line" && "$retry_line" -lt "$first_use_line" ]]; then
        pass "S2($n): RETRY_OPTS defined (line $retry_line) before its first splice site (line $first_use_line)"
    else
        fail "S2($n): RETRY_OPTS not defined before use (define=$retry_line use=$first_use_line)"
    fi
done

# S3: at least 5 splice sites in upgrade.sh (the bootstrap-tier _source_lib/_stage_lib
# fetches), at least 3 in install.sh (bootstrap fetch + _install_lib_source x2).
UPGRADE_SPLICES=$(grep -c '\${RETRY_OPTS\[@\]}' "$UPGRADE")
INSTALL_SPLICES=$(grep -c '\${RETRY_OPTS\[@\]}' "$INSTALL")
[[ "$UPGRADE_SPLICES" -ge 5 ]] \
    && pass "S3: upgrade.sh splices RETRY_OPTS into >=5 bootstrap-tier curl calls (got $UPGRADE_SPLICES)" \
    || fail "S3: expected >=5 RETRY_OPTS splice sites in upgrade.sh, got $UPGRADE_SPLICES"
[[ "$INSTALL_SPLICES" -ge 3 ]] \
    && pass "S3b: install.sh splices RETRY_OPTS into >=3 bootstrap-tier curl calls (got $INSTALL_SPLICES)" \
    || fail "S3b: expected >=3 RETRY_OPTS splice sites in install.sh, got $INSTALL_SPLICES"

# S4: the self-update-reexec fetches (both curl calls) now splice RETRY_OPTS. PR2
# deliberately left this untouched ("PR4 territory"); PR4/v0.14.5 claimed it — the
# same silent-429 that motivated RETRY_OPTS elsewhere was the ROOT CAUSE of the
# self-update no-op that killed 2/5 boxes in the v0.14.4 rollout. Assert the
# splice now covers BOTH fetches in the function.
REEXEC_SPLICES=$(sed -n '/_maybe_self_update_reexec()/,/^}$/p' "$UPGRADE" | grep -c '${RETRY_OPTS\[@\]}')
if [[ "$REEXEC_SPLICES" -ge 2 ]]; then
    pass "S4: _maybe_self_update_reexec's fetches splice RETRY_OPTS (>=2 sites, got $REEXEC_SPLICES) — PR4 429-hardened the self-update fetch"
else
    fail "S4: expected >=2 RETRY_OPTS splice sites in _maybe_self_update_reexec (upgrade.sh + SHA256SUMS fetch), got $REEXEC_SPLICES"
fi

# ---------------------------------------------------------------------------
# Extract the real RETRY_OPTS block (base array + curl-version probe) so the
# functional tests below exercise the ACTUAL code upgrade.sh runs, not a
# reimplementation.
# ---------------------------------------------------------------------------
RETRY_FN="$TMP/retry_opts.sh"
awk '/^RETRY_OPTS=\(--retry 3/{f=1} f{print} /^unset _curl_ver/{if(f)exit}' "$UPGRADE" > "$RETRY_FN"
if [[ -s "$RETRY_FN" ]] && grep -q '^RETRY_OPTS=' "$RETRY_FN"; then
    pass "X0: extraction captured the real RETRY_OPTS block (non-empty)"
else
    fail "X0: RETRY_OPTS extraction empty — awk anchor drifted from upgrade.sh"; exit 1
fi
bash -n "$RETRY_FN" && pass "X1: extracted RETRY_OPTS block parses" || { fail "X1: syntax error in extracted block"; exit 1; }

RETRY_ARR=$(bash -c "source '$RETRY_FN'; printf '%s\n' \"\${RETRY_OPTS[@]}\"")
if echo "$RETRY_ARR" | grep -qx -- '--retry-all-errors'; then
    pass "X2: this environment's curl ($(curl --version | head -1 | awk '{print $2}')) qualifies for --retry-all-errors, and RETRY_OPTS includes it"
else
    fail "X2: --retry-all-errors missing from RETRY_OPTS despite a qualifying curl ($(curl --version | head -1 | awk '{print $2}'))"
fi

# ---------------------------------------------------------------------------
# Flaky HTTP server fixture: returns 429 for the first FAIL_COUNT requests to
# a given path, then 200 with real content. Mirrors this repo's established
# python3 -m http.server convention (see test_upgrade_tag_form.sh) but needs a
# custom handler since the stdlib server has no built-in way to script a
# transient failure sequence.
# ---------------------------------------------------------------------------
SRV_PY="$TMP/flaky_server.py"
cat > "$SRV_PY" << 'PYEOF'
import sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer

PORT = int(sys.argv[1])
FAIL_COUNT = int(sys.argv[2])
BODY = b"lib-checksums-fixture-content\n"

hits = {}
lock = threading.Lock()

class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            n = hits.get(self.path, 0) + 1
            hits[self.path] = n
        if n <= FAIL_COUNT:
            self.send_response(429)
            self.send_header('Retry-After', '1')
            self.send_header('Content-Length', '0')
            self.end_headers()
            return
        self.send_response(200)
        self.send_header('Content-Length', str(len(BODY)))
        self.end_headers()
        self.wfile.write(BODY)
    def log_message(self, fmt, *args):
        pass

HTTPServer(('127.0.0.1', PORT), Handler).serve_forever()
PYEOF

PORT=18774
FAIL_COUNT=2
python3 "$SRV_PY" "$PORT" "$FAIL_COUNT" > "$TMP/server.log" 2>&1 &
SRV_PID=$!
for _i in 1 2 3 4 5; do
    curl -fsS --max-time 1 "http://127.0.0.1:$PORT/never-fails-because-fail-count-resets-per-path" >/dev/null 2>&1 && break
    sleep 1
done

# ---------------------------------------------------------------------------
# T1 (regression proof): a bare `curl -f` with NO retry options against a
# 429-then-200 endpoint fails immediately — this is the pre-fix behaviour
# RETRY_OPTS exists to cure. Non-vacuous: if this passed, RETRY_OPTS would be
# fixing nothing.
# ---------------------------------------------------------------------------
OUT_BARE="$TMP/out_bare.txt"
if curl -fsS --max-time 3 "http://127.0.0.1:$PORT/t1" -o "$OUT_BARE" 2>/dev/null; then
    fail "T1: bare curl -f unexpectedly SUCCEEDED against a 429 endpoint (fixture broken — cannot prove the fix)"
else
    pass "T1: bare curl -f (no RETRY_OPTS) fails immediately on a 429 — reproduces the pre-fix regression"
fi

# ---------------------------------------------------------------------------
# T2 (fix proof): the SAME request, with the real extracted RETRY_OPTS spliced
# in, survives the same 429-then-200 sequence and receives the real body.
# ---------------------------------------------------------------------------
OUT_RETRY="$TMP/out_retry.txt"
T2_RC=0
bash -c "
set -uo pipefail
source '$RETRY_FN'
curl -fsS --max-time 3 \"\${RETRY_OPTS[@]}\" \"http://127.0.0.1:$PORT/t2\" -o '$OUT_RETRY' 2>/dev/null
" || T2_RC=$?
if [[ "$T2_RC" -eq 0 ]] && [[ -f "$OUT_RETRY" ]] && grep -q 'lib-checksums-fixture-content' "$OUT_RETRY"; then
    pass "T2: curl with the real RETRY_OPTS survives a 429-then-200 sequence and gets the real body"
else
    fail "T2: curl with RETRY_OPTS did not survive the 429s (rc=$T2_RC, out=$(cat "$OUT_RETRY" 2>/dev/null || echo MISSING))"
fi

# ---------------------------------------------------------------------------
# T3: a DIFFERENT path (fresh per-path failure counter) also succeeds — proves
# T2 wasn't a fluke of request ordering/caching in the fixture.
# ---------------------------------------------------------------------------
OUT_RETRY2="$TMP/out_retry2.txt"
T3_RC=0
bash -c "
set -uo pipefail
source '$RETRY_FN'
curl -fsS --max-time 3 \"\${RETRY_OPTS[@]}\" \"http://127.0.0.1:$PORT/t3-different-path\" -o '$OUT_RETRY2' 2>/dev/null
" || T3_RC=$?
if [[ "$T3_RC" -eq 0 ]] && grep -q 'lib-checksums-fixture-content' "$OUT_RETRY2"; then
    pass "T3: a second, independent 429-then-200 path also succeeds with RETRY_OPTS"
else
    fail "T3: second path did not succeed with RETRY_OPTS (rc=$T3_RC)"
fi

kill "$SRV_PID" 2>/dev/null || true
wait "$SRV_PID" 2>/dev/null || true
SRV_PID=""

echo ""
echo "=== RETRY_OPTS 429 tests: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
