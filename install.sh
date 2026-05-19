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
# Phase 5.7 Item 5: pass --clean-sbin on upgrade to remove stale scripts
# from /usr/local/sbin/ that belonged to prior install versions (zombies).
# Without --clean-sbin the installer only warns about them; with it, they
# are removed. Safe: removes only scripts matching oxpulse-* not in the
# EXPECTED_SBIN_FILES list defined in lib/install-systemd.sh.
#   sudo bash install.sh ... --clean-sbin
# The manual-config JSON schema is documented in README.md.
set -euo pipefail

# ---------- Constants ----------
PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
PREFIX_SBIN=/usr/local/sbin
# Bug 20: PREFIX_LIBDIR must be declared before lib/install-systemd.sh is
# sourced — that module references $PREFIX_LIBDIR and runs under set -u.
# shellcheck disable=SC2034  # consumed by lib/install-systemd.sh
PREFIX_LIBDIR="${OXPULSE_PREFIX_LIBDIR:-/usr/local/lib/partner-edge}"
# shellcheck disable=SC2034  # consumed by systemd_install() in lib/install-systemd.sh
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
# Phase 5.5 MAJOR 1: _in_array, CHANNELS_FAILED, render_channel_soft, and
# compose_strip_failed_channels are now in lib/render-channel-lib.sh (extracted
# so hydrate.sh, update.sh, and refresh.sh can share the same semantics).
# Source it early — before any channel render logic — so the symbols are always
# available even on early-exit code paths.
_rl_local="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/render-channel-lib.sh"
_rl_installed="${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/render-channel-lib.sh"
_rl_sbin="${PREFIX_SBIN:-/usr/local/sbin}/render-channel-lib.sh"
if [[ -f "$_rl_local" ]]; then
	# shellcheck source=lib/render-channel-lib.sh
	source "$_rl_local"
elif [[ -f "$_rl_installed" ]]; then
	# shellcheck source=/dev/null
	source "$_rl_installed"
elif [[ -f "$_rl_sbin" ]]; then
	# shellcheck source=/dev/null
	source "$_rl_sbin"
else
	# Inline fallback — keeps install.sh self-contained if lib is missing.
	_in_array() { local needle=$1; shift; local el; for el in "$@"; do [[ "$el" == "$needle" ]] && return 0; done; return 1; }
	CHANNELS_FAILED=()
	render_channel_soft() {
		local kind=$1
		warn "render_channel_soft: lib/render-channel-lib.sh not found — channel $kind skipped"
		CHANNELS_FAILED+=("$kind"); return 1
	}
	compose_strip_failed_channels() {
		warn "compose_strip_failed_channels: lib/render-channel-lib.sh not found — compose not stripped"
		return 1
	}
fi
unset _rl_local _rl_installed _rl_sbin

