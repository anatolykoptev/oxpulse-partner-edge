#!/usr/bin/env bash
# install.sh — one-command bootstrap for an oxpulse-chat partner edge node.
#
#   curl -fsSL https://install.oxpulse.chat/partner | sudo bash -s -- \
#     --domain=call.rvpn.online --partner-id=rvpn --token=ptkn_xxx
#
# Manual-config fallback (until /api/partner/register lands — Task 4):
#   sudo bash install.sh --domain=call.rvpn.online --partner-id=rvpn \
#        --manual-config=./node-config.json
#
# The manual-config JSON schema is documented in README.md.
set -euo pipefail

# ---------- Constants ----------
PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
PREFIX_SBIN=/usr/local/sbin
SYSTEMD_DIR=/etc/systemd/system
# shellcheck disable=SC2034  # REGISTRY referenced by templates via IMAGE_VERSION, kept for override env surface
REGISTRY="${OXPULSE_IMAGE_REGISTRY:-ghcr.io/anatolykoptev}"
REPO_RAW="${OXPULSE_REPO_RAW:-https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main}"
BACKEND_API="${OXPULSE_BACKEND_API:-${OXPULSE_BACKEND_URL:-https://api.oxpulse.chat}}"
# Strip trailing slash so we never emit //api/partner/register.
BACKEND_API="${BACKEND_API%/}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- Args ----------
DOMAIN=""
PARTNER_ID=""
TOKEN=""
TUNNEL=vless
MANUAL_CONFIG=""
IMAGE_VERSION="${OXPULSE_IMAGE_VERSION:-latest}"
# v0.2.0-rc1 placeholder: real per-clone value comes from /api/partner/register
# response rendered by hydrate.sh in Phase 6 (Task 5.2).
TURNS_SUBDOMAIN="${TURNS_SUBDOMAIN:-turns}"
# M2.1: SFU UDP media port + Prometheus metrics port. Overridable via env or
# interactive prompt so operators with port conflicts don't need to edit files.
SFU_UDP_PORT="${SFU_UDP_PORT:-7878}"
SFU_METRICS_PORT="${SFU_METRICS_PORT:-8878}"
DRY_RUN=0
BAKE_MODE=0

usage() {
	sed -n '2,18p' "$0" >&2
	cat >&2 <<USAGE

Required:
  --domain=<fqdn>            Partner edge domain (must resolve to this host's public IP)
  --partner-id=<id>          Short partner identifier (e.g. rvpn, piter)

Registration (pick one):
  --token=<ptkn_...>         Fetch node config from $BACKEND_API/api/partner/register
  --manual-config=<path>     Read node config from a local JSON file

Optional:
  --tunnel=vless|wg|https    Backend tunnel kind (default: vless)
  --image-version=<tag>      Pull a specific image tag (default: latest)
  --dry-run                  Render templates + print plan, skip docker/systemd
  --bake                     Bake phase: install packages + images + units, no secrets, no start. For snapshot workflows.
  -h|--help                  Show this help

Env overrides: OXPULSE_IMAGE_REGISTRY, OXPULSE_BACKEND_API, OXPULSE_REPO_RAW
USAGE
	exit 2
}

while [[ $# -gt 0 ]]; do
	case "$1" in
		--domain=*)         DOMAIN="${1#*=}" ;;
		--partner-id=*)     PARTNER_ID="${1#*=}" ;;
		--token=*)          TOKEN="${1#*=}" ;;
		--manual-config=*)  MANUAL_CONFIG="${1#*=}" ;;
		--tunnel=*)         TUNNEL="${1#*=}" ;;
		--image-version=*)  IMAGE_VERSION="${1#*=}" ;;
		--dry-run)          DRY_RUN=1 ;;
		--bake)             BAKE_MODE=1 ;;
		-h|--help)          usage ;;
		*) die "unknown arg: $1 (try --help)" ;;
	esac
	shift
done

[[ -z "$DOMAIN" ]]     && die "--domain is required"
[[ -z "$PARTNER_ID" ]] && die "--partner-id is required"
if [[ "$BAKE_MODE" = "0" && -z "$TOKEN" && -z "$MANUAL_CONFIG" ]]; then
	die "either --token or --manual-config is required (see --help)"
fi
case "$TUNNEL" in
	vless|wg|https) : ;;
	*) die "--tunnel must be one of: vless, wg, https" ;;
esac

# Interactive prompts for SFU port overrides (non-interactive / OXPULSE_NONINTERACTIVE=1 skips).
if [[ -t 0 && "${OXPULSE_NONINTERACTIVE:-0}" != "1" ]]; then
	read -rp "SFU UDP port (media) [${SFU_UDP_PORT}]: " _inp
	SFU_UDP_PORT="${_inp:-$SFU_UDP_PORT}"
	read -rp "SFU metrics port (TCP) [${SFU_METRICS_PORT}]: " _inp
	SFU_METRICS_PORT="${_inp:-$SFU_METRICS_PORT}"
	unset _inp
