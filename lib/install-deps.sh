#!/usr/bin/env bash
# lib/install-deps.sh — Phase 4.1 extracted from install.sh Step 1b'/Step 2.
#
# Exports: deps_install
#
# Requires (caller globals):
#   OS_FAMILY      'debian' or 'rhel'
#   DRY_RUN        int
#   log warn die   functions

deps_install() {
	if [[ $DRY_RUN -eq 0 ]]; then
		local _pkg
		for _pkg in jq curl python3; do
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
		# PyYAML (python3 yaml module) — required by compose-strip logic (Phase 5.5
		# BLOCKER 1 fix). Checked via import, not command -v, since it is a module.
		if ! python3 -c "import yaml" 2>/dev/null; then
			log "  installing missing runtime dep: python3-yaml (PyYAML)"
			if [[ $OS_FAMILY == rhel ]]; then
				dnf install -y python3-pyyaml >/dev/null 2>&1 \
					|| die "dnf install python3-pyyaml failed — install manually then re-run"
			else
				apt-get install -y -q python3-yaml >/dev/null 2>&1 \
					|| die "apt-get install python3-yaml failed"
			fi
		fi
	fi

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

	_deps_configure_docker_logging
}

# Configure Docker daemon logging policy so container logs cannot fill disk.
# Default Docker policy is unlimited json-file logs; under steady traffic
# the caddy access log alone grows ~5MB/hour on a busy partner edge and
# fills / over weeks. Apply a 10MB/file x 3 file rotation policy --
# capped total per-container at 30MB. Idempotent: skip if daemon.json
# already sets log-driver.
_deps_configure_docker_logging() {
	if [[ $DRY_RUN -ne 0 ]]; then
		log "  [deps] [dry-run] would write /etc/docker/daemon.json log rotation policy"
		return 0
	fi
	local cfg=/etc/docker/daemon.json
	if [[ -f "$cfg" ]] && grep -q '"log-driver"' "$cfg"; then
		log "  [deps] /etc/docker/daemon.json already sets log-driver -- skipping"
		return 0
	fi
	mkdir -p /etc/docker
	if [[ -f "$cfg" ]]; then
		cp "$cfg" "${cfg}.bak.$(date +%s)"
	fi
	cat >"$cfg" <<JSON
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  }
}
JSON
	log "  [deps] wrote /etc/docker/daemon.json (json-file, max-size=10m, max-file=3)"
	# New policy applies only to containers created AFTER daemon reload.
	# Compose up at the end of install.sh recreates everything, so the new
	# policy reaches all partner-edge containers in the same install run.
	if systemctl is-active --quiet docker 2>/dev/null; then
		systemctl reload docker 2>/dev/null \
			|| warn "    systemctl reload docker failed -- policy applies to next-created containers only"
	fi
}
