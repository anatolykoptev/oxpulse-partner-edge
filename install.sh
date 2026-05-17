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
PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
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
die()  { while IFS= read -r _line; do printf '\033[31mERR\033[0m %s\n' "$_line" >&2; done <<< "$*"; exit 1; }

# Pre-scan args for --check before any guard (--check is a diagnostic-only mode
# that does not need partner-cli or docker).
_PRESCAN_CHECK=0
for _arg in "$@"; do [[ "$_arg" == "--check" ]] && _PRESCAN_CHECK=1 && break; done
unset _arg

# partner-cli is required for Reality x25519 keypair generation (M6 slice 2b).
# Ships as a prebuilt static binary in the oxpulse-partner-edge release assets.
if [[ $_PRESCAN_CHECK -eq 0 ]] && ! command -v partner-cli >/dev/null 2>&1; then
	_machine=$(uname -m)
	case "$_machine" in
		x86_64)  _cli_arch=amd64 ;;
		aarch64) _cli_arch=arm64 ;;
		*) die "partner-cli: unsupported architecture: $_machine (need x86_64 or aarch64)" ;;
	esac
	_cli_url="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-cli-${_cli_arch}"
	log "partner-cli not found -- downloading from release assets ($_cli_arch)"
	curl -fsSL --max-time 60 "$_cli_url" -o /usr/local/bin/partner-cli \
		|| die "failed to download partner-cli from $_cli_url\nInstall manually and re-run."
	chmod +x /usr/local/bin/partner-cli
	unset _machine _cli_arch _cli_url
fi

# opec is the typed render binary for all 5 stage templates (xray, coturn,
# naive, compose, caddy — Phase 3 OPEC render absorption). Without it,
# install.sh falls back to bash render_template — works but skips per-kind
# validation (JSON / realm / YAML / balanced-brace) that OPEC adds.
# Auto-fetch from release assets.
if [[ $_PRESCAN_CHECK -eq 0 ]] && ! command -v opec >/dev/null 2>&1; then
	_machine=$(uname -m)
	case "$_machine" in
		x86_64)  _opec_arch=amd64 ;;
		aarch64) _opec_arch=arm64 ;;
		*) warn "opec: unsupported architecture: $_machine — render falls back to bash render_template" ;;
	esac
	if [[ -n "${_opec_arch:-}" ]]; then
		_opec_url="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/opec-${_opec_arch}"
		log "opec not found -- downloading from release assets ($_opec_arch)"
		if curl -fsSL --max-time 60 "$_opec_url" -o /usr/local/bin/opec 2>/dev/null; then
			chmod +x /usr/local/bin/opec
		else
			warn "opec download failed from $_opec_url — render falls back to bash render_template"
			rm -f /usr/local/bin/opec
		fi
	fi
	unset _machine _opec_arch _opec_url
fi

# Best-effort install of `wg`/`wg-quick` for keygen and conf rendering. The
# AmneziaWG userspace binary (`amneziawg-go` + `awg`/`awg-quick`) is built
# from source in install_amneziawg() below; this helper only ensures the
# upstream wg-tools are present so we can `wg genkey | wg pubkey` before
# the awg-go build completes.
install_wg_tools_for_keygen() {
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y wireguard-tools >/dev/null 2>&1 || \
		  dnf install -y --enablerepo=epel wireguard-tools >/dev/null 2>&1 || \
		  warn "could not install wireguard-tools via dnf — falling back"
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get install -y -q wireguard-tools >/dev/null 2>&1 || \
		  warn "could not install wireguard-tools via apt"
	else
		warn "no supported package manager — wg keygen will fail"
	fi
}

# Build amneziawg-go (userspace daemon) + amneziawg-tools (awg / awg-quick)
# from the upstream Amnezia GitHub source. We don't ship pre-built binaries
# because the project has no canonical Linux x86_64 release artifact today
# (only Alpine + Ubuntu 22.04 zips and Windows). The build needs go + git +
# make + gcc — install_build_deps_for_awg() handles that. Idempotent: if
# /usr/local/bin/amneziawg-go exists with non-zero size, the build is skipped.
install_amneziawg() {
	if [[ -s /usr/local/bin/amneziawg-go && -x /usr/bin/awg-quick ]]; then
		log "  amneziawg already installed (skip)"
		return 0
	fi
	log "  building amneziawg from source (one-time)"
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y golang git make gcc >/dev/null 2>&1 || \
		  die "dnf install of go/git/make/gcc failed — install manually then re-run"
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get install -y -q golang git make gcc >/dev/null 2>&1 || \
		  die "apt-get install of go/git/make/gcc failed"
	else
		die "no supported package manager for the awg build toolchain"
	fi
	local build_root
	build_root=$(mktemp -d)
	(
		cd "$build_root" && \
		git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go.git && \
		git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git
	) || die "amneziawg git clone failed"
	(cd "$build_root/amneziawg-go" && make) >/dev/null 2>&1 || die "amneziawg-go build failed"
	install -m 0755 "$build_root/amneziawg-go/amneziawg-go" /usr/local/bin/amneziawg-go
	(cd "$build_root/amneziawg-tools/src" && make && make install) >/dev/null 2>&1 || \
	  die "amneziawg-tools build failed"
	rm -rf "$build_root"
}

# Render /etc/amnezia/amneziawg/awg0.conf from the register response and
# bring the interface up. Reads AWG_* vars set by the json_get block after
# registration, plus AWG_PRIV_PATH from earlier in install.sh.
configure_amneziawg() {
	local conf_path="/etc/amnezia/amneziawg/awg0.conf"
	install -d -m 0700 /etc/amnezia/amneziawg
	# ListenPort is intentionally a high random — outbound only, NAT-traversed
	# via PersistentKeepalive, no inbound peer dials this edge directly. We
	# pick a fresh port at install time so two edges on the same NAT don't
	# collide.
	local listen_port=$((43800 + RANDOM % 200))
	cat > "$conf_path" <<-AWGCONF
		[Interface]
		PrivateKey = $(cat "$AWG_PRIV_PATH")
		Address = ${AWG_ALLOCATED_IP}
		ListenPort = ${listen_port}
		Jc = ${AWG_JC}
		Jmin = ${AWG_JMIN}
		Jmax = ${AWG_JMAX}
		S1 = ${AWG_S1}
		S2 = ${AWG_S2}
		S4 = ${AWG_S4}
		H1 = ${AWG_H1}
		H2 = ${AWG_H2}
		H3 = ${AWG_H3}
		H4 = ${AWG_H4}
		Table = off
		MTU = 1300

		[Peer]
		PublicKey = ${AWG_MOTHERLY_PUBKEY}
		Endpoint = ${AWG_MOTHERLY_ENDPOINT}
		AllowedIPs = ${AWG_MOTHERLY_AWG_IP}/32
		PersistentKeepalive = 25
	AWGCONF
	chmod 0600 "$conf_path"
	systemctl daemon-reload
	systemctl enable --now awg-quick@awg0 >/dev/null 2>&1 || \
	  warn "awg-quick@awg0 enable failed — see 'systemctl status awg-quick@awg0'"
	# Sanity check: a successful handshake within 10s means the central
	# pre-added our peer and iptables let UDP through. Don't die() — the
	# rest of the install can still finish; operator can debug awg later.
	sleep 8
	if awg show awg0 2>/dev/null | grep -q "latest handshake"; then
		log "  awg0 handshake confirmed with motherly"
	else
		warn "awg0 handshake not seen yet — central may still be adding the peer"
	fi
}

# ---------- Args ----------
DOMAIN=""
PARTNER_ID=""
# Prefer env-passed token over CLI arg so secrets don't appear in
# /proc/<pid>/cmdline or shell history. Caller can also use --token-file=
# or pass `--token=-` to read from stdin (see arg parser below).
TOKEN="${OXPULSE_PARTNER_TOKEN:-}"
TOKEN_FILE=""
TUNNEL=vless
MANUAL_CONFIG=""
# Default to `stable` channel (manually promoted post-validation by
# .github/workflows/promote-stable.yml) rather than `latest` (mutable on
# every merge). stable still drifts on promotion, but only after a human
# pushed the channel forward — `latest` floats on every CI green and is
# how cheburator wound up running an unpinned partner-edge-sfu on prod.
# Operators can pin further via --image-version=v0.12.7.
IMAGE_VERSION="${OXPULSE_IMAGE_VERSION:-stable}"
# v0.2.0-rc1 placeholder: real per-clone value comes from /api/partner/register
# response rendered by hydrate.sh in Phase 6 (Task 5.2).
TURNS_SUBDOMAIN="${TURNS_SUBDOMAIN:-turns}"
# M2.1: SFU UDP media port + Prometheus metrics port. Overridable via env or
# interactive prompt so operators with port conflicts don't need to edit files.
SFU_UDP_PORT="${SFU_UDP_PORT:-7878}"
# Canonical Prom port per fleet convention (PROM_PORT = MCP_PORT + 1000 → 9317
# pairs with the SFU client_ws/relay base 8317). Older 0.12.x installs used
# 8878; new installs default to 9317 so prometheus.yml scrape config can
# treat all edges uniformly. Override via env when reinstalling on top of
# an older edge whose firewall / Oracle VCN was already provisioned for 8878.
SFU_METRICS_PORT="${SFU_METRICS_PORT:-9317}"
# Per-edge label for Prometheus const_label `edge_id` and Grafana dashboards.
# Default falls back from PARTNER_ID after CLI args parse — see derive block
# below the arg parser. Empty → SFU emits "local" which collides across edges
# in the central Prom view, so the post-parse derive ensures it is always set.
SFU_EDGE_ID="${SFU_EDGE_ID:-}"
# Region tag (e.g. `pl-waw`, `ru-msk`, `us-east`). Empty → auto-detect from
# public IP via ipinfo.io after Step 3. Honored over auto-detect when set.
REGION="${REGION:-}"
# Step 7 healthcheck loop deadline (seconds). ACME first-issuance can
# legitimately take 2–4 minutes when DNS is slow to propagate or the LE
# rate limiter throttles; 120 was too tight on call.cheburator.bot and
# left the operator staring at a `still red after 120s` warn.
HEALTHCHECK_TIMEOUT="${HEALTHCHECK_TIMEOUT:-300}"
# Optional path to a BrandingConfig JSON the operator wants to ship to
# the backend with this clone. The file is read literally and inlined
# into the /api/partner/register body as `branding`. Backend validates
# against branding::BrandingConfig and rejects malformed payloads with
# HTTP 400. Absent → backend stores NULL → resolver synthesizes an
# OxPulse default stub (display_name "OxPulse" + co_brand_partner=$PARTNER_ID).
BRANDING_CONFIG="${BRANDING_CONFIG:-}"
# Per-field branding shortcuts. When --branding-config is not used, the
# operator can supply individual brand attributes via these flags and
# install.sh assembles a minimal BrandingConfig payload on the fly.
# All are optional — unset fields fall back to backend defaults
# (display_name="OxPulse" + co_brand_partner=$PARTNER_ID).
BRAND_DISPLAY_NAME=""
BRAND_DESCRIPTION=""
BRAND_COLOR_PRIMARY=""
BRAND_COLOR_SECONDARY=""
BRAND_COLOR_ACCENT=""
BRAND_COLOR_ON_PRIMARY=""
BRAND_LOGO_LIGHT=""
BRAND_LOGO_DARK=""
BRAND_FAVICON=""
BRAND_OG_IMAGE=""
BRAND_CO_BRAND=""
BRAND_CANONICAL=""
BRAND_WORDMARK=""
# Hero title — single value applies to ru+en; per-locale flags override.
BRAND_HERO_TITLE=""
BRAND_HERO_TITLE_RU=""
BRAND_HERO_TITLE_EN=""
BRAND_HERO_TITLE_ZH=""
BRAND_HERO_TITLE_FA=""
# VPN affiliate CTA. --brand-cta-url + --brand-cta-text apply to ru+en;
# per-locale flags override (handy for partners with localized landings).
BRAND_CTA_URL=""
BRAND_CTA_TEXT=""
BRAND_CTA_URL_RU=""
BRAND_CTA_URL_EN=""
BRAND_CTA_URL_ZH=""
BRAND_CTA_URL_FA=""
BRAND_CTA_TEXT_RU=""
BRAND_CTA_TEXT_EN=""
BRAND_CTA_TEXT_ZH=""
BRAND_CTA_TEXT_FA=""
# Legal block — partner_entity / partner_country / partner_contact.
BRAND_LEGAL_ENTITY=""
BRAND_LEGAL_COUNTRY=""
BRAND_LEGAL_CONTACT=""
DRY_RUN=0
BAKE_MODE=0
CHECK_MODE=0
# Idempotency guard: when existing reality identity files are found, keygen is
# skipped and the existing UUID/keys are reused. Set to 1 via --force-keygen
# or --rotate-identity to override — this is the slice 3 contract for
# operator-initiated rotation. Requires explicit invocation; never auto-triggered.
FORCE_KEYGEN=0

