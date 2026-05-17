#!/usr/bin/env bash
# hydrate.sh — per-clone first-boot script for an oxpulse-chat partner edge node.
#
# Called by oxpulse-partner-edge-hydrate.service on first boot.
# Loads /etc/oxpulse-partner-edge/hydrate.env, registers with the backend,
# renders config templates, verifies DNS, starts services, and writes a
# sentinel for idempotency.
#
# Usage:
#   hydrate.sh             Normal run (idempotent; exits 0 if already hydrated).
#   hydrate.sh --reseed    Tear down containers, rm sentinel, re-hydrate.
set -euo pipefail

# ---------- Constants ----------
PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
HYDRATE_ENV="$PREFIX_ETC/hydrate.env"
SENTINEL="$PREFIX_LIB/hydrated"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
IMAGE_VERSION="${OXPULSE_IMAGE_VERSION:-latest}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- Args ----------
RESEED=0
for arg in "$@"; do
    case "$arg" in
        --reseed) RESEED=1 ;;
        *) die "unknown arg: $arg (use --reseed or no args)" ;;
    esac
done

# ---------- Ensure dirs ----------
mkdir -p "$PREFIX_LIB" "$PREFIX_ETC"

# ---------- Load env ----------
[[ -f "$HYDRATE_ENV" ]] || die "hydrate.env not found at $HYDRATE_ENV (cloud-init must write it)"
# shellcheck source=/dev/null
source "$HYDRATE_ENV"

# Source fleet-wide infrastructure defaults (after hydrate.env so operator
# overrides in hydrate.env take precedence via already-exported OXPULSE_* vars).
SCRIPT_DIR_HYDRATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_defaults_local="${SCRIPT_DIR_HYDRATE}/config/defaults.conf"
_defaults_installed="/usr/local/share/oxpulse-partner-edge/config/defaults.conf"
if [[ -f "$_defaults_local" ]]; then
    # shellcheck source=config/defaults.conf
    source "$_defaults_local"
