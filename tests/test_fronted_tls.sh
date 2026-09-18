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
# missing files (that would crash caddy at load). DRY_RUN=1 writes nothing.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	export PREFIX_ETC="$TMP/etc"
	mkdir -p "$PREFIX_ETC"
	unset EDGE_FRONTED_TLS DRY_RUN || true
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

# --- docker stub: volume inspect + docker info answer into $TMP --------------
stub_docker_volume() {
	docker() {
		case "$1 $2" in
			"inspect oxpulse-partner-caddy") return 1 ;;
			"volume inspect") echo "$TMP/vol/_data"; return 0 ;;
			"info --format") echo "$TMP/docker-root"; return 0 ;;
		esac
		return 0
	}
	export -f docker
	mkdir -p "$TMP/vol/_data"
}

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

@test "mode: auto → acme when node IP is the 4th+ A record (no row truncation)" {
	# getent emits 3 rows/address; a cap on ROWS (not unique IPs) drops the
	# node's own record on ≥4-record domains → false 'static' on a direct node.
	GETENT_FIXTURE="call.example.com 198.51.100.1 198.51.100.2 198.51.100.3 198.51.100.4 203.0.113.9"
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

@test "mode: auto + DNS failure + corrupt hint → acme (garbage hint not honoured)" {
	echo "garbage-not-a-mode" > "$PREFIX_ETC/.fronted-tls-mode"
	unset GETENT_FIXTURE
	run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "acme" ]
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

@test "mode: DRY_RUN=1 resolves but never writes the hint" {
	GETENT_FIXTURE="call.example.com 198.51.100.5"
	DRY_RUN=1 run fronted_tls_mode call.example.com 203.0.113.9 "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "static" ]
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
	stub_docker_volume
	DOCKER_BIN=docker EDGE_FRONTED_TLS=static run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ "$output" = "    tls /data/pki/call.example.com.crt /data/pki/call.example.com.key" ]
	[ -f "$TMP/vol/_data/pki/call.example.com.crt" ]
	[ -f "$TMP/vol/_data/pki/call.example.com.key" ]
	# key is not world-readable (coturn mounts caddy-data ro — 0644 leaked it)
	[ "$(stat -c %a "$TMP/vol/_data/pki/call.example.com.key" 2>/dev/null || stat -f %Lp "$TMP/vol/_data/pki/call.example.com.key")" = "600" ]
	# self-signed SAN covers the service domain
	run openssl x509 -in "$TMP/vol/_data/pki/call.example.com.crt" -noout -ext subjectAltName
	[ "$status" -eq 0 ]
	[[ "$output" == *"call.example.com"* ]]
	# no stray tmp files left beside the cert pair
	[ -z "$(ls "$TMP/vol/_data/pki/" | grep '\.tmp$' || true)" ]
}

