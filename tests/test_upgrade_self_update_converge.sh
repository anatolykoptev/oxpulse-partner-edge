#!/bin/bash
# tests/test_upgrade_self_update_converge.sh
#
# PR4 (v0.14.5) — self-update root-cause fix + convergence gate.
#
# LIVE INCIDENT (v0.14.4 rollout, 2/5 relay boxes):
#   The self-update fetch (_maybe_self_update_reexec's first curl) hit a silent
#   GitHub raw-CDN 429 and returned with ZERO diagnostic. The re-exec was skipped,
#   the OLD on-disk upgrade.sh process kept running, reached sync_host_scripts (which
#   installed the NEW host-script set to disk), then walked into a NEW
#   install-firewall.sh it did not understand and died deep in
#   reconcile_firewall_surface. No operator-visible clue that self-update no-op'd.
#
# THREE FIXES UNDER TEST:
#   A. ROOT CAUSE — the upgrade.sh fetch now warn()s on failure (parity with the
#      SHA256SUMS fetch) AND splices ${RETRY_OPTS[@]} (429-aware retry) into BOTH
#      curl calls, so a transient 429 is retried and, if it still fails, is loud.
#   B. _should_self_update() — the guard stack ("is self-update applicable to THIS
#      invocation") extracted into ONE predicate reused by both the re-exec fn and
#      the convergence gate (no second, drift-prone copy of the guard list).
#   C. _assert_self_update_converged() — fail-closed gate in each apply path, run
#      immediately AFTER sync_host_scripts: if this process is still executing the
#      OLD upgrade.sh while the NEW release bytes are already installed to the sbin
#      path, die() with an actionable "just re-run" message. No-op when self-update
#      was not applicable (dev/CI/manual/dry-run). Escape hatch
#      OXPULSE_UPGRADE_NO_CONVERGE_GATE=1 downgrades die->warn.
#
# Falsification (anti-vacuous): C-DIE requires the gate to die on divergent bytes;
# neutering _assert_self_update_converged to `return 0` flips it RED (verified during
# development). C-SILENT / C-NOTAPPLICABLE require it to NOT die. A-WARN requires the
# fetch-failure warn text to appear where it was silent before.
#
# REAL-CODE MANDATE: the predicate + gate are awk-extracted verbatim from upgrade.sh
# and inlined; only curl is stubbed (or a real flaky HTTP server is used for the
# retry proof, mirroring test_upgrade_retry_opts_429.sh).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== PR4: self-update root-cause fix + convergence gate ==="

