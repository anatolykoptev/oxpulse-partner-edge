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
}