usage() {
	sed -n '2,18p' "$0" >&2
	cat >&2 <<USAGE

Required:
  --domain=<fqdn>            Partner edge domain (must resolve to this host's public IP)
  --partner-id=<id>          Short partner identifier (e.g. rvpn, piter)

Registration (pick one):
  --token=<ptkn_...>         Fetch node config from $BACKEND_API/api/partner/register
                             (also accepts '-' to read from stdin; OXPULSE_PARTNER_TOKEN env supported)
  --token-file=<path>        Read token from a file (chmod 0600 recommended)
  --ghcr-token=<ghp_...>     GHCR PAT for pulling private partner-edge images.
                             Saved to /etc/oxpulse-partner-edge/ghcr.token (0600);
                             reused by upgrade.sh on every subsequent pull.
  --manual-config=<path>     Read node config from a local JSON file

Optional:
  --tunnel=vless|wg|https    Backend tunnel kind (default: vless)
  --image-version=<tag>      Pull a specific image tag (default: latest)
  --region=<tag>             Region tag (e.g. pl-waw, ru-msk). Auto-detected from public IP if omitted.
  --healthcheck-timeout=<s>  Step 7 wait deadline in seconds (default: 300, env: HEALTHCHECK_TIMEOUT)
  --branding-config=<path>   BrandingConfig JSON to ship with /api/partner/register (env: BRANDING_CONFIG).
                             Absent → backend synthesises an OxPulse default stub for the partner.

Brand shortcut flags (used when --branding-config is NOT set; install.sh
assembles a minimal BrandingConfig payload from whichever flags are set):
  --brand-display-name=<text>      Override display_name (default: OxPulse)
  --brand-description=<text>       <meta name=description> + OG description
  --brand-color-primary=<#hex>     CTA / accent UI colour
  --brand-color-secondary=<#hex>   Background / chrome colour
  --brand-color-accent=<#hex>      Tertiary highlight (optional)
  --brand-color-on-primary=<#hex>  Foreground on primary (optional)
  --brand-logo-light=<url>         Light-theme logo (absolute URL recommended)
  --brand-logo-dark=<url>          Dark-theme logo
  --brand-favicon=<url>            Favicon URL
  --brand-og-image=<url>           OG image (1200x630 PNG)
  --brand-co-brand=<name>          Co-brand label, e.g. "Cheburator"
  --brand-canonical=<url>          Canonical override (default https://oxpulse.chat/)
  --brand-wordmark=<url>           Partner wordmark image (rendered next to OxPulse logo)
  --brand-hero-title=<text>        Sets hero_title_ru + hero_title_en at once
  --brand-hero-title-{ru,en,zh,fa}=<text>   Per-locale override
  --brand-cta-url=<url>            Affiliate CTA URL (sets ru + en)
  --brand-cta-text=<text>          Affiliate CTA label (sets ru + en)
  --brand-cta-url-{ru,en,zh,fa}=<url>       Per-locale CTA URL
  --brand-cta-text-{ru,en,zh,fa}=<text>     Per-locale CTA label
  --brand-legal-entity=<text>      Legal entity name
  --brand-legal-country=<code>     ISO 3166 alpha-2 country code
  --brand-legal-contact=<email>    Legal contact email
  --check                    Re-render templates to /tmp, diff vs installed files. Exit 0=clean, 1=Caddyfile drift, 2=compose drift.
  --dry-run                  Render templates + print plan, skip docker/systemd
  --bake                     Bake phase: install packages + images + units, no secrets, no start. For snapshot workflows.
  --force-keygen             Force generation of a new Reality identity even if one exists.
  --rotate-identity          Alias for --force-keygen (slice 3 operator-rotation contract).
                             Both flags back up existing reality.{priv,pub,uuid} to .bak.<epoch>
                             before invoking keygen. Without this flag, any existing identity is
                             preserved — re-runs and re-deploys are fully idempotent.
  -h|--help                  Show this help

Env overrides: OXPULSE_IMAGE_REGISTRY, OXPULSE_BACKEND_API, OXPULSE_REPO_RAW, REGION
USAGE
	exit 2
}

# GHCR PAT supplied via --ghcr-token=ghp_xxx or OXPULSE_GHCR_TOKEN env.
# Flag wins over env. Empty disables (anonymous pull / assume prior docker login).
GHCR_TOKEN_FLAG="${OXPULSE_GHCR_TOKEN:-}"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--domain=*)         DOMAIN="${1#*=}" ;;
		--partner-id=*)     PARTNER_ID="${1#*=}" ;;
		--token=*)          TOKEN="${1#*=}" ;;
		--ghcr-token=*)     GHCR_TOKEN_FLAG="${1#*=}" ;;
		--token-file=*)     TOKEN_FILE="${1#*=}" ;;
		--manual-config=*)  MANUAL_CONFIG="${1#*=}" ;;
		--tunnel=*)         TUNNEL="${1#*=}" ;;
		--image-version=*)  IMAGE_VERSION="${1#*=}" ;;
		--region=*)         REGION="${1#*=}" ;;
		--healthcheck-timeout=*) HEALTHCHECK_TIMEOUT="${1#*=}" ;;
		--branding-config=*) BRANDING_CONFIG="${1#*=}" ;;
		--brand-display-name=*)    BRAND_DISPLAY_NAME="${1#*=}" ;;
		--brand-description=*)     BRAND_DESCRIPTION="${1#*=}" ;;
		--brand-color-primary=*)   BRAND_COLOR_PRIMARY="${1#*=}" ;;
		--brand-color-secondary=*) BRAND_COLOR_SECONDARY="${1#*=}" ;;
		--brand-color-accent=*)    BRAND_COLOR_ACCENT="${1#*=}" ;;
		--brand-color-on-primary=*) BRAND_COLOR_ON_PRIMARY="${1#*=}" ;;
		--brand-logo-light=*)      BRAND_LOGO_LIGHT="${1#*=}" ;;
		--brand-logo-dark=*)       BRAND_LOGO_DARK="${1#*=}" ;;
		--brand-favicon=*)         BRAND_FAVICON="${1#*=}" ;;
		--brand-og-image=*)        BRAND_OG_IMAGE="${1#*=}" ;;
		--brand-co-brand=*)        BRAND_CO_BRAND="${1#*=}" ;;
		--brand-canonical=*)       BRAND_CANONICAL="${1#*=}" ;;
		--brand-wordmark=*)        BRAND_WORDMARK="${1#*=}" ;;
		--brand-hero-title=*)      BRAND_HERO_TITLE="${1#*=}" ;;
		--brand-hero-title-ru=*)   BRAND_HERO_TITLE_RU="${1#*=}" ;;
		--brand-hero-title-en=*)   BRAND_HERO_TITLE_EN="${1#*=}" ;;
		--brand-hero-title-zh=*)   BRAND_HERO_TITLE_ZH="${1#*=}" ;;
		--brand-hero-title-fa=*)   BRAND_HERO_TITLE_FA="${1#*=}" ;;
		--brand-cta-url=*)         BRAND_CTA_URL="${1#*=}" ;;
		--brand-cta-text=*)        BRAND_CTA_TEXT="${1#*=}" ;;
		--brand-cta-url-ru=*)      BRAND_CTA_URL_RU="${1#*=}" ;;
		--brand-cta-url-en=*)      BRAND_CTA_URL_EN="${1#*=}" ;;
		--brand-cta-url-zh=*)      BRAND_CTA_URL_ZH="${1#*=}" ;;
		--brand-cta-url-fa=*)      BRAND_CTA_URL_FA="${1#*=}" ;;
		--brand-cta-text-ru=*)     BRAND_CTA_TEXT_RU="${1#*=}" ;;
		--brand-cta-text-en=*)     BRAND_CTA_TEXT_EN="${1#*=}" ;;
		--brand-cta-text-zh=*)     BRAND_CTA_TEXT_ZH="${1#*=}" ;;
		--brand-cta-text-fa=*)     BRAND_CTA_TEXT_FA="${1#*=}" ;;
		--brand-legal-entity=*)    BRAND_LEGAL_ENTITY="${1#*=}" ;;
		--brand-legal-country=*)   BRAND_LEGAL_COUNTRY="${1#*=}" ;;
		--brand-legal-contact=*)   BRAND_LEGAL_CONTACT="${1#*=}" ;;
		--check)            CHECK_MODE=1 ;;
		--dry-run)          DRY_RUN=1 ;;
		--bake)             BAKE_MODE=1 ;;
		--force-keygen|--rotate-identity) FORCE_KEYGEN=1 ;;
		-h|--help)          usage ;;
		*) die "unknown arg: $1 (try --help)" ;;
	esac
	shift
