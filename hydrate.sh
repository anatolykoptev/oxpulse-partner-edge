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
#
# Phase 5.5 MAJOR 1 (PR feat/phase5-6-...): render_channel_soft + CHANNELS_FAILED
# + compose_strip_failed_channels are now wired — channel render failures are
# non-fatal; failed channels are stripped from compose before docker compose up.
set -euo pipefail

# ---------- Constants ----------
PREFIX_ETC=/etc/oxpulse-partner-edge
PREFIX_LIB=/var/lib/oxpulse-partner-edge
HYDRATE_ENV="$PREFIX_ETC/hydrate.env"
SENTINEL="$PREFIX_LIB/hydrated"
# install.env is the canonical STATE_FILE for reconcile.sh's tier-2 resolution
# of PUBLIC_IP/PRIVATE_IP. It may be overridden in tests.
STATE_FILE="${STATE_FILE:-$PREFIX_LIB/install.env}"
BACKEND_URL="${OXPULSE_BACKEND_URL:-https://oxpulse.chat}"
# Resolve IMAGE_VERSION with strict precedence:
#   1. $OXPULSE_IMAGE_VERSION env (operator override via hydrate.env)
#   2. VERSION file shipped alongside this script (release artifact pins it)
#   3. die — hydrate is automated, no operator at the keyboard to recover,
#      and defaulting to a floating "latest" tag means clones drift away
#      from the pinned fleet within a single GHCR push. Audit 2026-05-22 F2.
SCRIPT_DIR_VERSION="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_VERSION="${OXPULSE_IMAGE_VERSION:-}"
if [[ -z "$IMAGE_VERSION" ]]; then
    _version_file="${SCRIPT_DIR_VERSION}/VERSION"
    if [[ -r "$_version_file" ]]; then
        # VERSION file format: "0.12.52  # x-release-please-version"
        IMAGE_VERSION=$(awk '{print $1; exit}' "$_version_file")
    fi
fi
[[ -n "$IMAGE_VERSION" ]] || die "IMAGE_VERSION unresolved: set OXPULSE_IMAGE_VERSION in hydrate.env or ship VERSION file alongside hydrate.sh"

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

# Detect private/NAT IP (optional). EXTERNAL_IP_LINE / ALLOWED_PEER_IP_LINE
# (coturn's external-ip, the OCI-hairpin allowed-peer-ip) are derived from
# this further down in resolve_external_ip (step 3c) — deferred until after
# registration because tier 2 of that resolution needs TURNS_SUBDOMAIN,
# which the backend only assigns in its response (step 3). The PUBLIC_IP
# detected just above is the host's OUTBOUND egress IP; it is used as-is for
# the registration POST body below (informational to the backend) but is
# NOT necessarily the right value for coturn/SFU inbound reachability — see
# resolve_external_ip's docstring.
PRIVATE_IP=$(ip route get 1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="src") print $(i+1)}' | head -1 || true)

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
    -H "X-Installer-Version: ${IMAGE_VERSION}" \
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
# T3b: central-authoritative public IP. The central's POST /api/partner/register
# resolves the edge's authoritative inbound IP server-side (it sees the edge's
# connection from outside the NAT, with no NAT-gateway hairpin confusion) and
# returns it here. Absent/empty on older/other centrals or when unresolvable →
# graceful degrade (behavior unchanged, falls through to DNS/egress tiers in
# resolve_external_ip). Consumed as a precedence tier there — MORE authoritative
# than the edge's own DNS-derive/egress, LESS than the operator's
# OXPULSE_PUBLIC_IP override.
REGISTER_PUBLIC_IP=$(jq_get public_ip)
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
# NOTE: hysteria2_auth / hysteria2_obfs are NOT returned by the backend's
# RegistrationOk (crates/server/src/partner_registry/types.rs has no such
# fields). The hy2 channel credentials (auth_pass / obfs_pass) are fleet-shared
# and come from GET /api/partner/hy2-credentials — fetched by
# hydrate_render_hy2 (lib/hydrate-hy2.sh) the same way install.sh does.
# HYSTERIA2_SERVER (the endpoint) IS returned and gates the hy2 render block.
HYSTERIA2_SERVER=$(jq_get hysteria2_server)
HYSTERIA2_PORT=$(jq_get hysteria2_port)
NAIVE_SERVER=$(jq_get naive_server)
NAIVE_PORT=$(jq_get naive_port)
NAIVE_USER=$(jq_get naive_user)
NAIVE_PASS=$(jq_get naive_pass)

