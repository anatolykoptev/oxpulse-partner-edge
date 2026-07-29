#!/bin/bash
# tests/test_upgrade_xray_healthcheck_heal.sh
#
# Regression + idempotency guard for _patch_compose_xray_healthcheck_probe(),
# the LIVE-BOX MIGRATION SHIM added to upgrade.sh (2026-07-28).
#
# Problem under test:
#   docker-compose.yml.tpl's xray-client healthcheck was `ss -ltn | grep -q
#   ':3080'` — it only asserted that something was listening on :3080, never
#   that the tunnel carried traffic. During the oxpulse-chat#2716 outage
#   both failing edges reported `healthy` for >24h while Caddy returned 502
#   on every probe through that same container. The TEMPLATE fix (first
#   commit of this PR) replaced the port check with a wget probe to
#   http://127.0.0.1:3080/api/health/live — but upgrade.sh never re-renders
#   docker-compose.yml from the template on an existing box, only sed-patches
#   image tags in place, so the template fix alone never reaches an
#   already-deployed compose file. A compose-level healthcheck also overrides
#   the image HEALTHCHECK, so the Dockerfile probe is masked too.
#
# Fix under test:
#   _patch_compose_xray_healthcheck_probe() replaces the test line, bumps
#   timeout 5s → 10s, and adds start_period: 30s — all scoped to the xray
#   healthcheck block — called from both compose-patch sites in upgrade.sh
#   (--with-templates and plain apply paths).
#
# Falsification (anti-vacuous):
#   Case (a) requires the new wget probe to actually be present and the old
#   ss -ltn form to be gone (not just "no crash"). Case (b) requires
#   BYTE-IDENTICAL output (not just "no error") on an already-healed file —
#   a sed that always mutates something would fail this via sha256 diff.
#   Case (c) requires other services' healthcheck blocks (caddy/coturn with
#   timeout: 5s) to be byte-identical too — a too-broad sed that also touches
#   their timeout would fail this. Case (d) requires a second consecutive
#   run to be a byte-identical no-op.
#
# REAL-CODE MANDATE: the real _patch_compose_xray_healthcheck_probe is
# awk-extracted from upgrade.sh (same seam as test_upgrade_sfu_healthcheck_heal.sh)
# — no reimplementation, no mock.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo ""
echo "=== _patch_compose_xray_healthcheck_probe: live-box xray healthcheck heal shim ==="

# --- Extract the real function. ---
FN="$TMP/heal_fn.sh"
awk '/^_patch_compose_xray_healthcheck_probe\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$FN"
if [[ -s "$FN" ]] && grep -q '^_patch_compose_xray_healthcheck_probe()' "$FN"; then
    pass "S0: extraction captured _patch_compose_xray_healthcheck_probe (non-empty, has signature)"
else
    fail "S0: extraction empty or signature-less — awk pattern drifted from upgrade.sh"; exit 1
fi
if bash -n "$FN"; then
    pass "S1: extracted _patch_compose_xray_healthcheck_probe parses (self-contained)"
else
    fail "S1: extracted function has syntax errors"; exit 1
fi
# shellcheck source=/dev/null
source "$FN"

# --- Shared fixture pieces: an unrelated image-tag line, a caddy healthcheck
# block (also uses timeout: 5s — adversarial for a too-broad timeout sed). ---
IMAGE_LINE='    image: ghcr.io/anatolykoptev/partner-edge-xray:v0.16.6'
CADDY_HC_BLOCK='    healthcheck:
      test: ["CMD", "wget", "-qO-", "--header=Host: localhost", "http://127.0.0.1:2019/config/"]
      interval: 30s
      timeout: 5s
      retries: 3'
