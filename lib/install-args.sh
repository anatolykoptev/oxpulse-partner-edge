#!/usr/bin/env bash
# lib/install-args.sh — Phase 4.9 extracted from install.sh L216-595.
#
# Exports: args_parse
#
# Requires (caller globals):
#   PREFIX_ETC   path, e.g. /etc/oxpulse-partner-edge
#   PREFIX_LIB   path, e.g. /var/lib/oxpulse-partner-edge
#   BACKEND_API  string, e.g. https://api.oxpulse.chat
#   REPO_RAW     string, raw GitHub URL base (used in --check mode template fetch)
#   log warn die functions (install.sh provides)
#
# Exports globals into caller scope (bash function, same shell):
#   DOMAIN, PARTNER_ID, TOKEN, TOKEN_FILE, TUNNEL, MANUAL_CONFIG
#   IMAGE_VERSION, TURNS_SUBDOMAIN, SFU_UDP_PORT, SFU_METRICS_PORT, SFU_EDGE_ID
#   REGION, HEALTHCHECK_TIMEOUT, BRANDING_CONFIG, GHCR_TOKEN_FLAG
#   BRAND_DISPLAY_NAME, BRAND_DESCRIPTION, BRAND_COLOR_PRIMARY,
#   BRAND_COLOR_SECONDARY, BRAND_COLOR_ACCENT, BRAND_COLOR_ON_PRIMARY,
#   BRAND_LOGO_LIGHT, BRAND_LOGO_DARK, BRAND_FAVICON, BRAND_OG_IMAGE,
#   BRAND_CO_BRAND, BRAND_CANONICAL, BRAND_WORDMARK,
#   BRAND_HERO_TITLE, BRAND_HERO_TITLE_RU, BRAND_HERO_TITLE_EN,
#   BRAND_HERO_TITLE_ZH, BRAND_HERO_TITLE_FA,
#   BRAND_CTA_URL, BRAND_CTA_TEXT,
#   BRAND_CTA_URL_RU, BRAND_CTA_URL_EN, BRAND_CTA_URL_ZH, BRAND_CTA_URL_FA,
#   BRAND_CTA_TEXT_RU, BRAND_CTA_TEXT_EN, BRAND_CTA_TEXT_ZH, BRAND_CTA_TEXT_FA,
#   BRAND_LEGAL_ENTITY, BRAND_LEGAL_COUNTRY, BRAND_LEGAL_CONTACT,
#   DRY_RUN, BAKE_MODE, CHECK_MODE, FORCE_KEYGEN, CLEAN_SBIN, SERVE_COUNTRIES, PROFILE,
#   ALLOW_DEGRADED, NO_INTEGRITY

