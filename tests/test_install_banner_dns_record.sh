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
#
# F4: the previous version of this test had three grep-only assertions that
# matched *variable names* in the file (_turns_dns_line, TURNS_SUBDOMAIN_VALID,
# TURNS_SUBDOMAIN.*DOMAIN.*PUBLIC_IP).  Those passed while the banner printed
# garbage, and the functional half was gated on `opec` which is absent in the
# CI job (ci.yml installer-bash-tests installs only bats; opec is a Rust
# binary built in release.yml).  This version extracts the real banner block
# from install.sh, renders it with concrete values, and asserts on the
# rendered output — no opec needed, no name-only assertions.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

bash -n "$INSTALL" || { echo "FAIL: install.sh syntax error"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Extract the non-bake banner block from install.sh: the _turns_dns_line
# pre-computation, the _health_banner pre-computation, and the cat <<BANNER
# heredoc.  Sourcing this fragment with the right variables set renders the
# exact banner an operator sees.
# ---------------------------------------------------------------------------
awk '
	/^# Pre-compute the TURNS subdomain DNS line/ { cap=1 }
	cap { print }
	cap && /^BANNER$/ { exit }
' "$INSTALL" > "$TMP/banner_block.sh"

if [[ ! -s "$TMP/banner_block.sh" ]]; then
	echo "FAIL: could not extract the banner block from install.sh"
	exit 1
fi
# Couple test to real code: the extracted block must contain the heredoc.
grep -q '^cat <<BANNER$' "$TMP/banner_block.sh" || {
	echo "FAIL: extracted banner block is missing the cat <<BANNER heredoc"
	exit 1
}

# ---------------------------------------------------------------------------
# Functional (valid TURNS_SUBDOMAIN): render the banner with a concrete
# api-<hex> subdomain and assert the output names the DNS record
# api-a1b2c3.dns.test.local → 203.0.113.10.  This is the assertion that
# breaks if the banner prints garbage — the old grep-only checks matched
# the variable name _turns_dns_line and passed regardless of what it held.
# ---------------------------------------------------------------------------
out=$(bash -c '
	set -euo pipefail
	# Concrete values an operator would see after a real install.
	TURNS_SUBDOMAIN=api-a1b2c3
	TURNS_SUBDOMAIN_VALID=1
	DOMAIN=dns.test.local
	PUBLIC_IP=203.0.113.10
	PARTNER_ID=dnstest
	NODE_ID=node-01
	TUNNEL=vless
	IMAGE_VERSION=stable
	PREFIX_ETC=/etc/oxpulse-partner-edge
	PREFIX_LIB=/var/lib/oxpulse-partner-edge
	PREFIX_SBIN=/usr/local/sbin
	# Health banner defaults — all green.
	HEALTHCHECK_CORE_FAILED=0
	HEALTHCHECK_TURNS_CERT_FAILED=0
	ALLOW_DEGRADED=0
	source "'"$TMP"'/banner_block.sh"
' 2>&1) || { echo "FAIL: banner block render exited non-zero"; echo "$out"; exit 1; }

if ! grep -q 'api-a1b2c3\.dns\.test\.local' <<< "$out"; then
	echo "FAIL: banner does not name the TURNS subdomain DNS record (api-a1b2c3.dns.test.local)"
	echo "$out" | tail -20
	exit 1
fi
if ! grep -q '203\.0\.113\.10' <<< "$out"; then
	echo "FAIL: banner does not name the public IP (203.0.113.10) in the DNS record line"
	echo "$out" | tail -20
	exit 1
fi
echo "PASS: valid TURNS_SUBDOMAIN → banner names api-a1b2c3.dns.test.local → 203.0.113.10"

# ---------------------------------------------------------------------------
# Functional (invalid TURNS_SUBDOMAIN): render the banner with the default
# 'turns' subdomain (TURNS_SUBDOMAIN_VALID=0) and assert the output warns
# explicitly rather than printing a malformed DNS instruction.
# ---------------------------------------------------------------------------
out2=$(bash -c '
	set -euo pipefail
	TURNS_SUBDOMAIN=turns
	TURNS_SUBDOMAIN_VALID=0
	DOMAIN=dns2.test.local
	PUBLIC_IP=203.0.113.10
	PARTNER_ID=dnstest2
	NODE_ID=node-02
	TUNNEL=vless
	IMAGE_VERSION=stable
	PREFIX_ETC=/etc/oxpulse-partner-edge
	PREFIX_LIB=/var/lib/oxpulse-partner-edge
	PREFIX_SBIN=/usr/local/sbin
	HEALTHCHECK_CORE_FAILED=0
	HEALTHCHECK_TURNS_CERT_FAILED=0
	ALLOW_DEGRADED=0
	source "'"$TMP"'/banner_block.sh"
' 2>&1) || { echo "FAIL: banner block render (invalid turns) exited non-zero"; echo "$out2"; exit 1; }

if ! grep -qiE 'TURNS_SUBDOMAIN.*(invalid|not set|not valid|expected api|missing|check|WARNING|degraded)' <<< "$out2"; then
	echo "FAIL: banner does not warn about invalid TURNS_SUBDOMAIN when it defaults to 'turns'"
	echo "$out2" | tail -20
	exit 1
fi
# Must NOT print a malformed DNS instruction for an invalid subdomain.
if grep -q 'turns\.dns2\.test\.local' <<< "$out2"; then
	echo "FAIL: banner prints a DNS instruction for invalid TURNS_SUBDOMAIN 'turns' — should warn instead"
	echo "$out2" | tail -20
	exit 1
fi
echo "PASS: invalid TURNS_SUBDOMAIN → banner warns explicitly, no malformed DNS line"

# ---------------------------------------------------------------------------
# Deeper e2e: run install.sh --dry-run end-to-end.  Skipped when opec is not
# available (ci.yml installer-bash-tests does not build the Rust opec binary;
# the functional extraction tests above cover the banner in CI without it).
# ---------------------------------------------------------------------------
if command -v opec >/dev/null 2>&1 || ls "$REPO_ROOT"/opec-* >/dev/null 2>&1; then
	# Valid TURNS_SUBDOMAIN: banner must show the DNS record.
	e2e_out=$(cd "$TMP" && TURNS_SUBDOMAIN=api-a1b2c3 bash "$INSTALL" \
		--domain=dns.test.local --partner-id=dnstest \
		--manual-config=/dev/stdin --dry-run <<'JSON' 2>&1
{"node_id":"t","backend_endpoint":"backend.test:443","turn_secret":"x","reality_uuid":"00000000-0000-0000-0000-000000000000","reality_public_key":"x","reality_short_id":"deadbeef","reality_server_name":"www.example.com","reality_encryption":""}
JSON
	) || { echo "FAIL: install.sh --dry-run (valid turns) exited non-zero"; echo "$e2e_out"; exit 1; }

	if ! grep -q 'api-a1b2c3.*dns\.test\.local' <<< "$e2e_out"; then
		echo "FAIL: e2e banner does not name the TURNS subdomain DNS record (api-a1b2c3.dns.test.local)"
		echo "$e2e_out" | tail -20
		exit 1
	fi
	echo "PASS: e2e valid TURNS_SUBDOMAIN → banner names the DNS record"
else
	echo "SKIP (e2e dry-run): opec binary not available — functional extraction tests passed"
fi