fi

if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
	die "must run as root (or with sudo) unless --dry-run"
fi

# ---------- Step 1: preflight ----------
log "[1/10] preflight checks"
OS_ID=""; OS_FAMILY=""
if [[ -r /etc/os-release ]]; then
	# shellcheck source=/dev/null
	. /etc/os-release
	OS_ID="$ID"
	case " $ID ${ID_LIKE:-} " in
		*" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
		*" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*|*" rocky "*) OS_FAMILY=rhel ;;
		*) die "unsupported OS: ID=$ID ID_LIKE=${ID_LIKE:-<empty>} (need Debian/Ubuntu/AlmaLinux/Rocky/RHEL)" ;;
	esac
fi
log "  os=$OS_ID family=$OS_FAMILY"

if [[ $DRY_RUN -eq 0 ]]; then
	check_port_free() {
		local port=$1 proto=$2
		if ss -ln"${proto}" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
			die "port $port/$proto is already in use — free it before installing"
		fi
	}
	for p in 80 443 3478 5349 "$SFU_METRICS_PORT"; do check_port_free "$p" t; done
	check_port_free 3478 u
	# M2.1: str0m SFU media port (UDP). Default 7878 avoids coturn's 3478.
	check_port_free "$SFU_UDP_PORT" u
	log "  ports 80/443/3478/5349/${SFU_UDP_PORT}(udp)/${SFU_METRICS_PORT}(tcp) are free"
fi

# ---------- Step 2: Docker ----------
log "[2/10] ensuring docker + compose plugin"
if [[ $DRY_RUN -eq 0 ]]; then
	if ! command -v docker >/dev/null 2>&1; then
		log "  docker not found — installing via get.docker.com"
		curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o /tmp/get-docker.sh
		sh /tmp/get-docker.sh
		rm -f /tmp/get-docker.sh
	fi
	if ! docker compose version >/dev/null 2>&1; then
		if [[ $OS_FAMILY == debian ]]; then
			apt-get update -q && apt-get install -y -q docker-compose-plugin dnsutils
		else
			dnf install -y docker-compose-plugin bind-utils || dnf install -y docker-compose bind-utils
		fi
	fi
	systemctl enable --now docker
	log "  docker $(docker --version | awk '{print $3}' | tr -d ,) ready"
else
	warn "  [dry-run] skipping docker install"
fi