_args_usage() {
	sed -n '2,18p' "$0" >&2
	cat >&2 <<USAGE

Required:
  --domain=<fqdn>            Partner edge domain (must resolve to this host's public IP)
  --partner-id=<id>          Short partner identifier (e.g. edge-c, relay-x)

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
  --serve-countries=<ISO1,ISO2,...>  Comma-separated client countries this edge serves
                             (e.g. --serve-countries=RU,BY). Operator-declared,
                             upper-folded server-side. Optional — falls back to
                             MaxMind country of public_ip.
  --profile=<russia>         Deployment profile. Currently accepted: "russia".
                             Activates RU-profile extras (split-routing) on top of the
                             base install. Omit for standard partner-edge installs.

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
  --brand-co-brand=<name>          Co-brand label, e.g. "Edge-a"
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
  --no-integrity             Skip tier-4 lib checksum validation when no local lib-checksums.txt is available.
                             Use when installing from a private fork or airgapped environment without a release tarball.
                             Implies you accept the risk that fetched libs cannot be verified.
  --allow-degraded           Exit 0 even when a core healthcheck failed (degraded-but-running node).
                             Provided for non-interactive callers that may intentionally proceed
                             on a degraded node; no caller passes it today (upgrade.sh has its own
                             converge engine and does not invoke install.sh). A human running
                             install.sh by hand should NOT set this — a non-zero exit is the signal
                             that the install did not really work. (env: OXPULSE_ALLOW_DEGRADED=1)
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
	# --help/-h is the one command a stranger runs first; a non-zero exit
	# breaks wrappers/Makefiles/CI that shell out to `install.sh --help`.
	# The missing-required-arg path uses die() (exit 1), so exit 0 here is
	# unambiguous and does not collide with any other exit code.
	exit 0
}

args_parse() {
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
	# how edge-a wound up running an unpinned partner-edge-sfu on prod.
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
	# Comma-separated client countries this edge serves (e.g. RU,BY). Absent = derive from MaxMind.
	SERVE_COUNTRIES="${SERVE_COUNTRIES:-}"
	# Deployment profile. Empty = standard install. "russia" activates split-routing extras.
	PROFILE="${PROFILE:-}"
	# Step 7 healthcheck loop deadline (seconds). ACME first-issuance can
	# legitimately take 2–4 minutes when DNS is slow to propagate or the LE
	# rate limiter throttles; 120 was too tight on edge-a.example and
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
	# Phase 5.7 Item 5: when 1, remove stale sbin scripts not in EXPECTED_SBIN_FILES.
	# Off by default — no surprise data-loss. Set to 1 via --clean-sbin.
	CLEAN_SBIN=0
	# BLOCKER 1 review-fix: tier-4 lib fetch fails closed when no local checksums
	# file is available AND the remote checksums fetch also fails.
	# Pass --no-integrity to explicitly acknowledge the risk and allow installation
	# without checksum validation (e.g. from a private fork or airgapped network).
	# Default 0 = fail-closed. Set to 1 via --no-integrity.
	NO_INTEGRITY=0
	# F2 honest-exit: when 1, the installer exits 0 even if a core healthcheck
	# failed (degraded-but-running node).  Provided so non-interactive callers
	# that may intentionally proceed on a degraded node are not broken by the
	# non-zero exit on core failure; no caller passes it today (upgrade.sh has
	# its own converge engine and does not invoke install.sh).  Set via
	# --allow-degraded or OXPULSE_ALLOW_DEGRADED=1.
	ALLOW_DEGRADED="${OXPULSE_ALLOW_DEGRADED:-0}"

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
			--serve-countries=*) SERVE_COUNTRIES="${1#*=}" ;;
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
			--profile=*)        PROFILE="${1#*=}" ;;
			--check)            CHECK_MODE=1 ;;
			--dry-run)          DRY_RUN=1 ;;
			--bake)             BAKE_MODE=1 ;;
			--force-keygen|--rotate-identity) FORCE_KEYGEN=1 ;;
			--clean-sbin)       CLEAN_SBIN=1 ;;
			--no-integrity)     NO_INTEGRITY=1 ;;
			--allow-degraded)   ALLOW_DEGRADED=1 ;;
			-h|--help)          _args_usage ;;
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
	local brand_flag_set=0
	local v
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
	case "${PROFILE:-}" in
		""|russia) : ;;
		*) die "--profile must be one of: russia (got: ${PROFILE})" ;;
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
		local _check_dir
		_check_dir=$(mktemp -d)
		trap 'rm -rf "$_check_dir"' RETURN

		# Determine template source: local checkout (detect from $0) or REPO_RAW fetch.
		# src_dir is not set yet at --check early-exit point; detect from BASH_SOURCE.
		local _check_src_dir=""
		local _check_self="${BASH_SOURCE[0]:-}"
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
		local _check_sha
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

		local _rc=0
		local _caddy_installed="$PREFIX_ETC/Caddyfile"
		local _compose_installed="$PREFIX_ETC/docker-compose.yml"
		local _confd_dir="$PREFIX_ETC/conf.d"
		local _confd_count=0
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
}
