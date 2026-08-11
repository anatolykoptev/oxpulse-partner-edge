#!/bin/bash
# tests/test_upgrade_audit_log.sh
#
# upgrade.sh is the only job on an edge that can gate a change and roll it back,
# and until now it was the only one with no log. On 2026-08-11 the render gate
# fired on two edges and which check regressed was unrecoverable: it existed only
# in the run's stdout, and the caller had piped that away.
#
# The wrapper is extracted and run against a stub body — the same idiom the other
# upgrade tests use — so these assertions are hermetic: no network, no docker, no
# root. The claim that the log records a REAL gate verdict is a live-probe claim
# and is not made here.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== upgrade.sh audit log ==="

# The wrapper must sit ABOVE everything else: it can only capture a run it starts
# before. If it drifts below the network fetch or the arg parse, the first lines
# of every run — and any early die — stop being recorded.
# grep -m1 rather than `| head -1`: under `set -o pipefail` a piped head kills the
# producer on SIGPIPE and the pipeline reports failure — tests/test_pipefail_early_
# exit_guard.sh enforces that repo-wide.
_wrapper_line=$(grep -n -m1 '^UPGRADE_LOG=' "$UPGRADE" | cut -d: -f1)
_prefix_line=$(grep -n -m1 '^PREFIX_ETC=' "$UPGRADE" | cut -d: -f1)
if [[ -n "$_wrapper_line" && -n "$_prefix_line" && "$_wrapper_line" -lt "$_prefix_line" ]]; then
	pass "the wrapper is above the rest of the script (line $_wrapper_line < $_prefix_line)"
else
	fail "the wrapper is not above the script body — it cannot capture what runs before it"
fi

# Build a stub that carries the real wrapper verbatim and a body we control.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
STUB="$TMP/fake-upgrade.sh"
{
	echo '#!/bin/bash'
	echo 'set -euo pipefail'
	awk '/^# --- audit log ---/{f=1} /^PREFIX_ETC=/{exit} f{print}' "$UPGRADE"
	echo 'echo "BODY-RAN args=[$*]"'
	echo 'echo "BODY-STDERR" >&2'
	echo 'exit "${FAKE_RC:-0}"'
} > "$STUB"
chmod +x "$STUB"

bash -n "$STUB" || { echo "FAIL: the extracted wrapper does not parse"; exit 1; }

L="$TMP/up.log"

# 1 — a run is recorded at all: header, body, exit line.
OXPULSE_UPGRADE_LOG="$L" "$STUB" >/dev/null 2>&1
grep -q '^===== ' "$L"        && pass "a run writes a header"        || fail "no header in the log"
grep -q 'BODY-RAN'  "$L"      && pass "stdout is captured"           || fail "stdout missing from the log"
grep -q 'BODY-STDERR' "$L"    && pass "stderr is captured too"       || fail "stderr missing — a die would leave no trace"
grep -q '^===== exit 0' "$L"  && pass "the exit code is recorded"    || fail "no exit line in the log"

# 2 — THE ONE THIS EXISTS FOR. A FAILING run must be recorded, with its code.
: > "$L"
FAKE_RC=7 OXPULSE_UPGRADE_LOG="$L" "$STUB" >/dev/null 2>&1 || true
grep -q '^===== exit 7' "$L" \
	&& pass "a FAILING run records its exit code" \
	|| fail "the failure — the only run anyone reads the log for — was not recorded"

# 3 — the caller still sees the real exit code, not tee's.
: > "$L"
set +e
FAKE_RC=7 OXPULSE_UPGRADE_LOG="$L" "$STUB" >/dev/null 2>&1
_rc=$?
set -e
[[ "$_rc" == 7 ]] && pass "the caller's exit code survives the tee pipeline ($_rc)" \
                  || fail "exit code became $_rc — tee's, not the script's; every caller's gate breaks"