# ---------- Phase 4.1: lib module loader ----------
# Resolves a lib/install-*.sh module via lookup order:
#   1. $INSTALL_LIB_DIR/<name>              (operator override / test)
#   2. /usr/local/lib/partner-edge/<name>   (FHS default, set by release tarball)
#   3. $(dirname "$0")/lib/<name>           (dev / running from checkout)
#   4. fetch $REPO_RAW/lib/<name>           (curl|bash flow, no tarball on disk)
_install_lib_source() {
	local name=$1
	local candidate
	for candidate in \
		"${INSTALL_LIB_DIR:-}/$name" \
		"/usr/local/lib/partner-edge/$name" \
		"$(dirname "$0")/lib/$name"; do
		# Skip "/<name>" produced when INSTALL_LIB_DIR is empty/unset.
		[[ -n "$candidate" && "$candidate" != "/$name" ]] || continue
		if [[ -r "$candidate" ]]; then
			# shellcheck source=/dev/null
			. "$candidate"
			return 0
		fi
	done
	local tmp
	tmp=$(mktemp)
	# Trap ensures the temp file is cleaned up even if the sourced module
	# calls die/exit (e.g. preflight_run on unsupported OS) — otherwise
	# every failing install leaves a stray /tmp/tmp.XXXX behind.
	# Use ${tmp:-} so the trap is safe under `set -u` after the function
	# returns and $tmp goes out of scope (RETURN trap fires post-return).
	trap 'rm -f "${tmp:-}"' RETURN
	if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
		"${REPO_RAW}/lib/$name" -o "$tmp"; then
		# Phase 5.7 Item 3: tamper-evident integrity check against lib-checksums.txt.
		#
		# What this provides: tamper-evident at rest — catches corruption in the
		# operator's local asset-bucket cache (tier-1/2/3 paths) and accidental
		# bit-rot. When both the lib and lib-checksums.txt are fetched from the same
		# REPO_RAW origin (tier-4 curl path), a channel-level MITM can substitute
		# both files simultaneously, so the checksum alone does NOT provide
		# MITM-resistance during download. Use a release tarball (tier-1/2/3) for
		# a stronger trust anchor.
		#
		# Lookup order for checksums file:
		#   1. $(dirname "$0")/lib/lib-checksums.txt  (local checkout / staged operator dir)
		#   2. /usr/local/lib/partner-edge/lib-checksums.txt  (deployed release tarball)
		#   3. Fetch from REPO_RAW/lib/lib-checksums.txt alongside the module
		#
		# Fail-closed: if no checksums file found (local or remote) AND --no-integrity
		# was NOT passed, die with a clear message. Operators who run curl|bash from
		# an untrusted or restricted environment must pass --no-integrity to acknowledge
		# the risk explicitly.
		#
		# If available and hash mismatches → die immediately (tamper detected).
		local _ck_file=""
		local _ck_src_local="${BASH_SOURCE[0]:-}"
		local _ck_src_dir=""
		[[ -n "$_ck_src_local" ]] && _ck_src_dir="$(cd "$(dirname "$_ck_src_local")" 2>/dev/null && pwd)"
		for _ck_cand in \
			"${_ck_src_dir:-.}/lib/lib-checksums.txt" \
			"/usr/local/lib/partner-edge/lib-checksums.txt"; do
			if [[ -r "$_ck_cand" ]]; then
				_ck_file="$_ck_cand"
				break
			fi
		done
		if [[ -z "$_ck_file" ]]; then
			# Attempt to fetch checksums file alongside the module
			local _ck_remote_tmp
			_ck_remote_tmp=$(mktemp)
			trap 'rm -f "${tmp:-}" "${_ck_remote_tmp:-}"' RETURN
			local _ck_fetch_ok=0
			if curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
				"${REPO_RAW}/lib/lib-checksums.txt" -o "$_ck_remote_tmp" 2>/dev/null; then
				_ck_file="$_ck_remote_tmp"
				_ck_fetch_ok=1
			fi
			# Fail-closed: no checksums available anywhere + --no-integrity not set → die.
			if [[ -z "$_ck_file" && "${NO_INTEGRITY:-0}" -eq 0 ]]; then
				die "tier-4 fetch without local checksums file is unsafe — either install from release tarball or pass --no-integrity to acknowledge the risk"
			elif [[ -z "$_ck_file" && "${NO_INTEGRITY:-0}" -eq 1 ]]; then
				warn "_install_lib_source: --no-integrity acknowledged — skipping checksum validation for $name (operator accepts risk)"
			fi
			unset _ck_fetch_ok
		fi
		if [[ -n "$_ck_file" && -f "$_ck_file" ]]; then
			local _actual_hash _expected_hash
			_actual_hash=$(sha256sum "$tmp" | awk '{print $1}')
			_expected_hash=$(grep "[[:space:]]${name}$" "$_ck_file" 2>/dev/null | awk '{print $1}')
			if [[ -n "$_expected_hash" && "$_actual_hash" != "$_expected_hash" ]]; then
				die "tier-4 fetch checksum mismatch for $name — refusing to source untrusted code (expected: ${_expected_hash:0:16}… got: ${_actual_hash:0:16}…)"
			fi
		fi
		unset _ck_file _ck_src_local _ck_src_dir _actual_hash _expected_hash
		# shellcheck source=/dev/null
		. "$tmp"
		return 0
	fi
	die "lib module $name not found in INSTALL_LIB_DIR / /usr/local/lib/partner-edge / \$(dirname \$0)/lib and fetch from \$REPO_RAW failed"
}

# Read the service token for Bearer auth. Prefers the env-var override
# (used in two scenarios: pre-rollout operator backfill, recovery from
# strand mode). Falls back to the persisted file. Returns 1 if neither
# is available so callers can substitute an empty string safely.
read_service_token() {
	if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
		printf '%s' "$OXPULSE_SERVICE_TOKEN"
		return 0
	fi
	if [[ -r "${PREFIX_ETC}/token" ]]; then
		cat "${PREFIX_ETC}/token"
		return 0
	fi
	return 1
}

# Pre-scan args for --check before any guard (--check is a diagnostic-only mode
# that does not need docker).
_PRESCAN_CHECK=0
for _arg in "$@"; do [[ "$_arg" == "--check" ]] && _PRESCAN_CHECK=1 && break; done
unset _arg

# opec is the typed render binary for all 5 stage templates (xray, coturn,
# naive, compose, caddy) plus secrets bootstrap (reality-keygen, awg-keygen,
# register, sfu-signing-key). Phase 4.4 made it a HARD requirement — there is
# no bash fallback for render anymore. Auto-fetch from release assets here so a
# fresh-install host needs only install.sh + a working network.
if [[ $_PRESCAN_CHECK -eq 0 ]] && ! command -v opec >/dev/null 2>&1; then
	_machine=$(uname -m)
	case "$_machine" in
		x86_64)  _opec_arch=amd64 ;;
		aarch64) _opec_arch=arm64 ;;
		*) die "opec: unsupported architecture: $_machine — supply an opec binary on PATH or use INSTALL_OPEC_FROM_PATH=" ;;
	esac
	if [[ -n "${_opec_arch:-}" ]]; then
		_opec_url="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/opec-${_opec_arch}"
		log "opec not found -- downloading from release assets ($_opec_arch)"
		if curl -fsSL --max-time 60 "$_opec_url" -o /usr/local/bin/opec 2>/dev/null; then
			chmod +x /usr/local/bin/opec
		else
			rm -f /usr/local/bin/opec
			die "opec download failed from $_opec_url — render is no longer optional (Phase 4.4 removed the bash fallback). Pre-stage /usr/local/bin/opec or check network connectivity to GitHub releases."
		fi
	fi
	unset _machine _opec_arch _opec_url