done

# --check mode: read install.env from installed prefix, no domain/token required.
if [[ "$CHECK_MODE" -eq 1 ]]; then
	_state_file="${PREFIX_LIB}/install.env"
	[[ -f "$_state_file" ]] || die "--check requires an installed node ($PREFIX_LIB/install.env not found)"
	# shellcheck source=/dev/null
	source "$_state_file"
	# install.env uses PARTNER_DOMAIN; install.sh uses DOMAIN.
	DOMAIN="${PARTNER_DOMAIN:-${DOMAIN:-}}"
fi

[[ -z "$DOMAIN" ]]     && [[ "$CHECK_MODE" -eq 0 ]] && die "--domain is required"
[[ -z "$PARTNER_ID" ]] && [[ "$CHECK_MODE" -eq 0 ]] && die "--partner-id is required"

# Resolve token from --token=- (stdin) / --token-file= / --token=raw / env.
# Order: explicit --token-file beats inline --token; stdin only when
# --token=- given so we don't block when stdin is a tty by mistake.
if [[ "$TOKEN" == "-" ]]; then
	IFS= read -r TOKEN || die "--token=- given but stdin closed before token arrived"
fi
if [[ -n "$TOKEN_FILE" ]]; then
	[[ -r "$TOKEN_FILE" ]] || die "token-file not readable: $TOKEN_FILE"
	TOKEN="$(tr -d '\r\n[:space:]' < "$TOKEN_FILE")"
fi
if [[ -n "$TOKEN" && -t 1 ]] && [[ "$*" == *"--token=ptkn_"* ]]; then
	warn "  --token=<raw> on the command line leaks via /proc/<pid>/cmdline + shell history; prefer --token-file= or OXPULSE_PARTNER_TOKEN env"
fi

if [[ "$BAKE_MODE" = "0" && "$CHECK_MODE" -eq 0 && -z "$TOKEN" && -z "$MANUAL_CONFIG" ]]; then
	die "either --token / --token-file / OXPULSE_PARTNER_TOKEN or --manual-config is required (see --help)"
fi

# Validate --branding-config=<path> at arg-parse time so dry-run + first
# real run both fail fast on a malformed file. Burning a single-use
# bootstrap token on a backend 400 is exactly the failure mode this
# dance prevents.
if [[ -n "$BRANDING_CONFIG" ]]; then
	[[ -r "$BRANDING_CONFIG" ]] || die "--branding-config not readable: $BRANDING_CONFIG"
	python3 -c 'import json, sys; json.load(open(sys.argv[1]))' "$BRANDING_CONFIG" 2>/dev/null \
		|| die "--branding-config is not valid JSON: $BRANDING_CONFIG"
fi

# --brand-* shorthand flags + --branding-config don't compose: the file
# is a literal payload, the flags are an alternative way to assemble
# one. Conflicting both would make the resulting branding ambiguous.
# Detect any BRAND_* set and error early.
brand_flag_set=0
for v in BRAND_DISPLAY_NAME BRAND_DESCRIPTION BRAND_COLOR_PRIMARY \
	BRAND_COLOR_SECONDARY BRAND_COLOR_ACCENT BRAND_COLOR_ON_PRIMARY \
	BRAND_LOGO_LIGHT BRAND_LOGO_DARK BRAND_FAVICON BRAND_OG_IMAGE \
	BRAND_CO_BRAND BRAND_CANONICAL BRAND_WORDMARK \
	BRAND_HERO_TITLE BRAND_HERO_TITLE_RU BRAND_HERO_TITLE_EN \
	BRAND_HERO_TITLE_ZH BRAND_HERO_TITLE_FA \
	BRAND_CTA_URL BRAND_CTA_TEXT \
	BRAND_CTA_URL_RU BRAND_CTA_URL_EN BRAND_CTA_URL_ZH BRAND_CTA_URL_FA \
	BRAND_CTA_TEXT_RU BRAND_CTA_TEXT_EN BRAND_CTA_TEXT_ZH BRAND_CTA_TEXT_FA \
	BRAND_LEGAL_ENTITY BRAND_LEGAL_COUNTRY BRAND_LEGAL_CONTACT; do
	[[ -n "${!v:-}" ]] && brand_flag_set=1 && break
done
if [[ $brand_flag_set -eq 1 && -n "$BRANDING_CONFIG" ]]; then
	die "--branding-config and --brand-* shorthand flags are mutually exclusive (use one or the other)"
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

if [[ $DRY_RUN -eq 0 && $CHECK_MODE -eq 0 && $EUID -ne 0 ]]; then
	die "must run as root (or with sudo) unless --dry-run"
fi

# ---------------------------------------------------------------------------
# --check mode: re-render templates to /tmp, diff vs installed files.
# Exit codes:
#   0 — Caddyfile + docker-compose.yml both byte-identical to fresh render
#   1 — Caddyfile differs (drift detected)
#   2 — docker-compose.yml differs (compose drift)
# conf.d/ is explicitly EXCLUDED from the diff (it's an operator override slot).
# ---------------------------------------------------------------------------
if [[ "$CHECK_MODE" -eq 1 ]]; then
	_check_dir=$(mktemp -d)
	trap 'rm -rf "$_check_dir"' EXIT

	# Determine template source: local checkout (detect from $0) or REPO_RAW fetch.
	# src_dir is not set yet at --check early-exit point; detect from BASH_SOURCE.
	_check_src_dir=""
	_check_self="${BASH_SOURCE[0]:-}"
	if [[ -n "$_check_self" && -f "$(cd "$(dirname "$_check_self")" 2>/dev/null && pwd)/Caddyfile.tpl" ]]; then
		_check_src_dir="$(cd "$(dirname "$_check_self")" && pwd)"
	fi
	_fetch_check_tpl() {
		local name=$1 dst=$2
		if [[ -n "$_check_src_dir" && -f "$_check_src_dir/$name" ]]; then
			cp "$_check_src_dir/$name" "$dst"
		else
			curl -fsSL --max-time 30 "$REPO_RAW/$name" -o "$dst" \
				|| die "[check] could not fetch $name from $REPO_RAW"
		fi
	}

	_fetch_check_tpl Caddyfile.tpl "$_check_dir/Caddyfile.tpl"
	_fetch_check_tpl docker-compose.yml.tpl "$_check_dir/compose.tpl"

	# Render Caddyfile using install.env values.
	sed \
		-e "s|{{PARTNER_DOMAIN}}|${DOMAIN}|g" \
		-e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN:-}|g" \
		"$_check_dir/Caddyfile.tpl" > "$_check_dir/Caddyfile"
	_check_sha=$(sha256sum "$_check_dir/Caddyfile" | awk '{print $1}')
	sed -i "s|__CADDYFILE_SHA__|${_check_sha}|g" "$_check_dir/Caddyfile"

	# Render compose — only for drift detection, no secret substitution needed
	# because we only check byte-identity of the base rendered content.
	# We use the same render() vars available at this point (sourced from install.env).
	sed \
		-e "s|{{PARTNER_ID}}|${PARTNER_ID:-}|g" \
		-e "s|{{PARTNER_DOMAIN}}|${DOMAIN}|g" \
		-e "s|{{TURNS_SUBDOMAIN}}|${TURNS_SUBDOMAIN:-}|g" \
		-e "s|{{IMAGE_VERSION}}|${IMAGE_VERSION:-latest}|g" \
		"$_check_dir/compose.tpl" > "$_check_dir/docker-compose.yml"

	_rc=0
	_caddy_installed="$PREFIX_ETC/Caddyfile"
	_compose_installed="$PREFIX_ETC/docker-compose.yml"
	_confd_dir="$PREFIX_ETC/conf.d"
	_confd_count=0
	[[ -d "$_confd_dir" ]] && _confd_count=$(find "$_confd_dir" -maxdepth 1 -name "*.caddy" | wc -l | tr -d " ")

	if diff -q "$_check_dir/Caddyfile" "$_caddy_installed" >/dev/null 2>&1; then
		printf "[OK]    Caddyfile\n"
	else
		printf "[DRIFT] Caddyfile\n"
		diff -u "$_check_dir/Caddyfile" "$_caddy_installed" || true
		_rc=1
	fi

	# Compose drift check: partial match only (compose has secrets not in install.env).
	# We diff only the first N lines that don't contain obvious secrets (image: lines).
	# This is best-effort; exit code 2 = warning, not catastrophic.
	if diff -q "$_check_dir/docker-compose.yml" "$_compose_installed" >/dev/null 2>&1; then
		printf "[OK]    docker-compose.yml\n"
	elif [[ $_rc -eq 0 ]]; then
		printf "[DRIFT] docker-compose.yml\n"
		_rc=2
	else
		printf "[DRIFT] docker-compose.yml (secondary drift)\n"
	fi

	printf "[conf.d/] %d files preserved\n" "$_confd_count"
	exit $_rc
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
	# Idempotency: if our own oxpulse-partner-* containers are already
	# bound to the ports, treat preflight as a no-op (re-install path).
	# Otherwise an unrelated process holding the port is still a hard fail.
	owned_by_oxpulse=0
	if command -v docker >/dev/null 2>&1 \
		&& docker ps --filter 'name=oxpulse-partner-' --format '{{.Names}}' 2>/dev/null \
		| grep -q .; then
		owned_by_oxpulse=1
	fi
	check_port_free() {
		local port=$1 proto=$2
		ss -ln"${proto}" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" || return 0
		if [[ $owned_by_oxpulse -eq 1 ]]; then
			warn "port $port/$proto held by existing oxpulse-partner-* container — re-install path, continuing"
			return 0
		fi
		die "port $port/$proto is already in use — free it before installing"
	}
	for p in 80 443 3478 5349 "$SFU_METRICS_PORT"; do check_port_free "$p" t; done
	check_port_free 3478 u
	# M2.1: str0m SFU media port (UDP). Default 7878 avoids coturn's 3478.
	check_port_free "$SFU_UDP_PORT" u
	log "  ports 80/443/3478/5349/${SFU_UDP_PORT}(udp)/${SFU_METRICS_PORT}(tcp) preflight done (oxpulse-owned=${owned_by_oxpulse})"
fi

# ---------- Step 1b: firewall auto-open ----------
# Without this, ACME HTTP-01 silently fails (port 80) and TURN/SFU media
# never reach the host. Confirmed 2026-05-01 on a fresh CentOS Stream 9
# install where firewalld was active by default.
#
# Supports two stacks (whichever is active):
#   firewalld   — default on RHEL/CentOS/Rocky/Alma
#   ufw         — common on Ubuntu/Debian when explicitly enabled
#
# If neither is active, assume operator runs an external SG / cloud
# firewall and skip silently.
fw_specs=(80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp \
	"${SFU_UDP_PORT}/udp" "${SFU_METRICS_PORT}/tcp")