# Service token — returned only on first registration (fresh hash). Persist
# atomically to $PREFIX_ETC/token so hydrate_render_hy2 can call
# GET /api/partner/hy2-credentials with it, and later scripts (refresh.sh,
# upgrade.sh) can re-fetch node-config. Mirrors install.sh:966-980.
# On reseed (idempotent re-register) the field is omitted — preserve the
# existing token file (COALESCE-PRESERVE, same invariant as cross-probe-token).
SERVICE_TOKEN=$(jq_get service_token)
SVC_TOKEN_FILE="$PREFIX_ETC/token"
if [[ -n "$SERVICE_TOKEN" ]]; then
    if [[ ! -e "$SVC_TOKEN_FILE" ]]; then
        _tok_tmp=$(mktemp "$SVC_TOKEN_FILE.XXXXXX")
        printf '%s' "$SERVICE_TOKEN" > "$_tok_tmp"
        chmod 0600 "$_tok_tmp"
        mv -f "$_tok_tmp" "$SVC_TOKEN_FILE"
        unset _tok_tmp
        log "  service token persisted → $SVC_TOKEN_FILE (raw value redacted)"
    else
        warn "  service token returned by server but local file already exists; preserved local copy"
    fi
else
    if [[ ! -e "$SVC_TOKEN_FILE" && -z "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
        warn "  no service_token in registration response and no local token file — hy2-credentials fetch will fail; set OXPULSE_SERVICE_TOKEN in hydrate.env as a fallback"
    fi
fi
unset SERVICE_TOKEN

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

# ---------- Step 3b: cross-probe mesh fields (P3b producer) ----------
# The central (P3a) may return a server-curated peer_roster[] + a scoped
# cross_probe_token (xprb_) so this edge can probe its peers' TURNS:443 relays
# and report a prober-attributed channel-health verdict. Both fields are
# OPTIONAL — a pre-P3a central omits them; the edge then simply never runs the
# peer-probe loop (fail-closed, see oxpulse-channels-health-report.sh). We
# persist them here so the 60s health-report timer can pick them up.
#
# Roster is NOT a secret (public TURNS endpoints) → 0644.
# cross_probe_token IS a credential (bearer for the prober-report POST) → 0600,
# mirroring the service-token file perms; atomic mktemp+rename.
#
# PRESERVE-ON-ABSENT INVARIANT (MAJOR 2): the central (P2 register.rs) mints a
# cross_probe_token on EVERY POST /api/partner/register WHEN peer_roster is
# non-empty AND CROSS_PROBE_TOKEN_SECRET is set on the central; otherwise it
# returns None and OMITS the field — graceful-degrade, NOT a revocation signal.
# So a register that TRANSIENTLY returns an empty roster (all peers momentarily
# unhealthy) returns no token. We MUST NOT rm an existing valid token on that
# transient: doing so would silently kill peer-probing until the next register
# that happens to carry a token. We therefore COALESCE-PRESERVE — keep the
# existing token when the response omits it — exactly mirroring install.sh's
# `[[ ! -e ... ]]` precedent. Revocation does NOT rely on rm: a rotated
# CROSS_PROBE_TOKEN_SECRET invalidates the old token server-side, so a stale
# token simply 4xx's on the prober-report POST and is then ignored (the loop
# logs PEER_PROBE_POST_4XX). This same invariant is documented at install.sh's
# cross-probe write site.
PEER_ROSTER=$(jq -c '.peer_roster // []' "$tmp_resp" 2>/dev/null || echo '[]')
CROSS_PROBE_TOKEN=$(jq_get cross_probe_token)

PEER_ROSTER_FILE="$PREFIX_LIB/peer-roster.json"
_roster_tmp=$(mktemp "$PEER_ROSTER_FILE.XXXXXX")
printf '%s\n' "$PEER_ROSTER" > "$_roster_tmp"
chmod 0644 "$_roster_tmp"
mv -f "$_roster_tmp" "$PEER_ROSTER_FILE"
unset _roster_tmp
_roster_count=$(printf '%s' "$PEER_ROSTER" | jq 'length' 2>/dev/null || echo 0)
log "  peer roster persisted → $PEER_ROSTER_FILE ($_roster_count peer(s))"

CROSS_PROBE_TOKEN_FILE="$PREFIX_ETC/cross-probe-token"
if [[ -n "$CROSS_PROBE_TOKEN" ]]; then
    _xprb_tmp=$(mktemp "$CROSS_PROBE_TOKEN_FILE.XXXXXX")
    printf '%s' "$CROSS_PROBE_TOKEN" > "$_xprb_tmp"
    chmod 0600 "$_xprb_tmp"
    mv -f "$_xprb_tmp" "$CROSS_PROBE_TOKEN_FILE"
    unset _xprb_tmp
    log "  cross-probe token persisted → $CROSS_PROBE_TOKEN_FILE (raw value redacted)"
elif [[ -e "$CROSS_PROBE_TOKEN_FILE" ]]; then
    # Response OMITS the token but a valid one already exists — COALESCE-PRESERVE.
    # This is the transient-empty-roster case (or a pre-P3a central that never
    # ships tokens but a prior register did). Do NOT wipe a working credential;
    # revocation is server-side via CROSS_PROBE_TOKEN_SECRET rotation (→ 4xx).
    log "  no cross-probe token in response — preserved existing $CROSS_PROBE_TOKEN_FILE (transient empty roster does not wipe a valid token)"
else
    # No token in the response AND none on disk → nothing to do; the peer-probe
    # loop stays disabled (fail-closed; empty roster also disables it).
    log "  no cross-probe token in response and none on disk — peer-probe loop stays disabled"
fi
unset PEER_ROSTER CROSS_PROBE_TOKEN

# Wipe raw response — no longer needed, don't leave secrets on disk.
rm -f "$tmp_resp"

# ---------------------------------------------------------------------------
# _persist_state_ip KEY VALUE
#
# Write KEY=VALUE to $STATE_FILE, replacing an existing line or appending if
# absent. Keeps exactly one line per key so repeated hydrate runs stay idempotent
# and reconcile.sh's tier-2 resolution reads the authoritative value.
# ---------------------------------------------------------------------------
_persist_state_ip() {
    local _key="$1" _value="$2" _file="$STATE_FILE"
    mkdir -p "$(dirname "$_file")"
    if [[ -f "$_file" ]] && grep -qE "^${_key}=" "$_file" 2>/dev/null; then
        sed -i "s|^${_key}=.*|${_key}=${_value}|" "$_file"
    else
        printf '%s=%s\n' "$_key" "$_value" >> "$_file"
    fi
    # New state files start locked down; keep perms on existing ones.
    if [[ -f "$_file" ]]; then
        chmod 0600 "$_file"
    fi
}

# ---------- Step 3c: resolve authoritative external IP ----------
# resolve_external_ip EGRESS_IP TURNS_SUBDOMAIN PARTNER_DOMAIN — resolve the
# AUTHORITATIVE external/public IP and (re)derive the coturn/SFU-facing
# EXTERNAL_IP_LINE + ALLOWED_PEER_IP_LINE from it. Mutates globals PUBLIC_IP,
# PUBLIC_IP_SOURCE, PRIVATE_IP, EXTERNAL_IP_LINE, ALLOWED_PEER_IP_LINE
# (PRIVATE_IP must already be set — empty string if there is none).
#
# The resolved PUBLIC_IP is the SINGLE source of truth for BOTH coturn's
# external-ip (EXTERNAL_IP_LINE) AND the SFU's SFU_PUBLIC_IP — the latter is
# rendered into docker-compose.yml from the {{PUBLIC_IP}} placeholder, so the
# two can never diverge. On a multi-homed edge a stale egress-only IP here
# breaks BOTH relay (coturn) and host-candidate (SFU) media paths at once.
#
# EGRESS_IP is the step-1 curl-detected outbound IP (tier 3 fallback,
# unchanged). On a multi-homed host (e.g. an Oracle Cloud instance whose
# NAT-gateway EGRESS IP differs from its reserved INBOUND public IP) that
# value is outbound-only and has no inbound path — using it verbatim as
# coturn's external-ip / the SFU's SFU_PUBLIC_IP makes every WebRTC relay
# candidate unreachable, so ICE connectivity checks stall (~6s) and calls
# never connect. Live incident 2026-07-17: egress=132.145.192.254 (no
# inbound path) vs. the real reachable IP 129.159.103.86 (the TURNS DNS
# A-record); relay RTT dropped 6000ms→67ms once external-ip was corrected.
#
# Precedence, most-authoritative first:
#   1. OXPULSE_PUBLIC_IP env override — operator escape hatch, always wins.
#   2. REGISTER_PUBLIC_IP (T3b) — the central's server-side-resolved public_ip
#      from the register response. The central sees the edge's connection from
#      outside the NAT (no hairpin confusion), so this is MORE authoritative
#      than the edge's own DNS-derive/egress, but LESS than the operator's
#      explicit override. Absent/empty on older/other centrals → graceful
#      degrade to tiers 3/4. Motherly-self guard applies (defense-in-depth:
#      never advertise the hub as the edge's own IP even if the central
#      mistakenly returned it).
#   3. DNS A-record of TURNS_SUBDOMAIN.PARTNER_DOMAIN — this is exactly the
#      address partner-edge CLIENTS connect to for TURNS:443, so it IS the
#      reachable inbound IP by construction. Only resolvable here (after
#      step 3) because TURNS_SUBDOMAIN is backend-assigned at registration.
#      Requires 'dig' or 'getent' — neither is a hard dependency of
#      hydrate.sh (unlike upgrade.sh), so this tier degrades gracefully to
#      tier 4 when both are absent, or when the record does not exist yet.
#   4. EGRESS_IP (step-1 autodetect, unchanged fallback).
#
# Motherly/central IP guard (T2): an edge must NEVER advertise the central
# backend's IP as its own public IP. Live bug: the RU edge's egress route
# traversed the AWG mesh tunnel to motherly, so curl ifconfig.me returned the
# central IP (192.9.243.148) — rendering that as coturn external-ip /
# SFU_PUBLIC_IP points clients at the hub, not the edge. The motherly IP is
# derived from OXPULSE_MOTHERLY_IP env (operator escape hatch) or by resolving
# BACKEND_URL's host A-record (best-effort; empty when unresolvable → guard
# is a no-op). Any tier that would yield the motherly IP is REJECTED and the
# resolver falls through to the next tier with a loud warning; if ALL tiers
# yield the motherly IP (or are empty) the resolver dies rather than ship the
# central IP as the edge's own. The guard applies to BOTH coturn external-ip
# and SFU_PUBLIC_IP because they share PUBLIC_IP.
resolve_external_ip() {
    local egress_ip="$1" turns_subdomain="$2" partner_domain="$3"
    local dns_ip="" motherly_ip=""

    # Reset the global so the precedence tiers run. hydrate.sh's caller sets
    # PUBLIC_IP to the egress autodetect before this function; the egress value
    # is still available via $egress_ip for the tier-3 fallback.
    PUBLIC_IP=""

    # --- motherly/central IP derivation (T2) ---
    if [[ -n "${OXPULSE_MOTHERLY_IP:-}" ]]; then
        motherly_ip="$OXPULSE_MOTHERLY_IP"
    elif [[ -n "${BACKEND_URL:-}" ]]; then
        local _be_host="${BACKEND_URL#*://}"
        _be_host="${_be_host%%/*}"
        _be_host="${_be_host%%:*}"
        if [[ -n "$_be_host" ]]; then
            if command -v dig >/dev/null 2>&1; then
                motherly_ip=$(dig +short +time=3 +tries=1 "$_be_host" A 2>/dev/null \
                    | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
            fi
            if [[ -z "$motherly_ip" ]] && command -v getent >/dev/null 2>&1; then
                motherly_ip=$(getent ahostsv4 "$_be_host" 2>/dev/null \
                    | awk '{print $1; exit}' || true)
            fi
        fi
    fi

    # --- tier 1: OXPULSE_PUBLIC_IP override (rejected if == motherly) ---
    if [[ -z "${PUBLIC_IP:-}" && -n "${OXPULSE_PUBLIC_IP:-}" ]]; then
        if [[ -n "$motherly_ip" && "$OXPULSE_PUBLIC_IP" == "$motherly_ip" ]]; then
            warn "  OXPULSE_PUBLIC_IP override ($OXPULSE_PUBLIC_IP) equals the motherly/central IP ($motherly_ip) — rejecting and falling through to DNS/autodetect (an edge must NOT advertise the central IP as its own public IP)"
        elif [[ ! "$OXPULSE_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "  OXPULSE_PUBLIC_IP override ($OXPULSE_PUBLIC_IP) is not a bare IPv4 address — rejecting and falling through to DNS/autodetect (only a validated IPv4 may be rendered into coturn external-ip + SFU_PUBLIC_IP)"
        else
            PUBLIC_IP="$OXPULSE_PUBLIC_IP"
            PUBLIC_IP_SOURCE="override (OXPULSE_PUBLIC_IP)"
        fi
    fi

    # --- tier 2: REGISTER_PUBLIC_IP (central-authoritative, T3b) ---
    # The central's register response carries a server-side-resolved public_ip
    # that is more authoritative than the edge's own DNS-derive/egress (the
    # central sees the edge from outside the NAT). Motherly-self guard still
    # applies: a central that mistakenly returns the hub IP is rejected and
    # we fall through to DNS/egress.
    if [[ -z "${PUBLIC_IP:-}" && -n "${REGISTER_PUBLIC_IP:-}" ]]; then
        if [[ -n "$motherly_ip" && "$REGISTER_PUBLIC_IP" == "$motherly_ip" ]]; then
            warn "  REGISTER_PUBLIC_IP ($REGISTER_PUBLIC_IP) equals the motherly/central IP ($motherly_ip) — rejecting and falling through to DNS/autodetect (the central must not return its own IP as the edge's public IP)"
        elif [[ ! "$REGISTER_PUBLIC_IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            warn "  REGISTER_PUBLIC_IP ($REGISTER_PUBLIC_IP) is not a bare IPv4 address — rejecting and falling through to DNS/autodetect (guards a malformed/null/IPv6 central value out of coturn external-ip + SFU_PUBLIC_IP; the DNS tier below self-heals)"
        else
            PUBLIC_IP="$REGISTER_PUBLIC_IP"
            PUBLIC_IP_SOURCE="register (central-authoritative public_ip)"
        fi
    fi

    # --- tier 3: TURNS DNS A-record (rejected if == motherly) ---
    if [[ -z "${PUBLIC_IP:-}" && -n "$turns_subdomain" && -n "$partner_domain" ]]; then
        if command -v dig >/dev/null 2>&1; then
            dns_ip=$(dig +short +time=3 +tries=1 "${turns_subdomain}.${partner_domain}" A 2>/dev/null \
                | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -1 || true)
        fi
        if [[ -z "$dns_ip" ]] && command -v getent >/dev/null 2>&1; then
            dns_ip=$(getent ahostsv4 "${turns_subdomain}.${partner_domain}" 2>/dev/null \
                | awk '{print $1; exit}' || true)
        fi
        if [[ -n "$dns_ip" ]]; then
            if [[ -n "$motherly_ip" && "$dns_ip" == "$motherly_ip" ]]; then
                warn "  TURNS DNS A-record ($dns_ip) equals the motherly/central IP ($motherly_ip) — rejecting and falling through to egress autodetect (DNS misconfig: the edge TURNS subdomain must NOT point at the central hub)"
            else
                PUBLIC_IP="$dns_ip"
                PUBLIC_IP_SOURCE="dns (A-record for ${turns_subdomain}.${partner_domain})"
            fi
        fi
    fi

    # --- tier 4: egress autodetect fallback (rejected if == motherly) ---
    if [[ -z "${PUBLIC_IP:-}" ]]; then
        if [[ -n "$motherly_ip" && "$egress_ip" == "$motherly_ip" ]]; then
            die "egress autodetect IP ($egress_ip) equals the motherly/central IP ($motherly_ip) — refusing to advertise the central hub as this edge's public IP. Fix: set OXPULSE_PUBLIC_IP to the edge's real inbound IP, or correct DNS/routing so the edge's egress does not traverse the central tunnel."
        fi
        PUBLIC_IP="$egress_ip"
        PUBLIC_IP_SOURCE="autodetect (ifconfig.me/api.ipify.org egress IP)"
    fi

    [[ -n "${PUBLIC_IP:-}" ]] || die "could not resolve a non-motherly public IP (override/DNS/egress all rejected or empty)"
    log "  external IP: $PUBLIC_IP (source: $PUBLIC_IP_SOURCE)"

    # Recompute the coturn/SFU-facing derived lines now that PUBLIC_IP may
    # have changed (same OCI-hairpin logic as the original step-1 site,
    # moved here so it runs against the final, authoritative PUBLIC_IP
    # rather than the raw egress IP). See coturn.conf.tpl / docker-compose.yml.tpl.
    if [[ "${PRIVATE_IP:-}" == "$PUBLIC_IP" ]]; then
        PRIVATE_IP=""
    fi
    EXTERNAL_IP_LINE="${PUBLIC_IP}"
    [[ -n "${PRIVATE_IP:-}" ]] && EXTERNAL_IP_LINE="${PUBLIC_IP}/${PRIVATE_IP}"
    ALLOWED_PEER_IP_LINE=""
    [[ -n "${PRIVATE_IP:-}" ]] && ALLOWED_PEER_IP_LINE="allowed-peer-ip=${PRIVATE_IP}"
}

log "[3c/7] resolving authoritative external IP"
resolve_external_ip "$PUBLIC_IP" "$TURNS_SUBDOMAIN" "$PARTNER_DOMAIN"

# Persist the resolved authoritative PUBLIC_IP/PRIVATE_IP to STATE_FILE so
# reconcile.sh's tier-2 resolution reads the DNS-authoritative IP, not the raw
# egress IP that install.sh originally persisted. This closes the
# converge-revert path that would otherwise re-render coturn external-ip /
# SFU_PUBLIC_IP back to the unreachable egress IP.
_persist_state_ip "PUBLIC_IP" "$PUBLIC_IP"
_persist_state_ip "PRIVATE_IP" "$PRIVATE_IP"

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

# Phase 5.5 MAJOR 1: load fail-soft render helpers (render_channel_soft,
# _in_array, CHANNELS_FAILED, compose_strip_failed_channels).
_rl_local="${SCRIPT_DIR}/lib/render-channel-lib.sh"
_rl_sbin="${PREFIX_SBIN:-/usr/local/sbin}/render-channel-lib.sh"
if [[ -f "$_rl_local" ]]; then
    # shellcheck source=lib/render-channel-lib.sh
    source "$_rl_local"
elif [[ -f "$_rl_sbin" ]]; then
    # shellcheck source=/dev/null
    source "$_rl_sbin"
else
    warn "render-channel-lib.sh not found — channel render failures will be fatal"
    # Stub: make render_channel_soft fall through to render_template (best-effort)
    render_channel_soft() { render_template "$2" "$3"; }
    CHANNELS_FAILED=()
fi
unset _rl_local _rl_sbin

# Source oxpulse-token-lib.sh for read_service_token (used by hydrate_render_hy2
# to call GET /api/partner/hy2-credentials with the persisted service token).
_tok_lib_local="${SCRIPT_DIR}/oxpulse-token-lib.sh"
_tok_lib_installed="${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-token-lib.sh"
if [[ -f "$_tok_lib_local" ]]; then
    # shellcheck source=oxpulse-token-lib.sh
    source "$_tok_lib_local"
elif [[ -f "$_tok_lib_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_tok_lib_installed"
fi
unset _tok_lib_local _tok_lib_installed

# Source lib/hydrate-hy2.sh (hydrate_render_hy2 — the hy2 channel render path
# extracted from the inline block for behavioural testability).
_hy2_lib_local="${SCRIPT_DIR}/lib/hydrate-hy2.sh"
_hy2_lib_installed="${PREFIX_SBIN:-/usr/local/sbin}/hydrate-hy2.sh"
if [[ -f "$_hy2_lib_local" ]]; then
    # shellcheck source=lib/hydrate-hy2.sh
    source "$_hy2_lib_local"
elif [[ -f "$_hy2_lib_installed" ]]; then
    # shellcheck source=/dev/null
    source "$_hy2_lib_installed"
else
    warn "lib/hydrate-hy2.sh not found — hy2 channel render will be skipped"
    hydrate_render_hy2() { return 0; }
fi
unset _hy2_lib_local _hy2_lib_installed

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
       PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE ALLOWED_PEER_IP_LINE \
       IMAGE_VERSION \
       RELAY_JWT_SECRET \
       HYSTERIA2_SERVER HYSTERIA2_PORT \
       NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS NAIVE_SOCKS_PORT \
       SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID OTEL_EXPORTER_OTLP_ENDPOINT \
       SFU_SIGNING_PUBLIC_KEY SIGNALING_SFU_SECRET \
       HY2_SERVER HY2_AUTH_PASS HY2_OBFS_PASS HY2_LOCAL_LISTEN HY2_REMOTE_BACKEND

# Chassis renders — strict (must succeed or hydrate aborts).
render_template "$(tpl_file docker-compose.yml.tpl)" "$PREFIX_ETC/docker-compose.yml"
render_template "$(tpl_file Caddyfile.tpl)"          "$PREFIX_ETC/Caddyfile"
render_template "$(tpl_file coturn.conf.tpl)"        "$PREFIX_ETC/coturn.conf"

# Phase 5.5 MAJOR 1: bypass channel renders use render_channel_soft (fail-soft).
# xray is always attempted; CH3/CH5 only when provisioned by backend.
render_channel_soft xray "$(tpl_file xray-client.json.tpl)" "$PREFIX_ETC/xray-client.json" \
    || warn "  xray render failed — continuing without xray channel"
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
    # hydrate_render_hy2 (lib/hydrate-hy2.sh) fetches fleet-shared hy2 credentials
    # from GET /api/partner/hy2-credentials — the same authenticated endpoint
    # install.sh uses — then calls re_render_hysteria2 (the dedicated hy2 renderer
    # shared with install.sh and enable-hy2). On failure it appends the compose
    # service name to CHANNELS_FAILED so compose_strip_failed_channels removes
    # the service block (closing the compose-strip gap where a failed render
    # left a bind mount pointing at a non-existent file).
    #
    # The register response does NOT carry hy2 credentials (hysteria2_auth /
    # hysteria2_obfs are never returned by the backend); only HYSTERIA2_SERVER
    # (the endpoint) gates this block. The prior inline block called
    # re_render_hysteria2 without setting HY2_AUTH_PASS / HY2_OBFS_PASS, so the
    # render always failed and no file was written — operationally worse than
    # the old render_template path it replaced.
    hydrate_render_hy2
fi
if [[ -n "${NAIVE_SERVER:-}" ]]; then
    render_channel_soft naive "$(tpl_file naive-client.json.tpl)" "$PREFIX_ETC/naive-client.json" \
        || warn "  naive render failed — continuing without naive channel"
fi

# Strip failed channel service blocks from compose so docker compose up
# does not fail on missing volume mounts (Phase 5.5 MAJOR 1).
if [[ ${#CHANNELS_FAILED[@]} -gt 0 && -f "$PREFIX_ETC/docker-compose.yml" ]]; then
    compose_strip_failed_channels "$PREFIX_ETC/docker-compose.yml" "${CHANNELS_FAILED[@]}"
fi
[[ ${#CHANNELS_FAILED[@]} -gt 0 ]] \
    && warn "  ${#CHANNELS_FAILED[@]} channel(s) failed render: ${CHANNELS_FAILED[*]} — node starting in degraded mode"

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