# ---------- Step 3: public/private IP autodetect ----------
log "[3/10] detecting IPs"
_detect_public_ipv4() {
	local ip
	ip=$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
	if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
	ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
	if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
	ip=$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
	if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
	return 1
}
PUBLIC_IP="${OXPULSE_PUBLIC_IP:-}"
[[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(_detect_public_ipv4 || true)
[[ -z "$PUBLIC_IP" ]] && die "unable to autodetect public IP — set OXPULSE_PUBLIC_IP"
PRIVATE_IP="${OXPULSE_PRIVATE_IP:-}"
if [[ -z "$PRIVATE_IP" ]]; then
	iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
	if [[ -n "$iface" ]]; then
		cand=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
		[[ "$cand" != "$PUBLIC_IP" ]] && PRIVATE_IP="$cand"
	fi
fi
log "  public=$PUBLIC_IP private=${PRIVATE_IP:-<none>}"

# Detect local checkout directory for template files (used in Steps 5 and 9).
# When invoked via `curl ... | bash`, BASH_SOURCE is unset and `set -u` would error;
# default to empty so the local-checkout branch falls through to REPO_RAW fetches.
src_dir=""
src_self="${BASH_SOURCE[0]:-}"
if [[ -n "$src_self" && -f "$(cd "$(dirname "$src_self")" 2>/dev/null && pwd)/docker-compose.yml.tpl" ]]; then
	src_dir="$(cd "$(dirname "$src_self")" && pwd)"
fi

# ---------- Step 3b: pre-pull images ----------
# Runs unconditionally (bake + full-install modes).
# In bake mode: caches images into the VM for snapshotting (spec line 1507).
# In full-install mode: ensures images are ready before compose-up.
log "[3b] pulling images (image_version=$IMAGE_VERSION)"
if [[ $DRY_RUN -eq 0 ]]; then
	tpl_src=""
	if [[ -n "$src_dir" && -f "$src_dir/docker-compose.yml.tpl" ]]; then
		tpl_src="$src_dir/docker-compose.yml.tpl"
	else
		tpl_src=$(mktemp)
		curl -fsSL "$REPO_RAW/docker-compose.yml.tpl" -o "$tpl_src"
	fi
	while IFS= read -r img_line; do
		img="${img_line#*image: }"
		img="${img//\{\{IMAGE_VERSION\}\}/$IMAGE_VERSION}"
		img="${img//[[:space:]]/}"
		[ -z "$img" ] && continue
		docker pull "$img"
	done < <(grep -E '^[[:space:]]+image:' "$tpl_src")
else
	warn "  [dry-run] would: docker pull images from docker-compose.yml.tpl"
fi

# ---------- Steps 4-8: hydrate path (secrets + service start) ----------
# Skipped in --bake mode; runs in legacy (default) mode only.
if [ "$BAKE_MODE" = "0" ]; then

# ---------- Step 4: fetch node config ----------
log "[4/10] fetching node config"
tmp_cfg=$(mktemp)
trap 'rm -f "$tmp_cfg"' EXIT
if [[ -n "$MANUAL_CONFIG" ]]; then
	[[ -r "$MANUAL_CONFIG" ]] || die "manual-config file not readable: $MANUAL_CONFIG"
	cp "$MANUAL_CONFIG" "$tmp_cfg"
	log "  using manual config: $MANUAL_CONFIG"
else
	log "  POST $BACKEND_API/api/partner/register"
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
		-X POST "$BACKEND_API/api/partner/register" \
		-H 'Content-Type: application/json' \
		-d "{\"partner_id\":\"$PARTNER_ID\",\"domain\":\"$DOMAIN\",\"token\":\"$TOKEN\",\"public_ip\":\"$PUBLIC_IP\",\"region\":\"$REGION\"}" \
		-o "$tmp_cfg"; then
		die "registration failed — endpoint may not yet be implemented (Task 4). Retry with --manual-config=<path>"
	fi
fi

# jq-free JSON extraction (small fixed schema).
json_get() {
	local key=$1 file=$2
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],''))" "$file" "$key" 2>/dev/null \
		|| sed -nE "s/.*\"$key\"[[:space:]]*:[[:space:]]*\"([^\"]*)\".*/\1/p" "$file" | head -1
}
json_get_raw() {
	local key=$1 file=$2
	python3 -c "
import json,sys
d=json.load(open(sys.argv[1]))
v=d.get(sys.argv[2])
print(json.dumps(v) if v is not None else 'null')
" "$file" "$key" 2>/dev/null || echo "null"
}
NODE_ID=$(json_get node_id "$tmp_cfg")
BACKEND_ENDPOINT=$(json_get backend_endpoint "$tmp_cfg")
TURN_SECRET=$(json_get turn_secret "$tmp_cfg")
REALITY_UUID=$(json_get reality_uuid "$tmp_cfg")
REALITY_PUBLIC_KEY=$(json_get reality_public_key "$tmp_cfg")
REALITY_SHORT_ID=$(json_get reality_short_id "$tmp_cfg")
REALITY_SERVER_NAME=$(json_get reality_server_name "$tmp_cfg")
# VLESS Encryption spec (e.g. mlkem768x25519plus...). Empty = legacy "none".
# The server-side xray-reality requires matching encryption, otherwise the
# tunnel completes the TLS handshake but silently drops payloads.
REALITY_ENCRYPTION=$(json_get reality_encryption "$tmp_cfg")
RELAY_JWT_SECRET=$(json_get relay_jwt_secret "$tmp_cfg")
# If not provided by backend, generate a local secret.
# The same secret must be added to the operator's signaling server RELAY_JWT_SECRET
# env var and SFU_EDGES relay_api_url for cascade relay to work.
[[ -z "$RELAY_JWT_SECRET" ]] && RELAY_JWT_SECRET=$(openssl rand -hex 32)
# Phase 7 M4.A6 — note: SFU_PUBLIC_IP is rendered into docker-compose.yml from
# the $PUBLIC_IP autodetected at line ~174 via the existing {{PUBLIC_IP}}
# template substitution. We do NOT json_get a public_ip from the registration
# response (the API doesn't return one — public_ip is sent UP, not down). The
# autodetect chain (cloud metadata → ipify → ifconfig.me) is the source of
# truth and matches what coturn already uses for PUBLIC_IPV4.
# Phase 7 M4.A5 — HS256 secret used by the SFU client_ws endpoint to verify
# browser-issued room JWTs. MUST match SIGNALING_SFU_SECRET on the signaling
# server (oxpulse-chat). When empty, the SFU disables /sfu/ws/{room_id}
# entirely and Caddy's reverse_proxy to :8920 will return 502 — that's
# the safe default (no unauthenticated browser WS exposure).
SIGNALING_SFU_SECRET=$(json_get signaling_sfu_secret "$tmp_cfg")
# Backend-assigned TURNS subdomain (format api-<6-hex>). Falls back to "turns"
# only if the backend did not return one (pre-v0.2 deployments).
REGISTER_TURNS_SUBDOMAIN=$(json_get turns_subdomain "$tmp_cfg")
# CH3/CH5 fallback channel vars — optional; empty if backend does not provision them.
HYSTERIA2_SERVER=$(json_get hysteria2_server "$tmp_cfg")
HYSTERIA2_PORT=$(json_get hysteria2_port "$tmp_cfg")
HYSTERIA2_AUTH=$(json_get hysteria2_auth "$tmp_cfg")
HYSTERIA2_OBFS=$(json_get hysteria2_obfs "$tmp_cfg")
NAIVE_SERVER=$(json_get naive_server "$tmp_cfg")
NAIVE_PORT=$(json_get naive_port "$tmp_cfg")
NAIVE_USER=$(json_get naive_user "$tmp_cfg")
NAIVE_PASS=$(json_get naive_pass "$tmp_cfg")
# channels[] — future-proof bypass channel array.
# Empty if server is older than v0.12 (no channels field yet).
CHANNELS_JSON=$(json_get_raw channels "$tmp_cfg")
[[ "$CHANNELS_JSON" == "null" || -z "$CHANNELS_JSON" ]] && CHANNELS_JSON="[]"
[[ -z "$NODE_ID" ]]            && NODE_ID="${PARTNER_ID}-$(hostname -s)"
[[ -z "$BACKEND_ENDPOINT" ]]   && die "backend_endpoint missing from config"
[[ -z "$TURN_SECRET" ]]        && die "turn_secret missing from config"
[[ -z "$REALITY_UUID" ]]       && die "reality_uuid missing from config"
[[ -z "$REALITY_PUBLIC_KEY" ]] && die "reality_public_key missing from config"

