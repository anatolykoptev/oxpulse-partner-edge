#!/bin/bash
# tests/test_upgrade_sfu_healthcheck_heal.sh
#
# Regression + idempotency guard for _patch_compose_sfu_healthcheck_cidr(), the
# LIVE-BOX MIGRATION SHIM added to upgrade.sh (2026-07-08, v0.14.5 PR1).
#
# Problem under test:
#   docker-compose.yml.tpl's SFU healthcheck used to substitute the raw
#   {{AWG_ALLOCATED_IP}} template placeholder (CIDR-suffixed, e.g. 10.9.0.7/24)
#   directly into the wget URL host and nc -z relay-API host. That /CIDR
#   suffix makes wget/nc target resolution fail permanently -> docker reports
#   "unhealthy" forever even though the SFU itself is healthy (confirmed live
#   on edge-d, failingstreak=19471+, 6+ days). The TEMPLATE fix (this PR)
#   references ${SFU_METRICS_BIND}/${SFU_RELAY_API_BIND} instead — but
#   upgrade.sh never re-renders docker-compose.yml from the template on an
#   existing box, only sed-patches image tags in place, so the template fix
#   alone never reaches an already-deployed compose file.
#
# Fix under test:
#   _patch_compose_sfu_healthcheck_cidr() sed-strips the /CIDR suffix from
#   the two SFU healthcheck host tokens in an on-disk compose file, narrowly
#   anchored to those two positions, called from both compose-patch sites in
#   upgrade.sh (--with-templates and plain apply paths).
#
# Falsification (anti-vacuous):
#   Case (a) requires the CIDR to actually be gone post-patch (not just "no
#   crash"). Case (b) requires BYTE-IDENTICAL output (not just "no error") on
#   both an already-healed file and a fresh v0.14.5 ${SFU_METRICS_BIND} file —
#   a sed that always mutates something would fail this via sha256 diff.
#   Case (c) requires specific unrelated lines to be byte-identical too — a
#   too-broad regex that also touches the image tag or an unrelated
#   IP/CIDR-bearing comment would fail this.
#
# REAL-CODE MANDATE: the real _patch_compose_sfu_healthcheck_cidr is
# awk-extracted from upgrade.sh (same seam as test_upgrade_self_reexec.sh /
# test_upgrade_tag_form.sh) — no reimplementation, no mock.
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
echo "=== _patch_compose_sfu_healthcheck_cidr: live-box CIDR heal shim ==="

# --- Extract the real function (self-contained: one sed -i call). ---
FN="$TMP/heal_fn.sh"
awk '/^_patch_compose_sfu_healthcheck_cidr\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$FN"
if [[ -s "$FN" ]] && grep -q '^_patch_compose_sfu_healthcheck_cidr()' "$FN"; then
    pass "S0: extraction captured _patch_compose_sfu_healthcheck_cidr (non-empty, has signature)"
else
    fail "S0: extraction empty or signature-less — awk pattern drifted from upgrade.sh"; exit 1
fi
if bash -n "$FN"; then
    pass "S1: extracted _patch_compose_sfu_healthcheck_cidr parses (self-contained)"
else
    fail "S1: extracted function has syntax errors"; exit 1
fi
# shellcheck source=/dev/null
source "$FN"

# --- Shared fixture pieces: an unrelated image-tag line and an unrelated
# comment that happens to mention an IP/CIDR in prose (adversarial for a
# too-broad sed). ---
IMAGE_LINE='    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.14.4'
UNRELATED_COMMENT='      # partner mesh IP is 10.9.0.6/24, assigned by central via awg0'
ENV_BIND_LINE='      SFU_METRICS_BIND: "10.9.0.7"'

# =============================================================================
# Case (a): a compose file WITH the CIDR bug gets correctly stripped.
# =============================================================================
BUGGY="$TMP/buggy.yml"
cat > "$BUGGY" <<EOF
$IMAGE_LINE
$UNRELATED_COMMENT
    environment:
$ENV_BIND_LINE
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://10.9.0.7/24:9317/metrics >/dev/null 2>&1 && { [ -z \"\$SIGNALING_SFU_SECRET\" ] || nc -z 127.0.0.1 \"\${SFU_CLIENT_WS_PORT:-8920}\"; } && { [ -z \"\$RELAY_JWT_SECRET\" ] || nc -z 10.9.0.7/24 \"\${SFU_RELAY_API_PORT:-8912}\"; } || exit 1"]
EOF
_patch_compose_sfu_healthcheck_cidr "$BUGGY"

HC_LINE_A=$(grep 'wget -qO- http' "$BUGGY")
if echo "$HC_LINE_A" | grep -qF 'http://10.9.0.7:9317/metrics'; then
    pass "a-1: wget URL host CIDR stripped (http://10.9.0.7:9317/metrics)"
else
    fail "a-1: wget URL host still wrong: $HC_LINE_A"
fi
if echo "$HC_LINE_A" | grep -qF 'nc -z 10.9.0.7 '; then
    pass "a-2: nc -z relay-API host CIDR stripped (nc -z 10.9.0.7 )"
else
    fail "a-2: nc -z relay-API host still wrong: $HC_LINE_A"
fi
if echo "$HC_LINE_A" | grep -qF '/24'; then
    fail "a-3: /24 CIDR suffix still present after heal: $HC_LINE_A"
else
    pass "a-3: no /24 CIDR suffix remains"
fi
# client_ws (127.0.0.1) must be untouched — it was never CIDR-suffixed.
if echo "$HC_LINE_A" | grep -qF 'nc -z 127.0.0.1 \"${SFU_CLIENT_WS_PORT:-8920}\"'; then
    pass "a-4: client_ws probe (127.0.0.1) untouched"
else
    fail "a-4: client_ws probe corrupted: $HC_LINE_A"
fi

# =============================================================================
# Case (b1): an ALREADY-HEALED compose file (prior sed run already stripped
# the CIDR) is left BYTE-IDENTICAL — true no-op idempotency.
# =============================================================================
HEALED="$TMP/healed.yml"
cp "$BUGGY" "$HEALED"   # $BUGGY is now post-heal from case (a) — already CIDR-free
SHA_BEFORE_B1=$(sha256sum "$HEALED" | awk '{print $1}')
_patch_compose_sfu_healthcheck_cidr "$HEALED"
SHA_AFTER_B1=$(sha256sum "$HEALED" | awk '{print $1}')
if [[ "$SHA_BEFORE_B1" == "$SHA_AFTER_B1" ]]; then
    pass "b1: already-healed compose file is byte-identical after re-running the heal"
else
    fail "b1: re-running heal on an already-healed file mutated it (sha $SHA_BEFORE_B1 -> $SHA_AFTER_B1)"
fi

# =============================================================================
# Case (b2): a FRESH v0.14.5 compose file (new template's ${SFU_METRICS_BIND}
# form, never had a raw CIDR to begin with) is left BYTE-IDENTICAL.
# =============================================================================
FRESH="$TMP/fresh.yml"
cat > "$FRESH" <<EOF
$IMAGE_LINE
$UNRELATED_COMMENT
    environment:
$ENV_BIND_LINE
    healchcheck_marker_unused:
      test: ["CMD-SHELL", "wget -qO- http://\${SFU_METRICS_BIND}:9317/metrics >/dev/null 2>&1 && { [ -z \"\$SIGNALING_SFU_SECRET\" ] || nc -z 127.0.0.1 \"\${SFU_CLIENT_WS_PORT:-8920}\"; } && { [ -z \"\$RELAY_JWT_SECRET\" ] || nc -z \${SFU_RELAY_API_BIND} \"\${SFU_RELAY_API_PORT:-8912}\"; } || exit 1"]
EOF
SHA_BEFORE_B2=$(sha256sum "$FRESH" | awk '{print $1}')
_patch_compose_sfu_healthcheck_cidr "$FRESH"
SHA_AFTER_B2=$(sha256sum "$FRESH" | awk '{print $1}')
if [[ "$SHA_BEFORE_B2" == "$SHA_AFTER_B2" ]]; then
    pass "b2: fresh v0.14.5 (\${SFU_METRICS_BIND} form) compose file is byte-identical after heal (true no-op)"