fi

# ---------- Args ----------
# shellcheck source=lib/install-args.sh
_install_lib_source install-args.sh
args_parse "$@"

# shellcheck source=lib/install-preflight.sh
_install_lib_source install-preflight.sh
# shellcheck source=lib/install-deps.sh
_install_lib_source install-deps.sh
# shellcheck source=lib/install-network.sh
_install_lib_source install-network.sh
# shellcheck source=lib/install-healthcheck.sh
_install_lib_source install-healthcheck.sh
# shellcheck source=lib/install-systemd.sh
_install_lib_source install-systemd.sh
# shellcheck source=lib/install-awg.sh
_install_lib_source install-awg.sh

preflight_run

deps_install

network_run

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
# shellcheck disable=SC2034  # REALITY_PRIV_PATH passed by name to opec secrets reality-keygen below
REALITY_PRIV_PATH="$PREFIX_ETC/reality.priv"
REALITY_PUB_PATH="$PREFIX_ETC/reality.pub"
REALITY_UUID_PATH="$PREFIX_ETC/reality.uuid"

# Phase 4.8: opec is a hard requirement (Phase 4.4). Unconditionally delegate
# reality keypair generation to opec secrets reality-keygen.
# Dry-run contract: OPEC path must be side-effect-free.
if [[ $DRY_RUN -eq 1 ]]; then
	warn "  [dry-run] would invoke: opec secrets reality-keygen --out-dir $PREFIX_ETC$([[ $FORCE_KEYGEN -eq 1 ]] && echo ' --rotate')"
	REALITY_PUBKEY="DRYRUN-reality-pubkey-placeholder"
	REALITY_UUID="00000000-0000-0000-0000-000000000000"
else
	log "  reality keypair: delegating to opec secrets reality-keygen"
	# Map operator-facing --force-keygen / --rotate-identity (FORCE_KEYGEN=1)
	# to the OPEC --rotate flag. Array form avoids unquoted-expansion fragility.
	_opec_args=(secrets reality-keygen --out-dir "$PREFIX_ETC")
	[[ $FORCE_KEYGEN -eq 1 ]] && _opec_args+=(--rotate)
	if ! opec "${_opec_args[@]}"; then
		die "opec secrets reality-keygen failed"
	fi
	REALITY_PUBKEY="$(cat "$REALITY_PUB_PATH")" \
		|| die "post-keygen: failed to read $REALITY_PUB_PATH"
	REALITY_UUID="$(cat "$REALITY_UUID_PATH")" \
		|| die "post-keygen: failed to read $REALITY_UUID_PATH"
	log "  reality_public_key: $REALITY_PUBKEY"
	log "  reality_uuid: $REALITY_UUID"
	unset _opec_args
fi

# AmneziaWG keypair — generated locally so the private key never leaves
# this host. Public key is sent UP at registration so the central can
# pre-create the awg0 peer entry on motherly before we bring up our own
# interface. Key persists at /etc/amnezia/amneziawg/private.key (mode
# 0600) so re-runs of install.sh re-use it instead of churning a fresh
# pubkey every time.
# Moved above the register dispatcher (Phase 4.3c T4) so AWG_PUB_PATH is
# available to both the OPEC and bash register paths.
# shellcheck disable=SC2034  # AWG_PRIV_PATH passed by name to opec secrets awg-keygen below
AWG_PRIV_PATH="$PREFIX_ETC/awg-private.key"
AWG_PUB_PATH="$PREFIX_ETC/awg-public.key"
# Phase 4.8: opec is a hard requirement. Unconditionally delegate AWG keypair
# generation to opec secrets awg-keygen.
if [[ $DRY_RUN -eq 1 ]]; then
	warn "  [dry-run] would invoke: opec secrets awg-keygen --out-dir $PREFIX_ETC$([[ $FORCE_KEYGEN -eq 1 ]] && echo ' --rotate')"
	AWG_PUBKEY="dryrun-awg-pubkey-placeholder"
else
	log "  awg keypair: delegating to opec secrets awg-keygen"
	install -d -m 0700 "$PREFIX_ETC"
	_opec_args=(secrets awg-keygen --out-dir "$PREFIX_ETC")
	[[ $FORCE_KEYGEN -eq 1 ]] && _opec_args+=(--rotate)
	if ! opec "${_opec_args[@]}"; then
		die "opec secrets awg-keygen failed"
	fi
	AWG_PUBKEY="$(cat "$AWG_PUB_PATH")" \
		|| die "post-awg-keygen: failed to read $AWG_PUB_PATH"
	log "  awg pubkey: $AWG_PUBKEY"
	unset _opec_args
fi

if [[ -n "$MANUAL_CONFIG" ]]; then
	[[ -r "$MANUAL_CONFIG" ]] || die "manual-config file not readable: $MANUAL_CONFIG"
	cp "$MANUAL_CONFIG" "$tmp_cfg"
	log "  using manual config: $MANUAL_CONFIG"