# Persist the resolved node config so oxpulse-partner-edge-refresh can
# detect operator-side Reality keypair rotations and hot-update it.
# Refresh script reads this file, merges new reality_* fields from
# /api/partner/keys, and reloads the bundle. The file MUST be 0600
# because reality_encryption is the partner-fleet PQ seed.
if [[ $DRY_RUN -eq 0 ]]; then
	install -d -m 0755 "$PREFIX_ETC"
	install -m 0600 "$tmp_cfg" "$PREFIX_ETC/node-config.json"
	log "  persisted node-config.json → $PREFIX_ETC/node-config.json"
	# Merge channels[] into node-config.json if server returned it.
	# The raw tmp_cfg already has all other fields; we just ensure channels
	# key is present for re_render_xray and future channel renderers.
	if [[ "$CHANNELS_JSON" != "[]" ]]; then
		python3 - "$PREFIX_ETC/node-config.json" "$CHANNELS_JSON" << 'PYEOF'
import json, sys
cfg = json.load(open(sys.argv[1]))
cfg['channels'] = json.loads(sys.argv[2])
open(sys.argv[1], 'w').write(json.dumps(cfg, indent=2))
PYEOF
		log "  channels[] written to node-config.json (${#CHANNELS_JSON} bytes)"
	fi
fi
[[ -z "$REALITY_SHORT_ID" ]]   && die "reality_short_id missing from config"
[[ -z "$REALITY_SERVER_NAME" ]] && REALITY_SERVER_NAME="www.samsung.com"
[[ -z "$REALITY_ENCRYPTION" ]] && REALITY_ENCRYPTION="none"
[[ -n "$REGISTER_TURNS_SUBDOMAIN" ]] && TURNS_SUBDOMAIN="$REGISTER_TURNS_SUBDOMAIN"

# Phase 2: Fetch Ed25519 SFU signing public key from /api/partner/keys at
# install time so the SFU container starts with the correct key on day 1
# (the daily refresh timer fires later; install must not leave it empty).
log "  fetching sfu_signing_public_key from $BACKEND_API/api/partner/keys"
SFU_SIGNING_PUBLIC_KEY=""
_keys_resp=$(curl -sS --max-time 10 -fL "$BACKEND_API/api/partner/keys" 2>/dev/null || true)
if [[ -n "$_keys_resp" ]]; then
	SFU_SIGNING_PUBLIC_KEY=$(printf '%s' "$_keys_resp" | jq -r '.sfu_signing_public_key // empty' 2>/dev/null || true)
fi
if [[ -n "$SFU_SIGNING_PUBLIC_KEY" ]]; then
	log "  sfu_signing_public_key obtained"
	if [[ $DRY_RUN -eq 0 ]]; then
		install -d -m 0700 "$PREFIX_LIB"
		printf 'SFU_SIGNING_PUBLIC_KEY=%s\n' "$SFU_SIGNING_PUBLIC_KEY" > "$PREFIX_LIB/sfu-keys.env"
		chmod 0600 "$PREFIX_LIB/sfu-keys.env"
	fi