elif [[ -f "$_defaults_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_defaults_installed"
fi
unset _defaults_local _defaults_installed SCRIPT_DIR_HYDRATE

[[ -n "${OXPULSE_PARTNER_DOMAIN:-}" ]]       || die "OXPULSE_PARTNER_DOMAIN not set in $HYDRATE_ENV"
[[ -n "${OXPULSE_PARTNER_ID:-}" ]]           || die "OXPULSE_PARTNER_ID not set in $HYDRATE_ENV"
[[ -n "${OXPULSE_REGISTRATION_TOKEN:-}" ]]   || die "OXPULSE_REGISTRATION_TOKEN not set in $HYDRATE_ENV"

PARTNER_DOMAIN="$OXPULSE_PARTNER_DOMAIN"
PARTNER_ID="$OXPULSE_PARTNER_ID"
REGISTRATION_TOKEN="$OXPULSE_REGISTRATION_TOKEN"

# ---------- Reseed: teardown ----------
if [[ $RESEED -eq 1 ]]; then
    log "reseed requested — stopping containers and removing sentinel"
    systemctl disable --now oxpulse-partner-edge.service oxpulse-partner-cert-watch.path 2>/dev/null || true
    if [[ -f "$PREFIX_ETC/docker-compose.yml" ]]; then
        docker compose -f "$PREFIX_ETC/docker-compose.yml" down --remove-orphans 2>/dev/null || true
    fi
    rm -f "$SENTINEL"
fi

# ---------- Idempotency check ----------
# Token is included so that rotation triggers a re-hydrate without --reseed.
config_input="${PARTNER_DOMAIN}:${PARTNER_ID}:${IMAGE_VERSION}:${REGISTRATION_TOKEN}"
config_sha256=$(printf '%s' "$config_input" | sha256sum | awk '{print $1}')

if [[ -f "$SENTINEL" ]]; then
    saved_sha=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('config_sha256',''))" "$SENTINEL" 2>/dev/null || true)
    if [[ "$saved_sha" == "$config_sha256" ]]; then
        log "already hydrated (config hash matches) — exiting 0"
        exit 0
    else
        warn "sentinel exists but config hash mismatch (saved=$saved_sha current=$config_sha256) — re-hydrating"
        rm -f "$SENTINEL"
    fi
fi

# ---------- Step 1: detect public IP ----------
log "[1/7] detecting public IP"
PUBLIC_IP=""
for ip_url in "https://ifconfig.me" "https://api.ipify.org"; do
    PUBLIC_IP=$(curl -fsSL --max-time 10 "$ip_url" 2>/dev/null || true)
    if [[ "$PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log "  public IP: $PUBLIC_IP (via $ip_url)"
        break
    fi
    PUBLIC_IP=""
done
[[ -n "$PUBLIC_IP" ]] || die "could not detect public IP (tried ifconfig.me and api.ipify.org)"

# Detect private/NAT IP (optional).
PRIVATE_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1 || true)
if [[ "${PRIVATE_IP:-}" == "$PUBLIC_IP" ]]; then
    PRIVATE_IP=""
fi
EXTERNAL_IP_LINE="${PUBLIC_IP}"
[[ -n "${PRIVATE_IP:-}" ]] && EXTERNAL_IP_LINE="${PUBLIC_IP}/${PRIVATE_IP}"

# ---------- Step 2: register with backend ----------
log "[2/7] registering with $BACKEND_URL/api/partner/register"

# Compose optional --cacert flag.
cacert_flag=()
[[ -n "${OXPULSE_BACKEND_CA:-}" ]] && cacert_flag=(--cacert "$OXPULSE_BACKEND_CA")

tmp_resp=$(mktemp)
trap 'rm -f "$tmp_resp"' EXIT

if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
    "${cacert_flag[@]}" \
    -X POST "$BACKEND_URL/api/partner/register" \
    -H 'Content-Type: application/json' \
    -d "{\"partner_id\":\"$PARTNER_ID\",\"domain\":\"$PARTNER_DOMAIN\",\"token\":\"$REGISTRATION_TOKEN\",\"public_ip\":\"$PUBLIC_IP\"}" \
    -o "$tmp_resp"; then
    die "registration POST failed — check $BACKEND_URL is reachable and token is valid"
fi

# ---------- Step 3: parse response ----------
log "[3/7] parsing registration response"

jq_get() { jq -r --arg k "$1" '.[$k] // empty' "$tmp_resp"; }

NODE_ID=$(jq_get node_id)
BACKEND_ENDPOINT=$(jq_get backend_endpoint)
TURN_SECRET=$(jq_get turn_secret)
TURNS_SUBDOMAIN=$(jq_get turns_subdomain)
REALITY_UUID=$(jq_get reality_uuid)
REALITY_PUBLIC_KEY=$(jq_get reality_public_key)
REALITY_SHORT_ID=$(jq_get reality_short_id)
REALITY_SERVER_NAME=$(jq_get reality_server_name)
REALITY_ENCRYPTION=$(jq_get reality_encryption)
RELAY_JWT_SECRET=$(jq_get relay_jwt_secret)
# If not provided by backend, generate a local secret.
# The same secret must be added to the operator's signaling server RELAY_JWT_SECRET
# env var and SFU_EDGES relay_api_url for cascade relay to work.
[[ -z "$RELAY_JWT_SECRET" ]] && RELAY_JWT_SECRET=$(openssl rand -hex 32)
# CH3/CH5 fallback channel vars — optional; empty if backend does not provision them.
HYSTERIA2_SERVER=$(jq_get hysteria2_server)
HYSTERIA2_PORT=$(jq_get hysteria2_port)
HYSTERIA2_AUTH=$(jq_get hysteria2_auth)
HYSTERIA2_OBFS=$(jq_get hysteria2_obfs)
NAIVE_SERVER=$(jq_get naive_server)
NAIVE_PORT=$(jq_get naive_port)
NAIVE_USER=$(jq_get naive_user)
NAIVE_PASS=$(jq_get naive_pass)

[[ -n "$NODE_ID" ]]             || die "node_id missing from registration response"
[[ -n "$BACKEND_ENDPOINT" ]]    || die "backend_endpoint missing from registration response"
[[ -n "$TURN_SECRET" ]]         || die "turn_secret missing from registration response"
[[ -n "$TURNS_SUBDOMAIN" ]]     || die "turns_subdomain missing from registration response"
[[ -n "$REALITY_UUID" ]]        || die "reality_uuid missing from registration response"
[[ -n "$REALITY_PUBLIC_KEY" ]]  || die "reality_public_key missing from registration response"
[[ -n "$REALITY_SHORT_ID" ]]    || die "reality_short_id missing from registration response"
[[ -z "$REALITY_SERVER_NAME" ]] && REALITY_SERVER_NAME="${OXPULSE_REALITY_SERVER_NAME:-www.samsung.com}"
# Empty encryption means legacy (non-PQ) tunnel — xray requires literal "none".
[[ -z "$REALITY_ENCRYPTION" ]] && REALITY_ENCRYPTION="none"

# Split backend_endpoint "host:port".
BACKEND_HOST="${BACKEND_ENDPOINT%:*}"
BACKEND_PORT="${BACKEND_ENDPOINT##*:}"
[[ "$BACKEND_HOST" == "$BACKEND_PORT" || -z "$BACKEND_PORT" ]] && \
    die "backend_endpoint must be host:port (got '$BACKEND_ENDPOINT')"

log "  node_id=$NODE_ID turns_subdomain=$TURNS_SUBDOMAIN reality_short_id=$REALITY_SHORT_ID"
log "  secrets fetched (turn_secret len=${#TURN_SECRET}, reality_uuid len=${#REALITY_UUID})"

# Wipe raw response — no longer needed, don't leave secrets on disk.
rm -f "$tmp_resp"

# ---------- Load render library ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_chan_lib_local="${SCRIPT_DIR}/channel-render-lib.sh"
_chan_lib_installed="${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh"
if [[ -f "$_chan_lib_local" ]]; then
    # shellcheck source=channel-render-lib.sh
    source "$_chan_lib_local"
elif [[ -f "$_chan_lib_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_chan_lib_installed"
else
    die "channel-render-lib.sh not found (looked at $_chan_lib_local and $_chan_lib_installed)"
fi
unset _chan_lib_local _chan_lib_installed

# ---------- Step 4: render templates ----------
log "[4/7] rendering config templates"

TPL_DIR="$SCRIPT_DIR"
[[ -d "$TPL_DIR" ]] || TPL_DIR="/usr/local/share/oxpulse-partner-edge"

tpl_file() {
    local name=$1
    local f="$TPL_DIR/$name"
    [[ -f "$f" ]] || die "template not found: $f"
    echo "$f"
}

# render_template (channel-render-lib.sh) calls python3 as a subprocess and
# reads template placeholders from ambient env. Every {{VAR}} placeholder in
# the .tpl files must therefore be exported. Hardcoded socks ports are set
# here to match the legacy sed render's inline defaults. Vars not provisioned
# by the backend response (SFU_*, OTEL_*, SIGNALING_*, HY2_*) are exported
# empty so placeholders become "" rather than the literal "{{VAR}}" string
# that the old sed render silently left behind.
# HYSTERIA2_SOCKS_PORT removed (T3 NIT): no {{HYSTERIA2_SOCKS_PORT}} placeholder
# in any .tpl file — dead export with no effect on rendered output.
NAIVE_SOCKS_PORT="${NAIVE_SOCKS_PORT:-18892}"
export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
       TURN_SECRET \
       REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
       REALITY_ENCRYPTION TURNS_SUBDOMAIN \
       PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE \
       IMAGE_VERSION \
       RELAY_JWT_SECRET \
       HYSTERIA2_SERVER HYSTERIA2_PORT HYSTERIA2_AUTH HYSTERIA2_OBFS \
       NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS NAIVE_SOCKS_PORT \
       SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID OTEL_EXPORTER_OTLP_ENDPOINT \
       SFU_SIGNING_PUBLIC_KEY SIGNALING_SFU_SECRET \
       HY2_SERVER HY2_AUTH_PASS HY2_OBFS_PASS HY2_LOCAL_LISTEN HY2_REMOTE_BACKEND

render_template "$(tpl_file docker-compose.yml.tpl)" "$PREFIX_ETC/docker-compose.yml"
render_template "$(tpl_file Caddyfile.tpl)"          "$PREFIX_ETC/Caddyfile"
render_template "$(tpl_file xray-client.json.tpl)"   "$PREFIX_ETC/xray-client.json"
render_template "$(tpl_file coturn.conf.tpl)"        "$PREFIX_ETC/coturn.conf"
# Render CH3 / CH5 if the backend provided the required vars.
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
    render_template "$(tpl_file hysteria2-client.yaml.tpl)" "$PREFIX_ETC/hysteria2-client.yaml"
    log "  hysteria2-client.yaml rendered"
fi
if [[ -n "${NAIVE_SERVER:-}" ]]; then
    render_template "$(tpl_file naive-client.json.tpl)" "$PREFIX_ETC/naive-client.json"
    log "  naive-client.json rendered"
fi

# Static assets — Caddy DPI-probe cover served from ./cover bind-mount.
# Missing file = silent 404 on partner root URL (regression fix 2026-04-20).
mkdir -p "$PREFIX_ETC/cover"
install -m 0644 "$(tpl_file cover/cover.html)" "$PREFIX_ETC/cover/cover.html"

log "  templates rendered to $PREFIX_ETC"

# ---------- Step 5: DNS verify ----------
log "[5/7] verifying DNS: $TURNS_SUBDOMAIN.$PARTNER_DOMAIN → $PUBLIC_IP"
TURNS_FQDN="${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN}"
dns_ip=$(dig +short "$TURNS_FQDN" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
if [[ "$dns_ip" != "$PUBLIC_IP" ]]; then
    die "DNS mismatch: $TURNS_FQDN resolves to '${dns_ip:-<nothing>}' but public IP is $PUBLIC_IP — update your DNS and retry"
fi
log "  DNS OK: $TURNS_FQDN → $PUBLIC_IP"

# ---------- Step 6: start containers ----------
log "[6/7] starting containers"
docker compose -f "$PREFIX_ETC/docker-compose.yml" up -d
log "  containers started"

# ---------- Step 6b: wait for Caddy ACME cert ----------
log "  waiting for Caddy TLS cert (up to 120s)"
CERT_PATH="/var/lib/oxpulse-partner-edge/caddy-data/certificates/acme-v02.api.letsencrypt.org-directory/${TURNS_FQDN}/${TURNS_FQDN}.crt"
waited=0
until [[ -f "$CERT_PATH" ]]; do
    if [[ $waited -ge 120 ]]; then
        die "ERROR: Caddy did not obtain TLS cert within 120s — check logs: docker compose -f $PREFIX_ETC/docker-compose.yml logs caddy"
    fi
    if ! docker compose -f "$PREFIX_ETC/docker-compose.yml" ps --status running caddy 2>/dev/null | grep -q caddy; then
        die "Caddy container is not running. Check: docker compose -f $PREFIX_ETC/docker-compose.yml logs caddy"
    fi
    sleep 5
    waited=$((waited + 5))
done
log "  TLS cert obtained after ${waited}s"

# ---------- Step 7: enable systemd units ----------
log "[7/7] enabling systemd units"
systemctl enable --now oxpulse-partner-cert-watch.path \
    || die "Failed to enable oxpulse-partner-cert-watch.path"
systemctl enable --now oxpulse-partner-edge.service \
    || die "Failed to enable oxpulse-partner-edge.service"

# ---------- Write sentinel ----------
hydrated_at=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
cat > "$SENTINEL" <<JSON
{
  "hydrated_at": "$hydrated_at",
  "node_id": "$NODE_ID",
  "domain": "$PARTNER_DOMAIN",
  "turns_subdomain": "$TURNS_SUBDOMAIN",
  "public_ip": "$PUBLIC_IP",
  "config_sha256": "$config_sha256"
}
JSON
chmod 0600 "$SENTINEL"

log "hydration complete — sentinel written to $SENTINEL"
log "  node_id=$NODE_ID domain=$PARTNER_DOMAIN turns_subdomain=$TURNS_SUBDOMAIN public_ip=$PUBLIC_IP"