if [[ $DRY_RUN -eq 0 ]] \
	&& command -v firewall-cmd >/dev/null 2>&1 \
	&& systemctl is-active --quiet firewalld; then
	log "[1b] opening firewalld ports"
	fw_added=0
	for spec in "${fw_specs[@]}"; do
		if ! firewall-cmd --query-port="$spec" >/dev/null 2>&1; then
			firewall-cmd --add-port="$spec" --permanent >/dev/null
			fw_added=1
			log "  + $spec"
		fi
	done
	if [[ $fw_added -eq 1 ]]; then
		firewall-cmd --reload >/dev/null
		log "  firewalld reloaded"
	else
		log "  all required ports already open"
	fi
elif [[ $DRY_RUN -eq 0 ]] \
	&& command -v ufw >/dev/null 2>&1 \
	&& ufw status 2>/dev/null | head -1 | grep -qi 'Status: active'; then
	log "[1b] opening ufw ports"
	for spec in "${fw_specs[@]}"; do
		# ufw allow takes "<port>/<proto>" directly; idempotent on identical rules.
		ufw allow "$spec" >/dev/null
		log "  + $spec"
	done
fi

# ---------- Step 1c: dnf cache sanity (rhel only) ----------
# Some VPS providers (e.g. fvds.ru / hoztnode) ship images where every
# `metalink=` and `baseurl=` line in /etc/yum.repos.d/centos.repo is
# commented out, expecting the operator to wire in a private mirror.
# `dnf install` then fails with the unhelpful "Cannot find a valid
# baseurl for repo: baseos" deep inside get.docker.com — confusing and
# hard to debug. Detect early and re-enable the official metalink.
if [[ $DRY_RUN -eq 0 && $OS_FAMILY == rhel ]] && command -v dnf >/dev/null 2>&1; then
	if ! dnf -q makecache --setopt=metadata_expire=0 >/dev/null 2>&1; then
		warn "  dnf makecache failed — checking for commented metalinks in /etc/yum.repos.d"
		repaired=0
		for f in /etc/yum.repos.d/centos.repo /etc/yum.repos.d/centos-addons.repo; do
			[[ -f "$f" ]] || continue
			if grep -q '^#metalink=https://mirrors.centos.org' "$f"; then
				sed -i 's|^#metalink=https://mirrors.centos.org|metalink=https://mirrors.centos.org|g' "$f"
				log "  re-enabled metalinks in $f"
				repaired=1
			fi
		done
		if [[ $repaired -eq 1 ]]; then
			dnf -q makecache --setopt=metadata_expire=0 >/dev/null 2>&1 \
				|| die "dnf still broken after metalink re-enable — inspect /etc/yum.repos.d/ manually"
			log "  dnf cache rebuilt"
		else
			die "dnf makecache failed and no commented-metalink pattern matched — inspect /etc/yum.repos.d/ and DNS"
		fi
	fi
fi

# ---------- Step 1b: runtime deps (jq, curl) ----------
# jq is required by oxpulse-partner-edge-refresh.sh for JSON parsing.
# curl is required by install.sh itself and the refresh script.
# Install both unconditionally so systemd-managed refresh runs succeed even
# on minimal OS images (e.g. CentOS Stream 9 / AlmaLinux without extras).
if [[ $DRY_RUN -eq 0 ]]; then
	for _pkg in jq curl; do
		if ! command -v "$_pkg" >/dev/null 2>&1; then
			log "  installing missing runtime dep: $_pkg"
			if [[ $OS_FAMILY == rhel ]]; then
				dnf install -y "$_pkg" >/dev/null 2>&1 \
					|| die "dnf install $_pkg failed — install manually then re-run"
			else
				apt-get install -y -q "$_pkg" >/dev/null 2>&1 \
					|| die "apt-get install $_pkg failed"
			fi
		fi
	done
	unset _pkg
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

# Auto-detect region tag from PUBLIC_IP via ipinfo.io when --region= /
# REGION env was not supplied. Format: lowercase `<country>-<city3>` to
# match existing tags (`pl-waw`, `ru-msk`, `us-east`). Failure leaves
# REGION empty — backend stores NULL and excludes the node from
# region-aware turn pool ordering, which is fine for first-boot.
_detect_region() {
	local payload cc city
	payload=$(curl -fsS --max-time 3 "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null || true)
	[[ -z "$payload" ]] && return 1
	cc=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("country") or "").lower())' 2>/dev/null || true)
	city=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("city") or "").lower())' 2>/dev/null || true)
	[[ -z "$cc" || -z "$city" ]] && return 1
	# strip non-ascii-letters from city, take first 3 chars
	city=$(printf '%s' "$city" | tr -cd 'a-z' | cut -c1-3)
	[[ -z "$city" ]] && return 1
	printf '%s-%s' "$cc" "$city"
}
if [[ -z "$REGION" ]]; then
	if REGION=$(_detect_region); then
		log "  region auto-detected: $REGION"
	else
		REGION=""
		warn "  region auto-detect failed (ipinfo.io unreachable or missing fields) — registering with NULL region"
	fi
else
	log "  region (override): $REGION"
fi

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
# ghcr-auth setup before the pull loop. Source lib (from checkout or sbin),
# then either configure-and-login (if --ghcr-token=) or relogin from stored
# token (idempotent). Anything missing → fall through; the docker pulls in
# the loop below will fail loud with a denied error on private packages.
_ghcr_lib_local="${src_dir:-.}/ghcr-auth-lib.sh"
_ghcr_lib_installed="$PREFIX_SBIN/ghcr-auth-lib.sh"
if [[ -f "$_ghcr_lib_local" ]]; then
	# shellcheck source=ghcr-auth-lib.sh
	source "$_ghcr_lib_local"
elif [[ -f "$_ghcr_lib_installed" ]]; then
	# shellcheck source=/dev/null
	source "$_ghcr_lib_installed"
fi
unset _ghcr_lib_local _ghcr_lib_installed

_chan_lib_local="${src_dir:-.}/channel-render-lib.sh"
_chan_lib_installed="$PREFIX_SBIN/channel-render-lib.sh"
_chan_lib_tmp=""
if [[ -f "$_chan_lib_local" ]]; then
	# shellcheck source=channel-render-lib.sh
	source "$_chan_lib_local"
elif [[ -f "$_chan_lib_installed" ]]; then
	# shellcheck source=/dev/null
	source "$_chan_lib_installed"
else
	# Fresh one-command install via curl: only install.sh was downloaded,
	# the lib isn't on disk yet. Fetch it from REPO_RAW the same way Step 5
	# fetches .tpl files. Step 8 (systemd install) reuses $_chan_lib_tmp
	# to copy the lib to $PREFIX_SBIN.
	_chan_lib_tmp=$(mktemp)
	if ! curl -fsSL "$REPO_RAW/channel-render-lib.sh" -o "$_chan_lib_tmp"; then
		rm -f "$_chan_lib_tmp"
		die "channel-render-lib.sh not found locally and could not fetch from $REPO_RAW"
	fi
	# shellcheck source=/dev/null
	source "$_chan_lib_tmp"
fi
unset _chan_lib_local _chan_lib_installed
# NOTE: do NOT unset _chan_lib_tmp here — Step 8 install needs it.

if [[ -n "${GHCR_TOKEN_FLAG:-}" ]] && declare -f ghcr_configure_token >/dev/null 2>&1; then
	ghcr_configure_token "$GHCR_TOKEN_FLAG" \
		|| die "failed to save/login with --ghcr-token (see warning above)"
	unset GHCR_TOKEN_FLAG
elif declare -f ghcr_login_from_file >/dev/null 2>&1; then
	ghcr_login_from_file || warn "ghcr: login from stored token failed; pull may fail"
fi

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
# Idempotent re-install protection: if state file from a prior install
# exists and the operator passed --token=<raw> (which is single-use and
# would 409 on the backend), short-circuit before burning the token.
# Operator is expected to use the upgrade tool, --manual-config=, or
# regenerate a token via partner-cli issue-token.
if [[ -f "$PREFIX_LIB/install.env" && -z "$MANUAL_CONFIG" ]]; then
	# shellcheck source=/dev/null
	prior_node_id=$(. "$PREFIX_LIB/install.env" 2>/dev/null && printf '%s' "${NODE_ID:-}")
	if [[ -n "$prior_node_id" ]]; then
		log "  existing install detected (node_id=$prior_node_id) — skipping registration"
		warn "  bootstrap tokens are single-use; the backend would return 409. To re-deploy:"
		warn "    • upgrade in place: sudo $PREFIX_SBIN/oxpulse-partner-edge-upgrade"
		warn "    • apply a freshly-issued config: rerun with --manual-config=<path>"
		log  "  running healthcheck and exiting 0"
		"$PREFIX_SBIN/oxpulse-partner-edge-healthcheck" || true
		exit 0
	fi
fi

# ---------- Reality x25519 keypair + UUID (M6 slice 2b) ----------
# Generated once at first install; persisted so reinstalls / upgrade runs reuse
# the same identity (idempotency guard — incident §13, 2026-05-14).
# To rotate: use --force-keygen / --rotate-identity flag (backs up + regenerates).
# reality_public_key is sent to the backend on POST /api/partner/register and
# stored in partner_nodes.reality_pubkey via the COALESCE upsert; slice 2c
# path-watcher SIGHUPs xray-reality to apply.
#
# File layout (under PREFIX_ETC = /etc/oxpulse-partner-edge/):
#   reality.priv  0600  base64url x25519 private key (never leaves this host)
#   reality.pub   0644  base64url x25519 public key  (sent to krolik on register)
#   reality.uuid  0644  lowercase UUID               (sent to krolik on register)
#
# Idempotency: re-registration with the same (partner_id, domain) is a safe
# upsert — ON CONFLICT DO UPDATE with COALESCE keeps the existing pubkey when
# the new request omits it. No 409 scenario exists. Verified in register.rs.
#
# partner-cli keygen output format (two lines, fixed labels):
#   private_key: <43-char base64url>
#   public_key:  <43-char base64url>
REALITY_PRIV_PATH="$PREFIX_ETC/reality.priv"
REALITY_PUB_PATH="$PREFIX_ETC/reality.pub"
REALITY_UUID_PATH="$PREFIX_ETC/reality.uuid"

