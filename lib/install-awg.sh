#!/usr/bin/env bash
# lib/install-awg.sh — Phase 4.10 extracted from install.sh.
#
# Builds amneziawg from source (Go 1.24+, kmod-free userspace impl) and
# renders /etc/amnezia/amneziawg/awg0.conf from caller-supplied AWG_* globals.
#
# Exports:
#   install_amneziawg     — idempotent build of amneziawg-go + amneziawg-tools
#   configure_amneziawg   — render awg0.conf + bring up interface
#   awg_extract           — parse one key from the JSON `awg` block (allocated_ip
#                           stays on this pinned legacy path in install.sh)
#   awg_extract_all       — ONE python3 spawn emitting the full v3 awg-block
#                           surface as NUL-delimited VAR=VALUE records
#                           (install.sh consumes it via a read-loop, no eval)
#
# Requires (caller globals):
#   AWG_PRIV_PATH AWG_PUB_PATH          private/public key file paths
#   AWG_MOTHERLY_PUBKEY                 motherly node's pubkey
#   AWG_MOTHERLY_ENDPOINT               host:port for motherly
#   AWG_MOTHERLY_AWG_IP                 motherly's AWG IP (peer AllowedIPs)
#   AWG_ALLOCATED_IP                    this edge's allocated AWG /32
#   AWG_JC AWG_JMIN AWG_JMAX            anti-cens jitter params
#   AWG_S1 AWG_S2 AWG_S4                pcap-fingerprint protection
#
#   INVARIANT — Jc/Jmin/Jmax/S1/S2/S4/H1..H4 MUST match the server-side
#   awg0.conf byte-for-byte, or the data plane silently drops decrypted
#   frames (WireGuard handshake still works; ping fails 100%). Do NOT
#   randomize, compute, or default these values here — write them
#   verbatim from the registration response. See docs/AWG_PARAM_INVARIANT.md
#   for the full failure mode and the 2026-05-20 edge-b.example outage RCA.
#   The same rule now covers every v3.1 field below: this file is a pure
#   renderer of central values — the ONLY edge-side client-param generator
#   lives in the awg-params-agent (AWG-3.1 D2), so nothing here invents a
#   value.
#   AWG_H1 AWG_H2 AWG_H3 AWG_H4         packet-header hashes (int or x-y range)
#
#   Optional v3.1 fields — render-if-present (never generated here):
#   AWG_S3                            third junk-packet size  [must-match]
#   AWG_HPK                           HeaderProtectionKey b64 [must-match;
#                                     renders only when effective S1-S4 >= 12]
#   AWG_RANDOM_TRAILERS               on|off                  [must-match]
#   AWG_I1..AWG_I5                    init-packet tags        [client-side]
#   AWG_CONTENT_PADDING_ADDITION      a or a-b                [client-side]
#   AWG_REKEY_AFTER_TIME AWG_REKEY_TIMEOUT AWG_REJECT_AFTER_TIME
#   AWG_KEEPALIVE_TIMEOUT AWG_MAX_HANDSHAKE_ATTEMPTS          [client-side]
#   AWG_DISABLE_COOKIES               on|off                  [client-side]
#
#   AWG_CONF_DEGRADED — OUT-param: configure_amneziawg sets it to 1 when a
#   required/identity/must-match field was dropped by the charset guard or
#   the HPK precondition. The caller surfaces it as awg=degraded (the link
#   will NOT come up while motherly expects a param we refused to render).
#   log warn die                        functions (install.sh provides)
#
# Pinned upstream refs — the single place the fleet's AWG dataplane version is
# set. Both ends of a mesh link must run wire-compatible builds: bump together
# and verify against the central (motherly) side before rolling to edges.
# AWG 3.x is wire-compatible with the v1.x param set we render (Jc/Jmin/Jmax/
# S1-S4/H1-H4 unchanged; I1-I5 + HeaderProtectionKey stay unset) — verified
# against the amneziawg-go README at the pinned tag.
AWG_GO_REF="${AWG_GO_REF:-v3.1.20260828}"        # amneziawg-go tag
AWG_TOOLS_REF="${AWG_TOOLS_REF:-v3.1.20260812}"  # amneziawg-tools tag
#
# Optional overrides (test hooks):
#   AWG_GO_VERSION         default 1.26.8 — Go toolchain floor; amneziawg-go
#                          v3 go.mod requires >= 1.25.0
#   AWG_GO_DL_BASE         default https://go.dev/dl
#   AWG_GO_BIN_PATH        default /usr/local/go/bin/go — test hook for version check
#   AWG_BUILD_ROOT         default $(mktemp -d) — test hook to skip git clone
#   AWG_INSTALL_PREFIX     default /usr/local — test hook to avoid root write
#   AWG_CONF_DIR           default /etc/amnezia/amneziawg
#   AWG_QUICK_BIN          default /usr/bin/awg-quick — test hook for idempotency
#                          gate (binary path; not the systemd unit name at L123).
#   AWG_BIN                default awg — test hook for the tools version check
#   AWG_LISTEN_PORT        default $((43800 + RANDOM % 200)) — test hook for golden file
#   AWG_HANDSHAKE_WAIT     default 8 — post-restart handshake grace (seconds)

