#!/bin/bash
# tests/test_install_banner_dns_record.sh
#
# F1: the final install banner must tell the operator to create the A record
# for the per-node TURNS subdomain (api-<hex>.<domain>), not just the apex
# domain.  Without that record TURNS on :443 fails the SNI match and UDP TURN
# is NXDOMAIN — a stranger following the printed instructions gets a node
# whose TURN is dead.
#
# The banner must also be honest when TURNS_SUBDOMAIN is empty or does not
# match ^api-: instead of printing a malformed instruction, it must say so
# explicitly (reusing the state from the warning block at install.sh:1080+).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

bash -n "$INSTALL" || { echo "FAIL: install.sh syntax error"; exit 1; }

# ---------------------------------------------------------------------------
# Structural: the non-bake banner must reference the TURNS subdomain DNS
# record.  The banner uses a pre-computed $_turns_dns_line variable that
# carries the TURNS_SUBDOMAIN.DOMAIN → PUBLIC_IP instruction.  Removing
# either the pre-computation or the banner reference must turn this RED.
# ---------------------------------------------------------------------------
# Extract the non-bake banner (the second cat <<BANNER ... BANNER block).
# The bake banner is the first; the real install banner is the second.
banner_blocks=$(grep -n '^cat <<BANNER$' "$INSTALL" | cut -d: -f1)
second_banner_line=$(echo "$banner_blocks" | sed -n '2p')
if [[ -z "$second_banner_line" ]]; then
	echo "FAIL: could not locate the non-bake banner block in install.sh"
	exit 1
fi
banner_end=$(awk -v start="$second_banner_line" 'NR>start && /^BANNER$/ {print NR; exit}' "$INSTALL")
banner_text=$(sed -n "${second_banner_line},${banner_end}p" "$INSTALL")

if ! grep -q '_turns_dns_line' <<< "$banner_text"; then
	echo "FAIL: non-bake banner does not reference _turns_dns_line — the per-node DNS record is never printed"
	exit 1
fi
# The pre-computation block must exist and reference TURNS_SUBDOMAIN + DOMAIN + PUBLIC_IP.
if ! grep -q 'TURNS_SUBDOMAIN_VALID' "$INSTALL"; then
	echo "FAIL: install.sh does not set TURNS_SUBDOMAIN_VALID — banner cannot reuse warning-block state"
	exit 1
fi
precomp_block=$(sed -n '/^# Pre-compute the TURNS subdomain DNS line/,/^fi$/p' "$INSTALL" | sed -n '1,10p')
if ! grep -q 'TURNS_SUBDOMAIN.*DOMAIN.*PUBLIC_IP' <<< "$precomp_block"; then
	echo "FAIL: TURNS DNS pre-computation does not name TURNS_SUBDOMAIN.DOMAIN → PUBLIC_IP"
	exit 1
fi
echo "PASS: banner references the TURNS subdomain DNS record"

# ---------------------------------------------------------------------------
# Functional: run install.sh --dry-run and check the banner output.
# With a valid TURNS_SUBDOMAIN (api-<hex>), the banner must name the record.
# Skipped when opec is not available (same guard as test_install_ships_cover.sh).
# ---------------------------------------------------------------------------
if command -v opec >/dev/null 2>&1 || ls "$REPO_ROOT"/opec-* >/dev/null 2>&1; then
	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT

	# Valid TURNS_SUBDOMAIN: banner must show the DNS record.
	out=$(cd "$TMP" && TURNS_SUBDOMAIN=api-a1b2c3 bash "$INSTALL" \
		--domain=dns.test.local --partner-id=dnstest \
		--manual-config=/dev/stdin --dry-run <<'JSON' 2>&1
{"node_id":"t","backend_endpoint":"backend.test:443","turn_secret":"x","reality_uuid":"00000000-0000-0000-0000-000000000000","reality_public_key":"x","reality_short_id":"deadbeef","reality_server_name":"www.example.com","reality_encryption":""}
JSON
	) || { echo "FAIL: install.sh --dry-run (valid turns) exited non-zero"; echo "$out"; exit 1; }

	if ! grep -q 'api-a1b2c3.*dns\.test\.local' <<< "$out"; then
		echo "FAIL: banner does not name the TURNS subdomain DNS record (api-a1b2c3.dns.test.local)"
		echo "$out" | tail -20
		exit 1
	fi
	echo "PASS: valid TURNS_SUBDOMAIN → banner names the DNS record"

	# Invalid TURNS_SUBDOMAIN (default 'turns'): banner must say so explicitly,
	# not print a malformed instruction.
	out2=$(cd "$TMP" && bash "$INSTALL" \
		--domain=dns2.test.local --partner-id=dnstest2 \
		--manual-config=/dev/stdin --dry-run <<'JSON' 2>&1
{"node_id":"t","backend_endpoint":"backend.test:443","turn_secret":"x","reality_uuid":"00000000-0000-0000-0000-000000000000","reality_public_key":"x","reality_short_id":"deadbeef","reality_server_name":"www.example.com","reality_encryption":""}
JSON
	) || { echo "FAIL: install.sh --dry-run (invalid turns) exited non-zero"; echo "$out2"; exit 1; }

	if ! grep -qiE 'TURNS_SUBDOMAIN.*(invalid|not set|not valid|expected api|missing|check|WARNING|degraded)' <<< "$out2"; then
		echo "FAIL: banner does not warn about invalid TURNS_SUBDOMAIN when it defaults to 'turns'"
		echo "$out2" | tail -20
		exit 1
	fi
	echo "PASS: invalid TURNS_SUBDOMAIN → banner warns explicitly"
else
	echo "SKIP (dry-run e2e): opec binary not available — structural checks passed"
fi