[[ -f "$UPGRADE" ]] || { fail "P0: upgrade.sh not found"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"; [[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null || true' EXIT

# ---------------------------------------------------------------------------
# S0: upgrade.sh parses.
# ---------------------------------------------------------------------------
bash -n "$UPGRADE" && pass "S0: upgrade.sh passes bash -n" || { fail "S0: syntax error"; exit 1; }

# ---------------------------------------------------------------------------
# Extract the three real functions under test (self-contained awk blocks).
# ---------------------------------------------------------------------------
SHOULD_FN="$TMP/should.sh"
awk '/^_should_self_update\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$SHOULD_FN"
GATE_FN="$TMP/gate.sh"
awk '/^_assert_self_update_converged\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$GATE_FN"
REEXEC_FN="$TMP/reexec.sh"
awk '/^_maybe_self_update_reexec\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$REEXEC_FN"
LOOKUP_FN="$TMP/lookup.sh"
awk '/^_lookup_expected_hash\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$LOOKUP_FN"

for pair in "should:_should_self_update:$SHOULD_FN" \
            "gate:_assert_self_update_converged:$GATE_FN" \
            "reexec:_maybe_self_update_reexec:$REEXEC_FN"; do
    tag="${pair%%:*}"; rest="${pair#*:}"; sig="${rest%%:*}"; file="${rest#*:}"
    if [[ -s "$file" ]] && grep -q "^${sig}()" "$file" && bash -n "$file"; then
        pass "S1($tag): extracted $sig() is non-empty, signed, and parses"
    else
        fail "S1($tag): extraction of $sig() empty/signature-less/unparseable — awk drifted"; exit 1
    fi
done

# ---------------------------------------------------------------------------
# PART B — single-copy predicate reuse (structural).
# ---------------------------------------------------------------------------
echo ""
echo "--- Part B: _should_self_update single-copy predicate ---"

# Exactly one definition of the predicate in upgrade.sh.
DEF_COUNT=$(grep -c '^_should_self_update()' "$UPGRADE")
[[ "$DEF_COUNT" -eq 1 ]] \
    && pass "B1: _should_self_update defined exactly once (got $DEF_COUNT)" \
    || fail "B1: expected exactly one _should_self_update definition, got $DEF_COUNT"

# Both consumers CALL the predicate rather than re-implementing the guard list.
if grep -qE '^\s*_should_self_update \|\| return 0' <(sed -n '/^_maybe_self_update_reexec()/,/^}$/p' "$UPGRADE"); then
    pass "B2: _maybe_self_update_reexec calls _should_self_update (no inline guard copy)"
else
    fail "B2: _maybe_self_update_reexec does not delegate to _should_self_update"
fi
if grep -qE '^\s*_should_self_update \|\| return 0' <(sed -n '/^_assert_self_update_converged()/,/^}$/p' "$UPGRADE"); then
    pass "B3: _assert_self_update_converged calls _should_self_update (shared predicate)"
else
    fail "B3: _assert_self_update_converged does not delegate to _should_self_update"
fi

# ---------------------------------------------------------------------------
# PART A — root-cause: warn on fetch failure + RETRY_OPTS on both fetches.
# ---------------------------------------------------------------------------
echo ""
echo "--- Part A: root-cause fetch hardening ---"

# A1 (structural): both curl calls in _maybe_self_update_reexec splice RETRY_OPTS.
A1_SPLICES=$(grep -c '${RETRY_OPTS\[@\]}' "$REEXEC_FN")
[[ "$A1_SPLICES" -ge 2 ]] \
    && pass "A1: both _maybe_self_update_reexec fetches splice RETRY_OPTS (got $A1_SPLICES)" \
    || fail "A1: expected >=2 RETRY_OPTS splices in _maybe_self_update_reexec, got $A1_SPLICES"

# A2 (behavioural): the FIRST fetch (upgrade.sh asset) failing now emits a warn where
# it was previously silent. Drive the real fn with a curl stub that fails ONLY the
# upgrade.sh fetch; capture stderr and assert the new warn text appears.
WRAP_A="$TMP/wrap_a"
{
    cat <<'PRE'
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ echo "WARN: $*" >&2; }
RETRY_OPTS=()
# curl stub: FAIL the partner-edge-upgrade.sh fetch (simulate an exhausted-retry 429),
# succeed anything else. Proves the first-fetch failure branch is now loud.
curl() {
    local url="" i; local a=("$@")
    for ((i=0; i<${#a[@]}; i++)); do case "${a[i]}" in *"://"*) url="${a[i]}";; esac; done
    case "$url" in *partner-edge-upgrade.sh) return 1;; esac
    return 0
}
PRE
    cat "$LOOKUP_FN"
    cat "$SHOULD_FN"
    cat "$REEXEC_FN"
    printf '_maybe_self_update_reexec "$@"\n'
    printf 'echo "PARENT_CONTINUED"\n'
} > "$WRAP_A"
chmod +x "$WRAP_A"
A2_OUT=$(env TMPDIR="$TMP" RELEASES_BASE="https://example.invalid/releases" \
    RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 PREFIX_SBIN="$TMP" \
    OXPULSE_INSTALLED_UPGRADE_PATH="$WRAP_A" \
    bash "$WRAP_A" v9.9.9 2>&1 || true)
if printf '%s\n' "$A2_OUT" | grep -q 'WARN: self-update: could not fetch upgrade.sh' \
    && printf '%s\n' "$A2_OUT" | grep -q 'PARENT_CONTINUED'; then
    pass "A2: a failed upgrade.sh fetch now WARNs (was silent) and degrades to continue"
else
    fail "A2: expected a fetch-failure warn + PARENT_CONTINUED; got: $A2_OUT"
fi

# A3 (behavioural, real curl): a 429-then-200 on the upgrade.sh-asset URL succeeds via
# RETRY_OPTS. Mirrors test_upgrade_retry_opts_429.sh: real curl against a real flaky
# HTTP server, using the exact retry flags the fn splices. (The fn's --proto=https pin
# is a TLS concern orthogonal to retry and cannot target a localhost http fixture; the
# pin is asserted structurally elsewhere. Here we prove the RETRY behaviour on the
# self-update asset path.)
if command -v python3 >/dev/null 2>&1; then
    RETRY_BLOCK="$TMP/retry_block.sh"
    awk '/^RETRY_OPTS=\(--retry 3/{f=1} f{print} /^unset _curl_ver/{if(f)exit}' "$UPGRADE" > "$RETRY_BLOCK"
    SRV_PY="$TMP/flaky.py"
    cat > "$SRV_PY" << 'PYEOF'
import sys, threading
from http.server import BaseHTTPRequestHandler, HTTPServer
PORT = int(sys.argv[1]); FAIL_COUNT = int(sys.argv[2])
BODY = b"#!/bin/bash\n# released partner-edge-upgrade.sh\n"
hits = {}; lock = threading.Lock()
class H(BaseHTTPRequestHandler):
    def do_GET(self):
        with lock:
            n = hits.get(self.path, 0) + 1; hits[self.path] = n
        if n <= FAIL_COUNT:
            self.send_response(429); self.send_header('Content-Length','0'); self.end_headers(); return
        self.send_response(200); self.send_header('Content-Length', str(len(BODY))); self.end_headers(); self.wfile.write(BODY)
    def log_message(self, *a): pass
HTTPServer(('127.0.0.1', PORT), H).serve_forever()
PYEOF
    PORT=18775
    python3 "$SRV_PY" "$PORT" 2 > "$TMP/srv.log" 2>&1 &
    SRV_PID=$!
    for _i in 1 2 3 4 5; do
        curl -fsS --max-time 1 "http://127.0.0.1:$PORT/warmup" >/dev/null 2>&1 && break; sleep 1
    done
    A3_OUT="$TMP/a3_asset.sh"; A3_RC=0
    bash -c "
    set -uo pipefail
    source '$RETRY_BLOCK'
    curl -fsSL --max-time 5 \"\${RETRY_OPTS[@]}\" \"http://127.0.0.1:$PORT/v9.9.9/partner-edge-upgrade.sh\" -o '$A3_OUT' 2>/dev/null
    " || A3_RC=$?
    if [[ "$A3_RC" -eq 0 ]] && grep -q 'released partner-edge-upgrade.sh' "$A3_OUT"; then
        pass "A3: a 429-then-200 on the upgrade.sh-asset URL succeeds via RETRY_OPTS (real curl)"
    else
        fail "A3: RETRY_OPTS did not survive the 429 on the self-update asset (rc=$A3_RC)"
    fi
    kill "$SRV_PID" 2>/dev/null || true; wait "$SRV_PID" 2>/dev/null || true; SRV_PID=""
else
    pass "A3: SKIPPED (python3 unavailable for the flaky-server fixture)"
fi

# ---------------------------------------------------------------------------
# PART C — convergence gate behaviour.
# ---------------------------------------------------------------------------
echo ""
echo "--- Part C: convergence gate ---"

# The gate harness: a self-contained script that inlines _should_self_update +
# _assert_self_update_converged, calls the gate, and echoes GATE_SURVIVED if the gate
# returned (i.e. did NOT die). _installed is set to the harness file itself so the
# _should_self_update realpath-match (running == installed) holds when applicable —
# exactly the production shape (the running process IS the sbin copy). Divergence is
# modelled the way it actually occurs in prod: the on-disk (installed) bytes are the
# NEW release while OXPULSE_UPGRADE_PRESYNC_RUNNING_SHA is the OLD in-memory
# fingerprint captured before sync overwrote the file.
GATE_WRAP="$TMP/gate_wrap"
{
    cat <<'PRE'
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ echo "WARN: $*" >&2; }
die(){ echo "DIE: $1" >&2; exit 1; }
RETRY_OPTS=()
PRE
    cat "$SHOULD_FN"
    cat "$GATE_FN"
    printf '_assert_self_update_converged\n'
    printf 'echo "GATE_SURVIVED"\n'
} > "$GATE_WRAP"
chmod +x "$GATE_WRAP"
GATE_WRAP_SHA=$(sha256sum "$GATE_WRAP" | awk '{print $1}')
ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"

# run_gate PRESYNC_SHA INSTALLED_PATH EXTRA_ENV... — installed defaults to the wrapper.
run_gate() {
    local presync="$1" installed="$2"; shift 2
    env RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 PREFIX_SBIN="$TMP" \
        OXPULSE_INSTALLED_UPGRADE_PATH="$installed" \
        OXPULSE_UPGRADE_PRESYNC_RUNNING_SHA="$presync" \
        "$@" \
        bash "$GATE_WRAP" 2>&1 || true
}

# C1: applicable + CONVERGED (presync == installed bytes) => silent, gate survives.
C1_OUT=$(run_gate "$GATE_WRAP_SHA" "$GATE_WRAP")
if printf '%s\n' "$C1_OUT" | grep -q 'GATE_SURVIVED' \
    && ! printf '%s\n' "$C1_OUT" | grep -qE 'DIE:|WARN:'; then
    pass "C1: applicable + converged (running bytes == installed) => gate silent, proceeds"
else
    fail "C1: expected silent GATE_SURVIVED on converged bytes; got: $C1_OUT"
fi

# C2 (INCIDENT REPRODUCTION): applicable + DIVERGENT (old in-memory bytes, new bytes
# installed) => DIE, gate does NOT survive. This is the exact v0.14.4 failure the gate
# exists to catch. Non-vacuous: neutering _assert_self_update_converged to `return 0`
# makes this go RED (verified in development).
C2_OUT=$(run_gate "$ZERO_SHA" "$GATE_WRAP")
if printf '%s\n' "$C2_OUT" | grep -q 'DIE: self-update did not converge' \
    && ! printf '%s\n' "$C2_OUT" | grep -q 'GATE_SURVIVED'; then
    pass "C2: applicable + divergent bytes => gate DIES with the actionable re-run message (incident caught)"
else
    fail "C2: expected a convergence DIE; got: $C2_OUT"
fi

# C3: escape hatch OXPULSE_UPGRADE_NO_CONVERGE_GATE=1 on the SAME divergent case =>
# warn instead of die, gate survives.
C3_OUT=$(run_gate "$ZERO_SHA" "$GATE_WRAP" OXPULSE_UPGRADE_NO_CONVERGE_GATE=1)
if printf '%s\n' "$C3_OUT" | grep -q 'WARN: self-update did NOT converge' \
    && printf '%s\n' "$C3_OUT" | grep -q 'GATE_SURVIVED' \
    && ! printf '%s\n' "$C3_OUT" | grep -q 'DIE:'; then
    pass "C3: OXPULSE_UPGRADE_NO_CONVERGE_GATE=1 downgrades die->warn and proceeds"
else
    fail "C3: escape hatch did not downgrade to warn+proceed; got: $C3_OUT"
fi

# C4 (false-positive guard): self-update NOT applicable (running copy != installed
# path) => gate is a silent no-op EVEN THOUGH the bytes differ. Without this, every
# dev/CI/manual invocation (which always has running != installed bytes) would die —
# a correctness disaster for this repo's own test suite. Point _installed at a
# DIFFERENT real file so the realpath-match fails.
OTHER_INSTALLED="$TMP/other_installed"; printf 'different bytes\n' > "$OTHER_INSTALLED"
C4_OUT=$(run_gate "$ZERO_SHA" "$OTHER_INSTALLED")
if printf '%s\n' "$C4_OUT" | grep -q 'GATE_SURVIVED' \
    && ! printf '%s\n' "$C4_OUT" | grep -q 'DIE:'; then
    pass "C4: not-applicable invocation (running != installed path) => gate no-ops, never false-dies"
else
    fail "C4: gate false-died on a non-applicable (dev/CI) invocation; got: $C4_OUT"
fi

# C5 (dry-run applicability): DRY_RUN=1 => not applicable => no-op even on divergent bytes.
C5_OUT=$(env RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=1 PREFIX_SBIN="$TMP" \
    OXPULSE_INSTALLED_UPGRADE_PATH="$GATE_WRAP" OXPULSE_UPGRADE_PRESYNC_RUNNING_SHA="$ZERO_SHA" \
    bash "$GATE_WRAP" 2>&1 || true)
if printf '%s\n' "$C5_OUT" | grep -q 'GATE_SURVIVED' && ! printf '%s\n' "$C5_OUT" | grep -q 'DIE:'; then
    pass "C5: DRY_RUN=1 => gate no-ops (dry-run never self-updates)"
else
    fail "C5: gate did not no-op under DRY_RUN; got: $C5_OUT"
fi

# ---------------------------------------------------------------------------
# PART C — structural: BOTH apply paths call the gate AFTER their sync_host_scripts.
# ---------------------------------------------------------------------------
echo ""
echo "--- Part C: both apply paths wire the gate after sync_host_scripts ---"

# The gate must be called exactly at the two real apply-path Step-4 sync sites (the
# ones followed by baseline/pull), not the incidental opec-fallback syncs. We assert
# there are exactly two _assert_self_update_converged call sites and each is preceded
# (nearby, upward) by a `sync_host_scripts "$RELEASE_TAG"` line.
GATE_CALLS=$(grep -cE '^[[:space:]]*_assert_self_update_converged$' "$UPGRADE")
[[ "$GATE_CALLS" -eq 2 ]] \
    && pass "C6: exactly two _assert_self_update_converged call sites (one per apply path), got $GATE_CALLS" \
    || fail "C6: expected 2 gate call sites, got $GATE_CALLS"

# For each gate call line, the nearest preceding non-comment code line must be the real
# sync (either `sync_host_scripts "$RELEASE_TAG"` exactly — no `|| true`, no MODE guard).
STRUCT_OK=1
while IFS= read -r gate_ln; do
    prev=$(awk -v g="$gate_ln" 'NR<g && $0 ~ /[^[:space:]]/ && $0 !~ /^[[:space:]]*#/ {last=$0; lastn=NR} END{print last}' "$UPGRADE")
    if [[ "$prev" != *'sync_host_scripts "$RELEASE_TAG"'* ]]; then
        STRUCT_OK=0
        echo "  gate at line $gate_ln is preceded by: [$prev] (expected the Step-4 sync)"
    fi
done < <(grep -nE '^[[:space:]]*_assert_self_update_converged$' "$UPGRADE" | cut -d: -f1)
[[ "$STRUCT_OK" -eq 1 ]] \
    && pass "C7: each gate call sits immediately after its path's sync_host_scripts \"\$RELEASE_TAG\"" \
    || fail "C7: a gate call is not positioned right after the Step-4 sync"

echo ""
echo "=== PR4 self-update converge: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