install_amneziawg() {
	local _prefix="${AWG_INSTALL_PREFIX:-/usr/local}"
	local _quick="${AWG_QUICK_BIN:-/usr/bin/awg-quick}"
	if [[ -s "${_prefix}/bin/amneziawg-go" && -x "${_quick}" ]]; then
		local _inst_go _inst_tools
		_inst_go=$("${_prefix}/bin/amneziawg-go" --version 2>/dev/null | awk '{print $2}')
		_inst_tools=$("${AWG_BIN:-awg}" --version 2>/dev/null | awk '{print $2}')
		if [[ "$_inst_go" == "$AWG_GO_REF" && "$_inst_tools" == "$AWG_TOOLS_REF" ]]; then
			log "  amneziawg already at ${_inst_go} (skip)"
			return 0
		fi
		log "  amneziawg version drift (go=${_inst_go:-?} tools=${_inst_tools:-?}, want ${AWG_GO_REF}/${AWG_TOOLS_REF}) — rebuilding at pinned tags"
	else
		log "  building amneziawg ${AWG_GO_REF} from source"
	fi
	# amneziawg-go v3 go.mod requires Go >= 1.25. Ubuntu 22.04 apt ships golang
	# 1.18, Debian 12 ships 1.19, and edges installed under the old unpinned
	# clone carry /usr/local/go 1.24. All too old. Install the official Go
	# tarball if /usr/local/go is missing or below 1.25 — leaves the system
	# golang package alone.
	local _go_ver="${AWG_GO_VERSION:-1.26.8}"
	local _go_dl_base="${AWG_GO_DL_BASE:-https://go.dev/dl}"
	local _go_bin="${AWG_GO_BIN_PATH:-/usr/local/go/bin/go}"
	if ! "$_go_bin" version 2>/dev/null | grep -qE "go1\\.(2[5-9]|[3-9][0-9])|go[2-9]\\."; then
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
		git clone --depth 1 -q -b "$AWG_GO_REF" https://github.com/amnezia-vpn/amneziawg-go.git && \
		git clone --depth 1 -q -b "$AWG_TOOLS_REF" https://github.com/amnezia-vpn/amneziawg-tools.git
	) || die "amneziawg git clone failed (${AWG_GO_REF}/${AWG_TOOLS_REF})"
	(cd "$build_root/amneziawg-go" && make) >/dev/null 2>&1 || die "amneziawg-go build failed"
	install -m 0755 "$build_root/amneziawg-go/amneziawg-go" "${_prefix}/bin/amneziawg-go"
	(cd "$build_root/amneziawg-tools/src" && make && make install) >/dev/null 2>&1 || \
	  die "amneziawg-tools build failed"
	rm -rf "$build_root"
	log "  amneziawg installed: $("${_prefix}/bin/amneziawg-go" --version 2>/dev/null | head -1)"
}

# ensure_amneziawg — converge an ALREADY-INSTALLED node's amneziawg stack to the
# pinned AWG_GO_REF/AWG_TOOLS_REF (the upgrade.sh apply paths call this;
# install.sh reaches the same pin through install_amneziawg itself).
#
# No-ops when: the node has no AWG mesh at all (no binary AND no awg0.conf —
# legacy installs where central returned no awg block), or the installed
# versions already match the pins. On drift: rebuilds from the pinned tags via
# install_amneziawg (die-isolating subshell — same contract as the install.sh
# call site), daemon-reloads (tools' make install may refresh the
# awg-quick@.service unit), restarts awg-quick@awg0 and verifies the handshake.
#
# Returns 0 on skip/converge, 1 on rebuild/restart/handshake failure — callers
# MUST warn-and-continue: AWG is the optional mesh channel, and a failed
# converge leaves the previous binaries running (the swap only lands on a
# successful build), so a converge failure never justifies rolling back an
# otherwise-green release.
ensure_amneziawg() {
	local _prefix="${AWG_INSTALL_PREFIX:-/usr/local}"
	local _conf_dir="${AWG_CONF_DIR:-/etc/amnezia/amneziawg}"
	local _go_bin="${_prefix}/bin/amneziawg-go"

	if [[ ! -x "$_go_bin" && ! -s "$_conf_dir/awg0.conf" ]]; then
		log "[awg] no amneziawg install on this node — skipping version converge"
		return 0
	fi

	local _inst_go="" _inst_tools=""
	[[ -x "$_go_bin" ]] && \
		_inst_go=$("$_go_bin" --version 2>/dev/null | awk '{print $2}')
	command -v "${AWG_BIN:-awg}" >/dev/null 2>&1 && \
		_inst_tools=$("${AWG_BIN:-awg}" --version 2>/dev/null | awk '{print $2}')

	if [[ "$_inst_go" == "$AWG_GO_REF" && "$_inst_tools" == "$AWG_TOOLS_REF" ]]; then
		log "[awg] amneziawg already at ${AWG_GO_REF} — skip"
		return 0
	fi

	log "[awg] converging amneziawg: go=${_inst_go:-absent}→${AWG_GO_REF} tools=${_inst_tools:-absent}→${AWG_TOOLS_REF}"
	if ! ( install_amneziawg ); then
		warn "[awg] rebuild failed — node keeps previous binaries (${_inst_go:-none})"
		return 1
	fi
	# tools' make install may have refreshed awg-quick@.service — reload before
	# restart so systemd does not warn about a stale unit file.
	systemctl daemon-reload 2>/dev/null || true
	if [[ -s "$_conf_dir/awg0.conf" ]]; then
		if ! systemctl restart awg-quick@awg0; then
			warn "[awg] awg-quick@awg0 restart failed after version swap"
			return 1
		fi
		sleep "${AWG_HANDSHAKE_WAIT:-8}"
		if "${AWG_BIN:-awg}" show awg0 2>/dev/null | grep -q "latest handshake"; then
			log "[awg] awg0 handshake confirmed on ${AWG_GO_REF}"
		else
			warn "[awg] awg0 handshake not seen after restart — mesh may still be establishing"
			return 1
		fi
	fi
	return 0
}