else
	if [[ $DRY_RUN -eq 1 ]]; then
		warn "  [dry-run] would invoke: opec secrets register --registry-url $BACKEND_API ..."
		# Synthesize a placeholder env-file with the same shape downstream
		# Step 5 consumes. reality_public_key + reality_uuid use the values
		# generated/reused by the Reality keygen block above.
		# NOTE: do NOT chmod the parent dir — mktemp already gives 0600 on
		# the file, and chmod'ing /tmp would lock out every other process.
		cat >"$tmp_cfg.env" <<DRYENV
NODE_ID="${PARTNER_ID}-DRYRUN"
BACKEND_ENDPOINT="https://api.oxpulse.chat"
TURN_SECRET="DRYRUN-turn-secret"
REALITY_UUID="${REALITY_UUID}"
REALITY_PUBLIC_KEY="${REALITY_PUBKEY}"
REALITY_SHORT_ID="0123456789abcdef"
REALITY_SERVER_NAME="www.cloudflare.com"
REALITY_ENCRYPTION=""
RELAY_JWT_SECRET="DRYRUN-relay-jwt-secret"
TURNS_SUBDOMAIN="${TURNS_SUBDOMAIN:-}"
DRYENV
		chmod 0600 "$tmp_cfg.env"
		set -a
		# shellcheck disable=SC1090
		. "$tmp_cfg.env"
		set +a
		# Same flag as the real-exec path — env-file was sourced, json_get
		# must NOT re-parse $tmp_cfg (which the dry-run never writes).
		OPEC_REGISTER_USED=1
	else
		log "  register: delegating to opec secrets register"
		_opec_register_args=(
			secrets register
			--registry-url "$BACKEND_API"
			--partner-id "$PARTNER_ID"
			--domain "$DOMAIN"
			--token "$TOKEN"
			--public-ip "$PUBLIC_IP"
			--reality-pub-file "$REALITY_PUB_PATH"
			--reality-uuid-file "$REALITY_UUID_PATH"
			--awg-pub-file "$AWG_PUB_PATH"
			--out-env "$tmp_cfg.env"
		)
		[[ -n "$REGION" ]] && _opec_register_args+=(--region "$REGION")
		[[ -n "$BRANDING_CONFIG" ]] && _opec_register_args+=(--branding-config "$BRANDING_CONFIG")
		if ! opec "${_opec_register_args[@]}"; then
			die "opec secrets register failed"
		fi
		# Source the env-file so downstream steps see NODE_ID, BACKEND_ENDPOINT, etc.
		set -a
		# shellcheck disable=SC1090
		. "$tmp_cfg.env"
		set +a
		unset _opec_register_args
		# Mark to skip json_get section below.
		OPEC_REGISTER_USED=1
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
# When OPEC handled registration, env-file was already sourced above and
# variables are already set. Skip json_get field extraction in that case.
if [[ -z "${OPEC_REGISTER_USED:-}" ]]; then
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
# the $PUBLIC_IP autodetected by network_run via the existing {{PUBLIC_IP}}
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
# top-level scalars. awg_extract() defined in lib/install-awg.sh.
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
# AWG_* above are consumed by configure_amneziawg() in lib/install-awg.sh via
# the _install_lib_source indirection that shellcheck cannot follow (SC2034
# false-positive). This `:` reference makes the intent explicit.
: "${AWG_ALLOCATED_IP:-}" "${AWG_MOTHERLY_PUBKEY:-}" "${AWG_MOTHERLY_ENDPOINT:-}" \
	"${AWG_MOTHERLY_AWG_IP:-}" "${AWG_JC:-}" "${AWG_JMIN:-}" "${AWG_JMAX:-}" \
	"${AWG_S1:-}" "${AWG_S2:-}" "${AWG_S4:-}" "${AWG_H1:-}" "${AWG_H2:-}" \
	"${AWG_H3:-}" "${AWG_H4:-}"
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
export NAIVE_SERVER NAIVE_PORT NAIVE_USER NAIVE_PASS NAIVE_SOCKS_PORT
NAIVE_SERVER=$(json_get naive_server "$tmp_cfg")
NAIVE_PORT=$(json_get naive_port "$tmp_cfg")
NAIVE_USER=$(json_get naive_user "$tmp_cfg")
NAIVE_PASS=$(json_get naive_pass "$tmp_cfg")
# naive-client.json.tpl binds {{NAIVE_SOCKS_PORT}} for the local SOCKS listener.
# Default 1080 matches naive's built-in default; override via node-config naive_socks_port.
NAIVE_SOCKS_PORT=$(json_get naive_socks_port "$tmp_cfg")
[[ -z "$NAIVE_SOCKS_PORT" ]] && NAIVE_SOCKS_PORT="1080"
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
fi  # end: if [[ -z "${OPEC_REGISTER_USED:-}" ]]

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
	# ── service_token persist (Follow-up #2 PR-B) ──────────────────────────────
	# Decision tree mirrors the Reality keypair idempotency guard (§13 incident,
	# line ~915). COALESCE-preserve: server only returns service_token when freshly
	# provisioned; on re-register it omits the field and the file is the authority.
	#
	#  Branch A — server returned token, file absent    → atomically write 0600
	#  Branch B — server returned token, file present   → warn, preserve local
	#  Branch C — server omitted token,  file absent    → fail-loud with recovery
	#  Branch D — server omitted token,  file present   → silent success (idempotent)
	SERVICE_TOKEN=$(jq -r '.service_token // empty' "$tmp_cfg" 2>/dev/null || true)
	SVC_TOKEN_FILE="$PREFIX_ETC/token"
	if [[ -n "$SERVICE_TOKEN" ]]; then
		if [[ ! -e "$SVC_TOKEN_FILE" ]]; then
			# Branch A: fresh install — atomically write token file.
			_tok_tmp=$(mktemp "$SVC_TOKEN_FILE.XXXXXX")
			printf '%s' "$SERVICE_TOKEN" > "$_tok_tmp"
			chmod 0600 "$_tok_tmp"
			mv "$_tok_tmp" "$SVC_TOKEN_FILE"
			unset _tok_tmp
			log "  service token persisted → $SVC_TOKEN_FILE (raw value redacted)"
		else
			# Branch B: operator may have rotated the file manually — don't overwrite.
			warn "  service token returned by server but local file already exists; preserved local copy (use partner-cli rotate-service-token --force to align)"
		fi
	else
		if [[ ! -e "$SVC_TOKEN_FILE" && -z "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
			# Branch C: stranded node — no token from server, no local file.
			NODE_ID_HINT="${NODE_ID:-<NODE_ID>}"
			die "service_token not returned by server (preserved existing) AND no local
$SVC_TOKEN_FILE found. This usually means the volume was wiped after the
original install.

Recovery:
  1. On krolik: docker exec oxpulse-chat partner-cli rotate-service-token \\
        --node-id $NODE_ID_HINT --force
     (copy the printed stkn_ value)
  2. scp the value to this edge as $SVC_TOKEN_FILE
     (mode 0600, root:root)
  3. Re-run install.sh

Or: re-run install.sh with OXPULSE_SERVICE_TOKEN=<raw> in the env
    to skip the file write and use the env var directly."
		else
			# Branch D: idempotent re-install with existing file (or env override).
			log "  service token reused from existing $SVC_TOKEN_FILE"
		fi
	fi
fi
[[ -z "$REALITY_SHORT_ID" ]]   && die "reality_short_id missing from config"
[[ -z "$REALITY_SERVER_NAME" ]] && REALITY_SERVER_NAME="www.samsung.com"
[[ -z "$REALITY_ENCRYPTION" ]] && REALITY_ENCRYPTION="none"
[[ -n "$REGISTER_TURNS_SUBDOMAIN" ]] && TURNS_SUBDOMAIN="$REGISTER_TURNS_SUBDOMAIN"

# Phase 4.3d: Fetch Ed25519 SFU signing public key from /api/partner/keys at
# install time so the SFU container starts with the correct key on day 1
# (the daily refresh timer fires later; install must not leave it empty).
# Phase 4.8: opec is a hard requirement. Unconditionally delegate SFU signing
# key fetch to opec secrets sfu-signing-key.
if [[ $DRY_RUN -eq 1 ]]; then
	warn "  [dry-run] would invoke: opec secrets sfu-signing-key --backend-api $BACKEND_API --out-file $PREFIX_LIB/sfu-keys.env"
else
	log "  sfu-signing-key: delegating to opec secrets sfu-signing-key"
	install -d -m 0700 "$PREFIX_LIB"
	if ! opec secrets sfu-signing-key \
		--backend-api "$BACKEND_API" \
		--out-file "$PREFIX_LIB/sfu-keys.env"; then
		warn "  opec secrets sfu-signing-key failed — SFU_SIGNING_PUBLIC_KEY will be empty"
		# Skip sourcing — if opec aborted between tempfile create and persist,
		# we do not trust whatever is on disk.
	else
		# Re-read the env-file to set SFU_SIGNING_PUBLIC_KEY in shell scope
		# (downstream templates substitute {{SFU_SIGNING_PUBLIC_KEY}}).
		# Note: opec's "empty key from backend" path Ok-returns WITHOUT writing
		# the file, so the [[ -r ]] guard correctly skips it.
		if [[ -r "$PREFIX_LIB/sfu-keys.env" ]]; then
			# shellcheck disable=SC1091
			. "$PREFIX_LIB/sfu-keys.env"
		fi
	fi
fi

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
# `opec render` reads template placeholders from ambient env (it shares the
# same {{VAR}} substitution semantics that the legacy bash render_template
# used pre-Phase-4.4). Every placeholder in the 6 .tpl files must therefore be
# exported. Co-located here so the export list is easy to audit against the
# placeholder set.
PARTNER_DOMAIN="$DOMAIN"
# Caddy tunnel upstream vars — sourced from defaults.conf via channel-render-lib.sh.
# Placeholder names in Caddyfile.tpl must match these var names exactly.
# Bug 3 (2026-05-18 live-edge): defaults.conf is sourced in Step 8 (systemd_install)
# but Step 5 (render) fires first on a fresh install. Under set -u these bare
# references abort. The inline defaults below mirror config/defaults.conf exactly
# and act as a safety belt for the fresh-install path before defaults.conf loads.
# DRIFT HAZARD: if defaults.conf changes these lines must change too (single truth
# is defaults.conf; these are a fall-through guard only).
AWG_MOTHERLY_IP="${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}"
HY2_FALLBACK_HOST="${OXPULSE_HY2_FALLBACK_HOST:-host.docker.internal}"
HY2_FALLBACK_PORT="${OXPULSE_HY2_FALLBACK_PORT:-18443}"
export PARTNER_ID PARTNER_DOMAIN BACKEND_ENDPOINT BACKEND_HOST BACKEND_PORT \
       AWG_MOTHERLY_IP HY2_FALLBACK_HOST HY2_FALLBACK_PORT \
       TURN_SECRET \
       REALITY_UUID REALITY_PUBLIC_KEY REALITY_SHORT_ID REALITY_SERVER_NAME \
       REALITY_ENCRYPTION TURNS_SUBDOMAIN \
       PUBLIC_IP PRIVATE_IP EXTERNAL_IP_LINE \
       IMAGE_VERSION \
       SFU_UDP_PORT SFU_METRICS_PORT SFU_EDGE_ID \
       OTEL_EXPORTER_OTLP_ENDPOINT \
       SFU_SIGNING_PUBLIC_KEY RELAY_JWT_SECRET SIGNALING_SFU_SECRET
# Phase 4.4: all 5 stage templates (compose, caddy, xray, coturn, naive) now go
# through `opec render`. The bash render_template fallback is GONE — opec is a
# hard requirement (auto-fetched at install.sh L60+; `partner-edge-installer.sh`
# release asset ships a recent opec binary alongside). The per-kind validation
# (JSON / YAML / balanced-brace / realm directive) is the whole point — without
# it a corrupt render would slip through to `docker compose up` and fail
# opaquely. Drop opec on PATH? install.sh die's loud at the first render below.
render_with_opec() {
    local kind=$1 src=$2 dst=$3
    command -v opec >/dev/null 2>&1 \
        || die "opec binary not on PATH — Phase 4.4 made it a hard requirement (no bash fallback). Re-run install.sh from a fresh tarball or set INSTALL_OPEC_FROM_PATH=/path/to/opec."
    opec render "$kind" --tpl "$src" --out "$dst" \
        || die "opec render $kind failed for $src — see error above"
}
# Phase 5.5 MAJOR 1: render_channel_soft is now provided by lib/render-channel-lib.sh
# (sourced near the top of this file). The inline definition has been removed to
# avoid duplicate definitions — channel-render-lib.sh is the single source of truth.
render_with_opec compose "$stage/compose.tpl" "$compose_out"
render_with_opec caddy   "$stage/caddy.tpl"   "$caddy_out"
# Phase 1: compute sha256 of rendered Caddyfile and substitute __CADDYFILE_SHA__
# placeholder so /canary/config-hash returns the actual hash at runtime.
_rendered_sha=$(sha256sum "$caddy_out" | awk '{print $1}')
sed -i "s|__CADDYFILE_SHA__|${_rendered_sha}|g" "$caddy_out"
# Bug 4 (2026-05-18 live-edge): Phase 3 (#151) moved xray render to `opec render
# xray` which is pure mustache env-substitution. Old bash re_render_xray in
# channel-render-lib.sh read XRAY_XHTTP_* from node-config.json via
# scripts/read-xhttp.py. After #151 install.sh never exported these vars — opec
# rendered empty placeholders → invalid JSON → validation rejected → install
# failed at Step 5. First production-surface: full wipe+reinstall of
# ru.oxpulse.chat on v0.12.37 (first time Phase 3 render fired in real flow).
#
# Fix: read channels[0].xray.xhttp from node-config.json inline; export as
# ambient env so opec render xray picks them up. Defaults match
# channel-render-lib.sh:166-172 exactly. server is source of truth.
#
# Phase 5.5 followup (FOLLOWUPS.md): teach `opec render xray --node-cfg <path>`
# to read xhttp natively, then drop this env-export block.
XRAY_XHTTP_MODE=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    xhttp = x.get("xhttp", {})
    v = xhttp.get("mode", "") or x.get("mode", "")
    print(v if v else "stream-one")
except Exception:
    print("stream-one")
PYEOF
)
XRAY_XHTTP_PATH=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    v = x.get("xhttp", {}).get("path", "")
    print(v if v else "/xh")
except Exception:
    print("/xh")
PYEOF
)
XRAY_XHTTP_XMUX_MAX_CONCURRENCY=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    xm = x.get("xhttp", {}).get("xmux") or x.get("xmux") or {}
    v = xm.get("maxConcurrency")
    print(v if v is not None else 1)