else
	warn "  sfu_signing_public_key not available from /api/partner/keys (signaling may need updating; SFU relay JWT auth will fall back to RELAY_JWT_SECRET)"
fi
unset _keys_resp

# Split backend_endpoint "host:port" into host + port for xray config.
BACKEND_HOST="${BACKEND_ENDPOINT%:*}"
BACKEND_PORT="${BACKEND_ENDPOINT##*:}"
if [[ "$BACKEND_HOST" == "$BACKEND_PORT" || -z "$BACKEND_PORT" ]]; then
	die "backend_endpoint must be host:port (got '$BACKEND_ENDPOINT')"
fi

# EXTERNAL_IP_LINE for coturn — "public/private" if behind NAT, else "public".
if [[ -n "${PRIVATE_IP:-}" ]]; then
	EXTERNAL_IP_LINE="${PUBLIC_IP}/${PRIVATE_IP}"
else
	EXTERNAL_IP_LINE="${PUBLIC_IP}"
fi

# ---------- Step 5: stage templates ----------
log "[5/10] rendering templates"
if [[ $DRY_RUN -eq 0 ]]; then
	install -d -m 0755 "$PREFIX_ETC"
	install -d -m 0700 "$PREFIX_LIB"
fi

if [[ -n "$src_dir" ]]; then
	log "  using templates from local checkout: $src_dir"
fi

fetch_tpl() {
	local name=$1 dst=$2
	if [[ -n "$src_dir" && -f "$src_dir/$name" ]]; then
		cp "$src_dir/$name" "$dst"
	else
		curl -fsSL "$REPO_RAW/$name" -o "$dst"
	fi
}

stage=$(mktemp -d)
fetch_tpl docker-compose.yml.tpl "$stage/compose.tpl"
fetch_tpl Caddyfile.tpl          "$stage/caddy.tpl"
fetch_tpl xray-client.json.tpl   "$stage/xray.tpl"
fetch_tpl coturn.conf.tpl        "$stage/coturn.tpl"
# CH3/CH5 templates — fetched unconditionally so nodes have them ready.
# Rendering is skipped unless HYSTERIA2_SERVER / NAIVE_SERVER are set.
fetch_tpl hysteria2-client.yaml.tpl "$stage/hysteria2.tpl"
fetch_tpl naive-client.json.tpl     "$stage/naive.tpl"

# Static assets bundle. cover/ is bind-mounted by docker-compose (./cover:/srv/cover:ro)
# and read by Caddy file_server when serving the DPI-probe decoy on GET /.
# Forgetting to ship it = silent 404 on the partner root URL (regression seen 2026-04-20).
mkdir -p "$stage/cover"
fetch_tpl cover/cover.html "$stage/cover/cover.html"

render() {
	local src=$1 dst=$2
	# Mustache-style placeholder substitution via sed. No external deps.
	# REALITY_ENCRYPTION may contain sed-special chars — use a literal-safe delimiter (|) and
	# emit via --posix-disabled sed -f script so embedded '|' never collides (none observed to date).
	sed \
		-e "s|{{PARTNER_ID}}|${PARTNER_ID}|g" \
		-e "s|{{PARTNER_DOMAIN}}|${DOMAIN}|g" \
		-e "s|{{BACKEND_ENDPOINT}}|${BACKEND_ENDPOINT}|g" \
		-e "s|{{BACKEND_HOST}}|${BACKEND_HOST}|g" \
		-e "s|{{BACKEND_PORT}}|${BACKEND_PORT}|g" \
		-e "s|{{TURN_SECRET}}|${TURN_SECRET}|g" \
		-e "s|{{REALITY_UUID}}|${REALITY_UUID}|g" \
		-e "s|{{REALITY_PUBLIC_KEY}}|${REALITY_PUBLIC_KEY}|g" \
		-e "s|{{REALITY_SHORT_ID}}|${REALITY_SHORT_ID}|g" \
		-e "s|{{REALITY_SERVER_NAME}}|${REALITY_SERVER_NAME}|g" \
		-e "s|{{REALITY_ENCRYPTION}}|${REALITY_ENCRYPTION}|g" \
		-e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" \
		-e "s|{{PUBLIC_IP}}|${PUBLIC_IP}|g" \
		-e "s|{{PRIVATE_IP}}|${PRIVATE_IP:-}|g" \
		-e "s|{{EXTERNAL_IP_LINE}}|${EXTERNAL_IP_LINE}|g" \
		-e "s|{{IMAGE_VERSION}}|${IMAGE_VERSION}|g" \
		-e "s|{{SFU_UDP_PORT}}|${SFU_UDP_PORT}|g" \
		-e "s|{{SFU_METRICS_PORT}}|${SFU_METRICS_PORT}|g" \
		-e "s|{{SFU_SIGNING_PUBLIC_KEY}}|${SFU_SIGNING_PUBLIC_KEY:-}|g" \
		-e "s|{{RELAY_JWT_SECRET}}|${RELAY_JWT_SECRET}|g" \
		-e "s|{{SIGNALING_SFU_SECRET}}|${SIGNALING_SFU_SECRET:-}|g" \
		-e "s|{{HYSTERIA2_SERVER}}|${HYSTERIA2_SERVER:-}|g" \
		-e "s|{{HYSTERIA2_PORT}}|${HYSTERIA2_PORT:-51822}|g" \
		-e "s|{{HYSTERIA2_AUTH}}|${HYSTERIA2_AUTH:-}|g" \
		-e "s|{{HYSTERIA2_OBFS}}|${HYSTERIA2_OBFS:-}|g" \
		-e "s|{{HYSTERIA2_SOCKS_PORT}}|${HYSTERIA2_SOCKS_PORT:-18891}|g" \
		-e "s|{{NAIVE_SERVER}}|${NAIVE_SERVER:-}|g" \
		-e "s|{{NAIVE_PORT}}|${NAIVE_PORT:-44433}|g" \
		-e "s|{{NAIVE_USER}}|${NAIVE_USER:-}|g" \
		-e "s|{{NAIVE_PASS}}|${NAIVE_PASS:-}|g" \
		-e "s|{{NAIVE_SOCKS_PORT}}|${NAIVE_SOCKS_PORT:-18892}|g" \
		"$src" > "$dst"
}

