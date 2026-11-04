#!/usr/bin/env bash
# tests/test_relay_release_assets.sh — the relay-only delivery chain is closed:
# every file relay/relay-manifest.txt tells oxpulse-relay-upgrade.sh to fetch must
# (1) exist in the repo, (2) be staged by release.yml, (3) be in the SHA256SUMS
# list and (4) be in the `gh release upload` list. A file missing from (3) is fetched
# by the upgrader and rejected ("not listed in SHA256SUMS"), one missing from (4)
# 404s: either way the fleet silently never upgrades — the failure class
# tests/test_release_upload_covers_delivery.sh guards for the edge.
#
# Mutation that must turn this RED: delete the `relay-turnserver-arm64 \` line from
# the `gh release upload` list in .github/workflows/release.yml -> "uploaded".
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
R="$REPO_ROOT/relay"; Y="${RELEASE_YML:-$REPO_ROOT/.github/workflows/release.yml}"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

sums_list() { awk '/^ *sha256sum \\$/{f=1;next} f{ if ($0 ~ /> SHA256SUMS/) exit; sub(/ *\\$/,""); gsub(/^ +/,""); print }' "$Y"; }
upload_list() { awk '/gh release upload/{f=1;next} f{ line=$0; has=(line ~ /\\$/); sub(/^[ \t]+/,"",line); sub(/[ \t]*\\$/,"",line); if (line!="") print line; if(!has) exit }' "$Y"; }
SUMS="$(sums_list)"; UP="$(upload_list)"
[[ -n "$SUMS" && -n "$UP" ]] && pass "release.yml lists parsed" || { fail "release.yml lists parsed"; exit 1; }

n=0
while read -r group kind asset name; do
	[[ -n "${group:-}" && "$group" != \#* ]] || continue
	for arch in amd64 arm64; do
		a="${asset//@ARCH@/$arch}"
		[[ "$asset" == *@ARCH@* || "$arch" == amd64 ]] || continue
		n=$((n+1))
		if [[ "$kind" == bin ]]; then
			grep -q "relay-coturn-$arch" "$Y" && grep -qE "cp relay-out/turn(server|utils_uclient) $a|cp relay-out/turn.* relay-turn.*-\\\$\{\{ matrix.arch.token \}\}" "$Y" \
				&& pass "$a: built by build-relay-coturn" || fail "$a: built by build-relay-coturn"
		else
			src="$R/$a"; [[ -f "$src" ]] || src="$REPO_ROOT/lib/$a"; [[ -f "$src" ]] || src="$REPO_ROOT/$a"
			[[ -f "$src" ]] && pass "$a: source file exists" || fail "$a: source file exists"
			[[ "$a" != "$name" && "$kind" == unit ]] && fail "$a: unit asset name equals installed name"
			if [[ "$a" != channel-health-lib.sh ]]; then   # staged by the edge block
				grep -qE "^ *cp (relay|lib)/$a +$a\$" "$Y" && pass "$a: staged" || fail "$a: staged"
			fi
		fi
		grep -qxF "$a" <<<"$SUMS" && pass "$a: in SHA256SUMS" || fail "$a: in SHA256SUMS"
		grep -qxF "$a" <<<"$UP" && pass "$a: uploaded" || fail "$a: uploaded"
	done
done < "$R/relay-manifest.txt"
grep -qxF relay-manifest.txt <<<"$SUMS" && grep -qxF relay-manifest.txt <<<"$UP" && grep -qE '^ *cp relay/relay-manifest.txt +relay-manifest.txt$' "$Y" \
	&& pass "relay-manifest.txt: staged, in SHA256SUMS, uploaded" || fail "relay-manifest.txt: staged, in SHA256SUMS, uploaded"
((n > 10)) && pass "manifest parsed ($n entries)" || fail "manifest parsed"

# The manifest must not carry a path: names are bare file names.
if grep -vE '^[[:space:]]*(#|$)' "$R/relay-manifest.txt" | awk '{print $3, $4}' | grep '/' >/dev/null; then fail "manifest carries no paths"; else pass "manifest carries no paths"; fi

# The coturn unit starts the binary the upgrader switches.
grep -q '^ExecStart=/usr/local/lib/oxpulse-relay/current/turnserver ' "$R/oxpulse-relay-coturn.service" && pass "coturn unit runs current/turnserver" || fail "coturn unit runs current/turnserver"

# The template is 4.18-only: keys 4.18 removed or never had must not return.
if grep -qE '^(no-dtls|no-tlsv1|no-tlsv1_1|allocation-default-timeout|no-loopback-peers)$' "$R/coturn-relay.conf.tpl"; then fail "template has no directive coturn 4.18 rejects"; else pass "template has no directive coturn 4.18 rejects"; fi
grep -qx 'denied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff' "$R/coturn-relay.conf.tpl" && grep -qx 'denied-peer-ip=::ffff:0.0.0.0-::ffff:255.255.255.255' "$R/coturn-relay.conf.tpl" \
	&& pass "template denies NAT64 and IPv4-mapped peers" || fail "template denies NAT64 and IPv4-mapped peers"

# The pinned source: a bare 64-hex sha256 and a version, used by the Dockerfile.
( . "$R/coturn-static/version.env"; [[ "$COTURN_SHA256" =~ ^[0-9a-f]{64}$ && "$COTURN_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] ) \
	&& pass "coturn source pinned by version + sha256" || fail "coturn source pinned by version + sha256"
grep -q 'sha256sum -c' "$R/coturn-static/Dockerfile" && pass "Dockerfile verifies the tarball hash" || fail "Dockerfile verifies the tarball hash"

echo ""; echo "relay release assets: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