if [[ $DRY_RUN -eq 1 ]]; then
	# Dry-run: show what keygen would produce / reuse, but do NOT write files.
	# No partner-cli invocation — dry-run must be side-effect-free.
	_dry_count=0
	for _f in "$REALITY_PRIV_PATH" "$REALITY_PUB_PATH" "$REALITY_UUID_PATH"; do
		[[ -s "$_f" ]] && _dry_count=$((_dry_count + 1))
	done
	unset _f
	if [[ $FORCE_KEYGEN -eq 1 ]]; then
		warn "  [dry-run] --force-keygen: would backup existing identity files and invoke partner-cli keygen"
		REALITY_PUBKEY="DRYRUN-pub"
		REALITY_UUID="DRYRUN-uuid-00000000-0000-0000-0000-000000000000"
	elif [[ $_dry_count -eq 3 ]]; then
		warn "  [dry-run] reality keypair already exists — would reuse (idempotent re-install)"
		REALITY_PUBKEY=$(cat "$REALITY_PUB_PATH")
		REALITY_UUID=$(cat "$REALITY_UUID_PATH")
		warn "  [dry-run] reality_public_key: $REALITY_PUBKEY"
		warn "  [dry-run] reality_uuid: $REALITY_UUID"
	elif [[ $_dry_count -gt 0 ]]; then
		warn "  [dry-run] PARTIAL identity files detected ($_dry_count/3) — would abort on real run"
		REALITY_PUBKEY="DRYRUN-pub"
		REALITY_UUID="DRYRUN-uuid-00000000-0000-0000-0000-000000000000"
	else
		warn "  [dry-run] would invoke: partner-cli keygen → $REALITY_PRIV_PATH $REALITY_PUB_PATH $REALITY_UUID_PATH"
		warn "  [dry-run] would write $REALITY_PRIV_PATH (mode 0600, not written)"
		warn "  [dry-run] would write $REALITY_PUB_PATH  (mode 0644, not written)"
		warn "  [dry-run] would write $REALITY_UUID_PATH (mode 0644, not written)"
		REALITY_PUBKEY="DRYRUN-pub"
		REALITY_UUID="DRYRUN-uuid-00000000-0000-0000-0000-000000000000"
	fi
	unset _dry_count
else
	install -d -m 0700 "$PREFIX_ETC"
	# ---------- Idempotency guard (incident §13, 2026-05-14) ----------
	# All three files (reality.priv + reality.pub + reality.uuid) form ONE atomic
	# identity unit. Re-runs MUST reuse the existing identity to prevent silent
	# breakage of all distributed VLESS links.
	#
	# Decision tree:
	#   FORCE_KEYGEN=1 (--force-keygen / --rotate-identity)
	#     → backup existing files, then generate fresh identity
	#   All three present and non-empty
	#     → skip keygen; reuse existing identity; echo UUID to stdout
	#   Exactly one or two present (partial state)
	#     → ABORT loudly; no files modified; operator must resolve manually
	#   None present (fresh install)
	#     → generate fresh identity; echo UUID to stdout
	_reality_all_present=0
	_reality_partial=0
	_reality_count=0
	for _f in "$REALITY_PRIV_PATH" "$REALITY_PUB_PATH" "$REALITY_UUID_PATH"; do
		[[ -s "$_f" ]] && _reality_count=$((_reality_count + 1))
	done
	[[ $_reality_count -eq 3 ]] && _reality_all_present=1
	[[ $_reality_count -gt 0 && $_reality_count -lt 3 ]] && _reality_partial=1

	if [[ $FORCE_KEYGEN -eq 1 ]]; then
		# Explicit operator-initiated rotation (slice 3 contract). Back up any
		# existing files before overwriting so a botched rotation is recoverable.
		log "  --force-keygen: backing up existing identity files (if present)"
		_bak_epoch=$(date +%s)
		for _f in reality.priv reality.pub reality.uuid; do
			if [[ -f "$PREFIX_ETC/$_f" ]]; then
				cp "$PREFIX_ETC/$_f" "$PREFIX_ETC/$_f.bak.$_bak_epoch"
				log "    backed up $PREFIX_ETC/$_f → $PREFIX_ETC/$_f.bak.$_bak_epoch"
			fi
		done
		unset _bak_epoch _f
		log "  generating Reality x25519 keypair via partner-cli keygen (forced rotation)"
		_do_keygen=1
	elif [[ $_reality_all_present -eq 1 ]]; then
		# All three files present — idempotent re-install or re-deploy.
		# Reuse existing identity; distributed VLESS links remain valid.
		log "  reality keypair: reusing existing identity (all three files present)"
		_do_keygen=0
	elif [[ $_reality_partial -eq 1 ]]; then
		# Partial state detected — this is not a clean fresh install.
		# Silent regeneration would silently rotate the UUID and break VLESS links.
		# Abort loudly so the operator can make an explicit decision.
		die "install: PARTIAL identity files detected ($_reality_count/3 reality.* files present).
Manual recovery required — choose one option:
  Option 1 (fresh identity): remove all reality.* files and re-run install.sh
    sudo rm -f $PREFIX_ETC/reality.priv $PREFIX_ETC/reality.pub $PREFIX_ETC/reality.uuid
  Option 2 (explicit rotation): run with --force-keygen to rotate and backup
    sudo bash install.sh --force-keygen <other-flags>
  Option 3 (restore from backup): copy reality.{priv,pub,uuid}.bak.* back to their originals