compose_out="$PREFIX_ETC/docker-compose.yml"
caddy_out="$PREFIX_ETC/Caddyfile"
xray_out="$PREFIX_ETC/xray-client.json"
coturn_out="$PREFIX_ETC/coturn.conf"
cover_out_dir="$PREFIX_ETC/cover"

if [[ $DRY_RUN -eq 1 ]]; then
	# Render to /tmp so caller can inspect without root.
	dryroot=$(mktemp -d)
	compose_out="$dryroot/docker-compose.yml"
	caddy_out="$dryroot/Caddyfile"
	xray_out="$dryroot/xray-client.json"
	coturn_out="$dryroot/coturn.conf"
	cover_out_dir="$dryroot/cover"
fi
render "$stage/compose.tpl" "$compose_out"
render "$stage/caddy.tpl"   "$caddy_out"
render "$stage/xray.tpl"    "$xray_out"
render "$stage/coturn.tpl"  "$coturn_out"
mkdir -p "$cover_out_dir"
install -m 0644 "$stage/cover/cover.html" "$cover_out_dir/cover.html"
# Render CH3 / CH5 if the backend provided the required vars
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
	render "$stage/hysteria2.tpl" "$PREFIX_ETC/hysteria2-client.yaml"
	chmod 0600 "$PREFIX_ETC/hysteria2-client.yaml"
	log "  hysteria2-client.yaml rendered"
fi
if [[ -n "${NAIVE_SERVER:-}" ]]; then
	render "$stage/naive.tpl" "$PREFIX_ETC/naive-client.json"
	chmod 0600 "$PREFIX_ETC/naive-client.json"
	log "  naive-client.json rendered"
fi
rm -rf "$stage"

# Secrets-containing files → 0600.
chmod 0600 "$xray_out" "$coturn_out" || true
log "  rendered → $compose_out (+ Caddyfile, xray-client.json, coturn.conf, cover/cover.html)"

# Persist install state for upgrade.sh.
if [[ $DRY_RUN -eq 0 ]]; then
	cat > "$PREFIX_LIB/install.env" <<EOF
PARTNER_ID=$PARTNER_ID
PARTNER_DOMAIN=$DOMAIN
NODE_ID=$NODE_ID
TUNNEL=$TUNNEL
IMAGE_VERSION=$IMAGE_VERSION
TURNS_SUBDOMAIN=$TURNS_SUBDOMAIN
INSTALLED_AT=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
	chmod 0600 "$PREFIX_LIB/install.env"
fi

# ---------- Step 6: start ----------
log "[6/10] starting services"
if [[ $DRY_RUN -eq 0 ]]; then
	(cd "$PREFIX_ETC" && docker compose up -d)
else
	warn "  [dry-run] would: docker compose up -d"
fi