# ---------------------------------------------------------------------------
# _awg_conf_safe VALUE — charset guard for every central-sourced string
# interpolated into awg0.conf. The forbidden set (\n \r [ ]) is byte-identical
# to FORBIDDEN_CONF_CHARS in crates/awg-params-agent/src/params.rs — the
# single grammar authority (opec/src/secrets/sfu_key.rs is the other
# sanctioned mirror). A value carrying these primitives can splice an
# injected [Peer] section into the conf: '\n'/'\r' start a new directive,
# '['/']' open a section header. TLS+bearer authenticates the CONNECTION, not
# the field content — so the register payload is an injection surface and the
# guard covers the pre-existing identity fields too (motherly_pubkey /
# motherly_endpoint / motherly_awg_ip / allocated_ip were injectable before).
# ---------------------------------------------------------------------------
_awg_conf_safe() {
	case "$1" in
		*$'\n'*|*$'\r'*|*'['*|*']'*) return 1 ;;
	esac
	return 0
}

# ---------------------------------------------------------------------------
# Grammar layer — mirrors the params-agent FIELD_SPECS validators
# (crates/awg-params-agent/src/params.rs) so both writers hold one contract.
# Upstream uapi (device/uapi.go @ v3.1): jc/jmin/jmax are ParseUint(10,32),
# s1-s4 ParseUint(10,16), h1-h4 are `N`/`N-M` u32 ranges with lo >= 5 and
# pairwise non-overlap in mergeWithDevice; header_protection_key must
# base64-decode to exactly 32 bytes; random_trailers/disable_cookies are
# on|off post-extraction normalization. A value outside that grammar renders
# a conf `awg syncconf` refuses outright — dead-but-green — so grammar
# failures take the same paths as charset failures (skip-write for required
# fields, drop-line+degraded for optional must-match).
# ---------------------------------------------------------------------------
# Digit-length caps in the numeric guards are LOAD-BEARING, not pedantry:
# `10#$v` wraps modulo 2^64 on input longer than ~19 digits, so a
# 20-digit "number" can wrap under the bound and falsely pass.
_awg_u16()   { [[ "$1" =~ ^[0-9]{1,5}$ ]] && (( 10#$1 <= 65535 )); }
_awg_u32()   { [[ "$1" =~ ^[0-9]{1,10}$ ]] && (( 10#$1 <= 4294967295 )); }
_awg_onoff() { [[ "$1" == "on" || "$1" == "off" ]]; }

# _awg_h_parse VALUE → "lo hi" on stdout; fails on shape, order, or bound.
# `N` collapses to `N N`. lo >= 5: 1-4 are the vanilla WG message types an H
# value must not shadow.
_awg_h_parse() {
	local lo hi
	if [[ "$1" =~ ^([0-9]{1,10})-([0-9]{1,10})$ ]]; then
		lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
	elif [[ "$1" =~ ^[0-9]{1,10}$ ]]; then
		lo="$1"; hi="$1"
	else
		return 1
	fi
	(( 10#$lo >= 5 && 10#$lo <= 10#$hi && 10#$hi <= 4294967295 )) || return 1
	printf '%s %s\n' "$lo" "$hi"
}

# _awg_range VALUE — `N` or `N-M` with lo <= hi (mirrors the agent's
# validate_range_string; upstream UintRange shape). Members capped at 18
# digits so the 10# compare can't wrap.
_awg_range() {
	local lo hi
	if [[ "$1" =~ ^([0-9]{1,18})-([0-9]{1,18})$ ]]; then
		lo="${BASH_REMATCH[1]}"; hi="${BASH_REMATCH[2]}"
	elif [[ "$1" =~ ^[0-9]{1,18}$ ]]; then
		lo="$1"; hi="$1"
	else
		return 1
	fi
	(( 10#$lo <= 10#$hi ))
}

# _awg_itag VALUE — mirrors upstream newObfChain: VALUE is a sequence of
# `<key>` / `<key arg>` tokens, keys in {b,t,r,rc,rd,d,ds,dz}; text between
# tokens is ignored (upstream scans for '<' … '>'). b needs a non-empty
# even-length hex arg (0x prefix ok); r/rc/rd/dz need a numeric length
# 0..=65535 (upstream Atoi accepts negatives that PANIC the daemon at send —
# we are stricter); t/d/ds ignore their arg. Empty <> tag, unterminated <,
# unknown key, or no tag at all → fail.
_awg_itag() {
	local rest="$1" tok key arg hex
	[[ "$rest" == *"<"* ]] || return 1
	while [[ "$rest" == *"<"* ]]; do
		rest="${rest#*<}"
		tok="${rest%%>*}"
		[[ "$tok" != "$rest" ]] || return 1   # unterminated <
		rest="${rest#*>}"
		# Mirror upstream strings.Cut(tag, " "): split on the FIRST literal
		# space only — the whole remainder is the arg. IFS-splitting would
		# wrongly accept `<r 5 junk>`, `<r  5>` (double space — upstream
		# Atoi(" 5") fails) and `<r\t5>` (tab isn't the cut char upstream —
		# the whole token is an unknown key there). Each wrong-accept writes
		# a conf syncconf rejects → persistent wedge.
		key="${tok%% *}"
		if [[ "$tok" == *" "* ]]; then arg="${tok#* }"; else arg=""; fi
		[[ -n "$key" ]] || return 1
		case "$key" in
		b)
			hex="${arg#0x}"
			[[ -n "$hex" && $(( ${#hex} % 2 )) -eq 0 && "$hex" =~ ^[0-9a-fA-F]+$ ]] || return 1
			;;
		t|d|ds) ;;
		r|rc|rd|dz)
			# A leading '+' is legal — upstream strconv.Atoi("+5")=5 and the
			# Rust twin's parse::<u64> both accept it. '-' stays rejected
			# (upstream parses negatives then PANICS at send — we fail closed).
			local _n="${arg#+}"
			{ [[ "$_n" =~ ^[0-9]{1,5}$ ]] && (( 10#$_n <= 65535 )); } || return 1
			;;
		*) return 1 ;;
		esac
	done
	return 0
}

# _awg_hpk32 VALUE — true iff VALUE base64-decodes to exactly 32 bytes (the
# wire width upstream XORs into the type field). Same check as the agent's
# decode_hpk (strict base64 — validate=True rejects whitespace and
# non-alphabet bytes).
_awg_hpk32() {
	python3 -c "import base64,sys
try: sys.exit(0 if len(base64.b64decode(sys.argv[1], validate=True)) == 32 else 1)
except Exception: sys.exit(1)" "$1" 2>/dev/null
}

# Optional-line builders — used ONLY inside configure_amneziawg. Both append
# to the caller-visible accumulators _opt_lines / _drop_mm / _drop_cl (bash
# dynamic scope — declared `local` in configure_amneziawg before the calls).
#
#   _awg_opt_mm <field-label> <ConfKey> <value> [validator-fn]
#       MUST-MATCH param (s3, header_protection_key, random_trailers): charset
#       guard, then optional upstream-grammar validator fn, then render
#       VERBATIM — the edge must not silently EDIT a must-match value, but a
#       value that fails the grammar must not render at all (an invalid
#       must-match is a dead link, not a degraded feature). Either failure →
#       record the drop; the bytes NEVER render.
#
#   _awg_opt_cl <field-label> <ConfKey> <value> <grammar-ERE>
#       CLIENT-SIDE param (i1-i5, content_padding_addition, the 5 timings,
#       disable_cookies): charset guard + whole-value grammar check; either
#       failure omits just that line — degrade the feature, keep the link
#       (the params agent may re-add the field from a later epoch).
_awg_opt_mm() {
	[[ -z "$3" ]] && return 0
	if ! _awg_conf_safe "$3"; then
		_drop_mm+="$1(charset) "
	elif [[ -n "${4:-}" ]] && ! "$4" "$3"; then
		_drop_mm+="$1(grammar) "
	else
		_opt_lines+="$2 = $3"$'\n'
	fi
}

_awg_opt_cl() {
	[[ -z "$3" ]] && return 0
	if ! _awg_conf_safe "$3"; then
		_drop_cl+="$1(charset) "
	elif [[ ! "$3" =~ $4 ]]; then
		_drop_cl+="$1(grammar) "
	else
		_opt_lines+="$2 = $3"$'\n'
	fi
}

# _awg_opt_clf — same client-side drop-line contract as _awg_opt_cl but $4
# is a validator FUNCTION (for grammars a bare ERE can't express: I-tag
# tokens, range ordering).
_awg_opt_clf() {
	[[ -z "$3" ]] && return 0
	if ! _awg_conf_safe "$3"; then
		_drop_cl+="$1(charset) "
	elif ! "$4" "$3"; then
		_drop_cl+="$1(grammar) "
	else
		_opt_lines+="$2 = $3"$'\n'
	fi
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
	# Single-writer coordination with the awg-params-agent daemon: both this
	# installer and the agent write awg0.conf. Serialize via an advisory flock on
	# <conf_path>.lock — shared byte-for-byte with the agent's rustix flock(2)
	# target (OXPULSE_AWG_CONF_LOCK_PATH defaults to the same "<conf>.lock").
	# Without it, a mid-install agent tick reads a pre-install conf and renames
	# its stale-identity merge over the just-rotated PrivateKey/Endpoint/Jc/S1-S4/
	# H1-H4 (data_loss). Reuses the established flock protocol (upgrade.sh:365,
	# lib/telegram-alert-lib.sh:46). -w 10 matches the agent's OXPULSE_AWG_LOCK_TIMEOUT.
	# We fd-open + flock + write + release around ONLY the conf write, so the slow
	# systemctl/handshake steps below never hold the lock against the agent.
	# Prefer OXPULSE_AWG_CONF_LOCK_PATH — the agent's own env-var name (main.rs) —
	# so an operator who redirects the agent's lock also redirects ours to the same
	# byte-for-byte file; AWG_CONF_LOCK_PATH stays as a legacy alias. Both default
	# to "<conf>.lock", identical to the agent's default_lock_path().
	local lock_path="${OXPULSE_AWG_CONF_LOCK_PATH:-${AWG_CONF_LOCK_PATH:-${conf_path}.lock}}"
	# Probe the lock-file open in a subshell first: `exec 9>` is a SPECIAL
	# builtin — a redirection failure aborts the whole non-interactive shell
	# outright (no || guard can catch it), which would skip firewall_apply
	# and every step after — the exact consequence the fail-soft contract
	# below exists to prevent.
	if ! ( : >> "$lock_path" ) 2>/dev/null; then
		warn "configure_amneziawg: cannot open lock file $lock_path — leaving awg0.conf UNTOUCHED this pass"
		printf '%s\n' "awg0.conf write SKIPPED $(date -u +%Y-%m-%dT%H:%M:%SZ): lock file $lock_path not writable; identity rotation NOT applied; re-run the install to apply it." \
			> "${conf_path}.rotation-skipped" 2>/dev/null || true
		# Same dead-but-green guard as the contention path below: a fresh
		# install with no conf at all must not report awg=active.
		[[ -s "$conf_path" ]] || AWG_CONF_DEGRADED=1
		return 0
	fi
	exec 9>"$lock_path"
	# Fail-soft, NOT die(): AWG is an optional mesh channel (install.sh Phase 5.7
	# Item 2) and configure_amneziawg is called directly — NOT in a die-isolating
	# subshell like install_amneziawg — so a die() here would `exit 1` the whole
	# install under `set -e`, skipping firewall_apply (which closes the otherwise
	# publicly-reachable :9317/:8912 per the 2026-05-21 audit) and every step after.
	# On lock contention we warn, leave the existing awg0.conf untouched (never a
	# partial unlocked write), and return so the install continues; the agent
	# reconciles on its next poll or the operator re-runs. `return 0` (not 1)
	# because the bare call site under `set -e` treats a non-zero return the same
	# as die() would.
	if ! flock -w 10 9; then
		# The awg-params-agent reconciles ONLY the obfuscation params (Jc/Jmin/Jmax/
		# S1-S4/H1-H4) — it preserves PrivateKey/Endpoint/Address verbatim (see
		# crates/awg-params-agent/src/conf_merge.rs::merge_obfuscation_params). So it
		# CANNOT self-heal a rotated identity: only re-running the install applies it.
		# The message must not imply an agent recovery path that does not exist for
		# identity fields.
		warn "configure_amneziawg: could not acquire $lock_path within 10s (awg-params-agent may be mid-write) — leaving awg0.conf UNTOUCHED this pass. The agent reconciles only obfuscation params, NOT identity (PrivateKey/Endpoint/Address), so any rotated identity was NOT applied — re-run the install to apply it."
		# Durable signal for non-interactive / scripted installs: warn() is a bare
		# stderr printf and this function returns 0 (a non-zero return would exit 1
		# the whole install under set -e and skip firewall_apply — see below), so the
		# skip would otherwise leave no observable trace. Drop a marker file a
		# post-install check (or the operator) can detect. Best-effort — the install
		# never fails on the marker write itself.
		printf '%s\n' "awg0.conf write SKIPPED $(date -u +%Y-%m-%dT%H:%M:%SZ): lock $lock_path held >10s by another writer; identity rotation NOT applied; re-run the install to apply it." \
			> "${conf_path}.rotation-skipped" 2>/dev/null || true
		# No conf at all + no write this pass = fresh-install dead-but-green —
		# mark degraded so the caller doesn't record awg=active on a link
		# that was never rendered. With a conf present the skip is a real
		# rotation-skip (old conf may still be live) and stays non-degraded.
		[[ -s "$conf_path" ]] || AWG_CONF_DEGRADED=1
		exec 9>&-
		return 0
	fi
	# --- AWG 3.1 pre-render guard (design D5: charset → never render) --------
	# Every central-sourced string interpolated below passes _awg_conf_safe.
	# Failure semantics by field class:
	#   identity/required — the conf can never be valid without the field, and
	#     a scrubbed placeholder would render a dead conf over a possibly
	#     working one. So: skip the whole write (mirrors the lock-contention
	#     path above — any existing awg0.conf stays byte-untouched), drop the
	#     .param-dropped marker, set AWG_CONF_DEGRADED for the caller's
	#     awg=degraded status. The injected bytes never reach the file.
	#   must-match option (S3/HeaderProtectionKey/RandomTrailers) — drop the
	#     line, still write the conf so the other params land; but while
	#     motherly expects the dropped param the link will NOT come up →
	#     marker + degraded.
	#   client-side (I1-I5/CPA/timings/DisableCookies) — drop just that line
	#     on charset OR grammar failure; marker records the omission; the link
	#     is unaffected and the agent may re-add the field via a later epoch.
	AWG_CONF_DEGRADED=""
	local _drop_ident="" _drop_mm="" _drop_cl="" _opt_lines=""
	local _marker="${conf_path}.param-dropped"
	local _f
	# Identity fields: non-empty + charset-safe. The numeric must-match
	# fields additionally carry upstream grammar (u32 junk trio, u16 S
	# values, `N`/`N-M` H ranges) — an out-of-grammar value renders a conf
	# `awg syncconf` refuses outright, i.e. dead-but-green, so it takes the
	# same skip-write path as a charset failure.
	for _f in AWG_ALLOCATED_IP AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
	          AWG_MOTHERLY_AWG_IP; do
		{ [[ -n "${!_f:-}" ]] && _awg_conf_safe "${!_f}"; } || _drop_ident+="$_f "
	done
	for _f in AWG_JC AWG_JMIN AWG_JMAX; do
		{ [[ -n "${!_f:-}" ]] && _awg_conf_safe "${!_f}" && _awg_u32 "${!_f}"; } \
			|| _drop_ident+="$_f "
	done
	for _f in AWG_S1 AWG_S2 AWG_S4; do
		{ [[ -n "${!_f:-}" ]] && _awg_conf_safe "${!_f}" && _awg_u16 "${!_f}"; } \
			|| _drop_ident+="$_f "
	done
	# H1-H4: range grammar + pairwise non-overlap (upstream mergeWithDevice
	# refuses an overlapping header set — the whole IpcSet op fails).
	local _h_name=() _h_lo=() _h_hi=() _hp i j
	for _f in AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
		if [[ -n "${!_f:-}" ]] && _awg_conf_safe "${!_f}" \
			&& _hp=$(_awg_h_parse "${!_f}"); then
			_h_name+=("$_f"); _h_lo+=("${_hp%% *}"); _h_hi+=("${_hp##* }")
		else
			_drop_ident+="$_f "
		fi
	done
	for ((i = 0; i < ${#_h_lo[@]}; i++)); do
		for ((j = i + 1; j < ${#_h_lo[@]}; j++)); do
			if (( 10#${_h_lo[i]} <= 10#${_h_hi[j]} && 10#${_h_lo[j]} <= 10#${_h_hi[i]} )); then
				_drop_ident+="${_h_name[i]}x${_h_name[j]} "
			fi
		done
	done
	# Resolved-set pair invariants (same checks the agent runs post-merge):
	# S1+56==S2 makes init/response handshake packets the same padded size —
	# upstream refuses it; jmin>jmax underflows `max-min` to a ~4GiB
	# allocation inside Device.JunkPackets. Run only when both sides parsed
	# (an unparsed side is already flagged above).
	if [[ "${AWG_S1:-}" =~ ^[0-9]+$ && "${AWG_S2:-}" =~ ^[0-9]+$ ]] && \
		(( 10#$AWG_S1 + 56 == 10#$AWG_S2 )); then
		_drop_ident+="AWG_S1+56==AWG_S2 "
	fi
	if [[ "${AWG_JMIN:-}" =~ ^[0-9]+$ && "${AWG_JMAX:-}" =~ ^[0-9]+$ ]] && \
		(( 10#$AWG_JMIN > 10#$AWG_JMAX )); then
		_drop_ident+="AWG_JMIN-gt-AWG_JMAX "
	fi
	# The private key is locally generated (not central) but interpolates the
	# same way — a corrupt key file is the same silent-dead-render class.
	# `|| true` keeps a missing/unreadable file from aborting the whole
	# install under `set -e` (the AWG channel is fail-soft); the empty result
	# then lands in _drop_ident as a configuration failure — a conf rendered
	# with `PrivateKey = ` would report awg=active on a link that can never
	# handshake (dead-but-green).
	local _privkey
	_privkey=$(cat "$AWG_PRIV_PATH" 2>/dev/null || true)
	[[ -n "$_privkey" ]] && _awg_conf_safe "$_privkey" || _drop_ident+="AWG_PRIV_PATH "
	_awg_conf_safe "$listen_port" || _drop_ident+="AWG_LISTEN_PORT "
	if [[ -n "$_drop_ident" ]]; then
		printf '%s\n' "awg0.conf render SKIPPED $(date -u +%Y-%m-%dT%H:%M:%SZ): required/identity field(s) failed the conf-injection charset/grammar guard: ${_drop_ident}— the offending bytes were NEVER written; any previous awg0.conf left untouched; fix the register payload and re-run." \
			> "$_marker" 2>/dev/null || true
		AWG_CONF_DEGRADED=1
		warn "configure_amneziawg: required AWG field(s) failed the charset/grammar guard: ${_drop_ident}— awg0.conf NOT written this pass (existing conf, if any, untouched). The AWG link will NOT come up from this render. See ${_marker}."
		exec 9>&-
		return 0
	fi
	# Render-if-present optional lines (v3.1). Values arrive normalized from
	# awg_extract_all (bools already on|off). Install NEVER generates values —
	# the single client-param generator is agent-side (D2). Emission order is
	# fixed: S3, I1-I5, HPK, CPA, the 5 timings, RandomTrailers, DisableCookies.
	_awg_opt_mm s3 S3 "${AWG_S3:-}" _awg_u16
	# I-tags get the full upstream tag grammar (_awg_itag — known keys, per-key
	# arg shape); timings/CPA get N|N-M with lo<=hi (_awg_range). Both are
	# function validators — an ERE can't express them.
	_awg_opt_clf i1 I1 "${AWG_I1:-}" _awg_itag
	_awg_opt_clf i2 I2 "${AWG_I2:-}" _awg_itag
	_awg_opt_clf i3 I3 "${AWG_I3:-}" _awg_itag
	_awg_opt_clf i4 I4 "${AWG_I4:-}" _awg_itag
	_awg_opt_clf i5 I5 "${AWG_I5:-}" _awg_itag
	# HPK precondition — mirrors upstream mergeWithDevice, evaluated on the
	# EFFECTIVE (post-extraction) set: a non-empty HeaderProtectionKey renders
	# only when ALL of S1/S2/S3/S4 are integers >= 12 (absent S3 = 0 — so HPK
	# without S3 always fails). Otherwise IpcSet would reject the key; we warn
	# + omit it + mark degraded rather than ship a key the kernel refuses.
	if [[ -n "${AWG_HPK:-}" ]]; then
		if ! _awg_conf_safe "$AWG_HPK"; then
			_drop_mm+="header_protection_key(charset) "
		elif ! _awg_hpk32 "$AWG_HPK"; then
			_drop_mm+="header_protection_key(grammar) "
		else
			local _hpk_ok=1 _sv
			for _sv in "${AWG_S1:-0}" "${AWG_S2:-0}" "${AWG_S3:-0}" "${AWG_S4:-0}"; do
				[[ "$_sv" =~ ^[0-9]+$ ]] || { _hpk_ok=0; break; }
				(( 10#${_sv} >= 12 )) || { _hpk_ok=0; break; }
			done
			if [[ "$_hpk_ok" -eq 1 ]]; then
				_opt_lines+="HeaderProtectionKey = ${AWG_HPK}"$'\n'
			else
				_drop_mm+="header_protection_key(requires-S1-S4>=12) "
			fi
		fi
	fi
	_awg_opt_clf content_padding_addition ContentPaddingAddition "${AWG_CONTENT_PADDING_ADDITION:-}" _awg_range
	_awg_opt_clf rekey_after_time RekeyAfterTime "${AWG_REKEY_AFTER_TIME:-}" _awg_range
	_awg_opt_clf rekey_timeout RekeyTimeout "${AWG_REKEY_TIMEOUT:-}" _awg_range
	_awg_opt_clf reject_after_time RejectAfterTime "${AWG_REJECT_AFTER_TIME:-}" _awg_range
	_awg_opt_clf keepalive_timeout KeepaliveTimeout "${AWG_KEEPALIVE_TIMEOUT:-}" _awg_range
	_awg_opt_clf max_handshake_attempts MaxHandshakeAttempts "${AWG_MAX_HANDSHAKE_ATTEMPTS:-}" _awg_range
	_awg_opt_mm random_trailers RandomTrailers "${AWG_RANDOM_TRAILERS:-}" _awg_onoff
	_awg_opt_cl disable_cookies DisableCookies "${AWG_DISABLE_COOKIES:-}" '^(on|off)$'
	# Atomic write: stream into a temp file in the SAME dir, chmod, then rename(2)
	# over awg0.conf. The agent's apply_to_kernel() reads the conf via awg-quick
	# strip OUTSIDE this shared lock, so a plain in-place "cat >" truncate could be
	# observed half-written; rename(2) is atomic, so that reader sees either the
	# whole old file or the whole new one. Mirrors the agent write_conf_atomic.
	local conf_tmp="${conf_path}.tmp.$$"
	# ${_opt_lines} sits glued at the head of the "Table = off" line: it expands
	# to "Key = value\n" rows (each \n-terminated) or to NOTHING — so with every
	# optional var empty the render stays byte-identical to the pre-3.1
	# template (the golden fixture proves it). No comment can live inside the
	# heredoc — it would render into the conf.
	cat > "$conf_tmp" <<-AWGCONF
		[Interface]
		PrivateKey = ${_privkey}
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
		${_opt_lines}Table = off
		MTU = 1300

		[Peer]
		PublicKey = ${AWG_MOTHERLY_PUBKEY}
		Endpoint = ${AWG_MOTHERLY_ENDPOINT}
		AllowedIPs = ${AWG_MOTHERLY_AWG_IP}/32
		PersistentKeepalive = 25
	AWGCONF
	chmod 0600 "$conf_tmp"
	mv -f "$conf_tmp" "$conf_path"
	# This pass wrote a fresh conf under the lock — clear any stale skip marker a
	# prior lock-contended run left behind so it cannot linger as a false signal.
	rm -f "${conf_path}.rotation-skipped"
	# Param-drop ledger (AWG 3.1 D9): every field the guards omitted lands here
	# with timestamp + field + why — mirroring the .rotation-skipped marker
	# pattern. A MUST-MATCH drop (charset-failed S3/HPK/RT, or HPK whose
	# effective S1-S4 are not all >= 12) means motherly expects a param this
	# conf lacks → the AWG link will NOT come up → AWG_CONF_DEGRADED=1 so the
	# caller writes awg=degraded (a dead-but-green install is the failure class
	# this exists to close). A client-side drop is feature-degraded only — the
	# link is unaffected and the params agent may re-add the field via epoch.
	# A clean pass removes a stale marker so it cannot linger as false signal.
	if [[ -n "$_drop_mm" || -n "$_drop_cl" ]]; then
		{
			printf '%s\n' "awg0.conf param-drop $(date -u +%Y-%m-%dT%H:%M:%SZ):"
			if [[ -n "$_drop_mm" ]]; then
				printf '%s\n' "  must-match dropped: ${_drop_mm% }— the AWG link will NOT come up while motherly expects these params (caller status: awg=degraded)"
			fi
			if [[ -n "$_drop_cl" ]]; then
				printf '%s\n' "  client-side omitted: ${_drop_cl% }— feature degraded, link unaffected (params agent may re-add via a later epoch)"
			fi
		} > "$_marker" 2>/dev/null || true
	else
		rm -f "$_marker"
	fi
	if [[ -n "$_drop_mm" ]]; then
		AWG_CONF_DEGRADED=1
		warn "configure_amneziawg: rendered awg0.conf WITHOUT must-match param(s): ${_drop_mm}— the AWG link will NOT come up while motherly requires them (an omitted must-match is a dead link, not a degraded feature). See ${_marker}."
	fi
	if [[ -n "$_drop_cl" ]]; then
		warn "configure_amneziawg: omitted client-side param(s) that failed validation: ${_drop_cl}— feature degraded, link unaffected. See ${_marker}."
	fi
	# Release the conf lock (close fd 9) before the slow systemctl/handshake
	# steps so a waiting agent tick is unblocked as soon as the write is durable.
	exec 9>&-
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

# awg_extract FILE KEY — single-key extraction, kept for the pinned legacy
# allocated_ip line in install.sh (tests/test_sfu_bind_strip_cidr.sh greps
# that literal for line ordering). Normalization now matches awg_extract_all:
# JSON null/absent → '' (the old a.get(key,'') printed the literal "None" on
# an explicit JSON null), JSON bool → on|off, else str — so no caller can
# leak Python repr literals (None/True/False) into the conf.
awg_extract() {
	python3 -c "import json,sys; d=json.load(open(sys.argv[1])); a=d.get('awg') or {}; v=a.get(sys.argv[2]); print('' if v is None else ('on' if v else 'off') if isinstance(v,bool) else v)" "$1" "$2" 2>/dev/null
}

# awg_extract_all FILE — ONE python3 spawn emitting the full v3 awg-block
# surface as NUL-delimited VAR=VALUE records, consumed by the read-loop in
# install.sh (no eval, ~30 fewer python3 spawns than the per-key path).
#
# NUL framing, NOT newlines: a legit string value may itself carry '\n' (e.g.
# a hostile i1) — line framing would silently truncate it at the first
# newline, hiding the injected tail from the render-side _awg_conf_safe guard.
# NUL cannot appear in a conf value, so records stay lossless and the guard
# sees the true bytes. (A JSON '\u0000' inside a string is stripped below —
# it can only split a record, never be a legit value.)
#
# Normalization lives at this single choke point (the fix for the per-key
# repr leak): JSON null/absent → ''; JSON bool → 'on'|'off' — upstream
# parse_bool (amneziawg-tools config.c:414-445) accepts on|off|0|1, and
# Python's True/False repr would render `RandomTrailers = True`, parse-FATAL
# for the whole conf; numbers → str (covers i64 fields and IntOrRange
# number-form H values; range-form "x-y" arrives already a string).
#
# The emitted VAR names come from this fixed table — JSON content can never
# name or inject a variable into the caller's `printf -v`. allocated_ip stays
# on the pinned awg_extract line (see above), everything else is here.
awg_extract_all() {
	python3 - "$1" <<'AWGEXTRACT' 2>/dev/null
import json, sys
KEYS = [
    ("motherly_pubkey",           "AWG_MOTHERLY_PUBKEY"),
    ("motherly_endpoint",         "AWG_MOTHERLY_ENDPOINT"),
    ("motherly_awg_ip",           "AWG_MOTHERLY_AWG_IP"),
    ("jc",                        "AWG_JC"),
    ("jmin",                      "AWG_JMIN"),
    ("jmax",                      "AWG_JMAX"),
    ("s1",                        "AWG_S1"),
    ("s2",                        "AWG_S2"),
    ("s3",                        "AWG_S3"),
    ("s4",                        "AWG_S4"),
    ("h1",                        "AWG_H1"),
    ("h2",                        "AWG_H2"),
    ("h3",                        "AWG_H3"),
    ("h4",                        "AWG_H4"),
    ("i1",                        "AWG_I1"),
    ("i2",                        "AWG_I2"),
    ("i3",                        "AWG_I3"),
    ("i4",                        "AWG_I4"),
    ("i5",                        "AWG_I5"),
    ("header_protection_key",     "AWG_HPK"),
    ("content_padding_addition",  "AWG_CONTENT_PADDING_ADDITION"),
    ("rekey_after_time",          "AWG_REKEY_AFTER_TIME"),
    ("rekey_timeout",             "AWG_REKEY_TIMEOUT"),
    ("reject_after_time",         "AWG_REJECT_AFTER_TIME"),
    ("keepalive_timeout",         "AWG_KEEPALIVE_TIMEOUT"),
    ("max_handshake_attempts",    "AWG_MAX_HANDSHAKE_ATTEMPTS"),
    ("random_trailers",           "AWG_RANDOM_TRAILERS"),
    ("disable_cookies",           "AWG_DISABLE_COOKIES"),
    ("edge_id",                   "SFU_EDGE_ID"),
    ("otel_endpoint",             "OTEL_EXPORTER_OTLP_ENDPOINT"),
]
a = json.load(open(sys.argv[1])).get("awg") or {}
w = sys.stdout.write
for jk, var in KEYS:
    v = a.get(jk)
    if v is None:
        s = ""
    elif isinstance(v, bool):
        s = "on" if v else "off"
    else:
        s = str(v)
    w(var + "=" + s.replace("\x00", "") + "\x00")
AWGEXTRACT
}