@test "directive: static mode but cert ungeneratable → empty (never reference missing files)" {
	# DOCKER_BIN=false: all three cert-dir tiers go through docker → unresolvable.
	DOCKER_BIN=false EDGE_FRONTED_TLS=static run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "directive: static mode + DRY_RUN mints nothing (dry-run is side-effect-free)" {
	stub_docker_volume
	DOCKER_BIN=docker DRY_RUN=1 EDGE_FRONTED_TLS=static run fronted_tls_directive call.example.com "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
	[ ! -f "$TMP/vol/_data/pki/call.example.com.crt" ]
}

@test "directive: invalid domain is suppressed (no traversal/DN-injection sinks)" {
	stub_docker_volume
	DOCKER_BIN=docker EDGE_FRONTED_TLS=static run fronted_tls_directive "../../etc/evil" "" "$PREFIX_ETC"
	[ "$status" -eq 0 ]
	[ -z "$output" ]
}

@test "ensure_cert: corrupt/truncated pair is regenerated, not pinned forever" {
	stub_docker_volume
	mkdir -p "$TMP/vol/_data/pki"
	echo sentinel-crt > "$TMP/vol/_data/pki/call.example.com.crt"
	echo sentinel-key > "$TMP/vol/_data/pki/call.example.com.key"
	DOCKER_BIN=docker run fronted_tls_ensure_cert call.example.com
	[ "$status" -eq 0 ]
	# sentinel content replaced by a real parseable cert+key
	[ "$(cat "$TMP/vol/_data/pki/call.example.com.crt")" != "sentinel-crt" ]
	run openssl x509 -in "$TMP/vol/_data/pki/call.example.com.crt" -noout
	[ "$status" -eq 0 ]
	run openssl pkey -in "$TMP/vol/_data/pki/call.example.com.key" -noout
	[ "$status" -eq 0 ]
}

@test "ensure_cert: valid existing pair is kept (true idempotency)" {
	stub_docker_volume
	mkdir -p "$TMP/vol/_data/pki"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
		-keyout "$TMP/vol/_data/pki/call.example.com.key" \
		-out "$TMP/vol/_data/pki/call.example.com.crt" -days 3650 \
		-subj "/CN=call.example.com" -addext "subjectAltName=DNS:call.example.com" 2>/dev/null
	local before
	before=$(sha256sum "$TMP/vol/_data/pki/call.example.com.crt" | awk '{print $1}')
	DOCKER_BIN=docker run fronted_tls_ensure_cert call.example.com
	[ "$status" -eq 0 ]
	[ "$(sha256sum "$TMP/vol/_data/pki/call.example.com.crt" | awk '{print $1}')" = "$before" ]
}

@test "ensure_cert: mismatched cert/key pair is regenerated" {
	stub_docker_volume
	mkdir -p "$TMP/vol/_data/pki"
	openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
		-keyout "$TMP/vol/_data/pki/call.example.com.key" \
		-out "$TMP/vol/_data/pki/call.example.com.crt" -days 3650 \
		-subj "/CN=call.example.com" 2>/dev/null
	# Replace the key with a DIFFERENT valid key → pair no longer matches.
	openssl ecparam -genkey -name prime256v1 -out "$TMP/vol/_data/pki/call.example.com.key" 2>/dev/null
	DOCKER_BIN=docker run fronted_tls_ensure_cert call.example.com
	[ "$status" -eq 0 ]
	local crt_pub key_pub
	crt_pub=$(openssl x509 -in "$TMP/vol/_data/pki/call.example.com.crt" -noout -pubkey)
	key_pub=$(openssl pkey -in "$TMP/vol/_data/pki/call.example.com.key" -pubout)
	[ "$crt_pub" = "$key_pub" ]
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
	# placeholder is on its OWN line: production captures the directive via
	# $(...) which strips trailing newlines — a placeholder fused onto another
	# directive line renders `tls …key    encode` as one line caddy rejects.
	# every line CARRYING the placeholder must be exactly `{{SERVICE_TLS_DIRECTIVE}}`
	# (the comment above it mentions it in prose — only the bare directive line counts)
	run grep -nF '{{SERVICE_TLS_DIRECTIVE}}' "$REPO_ROOT/Caddyfile.tpl"
	[ "$status" -eq 0 ]
	run grep -cFx '{{SERVICE_TLS_DIRECTIVE}}' "$REPO_ROOT/Caddyfile.tpl"
	[ "$output" = "1" ]
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

@test "rendered Caddyfile: static directive lands inside the service site on its OWN line" {
	command -v opec >/dev/null 2>&1 || skip "opec not on PATH"
	# Produce the value through the REAL capture path — $(fronted_tls_directive)
	# strips trailing newlines, the exact shape every producer exports.
	stub_docker_volume
	local directive
	directive=$(DOCKER_BIN=docker EDGE_FRONTED_TLS=static fronted_tls_directive call.example.com "" "$PREFIX_ETC")
	[ -n "$directive" ]
	PARTNER_DOMAIN=call.example.com TURNS_SUBDOMAIN=api-aaa \
		AWG_MOTHERLY_IP=10.9.0.2 HY2_FALLBACK_HOST=host.docker.internal \
		HY2_FALLBACK_PORT=18443 NAIVE_SOCKS_PORT=1080 \
		SERVICE_TLS_DIRECTIVE="$directive" \
		run opec render caddy --tpl "$REPO_ROOT/Caddyfile.tpl" --out "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
	run grep -n 'tls /data/pki/call.example.com.crt' "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
	# `encode` survived as its own directive — not fused onto the tls line.
	run grep -nE '^\s+encode gzip zstd' "$TMP/Caddyfile"
	[ "$status" -eq 0 ]
	! grep -qE 'tls /data/pki/.*encode' "$TMP/Caddyfile"
}
