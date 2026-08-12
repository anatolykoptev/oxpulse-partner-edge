#!/bin/bash
# tests/test_install_banner_health_honest.sh
#
# Issue #602(a): the degraded banner must name the check(s) that actually
# failed, not print "Healthcheck poll timed out" unconditionally whenever
# HEALTHCHECK_CORE_FAILED=1.  The TURNS-cert failure and the poll failure are
# separate conditions tracked in separate variables; the banner must show each
# line only when that specific check fired.
#
# This test extracts the real banner block from install.sh, renders it with
# concrete variable values for each of the three degraded states, and asserts
# on the RENDERED output — not on variable names in the source.  An assertion
# that greps install.sh for a variable name is not acceptable: this repo
# shipped exactly that and it went green over broken behaviour.
#
# Falsification: reverting the banner fix (removing the HEALTHCHECK_POLL_FAILED
# gate on the "Healthcheck poll timed out" line) makes the "cert failed only"
# case see that line when it should not → RED.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
INSTALL="$REPO_ROOT/install.sh"

bash -n "$INSTALL" || { echo "FAIL: install.sh syntax error"; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Extract the banner block from install.sh — same extraction as
# test_install_banner_dns_record.sh: from the TURNS DNS line pre-computation
# through the cat <<BANNER heredoc.  Sourcing this fragment with the right
# variables set renders the exact banner an operator sees.
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
grep -q '^cat <<BANNER$' "$TMP/banner_block.sh" || {
	echo "FAIL: extracted banner block is missing the cat <<BANNER heredoc"
	exit 1
}

# Common env prefix for every render — the non-health vars the banner block
# references.  Each state appends its own HEALTHCHECK_* values.
_COMMON='set -euo pipefail
	TURNS_SUBDOMAIN=api-test01
	TURNS_SUBDOMAIN_VALID=1
	DOMAIN=example.net
	PUBLIC_IP=203.0.113.10
	PARTNER_ID=healthtest
	NODE_ID=node-01
	TUNNEL=vless
	IMAGE_VERSION=stable
	PREFIX_ETC=/etc/oxpulse-partner-edge
	PREFIX_LIB=/var/lib/oxpulse-partner-edge
	PREFIX_SBIN=/usr/local/sbin
	ALLOW_DEGRADED=1'

# ---------------------------------------------------------------------------
# State 1: poll failed ONLY (cert was fine).
# Expect: "Healthcheck poll timed out" present, "TURNS TLS cert not ready" absent.
# ---------------------------------------------------------------------------
out_poll=$(bash -c "
	$_COMMON
	HEALTHCHECK_CORE_FAILED=1
	HEALTHCHECK_TURNS_CERT_FAILED=0
	HEALTHCHECK_POLL_FAILED=1
	source '$TMP/banner_block.sh'
" 2>&1) || { echo "FAIL: banner render (poll-only) exited non-zero"; echo "$out_poll"; exit 1; }

if ! grep -q 'Healthcheck poll timed out' <<< "$out_poll"; then
	echo "FAIL: poll-only — banner missing 'Healthcheck poll timed out' line"
	echo "$out_poll" | tail -20
	exit 1
fi
if grep -q 'TURNS TLS cert not ready' <<< "$out_poll"; then
	echo "FAIL: poll-only — banner names 'TURNS TLS cert not ready' but cert did NOT fail"
	echo "$out_poll" | tail -20
	exit 1
fi
echo "PASS: poll-only → 'Healthcheck poll timed out' present, 'TURNS TLS cert not ready' absent"

# ---------------------------------------------------------------------------
# State 2: cert failed ONLY (poll was fine).
# Expect: "TURNS TLS cert not ready" present, "Healthcheck poll timed out" absent.
# THIS IS THE RED CASE ON CURRENT MAIN: the banner prints "Healthcheck poll
# timed out" unconditionally when HEALTHCHECK_CORE_FAILED=1, so this assertion
# fails until the line is gated on HEALTHCHECK_POLL_FAILED.
# ---------------------------------------------------------------------------
out_cert=$(bash -c "
	$_COMMON
	HEALTHCHECK_CORE_FAILED=1
	HEALTHCHECK_TURNS_CERT_FAILED=1
	HEALTHCHECK_POLL_FAILED=0
	source '$TMP/banner_block.sh'
" 2>&1) || { echo "FAIL: banner render (cert-only) exited non-zero"; echo "$out_cert"; exit 1; }

if ! grep -q 'TURNS TLS cert not ready' <<< "$out_cert"; then
	echo "FAIL: cert-only — banner missing 'TURNS TLS cert not ready' line"
	echo "$out_cert" | tail -20
	exit 1
fi
if grep -q 'Healthcheck poll timed out' <<< "$out_cert"; then
	echo "FAIL: cert-only — banner names 'Healthcheck poll timed out' but poll did NOT fail"
	echo "$out_cert" | tail -20
	exit 1
fi
echo "PASS: cert-only → 'TURNS TLS cert not ready' present, 'Healthcheck poll timed out' absent"

# ---------------------------------------------------------------------------
# State 3: BOTH failed.
# Expect: both lines present.
# ---------------------------------------------------------------------------
out_both=$(bash -c "
	$_COMMON
	HEALTHCHECK_CORE_FAILED=1
	HEALTHCHECK_TURNS_CERT_FAILED=1
	HEALTHCHECK_POLL_FAILED=1
	source '$TMP/banner_block.sh'
" 2>&1) || { echo "FAIL: banner render (both) exited non-zero"; echo "$out_both"; exit 1; }

if ! grep -q 'TURNS TLS cert not ready' <<< "$out_both"; then
	echo "FAIL: both — banner missing 'TURNS TLS cert not ready' line"
	echo "$out_both" | tail -20
	exit 1
fi
if ! grep -q 'Healthcheck poll timed out' <<< "$out_both"; then
	echo "FAIL: both — banner missing 'Healthcheck poll timed out' line"
	echo "$out_both" | tail -20
	exit 1
fi
echo "PASS: both → both lines present"

echo "All banner honesty assertions passed."