except Exception:
    print(1)
PYEOF
)
XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    xm = x.get("xhttp", {}).get("xmux") or x.get("xmux") or {}
    v = xm.get("cMaxReuseTimes")
    print(v if v is not None else 64)
except Exception:
    print(64)
PYEOF
)
XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    xm = x.get("xhttp", {}).get("xmux") or x.get("xmux") or {}
    v = xm.get("cMaxLifetimeMs")
    print(v if v is not None else 15000)
except Exception:
    print(15000)
PYEOF
)
XRAY_XHTTP_X_PADDING_BYTES=$(python3 - "${PREFIX_ETC}/node-config.json" <<'PYEOF'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    ch = d.get("channels", []) or [{}]
    x = ch[0].get("xray", {}) if ch[0].get("protocol", "") == "vless-reality" else {}
    v = x.get("xhttp", {}).get("extra", {}).get("xPaddingBytes", "")
    print(v if v else "100-1000")
except Exception:
    print("100-1000")
PYEOF
)
export XRAY_XHTTP_MODE XRAY_XHTTP_PATH \
       XRAY_XHTTP_XMUX_MAX_CONCURRENCY \
       XRAY_XHTTP_XMUX_C_MAX_REUSE_TIMES \
       XRAY_XHTTP_XMUX_C_MAX_LIFETIME_MS \
       XRAY_XHTTP_X_PADDING_BYTES
