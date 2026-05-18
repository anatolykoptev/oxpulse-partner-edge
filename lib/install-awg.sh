#!/usr/bin/env bash
# lib/install-awg.sh — Phase 4.10 extracted from install.sh.
#
# Builds amneziawg from source (Go 1.24+, kmod-free userspace impl) and
# renders /etc/amnezia/amneziawg/awg0.conf from caller-supplied AWG_* globals.
#
# Exports:
#   install_amneziawg     — idempotent build of amneziawg-go + amneziawg-tools
#   configure_amneziawg   — render awg0.conf + bring up interface
#   awg_extract           — parse key from JSON file (used by Step 4 in install.sh)
#
# Requires (caller globals):
#   AWG_PRIV_PATH AWG_PUB_PATH          private/public key file paths
#   AWG_MOTHERLY_PUBKEY                 motherly node's pubkey
#   AWG_MOTHERLY_ENDPOINT               host:port for motherly
#   AWG_MOTHERLY_AWG_IP                 motherly's AWG IP (peer AllowedIPs)
#   AWG_ALLOCATED_IP                    this edge's allocated AWG /32
#   AWG_JC AWG_JMIN AWG_JMAX            anti-cens jitter params
#   AWG_S1 AWG_S2 AWG_S4                pcap-fingerprint protection
#   AWG_H1 AWG_H2 AWG_H3 AWG_H4         packet-header hashes
#   log warn die                        functions (install.sh provides)
#
# Optional overrides (test hooks):
#   AWG_GO_VERSION         default 1.24.4
#   AWG_GO_DL_BASE         default https://go.dev/dl
#   AWG_GO_BIN_PATH        default /usr/local/go/bin/go — test hook for version check
#   AWG_BUILD_ROOT         default $(mktemp -d) — test hook to skip git clone
#   AWG_INSTALL_PREFIX     default /usr/local — test hook to avoid root write
#   AWG_CONF_DIR           default /etc/amnezia/amneziawg
#   AWG_QUICK_BIN          default awg-quick — test hook to mock interface up
#   AWG_LISTEN_PORT        default $((43800 + RANDOM % 200)) — test hook for golden file

install_amneziawg() {
	local _prefix="${AWG_INSTALL_PREFIX:-/usr/local}"
	if [[ -s "${_prefix}/bin/amneziawg-go" && -x /usr/bin/awg-quick ]]; then
		log "  amneziawg already installed (skip)"
		return 0
	fi
	log "  building amneziawg from source (one-time)"
	# amneziawg-go go.mod requires Go >= 1.24. Ubuntu 22.04 apt ships golang 1.18,
	# Debian 12 ships 1.19. Both too old. Install official Go tarball if existing
	# /usr/local/go is missing or below 1.24 — leaves system golang package alone.
	local _go_ver="${AWG_GO_VERSION:-1.24.4}"
	local _go_dl_base="${AWG_GO_DL_BASE:-https://go.dev/dl}"
	local _go_bin="${AWG_GO_BIN_PATH:-/usr/local/go/bin/go}"
	if ! "$_go_bin" version 2>/dev/null | grep -qE "go1\\.(2[4-9]|[3-9][0-9])"; then
		log "    installing Go ${_go_ver} (system golang too old for amneziawg-go)"
		local _go_arch
		case "$(uname -m)" in
			x86_64)  _go_arch=amd64 ;;
			aarch64) _go_arch=arm64 ;;
			*) die "install_amneziawg: unsupported architecture: $(uname -m)" ;;
		esac
		curl -fsSL "${_go_dl_base}/go${_go_ver}.linux-${_go_arch}.tar.gz" -o /tmp/go-amneziawg.tgz \
		  || die "Go ${_go_ver} download failed (need internet at /tmp/go-amneziawg.tgz)"
		rm -rf /usr/local/go
		tar -C /usr/local -xzf /tmp/go-amneziawg.tgz || die "Go tarball extract failed"
		rm -f /tmp/go-amneziawg.tgz
		unset _go_arch
	fi
	export PATH="/usr/local/go/bin:$PATH"
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y git make gcc >/dev/null 2>&1 || \
		  die "dnf install of git/make/gcc failed — install manually then re-run"
	elif command -v apt-get >/dev/null 2>&1; then
		apt-get install -y -q git make gcc >/dev/null 2>&1 || \
		  die "apt-get install of git/make/gcc failed"
	else
		die "no supported package manager for the awg build toolchain"
	fi
	local build_root
	build_root="${AWG_BUILD_ROOT:-$(mktemp -d)}"
	(
		cd "$build_root" && \
		git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-go.git && \
		git clone --depth 1 -q https://github.com/amnezia-vpn/amneziawg-tools.git
	) || die "amneziawg git clone failed"
	(cd "$build_root/amneziawg-go" && make) >/dev/null 2>&1 || die "amneziawg-go build failed"
	install -m 0755 "$build_root/amneziawg-go/amneziawg-go" "${_prefix}/bin/amneziawg-go"
	(cd "$build_root/amneziawg-tools/src" && make && make install) >/dev/null 2>&1 || \
	  die "amneziawg-tools build failed"
	rm -rf "$build_root"
}

# Render /etc/amnezia/amneziawg/awg0.conf from the register response and
# bring the interface up. Reads AWG_* vars set by the json_get block after
# registration, plus AWG_PRIV_PATH from earlier in install.sh.
configure_amneziawg() {
	local _conf_dir="${AWG_CONF_DIR:-/etc/amnezia/amneziawg}"
	local conf_path="$_conf_dir/awg0.conf"
	install -d -m 0700 "$_conf_dir"
	# ListenPort is intentionally a high random — outbound only, NAT-traversed
	# via PersistentKeepalive, no inbound peer dials this edge directly. We
	# pick a fresh port at install time so two edges on the same NAT don't
	# collide.
	local listen_port="${AWG_LISTEN_PORT:-$((43800 + RANDOM % 200))}"
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

awg_extract() {
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); a=d.get('awg') or {}; print(a.get(sys.argv[2],''))" "$1" "$2" 2>/dev/null
}
