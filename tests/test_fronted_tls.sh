#!/usr/bin/env bats
# tests/test_fronted_tls.sh — fronted-node service-SNI TLS (#639).
#
# Incident under test: a node fronted by an external TLS terminator can never
# ACME its service domain (challenges die at the front). Caddy then aborts
# upstream TLS handshakes for that SNI → the front serves 502 on everything.
# Fix: emit `tls /data/pki/<domain>.{crt,key}` (self-signed, caddy-data volume)
# when — and only when — the node is positively fronted.
#
# Mode resolution contract (fronted_tls_mode):
#   EDGE_FRONTED_TLS=static|acme      operator override wins outright
#   auto + node_ip ∈ domain A records → acme (direct-exposed node)
#   auto + node_ip ∉ domain A records → static (fronted — DNS points elsewhere)
#   auto + ambiguous (no node_ip / DNS failure) → persisted hint → acme
#
# Directive contract (fronted_tls_directive): emits the `tls` line only when
# mode=static AND the cert files were generated — never renders a reference to
# missing files (that would crash caddy at load).

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	export PREFIX_ETC="$TMP/etc"
	mkdir -p "$PREFIX_ETC"
	unset EDGE_FRONTED_TLS || true
	# warn is a lib dependency; provide the no-op every caller supplies.
	warn() { :; }
	export -f warn
	. "$REPO_ROOT/lib/fronted-tls.sh"
}

teardown() {
	rm -rf "$TMP"
}

# --- getent stub: ahostsv4 answers per-domain from GETENT_FIXTURE -------------
#   GETENT_FIXTURE="call.example.com 203.0.113.9 203.0.113.10"
getent() {
	if [[ "$1" == "ahostsv4" && -n "${GETENT_FIXTURE:-}" ]]; then
		local want="$2"
		for line in $GETENT_FIXTURE; do :; done
		# fixture format: "<domain> <ip> [<ip>...]" — emit ahostsv4-style rows.
		local dom="${GETENT_FIXTURE%% *}"
		if [[ "$want" == "$dom" ]]; then
			local rest="${GETENT_FIXTURE#* }"
			for ip in $rest; do
				echo "$ip STREAM $dom"
				echo "$ip DGRAM"
				echo "$ip RAW"
			done
			return 0
		fi
	fi
	return 2
}
export -f getent

# ---------------------------------------------------------------------------
# mode resolution
# ---------------------------------------------------------------------------
@test "mode: EDGE_FRONTED_TLS=static wins without any DNS" {
	unset GETENT_FIXTURE
	EDGE_FRONTED_TLS=static run fronted_tls_mode call.example.com ""
	[ "$status" -eq 0 ]
	[ "$output" = "static" ]
}

@test "mode: EDGE_FRONTED_TLS=acme wins without any DNS" {
	unset GETENT_FIXTURE
	EDGE_FRONTED_TLS=acme run fronted_tls_mode call.example.com ""
	[ "$status" -eq 0 ]
	[ "$output" = "acme" ]
}

@test "mode: auto → acme when node IP is among the domain's A records" {
	GETENT_FIXTURE="call.example.com 203.0.113.9 203.0.113.10"
	run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "acme" ]
	[ "$(cat "$PREFIX_ETC/.fronted-tls-mode")" = "acme" ]
}

@test "mode: auto → static when domain resolves elsewhere (fronted), hint persisted" {
	GETENT_FIXTURE="call.example.com 198.51.100.5"
	run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "static" ]
	[ "$(cat "$PREFIX_ETC/.fronted-tls-mode")" = "static" ]
}

@test "mode: auto + DNS failure keeps the persisted hint (no flip to acme)" {
	echo static > "$PREFIX_ETC/.fronted-tls-mode"
	unset GETENT_FIXTURE   # getent stub returns 2 → no A records
	run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "static" ]
}

@test "mode: auto + DNS failure + no hint → acme (never guess fronted)" {
	unset GETENT_FIXTURE
	run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "acme" ]
}

@test "mode: auto + empty node_ip → ambiguous → hint/acme, never static-by-accident" {
	GETENT_FIXTURE="call.example.com 198.51.100.5"
	run fronted_tls_mode call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "acme" ]
	[ ! -f "$PREFIX_ETC/.fronted-tls-mode" ]
}