# Phase 5.5: xray is a bypass channel — render fail-soft.
# render_channel_soft appends to CHANNELS_FAILED on error; does NOT die.
render_channel_soft xray "$stage/xray.tpl" "$xray_out"
render_with_opec coturn  "$stage/coturn.tpl"  "$coturn_out"

# AmneziaWG mesh setup — runs only when the central returned an awg block.
# Builds amneziawg from source, writes /etc/amnezia/amneziawg/awg0.conf
# from the register response, brings up awg-quick@awg0, verifies handshake.
#
# Phase 5.7 Item 2: AWG is an optional mesh channel — failure is fail-soft.
# MAJOR 4 review-fix: install_amneziawg contains die() calls that invoke exit 1
# directly. An `if install_amneziawg; then` guard catches non-zero returns but
# NOT bare exit calls — die() in the same shell process exits the parent install.
# Wrapping in a subshell ( install_amneziawg ) isolates the exit so the outer
# shell continues and can mark awg=failed_at_setup.
# Side-effect: the PATH export inside install_amneziawg is not visible to the
# parent after the subshell exits, but configure_amneziawg only needs the awg
# binaries which are installed on disk, not the Go toolchain PATH.
# Status is written to channels-status.env below (awg=active|failed_at_setup|skipped).
_awg_status="skipped"
if [[ -n "${AWG_ALLOCATED_IP:-}" && -n "${AWG_MOTHERLY_PUBKEY:-}" && $DRY_RUN -eq 0 ]]; then
	log "[awg] central allocated $AWG_ALLOCATED_IP edge_id=$SFU_EDGE_ID — bringing up awg0"
	if ( install_amneziawg ); then
		configure_amneziawg
		_awg_status="active"
	else
		warn "[awg] install_amneziawg failed — edge will run without VPN mesh"
		warn "      Run 'install_amneziawg' manually after fixing the build environment."
		_awg_status="failed_at_setup"
	fi
