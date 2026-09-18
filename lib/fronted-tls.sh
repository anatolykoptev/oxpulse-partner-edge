# fronted-tls.sh — service-SNI TLS answer for fronted nodes (#639).
#
# Problem (prod incident 2026-09-17, rvpn-seed): when {{PARTNER_DOMAIN}} is
# fronted by an external TLS terminator (RU reverse-proxy fronts that hold the
# real Let's Encrypt cert and reverse-proxy to the node), the node can never
# complete ACME for that domain — challenge traffic terminates at the front.
# Caddy then cannot answer a ClientHello for SNI=<service domain>; the upstream
# handshake aborts (tlsv1 alert internal error 80) and the front serves 502 on
# every request. A cert previously held only in process memory masked this
# until the first container recreate.
#
# Fix: nodes that are fronted get a self-signed cert in the caddy-data volume
# and the Caddyfile emits `tls /data/pki/<domain>.crt /data/pki/<domain>.key`
# inside the service site block. Fronts do not verify upstream certs (nginx
# proxy_ssl_verify defaults off); browsers never see this cert — the front
# terminates client TLS. With `tls <cert> <key>` present, certmagic also stops
# burning ACME rate-limit budget on a name that can never issue.
#
# Mode resolution (fronted_tls_mode):
#   EDGE_FRONTED_TLS=static|acme   — operator override, wins outright
#   EDGE_FRONTED_TLS=auto (default)— DNS: static iff the domain resolves and the
#                                    node's public IP is NOT among its A records.
#                                    Ambiguous results fall back to the last
#                                    positively-detected mode (persisted hint),
#                                    then to acme — never guess "fronted".
#
# The static directive is emitted only when the cert files actually exist
# (fronted_tls_ensure_cert succeeded): a `tls` line pointing at missing files
# would crash caddy on load — acme fallback is the safer failure.
#
# Double-source guard: sourcing twice is a no-op.
[[ -n "${_FRONTED_TLS_LIB_LOADED:-}" ]] && return 0
_FRONTED_TLS_LIB_LOADED=1

# fronted_tls_mode DOMAIN NODE_IP [STATE_DIR]
#   echoes "static" | "acme". STATE_DIR defaults to $PREFIX_ETC; the persisted
#   hint lives at <STATE_DIR>/.fronted-tls-mode (best-effort write).
fronted_tls_mode() {
	local domain="$1" node_ip="${2:-}" state_dir="${3:-${PREFIX_ETC:-/etc/oxpulse-partner-edge}}"
	local hint="$state_dir/.fronted-tls-mode"

	case "${EDGE_FRONTED_TLS:-auto}" in
		static) echo static; return 0 ;;
		acme)   echo acme;   return 0 ;;
		auto|"") ;;
		*) warn "fronted_tls: EDGE_FRONTED_TLS='${EDGE_FRONTED_TLS}' invalid (auto|static|acme) — treating as auto" ;;
	esac

	# auto: positive DNS detection requires BOTH a resolved node_ip and a
	# non-empty domain answer. Node behind 1:1 NAT is fine — node_ip is the
	# registered PUBLIC_IP, not the egress interface address.
	local ips=""
	if [[ -n "$node_ip" ]]; then
		ips=$(getent ahostsv4 "$domain" 2>/dev/null | awk 'NR<=8 {print $1}' | sort -u)
	fi
	if [[ -n "$ips" ]]; then
		if grep -qxF "$node_ip" <<<"$ips"; then
			echo acme >"$hint" 2>/dev/null || true
			echo acme
		else
			echo static >"$hint" 2>/dev/null || true
			echo static
		fi
		return 0
	fi
	# Ambiguous (no node_ip, or DNS resolution failed/empty): last known mode
	# wins so a transient DNS failure cannot flip a fronted node back to ACME
	# and strip the tls line out of the next render.
	if [[ -f "$hint" ]]; then
		cat "$hint"
		return 0
	fi
	echo acme
}

# fronted_tls_cert_dir — echoes the HOST path of the caddy-data volume's pki/
# dir, empty when unresolvable. Chain: live container mount → named volume →
# deterministic local-driver path (covers pre-first-compose install, where the
# volume does not exist yet; pre-creating the dir is safe — docker populates
# the volume around it at first mount).
fronted_tls_cert_dir() {
	local mp=""
	mp=$(${DOCKER_BIN:-docker} inspect "${CADDY_CONTAINER:-oxpulse-partner-caddy}" \
		--format '{{range .Mounts}}{{if eq .Destination "/data"}}{{.Source}}{{end}}{{end}}' \
		2>/dev/null | head -1 || true)
	if [[ -z "$mp" ]]; then
		mp=$(${DOCKER_BIN:-docker} volume inspect \
			"${COMPOSE_PROJECT_NAME:-oxpulse-partner-edge}_caddy-data" \
			--format '{{.Mountpoint}}' 2>/dev/null || true)
	fi
	if [[ -z "$mp" && -d /var/lib/docker/volumes ]]; then
		mp="/var/lib/docker/volumes/${COMPOSE_PROJECT_NAME:-oxpulse-partner-edge}_caddy-data/_data"
	fi
	[[ -n "$mp" ]] && printf '%s/pki\n' "${mp%/}"
}

# fronted_tls_ensure_cert DOMAIN — idempotent self-signed cert at
# <caddy-data>/pki/<domain>.{crt,key}. 0 on success/present, 1 on failure.
fronted_tls_ensure_cert() {
	local domain="$1" dir
	dir=$(fronted_tls_cert_dir)
	[[ -n "$dir" ]] || { warn "fronted_tls: cannot resolve caddy-data volume path — cert not generated"; return 1; }
	[[ -f "$dir/$domain.crt" && -f "$dir/$domain.key" ]] && return 0
	mkdir -p "$dir" 2>/dev/null || { warn "fronted_tls: mkdir $dir failed"; return 1; }
	if ! openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
		-keyout "$dir/$domain.key" -out "$dir/$domain.crt" -days 3650 \
		-subj "/CN=$domain" -addext "subjectAltName=DNS:$domain" 2>/dev/null; then
		warn "fronted_tls: openssl self-signed cert generation failed for $domain"
		return 1
	fi
	chmod 0644 "$dir/$domain.crt" "$dir/$domain.key" 2>/dev/null || true
	# warn (not log): every caller defines warn; log is not guaranteed in all
	# source contexts and a missing function would trip set -e here.
	warn "fronted_tls: self-signed cert for $domain → $dir"
}

# fronted_tls_directive DOMAIN NODE_IP [STATE_DIR]
#   echoes the `tls ...` line for the service site block, or nothing.
#   Emits only when mode=static AND the cert is in place — never renders a
#   reference to files caddy cannot read.
fronted_tls_directive() {
	local domain="$1" node_ip="${2:-}" state_dir="${3:-}"
	[[ "$(fronted_tls_mode "$domain" "$node_ip" "$state_dir")" == "static" ]] || return 0
	if ! fronted_tls_ensure_cert "$domain"; then
		warn "fronted_tls: static mode resolved but cert unavailable — falling back to ACME render (upstream SNI stays unanswerable)"
		return 0
	fi
	printf '    tls /data/pki/%s.crt /data/pki/%s.key\n' "$domain" "$domain"
}
