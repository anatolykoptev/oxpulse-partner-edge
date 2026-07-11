#!/usr/bin/env bash
# lib/install-preflight.sh — Phase 4.1 extracted from install.sh Step 1/1b/1c.
#
# Exports: preflight_run
#
# Requires (caller globals):
#   OS_ID OS_FAMILY    set by this function
#   DRY_RUN            int, skip side-effecting branches when 1
#   SFU_UDP_PORT       int
#   SFU_METRICS_PORT   int
#   log warn die       functions (install.sh provides)
#
# Optional overrides (test hooks):
#   OS_RELEASE_PATH    default /etc/os-release

preflight_run() {
	local os_release_path="${OS_RELEASE_PATH:-/etc/os-release}"
	log "[1/10] preflight checks"
	OS_ID=""; OS_FAMILY=""
	if [[ -r "$os_release_path" ]]; then
		# shellcheck source=/dev/null
		. "$os_release_path"
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
		local owned_by_oxpulse=0
		if command -v docker >/dev/null 2>&1 \
			&& docker ps --filter 'name=oxpulse-partner-' --format '{{.Names}}' 2>/dev/null \
			| grep -q .; then
			owned_by_oxpulse=1
		fi
		_preflight_check_port_free() {
			local port=$1 proto=$2
			ss -ln"${proto}" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" || return 0
			if [[ $owned_by_oxpulse -eq 1 ]]; then
				warn "port $port/$proto held by existing oxpulse-partner-* container — re-install path, continuing"
				return 0
			fi
			die "port $port/$proto is already in use — free it before installing"
		}
		local p
		for p in 80 443 3478 5349 "$SFU_METRICS_PORT"; do _preflight_check_port_free "$p" t; done
		_preflight_check_port_free 3478 u
		# M2.1: str0m SFU media port (UDP). Default 7878 avoids coturn's 3478.
		_preflight_check_port_free "$SFU_UDP_PORT" u
		log "  ports 80/443/3478/5349/${SFU_UDP_PORT}(udp)/${SFU_METRICS_PORT}(tcp) preflight done (oxpulse-owned=${owned_by_oxpulse})"
	fi

	_preflight_cleanup_ghost_containers
	_preflight_firewall
	_preflight_low_memory_swap
	_preflight_dnf_cache_sanity
}

# Strip "ghost" partner-edge containers — those created by an out-of-band
# `docker run` (no compose labels, no RestartPolicy) using one of OUR images.
# Without this, prior debug runs / aborted installer attempts can leave
# orphan naive/xray-client/etc. containers consuming memory and network
# resources; the operator has no easy signal they exist. The 2026-05-21
# audit found 5 such ghost naive containers across the live fleet
# (4 on edge-b, 1 on edge-c).
#
# Safe-by-construction filter:
#   1. Image must be ghcr.io/anatolykoptev/partner-edge-* (one of ours).
#   2. com.docker.compose.project label must be EMPTY (compose-managed
#      containers always carry this label).
#   3. RestartPolicy MUST be "no" (compose containers use unless-stopped /
#      always; legitimate run-once containers have explicit reason to exist).
#
# Any container matching all three is a ghost — remove it.
_preflight_cleanup_ghost_containers() {
	if ! command -v docker >/dev/null 2>&1 || [[ $DRY_RUN -ne 0 ]]; then
		return 0
	 fi
	local ghosts cnt
	ghosts=$(docker ps -a \
		--filter 'label=com.docker.compose.project=' \
		--format '{{.Names}}\t{{.Image}}\t{{.Status}}' 2>/dev/null \
		| awk '$2 ~ /^ghcr\.io\/anatolykoptev\/partner-edge-/' || true)
	if [[ -z "$ghosts" ]]; then return 0; fi

	while IFS=$'\t' read -r name image _status; do
		[[ -z "$name" ]] && continue
		# Belt-and-suspenders — confirm RestartPolicy=no before remove.
		local pol
		pol=$(docker inspect "$name" --format '{{.HostConfig.RestartPolicy.Name}}' 2>/dev/null || echo "")
		if [[ "$pol" != "no" && "$pol" != "" ]]; then
			log "  [preflight] skip $name — RestartPolicy=$pol (not a ghost)"
			continue
		fi
		log "  [preflight] removing ghost container $name ($image)"
		docker rm -f "$name" >/dev/null 2>&1 || warn "    docker rm $name failed (ignoring)"
		cnt=$((${cnt:-0} + 1))
	done <<< "$ghosts"
	if [[ -n "${cnt:-}" ]]; then
		log "  [preflight] removed ${cnt} ghost container(s)"
	fi
}