elif [[ -z "${AWG_ALLOCATED_IP:-}" ]]; then
	log "[awg] central did not return awg config — running without VPN mesh (legacy path)"
fi
mkdir -p "$cover_out_dir"
install -m 0644 "$stage/cover/cover.html" "$cover_out_dir/cover.html"
# Render CH3 / CH5 if the backend provided the required vars.
# When rendered, activate the corresponding docker compose profile so the
# service starts alongside the core stack (docker compose --profile ch3 up).
COMPOSE_PROFILES_EXTRA=""
# Phase 1.7 — fetch shared hy2 credentials + render hysteria2-client.yaml.
# For Phase 1 these are fleet-shared (per-edge identity = Phase 7).
# Source: GET /api/partner/hy2-credentials returns JSON {auth_pass, obfs_pass}
# Falls back to env if API not yet deployed (HTTP 404 / connection refused).
# channel-render-lib.sh (including re_render_hysteria2) is already in scope —
# sourced unconditionally with die-on-missing at L766-776 (T2/T3 NIT: redundant
# source block removed from here).
#
# MAJOR 3 fix: _hy2_status is determined here (not via post-hoc sed patch) and
# written atomically to channels-status.env below.
# BLOCKER 2 fix: hysteria2 is counted in _CHANNELS_TOTAL when HYSTERIA2_SERVER
# is set, so an xray+naive fail does not kill an install where hy2 succeeds.
_hy2_status="skipped"
if [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
	# Mark as attempted so it counts toward _CHANNELS_TOTAL.
	_hy2_status="failed_at_start"
fi
if [[ -n "${HYSTERIA2_SERVER:-}" ]] && declare -f re_render_hysteria2 >/dev/null 2>&1; then
	log "fetching hy2 credentials"
	_hy2_creds_url="${BACKEND_API}/api/partner/hy2-credentials"
	_hy2_creds_json=$(curl -fsS --max-time 10 \
		-H "Authorization: Bearer $(read_service_token || echo '')" \
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
		_hy2_status="active"
	else
		warn "hy2 credentials unavailable — installing awg-only mode (hy2 will provision on next upgrade)"
		# _hy2_status stays "failed_at_start" — credentials missing is a provisioning failure
	fi
elif [[ -n "${HYSTERIA2_SERVER:-}" ]]; then
	warn "hy2 channel: re_render_hysteria2 not available — channel failed"
	# _hy2_status stays "failed_at_start"
fi
if [[ "${_hy2_status}" == "active" ]]; then
	COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch3"
	log "  hysteria2 CH3 profile enabled"
fi
if [[ -n "${NAIVE_SERVER:-}" ]]; then
	# Phase 5.5: naive is a bypass channel — render fail-soft.
	if render_channel_soft naive "$stage/naive.tpl" "$PREFIX_ETC/naive-client.json"; then
		chmod 0600 "$PREFIX_ETC/naive-client.json"
		COMPOSE_PROFILES_EXTRA="${COMPOSE_PROFILES_EXTRA:+$COMPOSE_PROFILES_EXTRA,}ch5"
		log "  naive-client.json rendered (CH5 profile enabled)"
	fi
fi
rm -rf "$stage"

# Phase 5.5: all-channels-failed guard.
# BLOCKER 2 fix: count all three bypass channels when configured.
# CHANNELS_FAILED tracks xray + naive render failures.
# _hy2_status != active means hy2 failed when HYSTERIA2_SERVER was set.
_CHANNELS_TOTAL=1  # xray always attempted
[[ -n "${NAIVE_SERVER:-}" ]] && _CHANNELS_TOTAL=$((_CHANNELS_TOTAL + 1))
[[ -n "${HYSTERIA2_SERVER:-}" ]] && _CHANNELS_TOTAL=$((_CHANNELS_TOTAL + 1))
# Map hy2 failed_at_start into CHANNELS_FAILED so the count is unified.
[[ "${_hy2_status}" == "failed_at_start" ]] && CHANNELS_FAILED+=("hysteria2")
CHANNELS_FAILED_COUNT=${#CHANNELS_FAILED[@]}
if [[ $CHANNELS_FAILED_COUNT -ge $_CHANNELS_TOTAL && $_CHANNELS_TOTAL -gt 0 ]]; then
	die "all channels failed render: ${CHANNELS_FAILED[*]:-<none>} — no bypass channel is usable; check opec and node-config"
fi
[[ $CHANNELS_FAILED_COUNT -gt 0 ]] && \
	warn "  ${CHANNELS_FAILED_COUNT} channel(s) failed render (${CHANNELS_FAILED[*]:-}); continuing with remaining channels"
unset _CHANNELS_TOTAL

# Phase 5.5: write per-channel status to state file consumed by healthcheck.
# Statuses: active|failed_at_render|failed_at_start|skipped
# BLOCKER 1 fix: compose strip applied BELOW this block, after statuses are final.
# BLOCKER 3 fix: atomic tmp+rename so a mid-write crash leaves no partial file.
if [[ $DRY_RUN -eq 0 ]]; then
	install -d -m 0700 "$PREFIX_LIB"
	_chs_tmp=$(mktemp "$PREFIX_LIB/.channels-status-XXXXXX.tmp")
	{
		printf '# Generated by install.sh — DO NOT EDIT\n'
		# xray is always attempted; naive only when NAIVE_SERVER is set
		if _in_array xray "${CHANNELS_FAILED[@]:-}"; then
			printf 'xray=%s\n' "failed_at_render"
		else
			printf 'xray=%s\n' "active"
		fi
		printf 'hysteria2=%s\n' "${_hy2_status}"
		if [[ -n "${NAIVE_SERVER:-}" ]]; then
			if _in_array naive "${CHANNELS_FAILED[@]:-}"; then
				printf 'naive=%s\n' "failed_at_render"
			else
				printf 'naive=%s\n' "active"
			fi
		else
			printf 'naive=%s\n' "skipped"
		fi
		# Phase 5.7: AWG mesh channel status (active|failed_at_setup|skipped)
		printf 'awg=%s\n' "${_awg_status}"
	} > "$_chs_tmp"
	chmod 0640 "$_chs_tmp"
	mv -f "$_chs_tmp" "$PREFIX_LIB/channels-status.env"
	unset _chs_tmp
fi
unset _hy2_status _awg_status

# Secrets-containing files → 0600.
chmod 0600 "$xray_out" "$coturn_out" || true
log "  rendered → $compose_out (+ Caddyfile, xray-client.json, coturn.conf, cover/cover.html)"

# BLOCKER 1 fix — Phase 5.5: strip failed channels from rendered docker-compose.yml.
# compose.tpl is rendered strictly (render_with_opec) and contains service blocks
# for ALL channels (xray, hysteria2, naive). If a channel failed render its config
# file (e.g. xray-client.json) is missing, so `docker compose up` would fail on
# the volume mount. Strip failed-channel service blocks + their depends_on refs now,
# while CHANNELS_FAILED is finalised and compose_out is still on disk.
# Phase 5.5 MAJOR 1: delegated to compose_strip_failed_channels() from
# lib/render-channel-lib.sh (sourced at top-of-file).
if [[ ${#CHANNELS_FAILED[@]} -gt 0 && -f "$compose_out" ]]; then
	compose_strip_failed_channels "$compose_out" "${CHANNELS_FAILED[@]}"
fi

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
healthcheck_run

fi  # end BAKE_MODE=0 (hydrate path)

# ---------- Step 8: systemd ----------
systemd_run

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