# ---------- Step 7: healthcheck ----------
log "[7/10] waiting for healthcheck (timeout 120s)"
if [[ $DRY_RUN -eq 0 ]]; then
	deadline=$(( $(date +%s) + 120 ))
	hc_script="$PREFIX_SBIN/oxpulse-partner-edge-healthcheck"
	# Ship healthcheck.sh into /usr/local/sbin too so systemd + manual runs both work.
	if [[ -n "$src_dir" && -f "$src_dir/healthcheck.sh" ]]; then
		install -m 0755 "$src_dir/healthcheck.sh" "$hc_script"
	else
		curl -fsSL "$REPO_RAW/healthcheck.sh" -o "$hc_script"
		chmod 0755 "$hc_script"
	fi
	# coturn starts before Caddy finishes the ACME dance for the TURNS
	# subdomain, so its TLS listener is disabled on first boot (cert file
	# missing). Once Caddy obtains the cert the cert-watch.path sends
	# SIGUSR2 for subsequent renewals, but the initial kick has to come
	# from install.sh — otherwise :5349 stays silent until the first
	# real renewal months later. Poll for the cert, then restart coturn.
	turns_cert_dir="/var/lib/docker/volumes/oxpulse-partner-edge_caddy-data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${TURNS_SUBDOMAIN}.${DOMAIN}"
	turns_cert_deadline=$(( $(date +%s) + 180 ))
	turns_cert_ready=0
	while :; do
		if [[ -s "$turns_cert_dir/${TURNS_SUBDOMAIN}.${DOMAIN}.crt" ]]; then
			turns_cert_ready=1
			break
		fi
		if (( $(date +%s) > turns_cert_deadline )); then
			break
		fi
		sleep 3
	done
	if (( turns_cert_ready == 1 )); then
		log "  TURNS cert ready → restarting coturn to enable :5349 TLS listener"
		(cd "$PREFIX_ETC" && docker compose restart coturn >/dev/null 2>&1 || true)
	else
		warn "  TURNS cert not ready after 180s — coturn TLS listener may be disabled. Retry: 'docker compose -f $PREFIX_ETC/docker-compose.yml restart coturn' once Caddy obtains the cert"
	fi

	while :; do
		if OXPULSE_EDGE_CONFIG_DIR="$PREFIX_ETC" "$hc_script" --local >/dev/null 2>&1; then
			log "  healthcheck green"
			break
		fi
		if (( $(date +%s) > deadline )); then
			warn "  healthcheck still red after 120s — continuing, inspect with: $hc_script"
			break
		fi
		sleep 3
	done
else
	warn "  [dry-run] skipping healthcheck"
fi

fi  # end BAKE_MODE=0 (hydrate path)

