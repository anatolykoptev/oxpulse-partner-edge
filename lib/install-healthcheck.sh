#!/usr/bin/env bash
# lib/install-healthcheck.sh — Phase 4.6 extracted from install.sh Step 7.
#
# Exports: healthcheck_run
#
# Requires (caller globals):
#   DRY_RUN              int, skip side-effecting branches when 1
#   HEALTHCHECK_TIMEOUT  int, poll deadline in seconds
#   PREFIX_SBIN          path, e.g. /usr/local/sbin
#   PREFIX_ETC           path, docker-compose project dir
#   src_dir              string, local checkout dir (empty when curl|bash)
#   REPO_RAW             string, raw GitHub URL base for fallback fetches
#   TURNS_SUBDOMAIN      string, e.g. api-test01
#   DOMAIN               string, e.g. example.net
#   log warn die         functions (install.sh provides)

# Install healthcheck.sh into $PREFIX_SBIN.
# Prefers a local copy from $src_dir; falls back to fetching from $REPO_RAW.
_healthcheck_install_script() {
	local hc_script="$PREFIX_SBIN/oxpulse-partner-edge-healthcheck"
	if [[ -n "$src_dir" && -f "$src_dir/healthcheck.sh" ]]; then
		install -m 0755 "$src_dir/healthcheck.sh" "$hc_script"
	else
		curl -fsSL "$REPO_RAW/healthcheck.sh" -o "$hc_script"
		chmod 0755 "$hc_script"
	fi
}

# Poll for the TURNS TLS certificate; restart coturn once it appears.
# coturn starts before Caddy finishes the ACME dance for the TURNS subdomain,
# so its TLS listener is disabled on first boot (cert file missing). Once Caddy
# obtains the cert the cert-watch.path sends SIGUSR2 for subsequent renewals,
# but the initial kick must come from install.sh — otherwise :5349 stays
# silent until the first real renewal months later.
_healthcheck_wait_turns_cert() {
	local turns_cert_dir="/var/lib/docker/volumes/oxpulse-partner-edge_caddy-data/_data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/${TURNS_SUBDOMAIN}.${DOMAIN}"
	local turns_cert_deadline turns_cert_ready
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
}

# Poll healthcheck.sh --local until it returns 0 or the deadline is reached.
_healthcheck_poll() {
	local hc_script="$PREFIX_SBIN/oxpulse-partner-edge-healthcheck"
	local deadline
	deadline=$(( $(date +%s) + HEALTHCHECK_TIMEOUT ))
	while :; do
		if OXPULSE_EDGE_CONFIG_DIR="$PREFIX_ETC" "$hc_script" --local >/dev/null 2>&1; then
			log "  healthcheck green"
			break
		fi
		if (( $(date +%s) > deadline )); then
			warn "  healthcheck still red after ${HEALTHCHECK_TIMEOUT}s — continuing, inspect with: $hc_script"
			warn "  SFU containers commonly take 30-60s after first deploy; re-run '$hc_script' manually after 60s"
			warn "  If your environment is consistently slow, re-install with --healthcheck-timeout=600"
			break
		fi
		sleep 3
	done
}

healthcheck_run() {
	log "[7/10] waiting for healthcheck (timeout ${HEALTHCHECK_TIMEOUT}s)"
	if [[ $DRY_RUN -eq 0 ]]; then
		_healthcheck_install_script
		_healthcheck_wait_turns_cert
		_healthcheck_poll
	else
		warn "  [dry-run] skipping healthcheck"
	fi
}
