#!/usr/bin/env bash
# lib/install-runtime.sh — Phase 4.5 extracted from install.sh Step 5b + install.env + Step 6.
#
# Exports: runtime_run
#
# Reads (caller globals):
#   DRY_RUN, src_dir, REPO_RAW, PREFIX_SBIN, PREFIX_LIB, PREFIX_ETC,
#   PARTNER_ID, DOMAIN, NODE_ID, TUNNEL, IMAGE_VERSION, TURNS_SUBDOMAIN,
#   _rendered_sha, COMPOSE_PROFILES_EXTRA (optional)
# Uses: log, warn, die (install.sh helpers; die MUST exit)

runtime_run() {
	_runtime_provision_mmdb
	_runtime_persist_install_env
	_runtime_compose_up
}

_runtime_provision_mmdb() {
	if [[ $DRY_RUN -eq 0 ]]; then
		log "[5b/10] provisioning DB-IP mmdb"
		if [[ -n "${src_dir:-}" && -f "$src_dir/scripts/oxpulse-geoip-refresh.sh" ]]; then
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
}

_runtime_persist_install_env() {
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
		printf 'CADDYFILE_SHA=%s\n' "${_rendered_sha:-}" >> "$PREFIX_LIB/install.env"
	fi
}

_runtime_compose_up() {
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
}