# ---------- Step 8: systemd ----------
log "[8/10] installing systemd unit"
if [[ $DRY_RUN -eq 0 ]]; then
	unit_src=""
	if [[ -n "$src_dir" && -f "$src_dir/systemd/oxpulse-partner-edge.service" ]]; then
		unit_src="$src_dir/systemd/oxpulse-partner-edge.service"
		install -m 0644 "$unit_src" "$SYSTEMD_DIR/oxpulse-partner-edge.service"
	else
		curl -fsSL "$REPO_RAW/systemd/oxpulse-partner-edge.service" \
			-o "$SYSTEMD_DIR/oxpulse-partner-edge.service"
	fi
	# Upgrade script into /usr/local/sbin.
	if [[ -n "$src_dir" && -f "$src_dir/upgrade.sh" ]]; then
		install -m 0755 "$src_dir/upgrade.sh" "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
	else
		curl -fsSL "$REPO_RAW/upgrade.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-upgrade"
	fi
	# Shared channel render library (sourced by upgrade.sh + refresh.sh).
	if [[ -n "$src_dir" && -f "$src_dir/channel-render-lib.sh" ]]; then
		install -m 0644 "$src_dir/channel-render-lib.sh" "$PREFIX_SBIN/channel-render-lib.sh"
	else
		curl -fsSL "$REPO_RAW/channel-render-lib.sh" -o "$PREFIX_SBIN/channel-render-lib.sh"
		chmod 0644 "$PREFIX_SBIN/channel-render-lib.sh"
	fi
	# Hydrate script into /usr/local/sbin (installed in all modes; needed by the
	# oneshot unit on first boot after snapshot→clone).
	if [[ -n "$src_dir" && -f "$src_dir/hydrate.sh" ]]; then
		install -m 0755 "$src_dir/hydrate.sh" "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
	else
		curl -fsSL "$REPO_RAW/hydrate.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-hydrate"
	fi
	# Hydrate oneshot unit (sentinel-gated; fires on first boot after clone).
	if [[ -n "$src_dir" && -f "$src_dir/systemd/oxpulse-partner-edge-hydrate.service" ]]; then
		install -m 0644 "$src_dir/systemd/oxpulse-partner-edge-hydrate.service" \
			"$SYSTEMD_DIR/oxpulse-partner-edge-hydrate.service"
	else
		curl -fsSL "$REPO_RAW/systemd/oxpulse-partner-edge-hydrate.service" \
			-o "$SYSTEMD_DIR/oxpulse-partner-edge-hydrate.service"
	fi
	# Cert-watch units (Task 2A.5): inotify path unit + oneshot signal service.
	# Substitute {{TURNS_SUBDOMAIN}} + {{PARTNER_DOMAIN}} before install.
	for unit in oxpulse-partner-cert-watch.path oxpulse-partner-cert-watch.service; do
		local_src=""
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			local_src="$src_dir/systemd/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "/tmp/${unit}.fetched"
			local_src="/tmp/${unit}.fetched"
		fi
		sed -e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN}|g" -e "s|{{PARTNER_DOMAIN}}|${DOMAIN}|g" \
			"$local_src" > "/tmp/${unit}.rendered"
		install -m 0644 "/tmp/${unit}.rendered" "$SYSTEMD_DIR/${unit}"
		rm -f "/tmp/${unit}.rendered" "/tmp/${unit}.fetched"
	done

	# Auto-refresh script + units: daily check of /api/partner/keys for
	# operator-side Reality keypair rotation. Without this, partner edges
	# break on every quarterly rotation until manually re-registered.
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-partner-edge-refresh.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-partner-edge-refresh.sh" "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
	else
		curl -fsSL "$REPO_RAW/oxpulse-partner-edge-refresh.sh" -o "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-refresh"
	fi
	for unit in oxpulse-partner-edge-refresh.service oxpulse-partner-edge-refresh.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done

	# SNI rotation script + timer.
	if [[ -n "$src_dir" && -f "$src_dir/oxpulse-partner-edge-sni-rotate.sh" ]]; then
		install -m 0755 "$src_dir/oxpulse-partner-edge-sni-rotate.sh" \
			"$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
	else
		curl -fsSL "$REPO_RAW/oxpulse-partner-edge-sni-rotate.sh" \
			-o "$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
		chmod 0755 "$PREFIX_SBIN/oxpulse-partner-edge-sni-rotate"
	fi
	for unit in oxpulse-partner-edge-sni-rotate.service oxpulse-partner-edge-sni-rotate.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done
	systemctl daemon-reload
	if [ "$BAKE_MODE" = "0" ]; then
		systemctl enable --now oxpulse-partner-edge.service
		systemctl enable --now oxpulse-partner-cert-watch.path
		systemctl enable --now oxpulse-partner-edge-refresh.timer
		systemctl enable --now oxpulse-partner-edge-sni-rotate.timer
	else
		# Bake mode: enable hydrate so it fires on first boot after snapshot→clone.
		# Do NOT start it now — secrets aren't present yet.
		systemctl enable oxpulse-partner-edge-hydrate.service
		systemctl enable oxpulse-partner-edge-refresh.timer
		systemctl enable oxpulse-partner-edge-sni-rotate.timer
		log "  [bake] units installed, daemon-reloaded; hydrate + refresh enabled for first boot"
	fi
else
	warn "  [dry-run] skipping systemd install"
fi

# ---------- Step 10: report ----------
log "[10/10] done"

if [ "$BAKE_MODE" = "1" ]; then
cat <<BANNER

========================================================================
  OxPulse partner-edge BAKE complete (snapshot-safe).

  Partner   : $PARTNER_ID
  Domain    : $DOMAIN
  Version   : $IMAGE_VERSION

  Packages, Docker images, and systemd units are installed.
  Services are NOT started. Take your snapshot now, then run
  hydrate.sh on first boot of each cloned VM.
========================================================================
BANNER
else
cat <<BANNER

========================================================================
  OxPulse partner-edge node installed.

  Partner   : $PARTNER_ID
  Node ID   : $NODE_ID
  Domain    : https://$DOMAIN
  Public IP : $PUBLIC_IP
  Tunnel    : $TUNNEL
  Version   : $IMAGE_VERSION
  Config    : $PREFIX_ETC/
  State     : $PREFIX_LIB/install.env

  Verify    : $PREFIX_SBIN/oxpulse-partner-edge-healthcheck
  Upgrade   : $PREFIX_SBIN/oxpulse-partner-edge-upgrade
  Logs      : docker compose -f $PREFIX_ETC/docker-compose.yml logs -f
  Systemd   : systemctl status oxpulse-partner-edge

  Next steps:
  1. Point DNS A record for $DOMAIN → $PUBLIC_IP
  2. Wait for Caddy LE cert issuance (~60s after DNS propagates)
  3. Open https://$DOMAIN and verify branding
========================================================================
BANNER
fi