_preflight_firewall() {
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
	local fw_specs=(80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp \
		"${SFU_UDP_PORT}/udp" "${SFU_METRICS_PORT}/tcp")

	if [[ $DRY_RUN -eq 0 ]] \
		&& command -v firewall-cmd >/dev/null 2>&1 \
		&& systemctl is-active --quiet firewalld; then
		log "[1b] opening firewalld ports"
		local fw_added=0 spec
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
		local spec
		for spec in "${fw_specs[@]}"; do
			# ufw allow takes "<port>/<proto>" directly; idempotent on identical rules.
			ufw allow "$spec" >/dev/null
			log "  + $spec"
		done
	fi
}


_preflight_low_memory_swap() {
	# On low-memory edges (<1.5 GiB total) dnf makecache + image pulls regularly
	# OOM-kill mid-install (incident 2026-05-20 edge-a: 951 MiB RAM, dnf
	# anon-rss 502 MiB, no swap headroom -> killed at preflight). Add a 1 GiB
	# temp swapfile if neither total RAM nor existing swap clears the floor.
	[[ $DRY_RUN -ne 0 ]] && return 0
	local mem_total_mib swap_total_mib
	mem_total_mib=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
	swap_total_mib=$(awk '/^SwapTotal:/ {print int($2/1024)}' /proc/meminfo 2>/dev/null || echo 0)
	local headroom_mib=$((mem_total_mib + swap_total_mib))
	if (( headroom_mib >= 1536 )); then
		return 0
	fi
	local swapfile=/var/lib/oxpulse-partner-edge.swap
	if swapon --show=NAME --noheadings 2>/dev/null | grep -qx "$swapfile"; then
		log "  low-mem swap already active at $swapfile (mem=${mem_total_mib}MiB swap=${swap_total_mib}MiB)"
		return 0
	fi
	local size_mib=$(( 1536 - headroom_mib + 256 ))   # extra 256 MiB headroom
	(( size_mib < 512 )) && size_mib=512
	log "  low memory (${mem_total_mib}MiB RAM + ${swap_total_mib}MiB swap) -> adding ${size_mib}MiB temp swap at $swapfile"
	# Stale-file safety: a previous install or reboot may have left an inactive
	# file at $swapfile. Truncating it with dd while kernel still maps zero
	# pages would corrupt swap. Belt-and-braces: swapoff first (no-op if not
	# active), then atomic-replace the file via fallocate which errors upfront
	# on ENOSPC rather than half-writing.
	swapoff "$swapfile" 2>/dev/null || true
	rm -f "$swapfile"
	if ! fallocate -l "${size_mib}M" "$swapfile" 2>/dev/null; then
		# fallocate not available on every fs (e.g. tmpfs); fall back to dd.
		if ! dd if=/dev/zero of="$swapfile" bs=1M count="$size_mib" status=none 2>/dev/null; then
			warn "  swapfile allocation failed; continuing without swap (dnf may OOM)"
			rm -f "$swapfile"
			return 0
		fi
	fi
	chmod 600 "$swapfile"
	if ! mkswap "$swapfile" >/dev/null 2>&1 || ! swapon "$swapfile" 2>/dev/null; then
		warn "  swapfile activation failed; continuing without swap (dnf may OOM)"
		rm -f "$swapfile"
		return 0
	fi
	if ! grep -qF "$swapfile" /etc/fstab 2>/dev/null; then
		printf '%s none swap sw 0 0
' "$swapfile" >> /etc/fstab
	fi
	log "  swap active: $(swapon --show=NAME,SIZE --noheadings 2>/dev/null | head -3 | tr '
' ';' )"
}

_preflight_dnf_cache_sanity() {
	# Some VPS providers (e.g. fvds.ru / hoztnode) ship images where every
	# `metalink=` and `baseurl=` line in /etc/yum.repos.d/centos.repo is
	# commented out, expecting the operator to wire in a private mirror.
	# `dnf install` then fails with the unhelpful "Cannot find a valid
	# baseurl for repo: baseos" deep inside get.docker.com — confusing and
	# hard to debug. Detect early and re-enable the official metalink.
	if [[ $DRY_RUN -eq 0 && $OS_FAMILY == rhel ]] && command -v dnf >/dev/null 2>&1; then
		if ! dnf -q makecache --setopt=metadata_expire=0 >/dev/null 2>&1; then
			warn "  dnf makecache failed — checking for commented metalinks in /etc/yum.repos.d"
			local repaired=0 f
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
}