# ---------------------------------------------------------------------------
# directive emission
# ---------------------------------------------------------------------------
@test "directive: acme mode emits nothing" {
	EDGE_FRONTED_TLS=acme run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive: static mode emits tls line AND generates the cert it references" {
	# Stub docker: volume inspect → a tmp mountpoint.
	docker() {
		case "$1 $2" in
			"inspect oxpulse-partner-caddy") return 1 ;;
			"volume inspect") echo "$TMP/vol/_data" ;;
		esac
		return 0
	}
	export -f docker
	DOCKER_BIN=docker EDGE_FRONTED_TLS=static run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "    tls /data/pki/call.example.com.crt /data/pki/call.example.com.key" ]
	[ -f "$TMP/vol/_data/pki/call.example.com.crt" ]
	[ -f "$TMP/vol/_data/pki/call.example.com.key" ]
	# self-signed SAN covers the service domain
	run openssl x509 -in "$TMP/vol/_data/pki/call.example.com.crt" -noout -ext subjectAltName
	[ "$status" -eq 0 ]
	[[ "$output" == *"call.example.com"* ]]
}

@test "directive: static mode but cert ungeneratable → empty (never reference missing files)" {
	# No docker stub, no /var/lib/docker → cert dir unresolvable.
	DOCKER_BIN=false EDGE_FRONTED_TLS=static run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "ensure_cert: idempotent — existing crt+key skips openssl" {
	mkdir -p "$TMP/vol/_data/pki"
	echo sentinel-crt > "$TMP/vol/_data/pki/call.example.com.crt"
	echo sentinel-key > "$TMP/vol/_data/pki/call.example.com.key"
	docker() {
		case "$1 $2" in
			"volume inspect") echo "$TMP/vol/_data" ;;
		esac
		return 0
	}
	export -f docker
	DOCKER_BIN=docker run fronted_tls_ensure_cert call.example.com
	[ "$status" -eq 0 ]
	# files untouched (sentinel content preserved — openssl never ran)
	[ "$(cat "$TMP/vol/_data/pki/call.example.com.crt")" = "sentinel-crt" ]
}

# ---------------------------------------------------------------------------
# template surface
# ---------------------------------------------------------------------------
@test "Caddyfile.tpl carries {{SERVICE_TLS_DIRECTIVE}} inside the service site block" {
	run grep -n '{{SERVICE_TLS_DIRECTIVE}}' "$REPO_ROOT/Caddyfile.tpl"
	[ "$status" -eq 0 ]
	# placeholder sits inside {{PARTNER_DOMAIN}} { ... } — before its `encode`
	run awk '/{{PARTNER_DOMAIN}} \{/{f=1} f && /{{SERVICE_TLS_DIRECTIVE}}/{found=1} f && /^}/{exit} END{exit !found}' "$REPO_ROOT/Caddyfile.tpl"
	[ "$status" -eq 0 ]
}

@test "rendered Caddyfile: empty directive leaves no unresolved placeholder" {
	command -v opec >/dev/null 2>&1 || skip "opec not on PATH"
	PARTNER_DOMAIN=call.example.com TURNS_SUBDOMAIN=api-aaa \
		AWG_MOTHERLY_IP=10.9.0.2 HY2_FALLBACK_HOST=host.docker.internal \
		HY2_FALLBACK_PORT=18443 NAIVE_SOCKS_PORT=1080 SERVICE_TLS_DIRECTIVE= \
		run opec render caddy --tpl "$REPO_ROOT/Caddyfile.tpl" --out "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
	run grep -c '{{' "$TMP/Caddyfile"
	[ "$output" = "0" ] || [ "$output" = "1" ]  # __CADDYFILE_SHA__ may remain
}

@test "rendered Caddyfile: static directive lands inside the service site" {
	command -v opec >/dev/null 2>&1 || skip "opec not on PATH"
	PARTNER_DOMAIN=call.example.com TURNS_SUBDOMAIN=api-aaa \
		AWG_MOTHERLY_IP=10.9.0.2 HY2_FALLBACK_HOST=host.docker.internal \
		HY2_FALLBACK_PORT=18443 NAIVE_SOCKS_PORT=1080 \
		SERVICE_TLS_DIRECTIVE=$'    tls /data/pki/call.example.com.crt /data/pki/call.example.com.key\n' \
		run opec render caddy --tpl "$REPO_ROOT/Caddyfile.tpl" --out "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
	run grep -n 'tls /data/pki/call.example.com.crt' "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
}