Aborting to prevent silent UUID rotation and VLESS link breakage."
	else
		# All three absent — fresh install.
		log "  reality keypair: fresh install, generating new identity"
		_do_keygen=1
	fi
	unset _reality_all_present _reality_partial _reality_count

	if [[ ${_do_keygen:-0} -eq 1 ]]; then
		log "  generating Reality x25519 keypair via partner-cli keygen"
		_keygen_out=$(partner-cli keygen)
		_reality_priv=$(printf '%s' "$_keygen_out" | grep '^private_key:' | awk '{print $2}')
		_reality_pub=$(printf '%s' "$_keygen_out"  | grep '^public_key:'  | awk '{print $2}')
		[[ -n "$_reality_priv" && -n "$_reality_pub" ]] || \
			die "partner-cli keygen produced unexpected output — cannot parse private_key/public_key"
		# Edge-side length validation before persisting.
		# Server-side validate_reality_pubkey enforces the same 43-char constraint,
		# but catching it here gives a clearer error message at install time.
		[[ ${#_reality_priv} -eq 43 && ${#_reality_pub} -eq 43 ]] || \
			die "partner-cli keygen output malformed (expected 43-char base64url private + public; got ${#_reality_priv} + ${#_reality_pub})"
		# Write private key (mode 0600).
		# bash cannot zero memory; unset != memset(0). Slice 1 partner-cli uses
		# Zeroizing<String> to clear the private key post-print at the source.
		# This script's exposure window is the install duration only — operator
		# should re-run install.sh on a fresh shell after rotation.
		_reality_priv_tmp=$(mktemp "$PREFIX_ETC/.reality.priv.XXXXXX")
		chmod 0600 "$_reality_priv_tmp"
		printf '%s\n' "$_reality_priv" >"$_reality_priv_tmp"
		mv "$_reality_priv_tmp" "$REALITY_PRIV_PATH"
		# Write public key (mode 0644 — explicit, not umask-dependent).
		_reality_pub_tmp=$(mktemp "$PREFIX_ETC/.reality.pub.XXXXXX")
		chmod 0644 "$_reality_pub_tmp"
		printf '%s\n' "$_reality_pub" >"$_reality_pub_tmp"
		mv "$_reality_pub_tmp" "$REALITY_PUB_PATH"
		unset _keygen_out _reality_priv _reality_pub _reality_priv_tmp _reality_pub_tmp
		# Generate UUID and write (mode 0644 — explicit, not umask-dependent).
		if ! command -v uuidgen >/dev/null 2>&1; then
			die "uuidgen not found — install uuid-runtime (Debian/Ubuntu) or util-linux (RHEL) and retry"
		fi
		_uuid=$(uuidgen | tr '[:upper:]' '[:lower:]')
		# Validate format: 8-4-4-4-12 hex groups separated by dashes.
		if ! printf '%s' "$_uuid" | grep -qE \
			'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'; then
			die "uuidgen produced unexpected output: $_uuid"
		fi
		_uuid_tmp=$(mktemp "$PREFIX_ETC/.reality.uuid.XXXXXX")
		chmod 0644 "$_uuid_tmp"
		printf '%s\n' "$_uuid" >"$_uuid_tmp"
		mv "$_uuid_tmp" "$REALITY_UUID_PATH"
		unset _uuid _uuid_tmp _do_keygen
	fi
	REALITY_PUBKEY=$(cat "$REALITY_PUB_PATH")
	REALITY_UUID=$(cat "$REALITY_UUID_PATH")
	log "  reality_public_key: $REALITY_PUBKEY"
	log "  reality_uuid: $REALITY_UUID"
fi

if [[ -n "$MANUAL_CONFIG" ]]; then
	[[ -r "$MANUAL_CONFIG" ]] || die "manual-config file not readable: $MANUAL_CONFIG"
	cp "$MANUAL_CONFIG" "$tmp_cfg"
	log "  using manual config: $MANUAL_CONFIG"
elif [[ $DRY_RUN -eq 1 ]]; then
	warn "  [dry-run] skipping POST $BACKEND_API/api/partner/register"
	# Synthesize a placeholder node config so Step 5 templates render without
	# leaking real secrets. reality_public_key + reality_uuid use the values
	# generated/reused by the Reality keygen block above (real per-edge values).
	# Other secrets remain obvious sentinels (DRYRUN-…).
	cat >"$tmp_cfg" <<DRYJSON
{
  "node_id": "${PARTNER_ID}-DRYRUN",
  "backend_endpoint": "https://api.oxpulse.chat",
  "turn_secret": "DRYRUN-turn-secret",
  "reality_uuid": "${REALITY_UUID}",
  "reality_public_key": "${REALITY_PUBKEY}",
  "reality_short_id": "0123456789abcdef",
  "reality_server_name": "www.cloudflare.com",
  "reality_encryption": "",
  "relay_jwt_secret": "DRYRUN-relay-jwt-secret",
  "turns_subdomain": "${TURNS_SUBDOMAIN}"
}
DRYJSON
else
	log "  POST $BACKEND_API/api/partner/register"
	[[ -n "$BRANDING_CONFIG" ]] && log "  shipping branding-config: $BRANDING_CONFIG"
	[[ $brand_flag_set -eq 1 ]] && log "  shipping branding from --brand-* shorthand flags"

	# AmneziaWG keypair — generated locally so the private key never leaves
	# this host. Public key is sent UP at registration so the central can
	# pre-create the awg0 peer entry on motherly before we bring up our own
	# interface. Key persists at /etc/amnezia/amneziawg/private.key (mode
	# 0600) so re-runs of install.sh re-use it instead of churning a fresh
	# pubkey every time.
	AWG_PRIV_PATH="$PREFIX_ETC/awg-private.key"
	AWG_PUB_PATH="$PREFIX_ETC/awg-public.key"
	if [[ $DRY_RUN -eq 0 ]]; then
		install -d -m 0700 "$PREFIX_ETC"
		if [[ ! -s "$AWG_PRIV_PATH" ]]; then
			# wg genkey is the same binary across wg-tools and amneziawg-tools
			# (just calls into the kernel CSPRNG); we use whichever is on PATH.
			# wg-tools is dnf-installable on every supported edge OS, so we
			# can rely on it being available before the awg-go binaries are.
			if ! command -v wg >/dev/null 2>&1; then
				install_wg_tools_for_keygen
			fi
			umask 077
			wg genkey > "$AWG_PRIV_PATH"
			chmod 0600 "$AWG_PRIV_PATH"
		fi
		wg pubkey < "$AWG_PRIV_PATH" > "$AWG_PUB_PATH"
		AWG_PUBKEY=$(cat "$AWG_PUB_PATH")
		log "  awg pubkey: $AWG_PUBKEY"
	else
		AWG_PUBKEY="dryrun-awg-pubkey-placeholder"
	fi
	# Build body via python so we (1) omit `region` cleanly when empty,
	# (2) inline `branding` as a parsed object, and (3) assemble a
	# minimal BrandingConfig from --brand-* flags when they are set
	# (and --branding-config is not). The backend column is nullable
	# and the register handler treats absent + null + "" as
	# Option::None — see register.rs.
	register_body=$(
		REG_PARTNER="$PARTNER_ID" REG_DOMAIN="$DOMAIN" REG_TOKEN="$TOKEN" \
		REG_PUBLIC_IP="$PUBLIC_IP" REG_REGION="$REGION" \
		REG_BRANDING_FILE="$BRANDING_CONFIG" \
		REG_AWG_PUBKEY="$AWG_PUBKEY" \
		REG_REALITY_PUBKEY="$REALITY_PUBKEY" \
		REG_REALITY_UUID="$REALITY_UUID" \
		REG_BRAND_DISPLAY_NAME="$BRAND_DISPLAY_NAME" \
		REG_BRAND_DESCRIPTION="$BRAND_DESCRIPTION" \
		REG_BRAND_COLOR_PRIMARY="$BRAND_COLOR_PRIMARY" \
		REG_BRAND_COLOR_SECONDARY="$BRAND_COLOR_SECONDARY" \
		REG_BRAND_COLOR_ACCENT="$BRAND_COLOR_ACCENT" \
		REG_BRAND_COLOR_ON_PRIMARY="$BRAND_COLOR_ON_PRIMARY" \
		REG_BRAND_LOGO_LIGHT="$BRAND_LOGO_LIGHT" \
		REG_BRAND_LOGO_DARK="$BRAND_LOGO_DARK" \
		REG_BRAND_FAVICON="$BRAND_FAVICON" \
		REG_BRAND_OG_IMAGE="$BRAND_OG_IMAGE" \
		REG_BRAND_CO_BRAND="$BRAND_CO_BRAND" \
		REG_BRAND_CANONICAL="$BRAND_CANONICAL" \
		REG_BRAND_WORDMARK="$BRAND_WORDMARK" \
		REG_BRAND_HERO_TITLE="$BRAND_HERO_TITLE" \
		REG_BRAND_HERO_TITLE_RU="$BRAND_HERO_TITLE_RU" \
		REG_BRAND_HERO_TITLE_EN="$BRAND_HERO_TITLE_EN" \
		REG_BRAND_HERO_TITLE_ZH="$BRAND_HERO_TITLE_ZH" \
		REG_BRAND_HERO_TITLE_FA="$BRAND_HERO_TITLE_FA" \
		REG_BRAND_CTA_URL="$BRAND_CTA_URL" \
		REG_BRAND_CTA_TEXT="$BRAND_CTA_TEXT" \
		REG_BRAND_CTA_URL_RU="$BRAND_CTA_URL_RU" \
		REG_BRAND_CTA_URL_EN="$BRAND_CTA_URL_EN" \
		REG_BRAND_CTA_URL_ZH="$BRAND_CTA_URL_ZH" \
		REG_BRAND_CTA_URL_FA="$BRAND_CTA_URL_FA" \
		REG_BRAND_CTA_TEXT_RU="$BRAND_CTA_TEXT_RU" \
		REG_BRAND_CTA_TEXT_EN="$BRAND_CTA_TEXT_EN" \
		REG_BRAND_CTA_TEXT_ZH="$BRAND_CTA_TEXT_ZH" \
		REG_BRAND_CTA_TEXT_FA="$BRAND_CTA_TEXT_FA" \
		REG_BRAND_LEGAL_ENTITY="$BRAND_LEGAL_ENTITY" \
		REG_BRAND_LEGAL_COUNTRY="$BRAND_LEGAL_COUNTRY" \
		REG_BRAND_LEGAL_CONTACT="$BRAND_LEGAL_CONTACT" \
		python3 -c '
import json, os

def env(name, default=""):
    return os.environ.get(name, default).strip()

body = {
    "partner_id": env("REG_PARTNER"),
    "domain":     env("REG_DOMAIN"),
    "token":      env("REG_TOKEN"),
    "public_ip":  env("REG_PUBLIC_IP"),
}
region = env("REG_REGION")
if region:
    body["region"] = region
awg_pubkey = env("REG_AWG_PUBKEY")
if awg_pubkey:
    body["awg_pubkey"] = awg_pubkey
reality_pubkey = env("REG_REALITY_PUBKEY")
if reality_pubkey:
    body["reality_public_key"] = reality_pubkey
reality_uuid = env("REG_REALITY_UUID")
if reality_uuid:
    body["reality_uuid"] = reality_uuid

branding_path = env("REG_BRANDING_FILE")
if branding_path:
    with open(branding_path) as f:
        body["branding"] = json.load(f)
else:
    # Assemble a BrandingConfig from --brand-* flags. Only fields with
    # non-empty values are emitted; the backend deserializer rejects a
    # payload that lacks BrandingConfig required keys, so we pre-fill
    # sensible defaults (display_name="OxPulse" + co_brand=$PARTNER_ID,
    # the same shape the resolver synthesises for NULL rows) when ANY
    # brand flag is set.
    brand_keys = [
        "DISPLAY_NAME","DESCRIPTION","COLOR_PRIMARY","COLOR_SECONDARY",
        "COLOR_ACCENT","COLOR_ON_PRIMARY","LOGO_LIGHT","LOGO_DARK",
        "FAVICON","OG_IMAGE","CO_BRAND","CANONICAL","WORDMARK",
        "HERO_TITLE","HERO_TITLE_RU","HERO_TITLE_EN","HERO_TITLE_ZH","HERO_TITLE_FA",
        "CTA_URL","CTA_TEXT","CTA_URL_RU","CTA_URL_EN","CTA_URL_ZH","CTA_URL_FA",
        "CTA_TEXT_RU","CTA_TEXT_EN","CTA_TEXT_ZH","CTA_TEXT_FA",
        "LEGAL_ENTITY","LEGAL_COUNTRY","LEGAL_CONTACT",
    ]
    any_set = any(env("REG_BRAND_"+k) for k in brand_keys)
    if any_set:
        b = {
            "partner_id":   body["partner_id"],
            "domains":      [body["domain"]],
            "display_name": env("REG_BRAND_DISPLAY_NAME") or "OxPulse",
            "description":  env("REG_BRAND_DESCRIPTION") or "End-to-end encrypted video calls. Free, anonymous, no account.",
            "logo": {
                "light": env("REG_BRAND_LOGO_LIGHT") or "/logo-light.svg",
                "dark":  env("REG_BRAND_LOGO_DARK")  or "/logo-dark.svg",
            },
            "favicon":   env("REG_BRAND_FAVICON")  or "/favicon.svg",
            "og_image":  env("REG_BRAND_OG_IMAGE") or "/og-image.png",
            "colors": {
                "primary":   env("REG_BRAND_COLOR_PRIMARY")   or "#C9A96E",
                "secondary": env("REG_BRAND_COLOR_SECONDARY") or "#1E293B",
            },
            "copy": {},
            "co_brand_partner": env("REG_BRAND_CO_BRAND") or body["partner_id"],
            "canonical_override": env("REG_BRAND_CANONICAL") or "https://oxpulse.chat/",
        }
        accent = env("REG_BRAND_COLOR_ACCENT")
        if accent: b["colors"]["accent"] = accent
        on_primary = env("REG_BRAND_COLOR_ON_PRIMARY")
        if on_primary: b["colors"]["on_primary"] = on_primary
        wordmark = env("REG_BRAND_WORDMARK")
        if wordmark: b["partner_wordmark"] = wordmark

        # hero_title — single value populates ru+en; per-locale wins.
        hero_short = env("REG_BRAND_HERO_TITLE")
        for loc in ("ru","en","zh","fa"):
            specific = env(f"REG_BRAND_HERO_TITLE_{loc.upper()}")
            value = specific or (hero_short if loc in ("ru","en") else "")
            if value:
                b["copy"][f"hero_title_{loc}"] = value

        # affiliate CTA — short flags populate ru+en; per-locale wins.
        cta_url_short  = env("REG_BRAND_CTA_URL")
        cta_text_short = env("REG_BRAND_CTA_TEXT")
        cta_urls, cta_texts = {}, {}
        for loc in ("ru","en","zh","fa"):
            url  = env(f"REG_BRAND_CTA_URL_{loc.upper()}")  or (cta_url_short  if loc in ("ru","en") else "")
            txt  = env(f"REG_BRAND_CTA_TEXT_{loc.upper()}") or (cta_text_short if loc in ("ru","en") else "")
            if url:  cta_urls[loc]  = url
            if txt:  cta_texts[loc] = txt
        if cta_urls or cta_texts:
            # BrandingConfig::AffiliateConfig requires both maps. Fall
            # back to first available locale to preserve schema validity.
            if cta_urls and not cta_texts:
                cta_texts = {next(iter(cta_urls)): "Try VPN"}
            if cta_texts and not cta_urls:
                cta_urls = {next(iter(cta_texts)): "https://example.com/"}
            b["affiliate"] = {"vpn_cta_url": cta_urls, "vpn_cta_text": cta_texts}

        legal_entity  = env("REG_BRAND_LEGAL_ENTITY")
        legal_country = env("REG_BRAND_LEGAL_COUNTRY")
        legal_contact = env("REG_BRAND_LEGAL_CONTACT")
        if legal_entity or legal_country or legal_contact:
            b["legal"] = {
                "partner_entity":  legal_entity  or body["partner_id"],
                "partner_country": legal_country or "unknown",
                "partner_contact": legal_contact or "partnerships@oxpulse.chat",
            }

        body["branding"] = b

print(json.dumps(body, ensure_ascii=False))
')
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
		-X POST "$BACKEND_API/api/partner/register" \
		-H 'Content-Type: application/json' \
		-d "$register_body" \
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
# Sanity: server-side xray-reality with `decryption: mlkem768x25519plus...`
# (post-quantum VLESS) silently rejects clients with `encryption: none`,
# producing 502s at Caddy with cryptic "connection reset by peer" /
# EOF entries — the handshake completes at TLS but VLESS auth fails
# without a log line. Catch the missing PARTNER_REALITY_ENCRYPTION
# env on the operator side here, with an actionable hint, instead of
# letting the operator chase tunnels for an hour.
# Reproduced 2026-05-02 on call.cheburator.bot — operator's .env had
# the var stripped, every fresh registration silently broke.
if [[ -z "$REALITY_ENCRYPTION" && -n "$REALITY_PUBLIC_KEY" ]]; then
	warn "  backend returned reality_encryption=\"\" but reality_public_key is set"
	warn "  this almost always means PARTNER_REALITY_ENCRYPTION is missing from oxpulse-chat .env"
	warn "  the tunnel will silently fail at VLESS auth (Caddy 502 with 'connection reset by peer')"
	warn "  ask the operator to set PARTNER_REALITY_ENCRYPTION on the signaling server, recreate"
	warn "  oxpulse-chat, then re-issue the bootstrap token and rerun this install"
	die "stale backend reality creds — refusing to write a known-broken xray-client config"
fi
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

# AmneziaWG mesh config — present when the central is awg-equipped (the
# register handler returns the `awg` object only when motherly's awg pubkey
# is configured AND we sent up our awg_pubkey). All fields are extracted
# from the nested `awg` object via python — sed-based json_get only handles
# top-level scalars.
awg_extract() {
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); a=d.get('awg') or {}; print(a.get(sys.argv[2],''))" "$1" "$2" 2>/dev/null
}
AWG_ALLOCATED_IP=$(awg_extract     "$tmp_cfg" allocated_ip)
AWG_MOTHERLY_PUBKEY=$(awg_extract  "$tmp_cfg" motherly_pubkey)
AWG_MOTHERLY_ENDPOINT=$(awg_extract "$tmp_cfg" motherly_endpoint)
AWG_MOTHERLY_AWG_IP=$(awg_extract  "$tmp_cfg" motherly_awg_ip)
AWG_JC=$(awg_extract               "$tmp_cfg" jc)
AWG_JMIN=$(awg_extract             "$tmp_cfg" jmin)
AWG_JMAX=$(awg_extract             "$tmp_cfg" jmax)
AWG_S1=$(awg_extract               "$tmp_cfg" s1)
AWG_S2=$(awg_extract               "$tmp_cfg" s2)
AWG_S4=$(awg_extract               "$tmp_cfg" s4)
AWG_H1=$(awg_extract               "$tmp_cfg" h1)
AWG_H2=$(awg_extract               "$tmp_cfg" h2)
AWG_H3=$(awg_extract               "$tmp_cfg" h3)
AWG_H4=$(awg_extract               "$tmp_cfg" h4)
SFU_EDGE_ID=$(awg_extract          "$tmp_cfg" edge_id)
export OTEL_EXPORTER_OTLP_ENDPOINT
OTEL_EXPORTER_OTLP_ENDPOINT=$(awg_extract "$tmp_cfg" otel_endpoint)
# Pre-existing SFU_EDGE_ID derivation (post-arg-parse) is the fallback when
# backend doesn't return one — keep that path.
[[ -z "$SFU_EDGE_ID" ]] && SFU_EDGE_ID="${PARTNER_ID}1"

# Backend-assigned TURNS subdomain (format api-<6-hex>). Falls back to "turns"
# only if the backend did not return one (pre-v0.2 deployments).
REGISTER_TURNS_SUBDOMAIN=$(json_get turns_subdomain "$tmp_cfg")
# CH3/CH5 fallback channel vars — optional; empty if backend does not provision them.
export HYSTERIA2_SERVER HYSTERIA2_PORT HYSTERIA2_AUTH HYSTERIA2_OBFS
HYSTERIA2_SERVER=$(json_get hysteria2_server "$tmp_cfg")
HYSTERIA2_PORT=$(json_get hysteria2_port "$tmp_cfg")
HYSTERIA2_AUTH=$(json_get hysteria2_auth "$tmp_cfg")
HYSTERIA2_OBFS=$(json_get hysteria2_obfs "$tmp_cfg")
export NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS
NAIVE_SERVER=$(json_get naive_server "$tmp_cfg")
NAIVE_PORT=$(json_get naive_port "$tmp_cfg")
NAIVE_USER=$(json_get naive_user "$tmp_cfg")
NAIVE_PASS=$(json_get naive_pass "$tmp_cfg")
# channels[] — future-proof bypass channel array.
# Empty if server is older than v0.12 (no channels field yet).
CHANNELS_JSON=$(json_get_raw channels "$tmp_cfg")
[[ "$CHANNELS_JSON" == "null" || -z "$CHANNELS_JSON" ]] && CHANNELS_JSON="[]"
[[ -z "$NODE_ID" ]]            && NODE_ID="${PARTNER_ID}-$(hostname -s)"
# SFU_EDGE_ID derives from PARTNER_ID once it is known. Convention is
# `<partner>1` to leave room for `<partner>2` if the partner ever runs
# more than one edge (rvpn1, piter1, motherly1, cheburator1).
[[ -z "$SFU_EDGE_ID" ]]        && SFU_EDGE_ID="${PARTNER_ID}1"
# Hard-fail when the central did not return a signaling_sfu_secret. With it
# empty, docker-compose renders SIGNALING_SFU_SECRET= empty, the SFU disables
# /sfu/ws/{room_id} entirely, and browser group calls silently fail end-to-
# end — exactly the motherly1 outage of 2026-05-06 (SIGNALING_SFU_SECRET
# missing from chat compose for ~8 weeks). Operator must fix on the central
# (set SIGNALING_SFU_SECRET on motherly + redeploy oxpulse-chat) before re-
# running this installer; warn-and-continue here is what created the silent-
# fail class in the first place.
if [[ -z "${SIGNALING_SFU_SECRET:-}" ]]; then
	die "Backend /api/partner/register did not return signaling_sfu_secret.
  Without it, the SFU's browser WebSocket API stays disabled and group
  calls silently fail end-to-end. Causes:
    - oxpulse-chat backend SIGNALING_SFU_SECRET env unset (set on motherly,
      redeploy chat service)
    - oxpulse-chat backend version <2026-05-06 (predates field)
  Resolve on the central, then re-run this installer."
fi
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
# Backend returns PEM with embedded newlines. Escape them as literal \n so the
# rendered docker-compose.yml stays a valid YAML inline string. The YAML parser
# then converts \n back to real newlines when the SFU container reads its env.
if [[ -n "$SFU_SIGNING_PUBLIC_KEY" ]]; then
	SFU_SIGNING_PUBLIC_KEY="${SFU_SIGNING_PUBLIC_KEY//$'\n'/\\n}"
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
export EXTERNAL_IP_LINE

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
fetch_tpl hysteria2-client.yaml.tpl "$stage/hysteria2-client.yaml.tpl"
fetch_tpl naive-client.json.tpl     "$stage/naive.tpl"

# Static assets bundle. cover/ is bind-mounted by docker-compose (./cover:/srv/cover:ro)
# and read by Caddy file_server when serving the DPI-probe decoy on GET /.
# Forgetting to ship it = silent 404 on the partner root URL (regression seen 2026-04-20).
mkdir -p "$stage/cover"
fetch_tpl cover/cover.html "$stage/cover/cover.html"

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
# render_template (channel-render-lib.sh) calls python3 as a subprocess and
# reads template placeholders from ambient env. Every {{VAR}} placeholder in
# the 6 .tpl files must therefore be exported. Co-located here so the export
# list is easy to audit against the placeholder set. Previously these were
# passed as `VAR=val python3 -c '...'` env prefix inside the deleted local
# render() function.
PARTNER_DOMAIN="$DOMAIN"
export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
       TURN_SECRET \
       REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
       REALITY_ENCRYPTION TURNS_SUBDOMAIN \
       PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE \
       IMAGE_VERSION \
       SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID \
       OTEL_EXPORTER_OTLP_ENDPOINT \
       SFU_SIGNING_PUBLIC_KEY RELAY_JWT_SECRET SIGNALING_SFU_SECRET
# Phase 3 delegation complete: all 5 stage templates (compose, caddy, xray,
# coturn, naive) now go through render_with_opec_or_fallback. OPEC adds
# per-kind validation (JSON / YAML / balanced-brace / realm directive)
# that catches corrupt renders before docker compose start. bash
# render_template remains as the fallback when opec is not on PATH.
render_with_opec_or_fallback() {
    local kind=$1 src=$2 dst=$3
    if command -v opec >/dev/null 2>&1; then
        opec render "$kind" --tpl "$src" --out "$dst"
    else
        render_template "$src" "$dst"
    fi
}
render_with_opec_or_fallback compose "$stage/compose.tpl" "$compose_out"
render_with_opec_or_fallback caddy   "$stage/caddy.tpl"   "$caddy_out"
# Phase 1: compute sha256 of rendered Caddyfile and substitute __CADDYFILE_SHA__
# placeholder so /canary/config-hash returns the actual hash at runtime.
_rendered_sha=$(sha256sum "$caddy_out" | awk '{print $1}')
sed -i "s|__CADDYFILE_SHA__|${_rendered_sha}|g" "$caddy_out"
render_with_opec_or_fallback xray    "$stage/xray.tpl"    "$xray_out"
render_with_opec_or_fallback coturn  "$stage/coturn.tpl"  "$coturn_out"

# AmneziaWG mesh setup — runs only when the central returned an awg block.
# Builds amneziawg from source, writes /etc/amnezia/amneziawg/awg0.conf
# from the register response, brings up awg-quick@awg0, verifies handshake.
if [[ -n "${AWG_ALLOCATED_IP:-}" && -n "${AWG_MOTHERLY_PUBKEY:-}" && $DRY_RUN -eq 0 ]]; then
	log "[awg] central allocated $AWG_ALLOCATED_IP edge_id=$SFU_EDGE_ID — bringing up awg0"
	install_amneziawg
	configure_amneziawg
elif [[ -z "${AWG_ALLOCATED_IP:-}" ]]; then
	log "[awg] central did not return awg config — running without VPN mesh (legacy path)"
fi
mkdir -p "$cover_out_dir"
install -m 0644 "$stage/cover/cover.html" "$cover_out_dir/cover.html"
# Render CH3 / CH5 if the backend provided the required vars.
# When rendered, activate the corresponding docker compose profile so the
# service starts alongside the core stack (docker compose --profile ch3 up).
COMPOSE_PROFILES_EXTRA=""
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
	# Dead early render removed (T2/T3 NIT): re_render_hysteria2 at ~L1555
	# fetches HY2_AUTH_PASS/HY2_OBFS_PASS from the API then overwrites this
	# file, so this first-pass output was never read by any service.
	# channel-render-lib.sh is already sourced unconditionally at L766-776.
	COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch3"
	log "  hysteria2 CH3 profile enabled (credentials provisioned by re_render_hysteria2 below)"
fi
# Phase 1.7 — fetch shared hy2 credentials + render hysteria2-client.yaml.
# For Phase 1 these are fleet-shared (per-edge identity = Phase 7).
# Source: GET /api/partner/hy2-credentials returns JSON {auth_pass, obfs_pass}
# Falls back to env if API not yet deployed (HTTP 404 / connection refused).
# channel-render-lib.sh (including re_render_hysteria2) is already in scope —
# sourced unconditionally with die-on-missing at L766-776 (T2/T3 NIT: redundant
# source block removed from here).
if declare -f re_render_hysteria2 >/dev/null 2>&1; then
	log "fetching hy2 credentials"
	_hy2_creds_url="${BACKEND_API}/api/partner/hy2-credentials"
	_hy2_creds_json=$(curl -fsS --max-time 10 \
		-H "Authorization: Bearer ${OXPULSE_SERVICE_TOKEN:-}" \
		"$_hy2_creds_url" 2>/dev/null || echo '{}')
	HY2_AUTH_PASS=$(printf '%s' "$_hy2_creds_json" | jq -r '.auth_pass // empty' 2>/dev/null || true)
	HY2_OBFS_PASS=$(printf '%s' "$_hy2_creds_json" | jq -r '.obfs_pass // empty' 2>/dev/null || true)
	unset _hy2_creds_url _hy2_creds_json
	# Fallback: env vars (for offline install / pre-API-deploy)
	HY2_AUTH_PASS="${HY2_AUTH_PASS:-${OXPULSE_HY2_AUTH_PASS:-}}"
	HY2_OBFS_PASS="${HY2_OBFS_PASS:-${OXPULSE_HY2_OBFS_PASS:-}}"
	if [[ -n "$HY2_AUTH_PASS" && -n "$HY2_OBFS_PASS" ]]; then
		export HY2_AUTH_PASS HY2_OBFS_PASS OXPULSE_REPO_DIR="$stage"
		re_render_hysteria2
		COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch3"
		log "hy2 channel provisioned"
	else
		warn "hy2 credentials unavailable — installing awg-only mode (hy2 will provision on next upgrade)"
	fi
fi
if [[ -n "${NAIVE_SERVER:-}" ]]; then
	render_with_opec_or_fallback naive "$stage/naive.tpl" "$PREFIX_ETC/naive-client.json"
	chmod 0600 "$PREFIX_ETC/naive-client.json"
	COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch5"
	log "  naive-client.json rendered (CH5 profile enabled)"
fi
rm -rf "$stage"

# Secrets-containing files → 0600.
chmod 0600 "$xray_out" "$coturn_out" || true
log "  rendered → $compose_out (+ Caddyfile, xray-client.json, coturn.conf, cover/cover.html)"

# Phase 3: create conf.d/ override slot. mkdir -p only — never touch files inside.
# Operator-side *.caddy files survive install.sh reruns; Caddyfile.tpl imports them at the end.
if [[ $DRY_RUN -eq 0 ]]; then
	install -d -m 0755 "$PREFIX_ETC/conf.d"
	# Write README only if it does not exist (idempotent; preserves operator edits).
	if [[ ! -f "$PREFIX_ETC/conf.d/README.txt" ]]; then
		cat > "$PREFIX_ETC/conf.d/README.txt" << 'CONFD_README'
oxpulse-partner-edge — conf.d/ override slot
==========================================

Files matching *.caddy in this directory are loaded by Caddy AFTER the
rendered Caddyfile (via `import /etc/oxpulse-partner-edge/conf.d/*.caddy`).

Survival guarantee
------------------
install.sh, update.sh, and upgrade.sh --with-templates NEVER modify files
inside conf.d/. Your overrides survive every re-run and image upgrade.

File naming convention
----------------------
  <tenant>-<purpose>.caddy
Examples:
  cheburator-vhosts.caddy   — cheburator.bot + www.cheburator.bot vhosts
  cheburator-webhook.caddy  — webhook proxy to internal service
  emergency-patch.caddy     — hotfix that must survive next upgrade

Drift check
-----------
  install.sh --check
Re-renders templates and diffs vs installed Caddyfile + docker-compose.yml.
conf.d/ files are excluded from the diff (they are operator-managed).
Exit codes: 0=clean, 1=Caddyfile drift, 2=compose drift.

See docs/runbooks/conf-d.md for full guidance and worked examples.
CONFD_README
	fi
	warn "  conf.d/ slot ready ($PREFIX_ETC/conf.d/) — drop *.caddy files here for persistent overrides"
else
	warn "  [dry-run] would create $PREFIX_ETC/conf.d/ override slot"
fi

# ---------- Step 5b: provision DB-IP mmdb (M2b.2) ----------
# Downloads dbip-country-lite-{YYYY-MM}.mmdb.gz from db-ip.com (CC-BY 4.0,
# no API key required). Caddy's maxmind_geolocation handler reads this file
# to inject X-Geo-Country into upstream requests (oxpulse-chat #748).
# Non-fatal: if the download fails, Caddy starts without geolocation; the
# Rust fallback chain (X-Client-Region → CF-IPCountry → in-process GeoDb)
# covers the gap until the monthly timer succeeds.
if [[ $DRY_RUN -eq 0 ]]; then
	log "[5b/10] provisioning DB-IP mmdb"
	if [[ -n "$src_dir" && -f "$src_dir/scripts/oxpulse-geoip-refresh.sh" ]]; then
		install -m 0755 "$src_dir/scripts/oxpulse-geoip-refresh.sh" \
			"$PREFIX_SBIN/oxpulse-geoip-refresh"
	else
		curl -fsSL "$REPO_RAW/scripts/oxpulse-geoip-refresh.sh" \
			-o "$PREFIX_SBIN/oxpulse-geoip-refresh"
		chmod 0755 "$PREFIX_SBIN/oxpulse-geoip-refresh"
	fi
	# Run initial download; warn-only on failure.
	if "$PREFIX_SBIN/oxpulse-geoip-refresh"; then
		log "  DB-IP mmdb provisioned → /var/lib/geoip/dbip-country-lite.mmdb"
	else
		warn "  DB-IP mmdb download failed — maxmind_geolocation will be a no-op until geoip-refresh.timer succeeds"
	fi
else
	warn "  [dry-run] skipping DB-IP mmdb download"
fi

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
	# Phase 1: record sha256 of rendered Caddyfile for drift detection.
	# healthcheck.sh check 15 compares this against /canary/config-hash.
	_caddy_sha="$_rendered_sha"  # reuse hash computed before substitution (drift-safe)
	printf 'CADDYFILE_SHA=%s\n' "$_caddy_sha" >> "$PREFIX_LIB/install.env"
fi

# ---------- Step 6: start ----------
log "[6/10] starting services"
if [[ $DRY_RUN -eq 0 ]]; then
	# Pass extra profiles (ch3, ch5) when bypass channels were provisioned.
	if [[ -n "${COMPOSE_PROFILES_EXTRA:-}" ]]; then
		(cd "$PREFIX_ETC" && COMPOSE_PROFILES="$COMPOSE_PROFILES_EXTRA" docker compose --profile "$COMPOSE_PROFILES_EXTRA" up -d)
	else
		(cd "$PREFIX_ETC" && docker compose up -d)
	fi
else
	warn "  [dry-run] would: docker compose up -d (profiles: ${COMPOSE_PROFILES_EXTRA:-none})"
fi

# ---------- Step 7: healthcheck ----------
log "[7/10] waiting for healthcheck (timeout ${HEALTHCHECK_TIMEOUT}s)"
if [[ $DRY_RUN -eq 0 ]]; then
	deadline=$(( $(date +%s) + HEALTHCHECK_TIMEOUT ))
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
	elif [[ -n "${_chan_lib_tmp:-}" && -f "$_chan_lib_tmp" ]]; then
		install -m 0644 "$_chan_lib_tmp" "$PREFIX_SBIN/channel-render-lib.sh"
		rm -f "$_chan_lib_tmp"
	else
		curl -fsSL "$REPO_RAW/channel-render-lib.sh" -o "$PREFIX_SBIN/channel-render-lib.sh"
		chmod 0644 "$PREFIX_SBIN/channel-render-lib.sh"
	fi

	# GHCR auth lib into /usr/local/sbin (sourced by upgrade.sh).
	if [[ -n "$src_dir" && -f "$src_dir/ghcr-auth-lib.sh" ]]; then
		install -m 0644 "$src_dir/ghcr-auth-lib.sh" "$PREFIX_SBIN/ghcr-auth-lib.sh"
	else
		curl -fsSL "$REPO_RAW/ghcr-auth-lib.sh" -o "$PREFIX_SBIN/ghcr-auth-lib.sh"
		chmod 0644 "$PREFIX_SBIN/ghcr-auth-lib.sh"
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
	# xray auto-update timer (mirrors SFU pattern; script lives in /usr/local/bin/)
	if [[ -n "$src_dir" && -f "$src_dir/scripts/oxpulse-xray-update.sh" ]]; then
		install -m 0755 "$src_dir/scripts/oxpulse-xray-update.sh" \
			"/usr/local/bin/oxpulse-xray-update.sh"
	else
		curl -fsSL "$REPO_RAW/scripts/oxpulse-xray-update.sh" \
			-o "/usr/local/bin/oxpulse-xray-update.sh"
		chmod 0755 "/usr/local/bin/oxpulse-xray-update.sh"
	fi
	for unit in oxpulse-xray-update.service oxpulse-xray-update.timer; do
		if [[ -n "$src_dir" && -f "$src_dir/systemd/${unit}" ]]; then
			install -m 0644 "$src_dir/systemd/${unit}" "$SYSTEMD_DIR/${unit}"
		else
			curl -fsSL "$REPO_RAW/systemd/${unit}" -o "$SYSTEMD_DIR/${unit}"
		fi
	done
	# M2b.2: monthly geoip-refresh timer (DB-IP mmdb for Caddy maxmind_geolocation).
	# Script already placed into PREFIX_SBIN by Step 5b; only units land here.
	for unit in oxpulse-geoip-refresh.service oxpulse-geoip-refresh.timer; do
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
		systemctl enable --now oxpulse-xray-update.timer
		systemctl enable --now oxpulse-geoip-refresh.timer
	else
		# Bake mode: enable hydrate so it fires on first boot after snapshot→clone.
		# Do NOT start it now — secrets aren't present yet.
		systemctl enable oxpulse-partner-edge-hydrate.service
		systemctl enable oxpulse-partner-edge-refresh.timer
		systemctl enable oxpulse-partner-edge-sni-rotate.timer
		systemctl enable oxpulse-xray-update.timer
		systemctl enable oxpulse-geoip-refresh.timer
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