COTURN_HC_BLOCK='    healthcheck:
      test: ["CMD-SHELL", "pgrep turnserver >/dev/null || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3'

# =============================================================================
# Case (a): a compose file WITH the old ss -ltn probe gets the new wget probe,
# timeout bumped, and start_period added.
# =============================================================================
BUGGY="$TMP/buggy.yml"
cat > "$BUGGY" <<EOF
  caddy:
$CADDY_HC_BLOCK

  xray-client:
$IMAGE_LINE
    expose:
      - "3080"
    healthcheck:
      test: ["CMD-SHELL", "ss -ltn | grep -q ':3080' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3

  coturn:
$COTURN_HC_BLOCK
EOF
_patch_compose_xray_healthcheck_probe "$BUGGY"

HC_LINE_A=$(grep 'CMD-SHELL.*3080' "$BUGGY")
if echo "$HC_LINE_A" | grep -qF 'wget -q -O /dev/null -T 5 http://127.0.0.1:3080/api/health/live'; then
    pass "a-1: test line replaced with wget tunnel-path probe"
else
    fail "a-1: test line still wrong: $HC_LINE_A"
fi
if echo "$HC_LINE_A" | grep -qF 'ss -ltn'; then
    fail "a-2: old ss -ltn probe still present: $HC_LINE_A"
else
    pass "a-2: old ss -ltn probe removed"
fi
# timeout must be bumped to 10s in the xray block.
XRAY_TIMEOUT=$(awk '/xray-client/{f=1} f && /timeout:/{print; exit}' "$BUGGY")
if echo "$XRAY_TIMEOUT" | grep -qF 'timeout: 10s'; then
    pass "a-3: xray timeout bumped to 10s"
else
    fail "a-3: xray timeout not bumped: $XRAY_TIMEOUT"
fi
# start_period must be added.
if grep -qF 'start_period: 30s' "$BUGGY"; then
    pass "a-4: start_period: 30s added"
else
    fail "a-4: start_period: 30s missing"
fi

# =============================================================================
# Case (b): an ALREADY-HEALED compose file (new probe in place) is left
# BYTE-IDENTICAL — true no-op idempotency.
# =============================================================================
HEALED="$TMP/healed.yml"
cp "$BUGGY" "$HEALED"   # $BUGGY is now post-heal from case (a)
SHA_BEFORE_B=$(sha256sum "$HEALED" | awk '{print $1}')
_patch_compose_xray_healthcheck_probe "$HEALED"
SHA_AFTER_B=$(sha256sum "$HEALED" | awk '{print $1}')
if [[ "$SHA_BEFORE_B" == "$SHA_AFTER_B" ]]; then
    pass "b: already-healed compose file is byte-identical after re-running the heal"
else
    fail "b: re-running heal on an already-healed file mutated it (sha $SHA_BEFORE_B -> $SHA_AFTER_B)"
fi

# =============================================================================
# Case (c): unrelated lines — image tag, caddy/coturn healthcheck blocks
# (which also use timeout: 5s) — are provably untouched by this sed.
# =============================================================================
if grep -qF "$IMAGE_LINE" "$BUGGY"; then
    pass "c-1: image tag line untouched"
else
    fail "c-1: image tag line was modified by the healthcheck-only sed"
fi
# Caddy timeout must STILL be 5s (not bumped to 10s).
CADDY_TIMEOUT=$(awk '/caddy:/{f=1} f && /timeout:/{print; exit}' "$BUGGY")
if echo "$CADDY_TIMEOUT" | grep -qF 'timeout: 5s'; then
    pass "c-2: caddy healthcheck timeout untouched (still 5s)"
else
    fail "c-2: caddy timeout was modified by the xray-scoped sed: $CADDY_TIMEOUT"
fi
# Coturn timeout must STILL be 5s.
COTURN_TIMEOUT=$(awk '/coturn:/{f=1} f && /timeout:/{print; exit}' "$BUGGY")
if echo "$COTURN_TIMEOUT" | grep -qF 'timeout: 5s'; then
    pass "c-3: coturn healthcheck timeout untouched (still 5s)"
else
    fail "c-3: coturn timeout was modified by the xray-scoped sed: $COTURN_TIMEOUT"
fi
# Caddy test line must be untouched.
if grep -qF 'http://127.0.0.1:2019/config/' "$BUGGY"; then
    pass "c-4: caddy healthcheck test line untouched"
else
    fail "c-4: caddy healthcheck test line was modified"
fi

# =============================================================================
# Case (d): idempotency across two consecutive runs on a freshly-buggy file —
# second run must be a no-op (matches case a's output byte-for-byte).
# =============================================================================
DOUBLE="$TMP/double.yml"
cat > "$DOUBLE" <<EOF
  xray-client:
    healthcheck:
      test: ["CMD-SHELL", "ss -ltn | grep -q ':3080' || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF
_patch_compose_xray_healthcheck_probe "$DOUBLE"
SHA_FIRST=$(sha256sum "$DOUBLE" | awk '{print $1}')
_patch_compose_xray_healthcheck_probe "$DOUBLE"
SHA_SECOND=$(sha256sum "$DOUBLE" | awk '{print $1}')
if [[ "$SHA_FIRST" == "$SHA_SECOND" ]]; then
    pass "d: second consecutive run is a byte-identical no-op"
else
    fail "d: second run further mutated an already-healed file (sha $SHA_FIRST -> $SHA_SECOND)"
fi

# =============================================================================
# Case (e): a file with NEITHER form (custom healthcheck) is left untouched.
# =============================================================================
CUSTOM="$TMP/custom.yml"
cat > "$CUSTOM" <<EOF
  xray-client:
    healthcheck:
      test: ["CMD-SHELL", "custom-probe --port 3080 || exit 1"]
      interval: 30s
      timeout: 5s
      retries: 3
EOF
SHA_BEFORE_E=$(sha256sum "$CUSTOM" | awk '{print $1}')
_patch_compose_xray_healthcheck_probe "$CUSTOM"
SHA_AFTER_E=$(sha256sum "$CUSTOM" | awk '{print $1}')
if [[ "$SHA_BEFORE_E" == "$SHA_AFTER_E" ]]; then
    pass "e: custom-probe file (neither old nor new form) is byte-identical no-op"
else
    fail "e: heal mutated a file that has neither the old nor new probe (sha $SHA_BEFORE_E -> $SHA_AFTER_E)"
fi

# =============================================================================
# Case (f): wiring — both mutation sites in upgrade.sh call the heal helper
# right after the existing image-tag sed (same pattern as the SFU shim).
# =============================================================================
CALL_COUNT=$(grep -c '_patch_compose_xray_healthcheck_probe "\$COMPOSE_FILE"' "$UPGRADE" || true)
if [[ "$CALL_COUNT" -eq 2 ]]; then
    pass "f: _patch_compose_xray_healthcheck_probe called at exactly 2 compose-patch sites"
else
    fail "f: expected 2 call sites, found $CALL_COUNT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