# 4 — SECRETS. --ghcr-token=… arrives as an ARGUMENT, so the header is the one
# place in this script where a credential can reach a file on disk.
: > "$L"
OXPULSE_UPGRADE_LOG="$L" "$STUB" --ghcr-token=ghp_AbCdEfGhIjKlMnOpQrStUvWxYz0123456789 >/dev/null 2>&1 || true
if grep -q 'ghp_AbCdEfGhIjKlMnOpQrStUvWxYz' "$L"; then
	fail "the GHCR token was written to the log in clear"
else
	pass "the GHCR token is redacted from the header"
fi
grep -q 'redacted' "$L" && pass "the redaction is visible, not a silent drop" \
                        || fail "the argument vanished instead of being marked redacted"

# 5 — redaction by SHAPE as well as by flag name: a token that arrives some other
# way is still masked. A flag-name-only rule is one rename away from leaking.
: > "$L"
OXPULSE_UPGRADE_LOG="$L" "$STUB" v0.16.22 gho_ZzZzZzZzZzZzZzZzZzZzZzZzZzZzZzZz >/dev/null 2>&1 || true
grep -q 'gho_ZzZzZzZzZzZz' "$L" \
	&& fail "a token-shaped argument leaked because only the flag name is matched" \
	|| pass "a token-shaped argument is masked whatever flag carried it"

# 6 — the log is never world-readable. It carries a full upgrade transcript.
: > "$L"; chmod 0644 "$L"; rm -f "$L"
OXPULSE_UPGRADE_LOG="$L" "$STUB" >/dev/null 2>&1
_mode=$(stat -c '%a' "$L" 2>/dev/null || stat -f '%Lp' "$L" 2>/dev/null)
[[ "$_mode" == "600" ]] && pass "the log is created 0600 (got $_mode)" \
                        || fail "the log is $_mode — a full transcript should not be world-readable"

# 7 — bounded without logrotate. An unbounded transcript on a 15G edge is a
# disk-filler, and shipping a rotate drop-in would be another host artefact.
: > "$L"
head -c 3000 /dev/zero | tr '\0' 'x' > "$L"
OXPULSE_UPGRADE_LOG="$L" OXPULSE_UPGRADE_LOG_MAX_BYTES=1000 "$STUB" >/dev/null 2>&1
_sz=$(wc -c < "$L")
[[ "$_sz" -lt 3000 ]] && pass "an oversized log is trimmed before the run ($_sz bytes)" \
                      || fail "the log grew unbounded ($_sz bytes)"
grep -q 'BODY-RAN' "$L" && pass "the trim keeps the CURRENT run, not just old bytes" \
                        || fail "trimming discarded the run it was supposed to record"

# 8 — the sentinel. Without it the re-exec recurses until the process table gives
# up, and it would do so on every edge at once.
: > "$L"
_out=$(OXPULSE_UPGRADE_LOG="$L" "$STUB" 2>&1)
_n=$(grep -c 'BODY-RAN' <<< "$_out")
[[ "$_n" == 1 ]] && pass "the body runs exactly once (sentinel holds)" \
                 || fail "the body ran $_n times — the re-exec recurses"

# 9 — an operator can turn it off, and an unwritable path must not abort the
# upgrade. A log that can refuse to run the upgrade is worse than no log.
: > "$L"
_out=$(OXPULSE_UPGRADE_LOG=none "$STUB" 2>&1) && _rc=0 || _rc=$?
grep -q 'BODY-RAN' <<< "$_out" && pass "OXPULSE_UPGRADE_LOG=none still runs the upgrade" \
                               || fail "disabling the log broke the upgrade"
set +e
_out=$(OXPULSE_UPGRADE_LOG=/proc/nonexistent/dir/up.log "$STUB" 2>&1)
_rc=$?
set -e
if [[ "$_rc" == 0 ]] && grep -q 'BODY-RAN' <<< "$_out"; then
	pass "an unwritable log path is skipped, not fatal"
else
	fail "an unwritable log path aborted the upgrade (rc=$_rc)"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