else
    fail "b2: heal mutated a fresh v0.14.5 compose file that never had a CIDR bug (sha $SHA_BEFORE_B2 -> $SHA_AFTER_B2)"
fi

# =============================================================================
# Case (c): unrelated lines — image tag, env SFU_METRICS_BIND line, and a
# CIDR-bearing prose comment — are provably untouched by this sed.
# =============================================================================
REBUILD="$TMP/rebuild.yml"
cat > "$REBUILD" <<EOF
$IMAGE_LINE
$UNRELATED_COMMENT
    environment:
$ENV_BIND_LINE
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://10.9.0.7/24:9317/metrics >/dev/null 2>&1 && { [ -z \"\$SIGNALING_SFU_SECRET\" ] || nc -z 127.0.0.1 \"\${SFU_CLIENT_WS_PORT:-8920}\"; } && { [ -z \"\$RELAY_JWT_SECRET\" ] || nc -z 10.9.0.7/24 \"\${SFU_RELAY_API_PORT:-8912}\"; } || exit 1"]
EOF
_patch_compose_sfu_healthcheck_cidr "$REBUILD"

if grep -qF "$IMAGE_LINE" "$REBUILD"; then
    pass "c-1: image tag line untouched"
else
    fail "c-1: image tag line was modified by the healthcheck-only sed"
fi
if grep -qF "$UNRELATED_COMMENT" "$REBUILD"; then
    pass "c-2: unrelated CIDR-bearing comment untouched"
else
    fail "c-2: unrelated comment (contains an unrelated /24) was modified"
fi
if grep -qF "$ENV_BIND_LINE" "$REBUILD"; then
    pass "c-3: environment: block SFU_METRICS_BIND line untouched"
else
    fail "c-3: environment: block SFU_METRICS_BIND line was modified"
fi

# =============================================================================
# Case (d): idempotency across two consecutive runs on a freshly-buggy file —
# second run must be a no-op (matches case a's output byte-for-byte).
# =============================================================================
DOUBLE="$TMP/double.yml"
cat > "$DOUBLE" <<EOF
$IMAGE_LINE
    healthcheck:
      test: ["CMD-SHELL", "wget -qO- http://10.9.0.9/32:9317/metrics >/dev/null 2>&1 && { [ -z \"\$RELAY_JWT_SECRET\" ] || nc -z 10.9.0.9/32 \"\${SFU_RELAY_API_PORT:-8912}\"; } || exit 1"]
EOF
_patch_compose_sfu_healthcheck_cidr "$DOUBLE"
SHA_FIRST=$(sha256sum "$DOUBLE" | awk '{print $1}')
_patch_compose_sfu_healthcheck_cidr "$DOUBLE"
SHA_SECOND=$(sha256sum "$DOUBLE" | awk '{print $1}')
if [[ "$SHA_FIRST" == "$SHA_SECOND" ]]; then
    pass "d: second consecutive run is a byte-identical no-op (/32 CIDR case too)"
else
    fail "d: second run of the heal further mutated an already-healed file (sha $SHA_FIRST -> $SHA_SECOND)"
fi
if grep -qF '10.9.0.9/32' "$DOUBLE"; then
    fail "d: /32 CIDR still present after heal"
else
    pass "d: /32 CIDR correctly stripped (not just the /24 case)"
fi

# =============================================================================
# Case (e): wiring — both mutation sites in upgrade.sh call the heal helper
# right after the existing image-tag sed (same pattern reuse the spec calls for).
# =============================================================================
CALL_COUNT=$(grep -c '_patch_compose_sfu_healthcheck_cidr "\$COMPOSE_FILE"' "$UPGRADE" || true)
if [[ "$CALL_COUNT" -eq 2 ]]; then
    pass "e: _patch_compose_sfu_healthcheck_cidr called at exactly 2 compose-patch sites"
else
    fail "e: expected 2 call sites, found $CALL_COUNT"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
