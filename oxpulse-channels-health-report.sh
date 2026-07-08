#!/usr/bin/env bash
# oxpulse-channels-health-report.sh — per-channel REAL end-to-end tunnel
# probe + health report to the central server via
# POST /api/partner/channel-health.
#
# Invoked by oxpulse-channels-health-report.timer every 60s.
# Each provisioned channel produces one POST with the server's schema:
#   { node_id, channel_name, channel_rtt_ms?, channel_handshake_ok?,
#     channel_probed_at }
#
# probe_ch1/ch2/ch3 each dial all the way through their own tunnel/upstream
# to the central backend's lightweight /api/health (or the local canary
# route that fronts it) — NOT a local container-liveness check. A relay
# whose process is up but whose tunnel is DPI-blocked end-to-end (live-
# verified on zvonilka: xray listening, VLESS-Reality 502 on the real path)
# now reports channel_handshake_ok=false instead of a false-healthy local
# check. ch1-ch3 run CONCURRENTLY (backgrounded, each bounded by its own
# curl --max-time via OXPULSE_CHANNEL_PROBE_TIMEOUT) so one blocked channel
# cannot delay the others.
#
# Usage:
#   oxpulse-channels-health-report           — probe + report, exit
#   oxpulse-channels-health-report --dry-run — print JSON to stdout, skip POST
#   oxpulse-channels-health-report --once    — synonym for default (for clarity)
#   oxpulse-channels-health-report --curl-trace — log Authorization header (dry-run only)
#
# Federation plan §12, M2 #6a.
set -euo pipefail

# ---------- paths / env ----------
_SBIN=/usr/local/sbin
_TOKEN_LIB="${_TOKEN_LIB:-${_SBIN}/oxpulse-token-lib.sh}"
_PREFIX_ETC="${PARTNER_EDGE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
_NODE_CONFIG="${_NODE_CONFIG:-${_PREFIX_ETC}/node-config.json}"

# Prefer installed defaults.conf (canonical share path — Bug 8 fix);
# fall back to repo-relative for local testing.
# install-systemd.sh installs this to /usr/local/share/oxpulse-partner-edge/config/.
_DEFAULTS_CONF="${_DEFAULTS_CONF:-/usr/local/share/oxpulse-partner-edge/config/defaults.conf}"
_DEFAULTS_CONF_LOCAL="${_DEFAULTS_CONF_LOCAL:-$(dirname "$0")/config/defaults.conf}"

# lib/peer-ip-guard-lib.sh sha-verified install path — same PREFIX_SBIN as
# _TOKEN_LIB above, and the same install target telegram-alert-lib.sh uses
# (the existing lib consumed by THIS script's transition detector; installed
# by lib/install-systemd.sh's _systemd_install_lib_scripts AND synced to
# existing fleet nodes by upgrade.sh's _HOST_SCRIPT_SBIN_FILES). Repo-relative
# fallback is for local dev/test runs from a checkout only.
_PEER_IP_GUARD_LIB="${_PEER_IP_GUARD_LIB:-${_SBIN}/peer-ip-guard-lib.sh}"
_PEER_IP_GUARD_LIB_LOCAL="${_PEER_IP_GUARD_LIB_LOCAL:-$(dirname "$0")/lib/peer-ip-guard-lib.sh}"

# ---------- flags ----------
DRY_RUN=0
CURL_TRACE=0
SERVE_ONLY=0

for _arg in "$@"; do
    case "$_arg" in
        --dry-run)    DRY_RUN=1 ;;
        --curl-trace) CURL_TRACE=1 ;;
        --serveability) SERVE_ONLY=1 ;;   # settle-gate probe-only mode (see _emit_serveability)
        --once)       ;;   # no-op; timer drives cadence, --once is for clarity
        *) printf 'WARN: unknown flag: %s\n' "$_arg" >&2 ;;
    esac
done
unset _arg

# ---------- logging ----------
log()  { printf '[oxpulse-health] %s\n' "$*" >&2; }
warn() { printf '[oxpulse-health] WARN: %s\n' "$*" >&2; }
die()  { printf '[oxpulse-health] ERR:  %s\n' "$*" >&2; exit 1; }

# ---------- load token lib ----------
if [[ -r "$_TOKEN_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_TOKEN_LIB"
else
    # Inline fallback — same logic as oxpulse-token-lib.sh.
    read_service_token() {
        if [[ -n "${OXPULSE_SERVICE_TOKEN:-}" ]]; then
            printf '%s' "$OXPULSE_SERVICE_TOKEN"; return 0
        fi
        if [[ -r "${_PREFIX_ETC}/token" ]]; then
            cat "${_PREFIX_ETC}/token"; return 0
        fi
        return 1
    }
fi

# ---------- load peer-ip-guard-lib.sh (SSRF / internal-IP classification) ----------
# Security-critical (SEC-CR-301/306/322-02): sourced fail-closed from the
# sha-verified installed dir (install-systemd.sh syncs, lib-checksums.txt
# verifies at install time — ADR-6 of the 2026-07-08 health-report-lib-
# extraction plan). NOT re-fetched per-tick — the integrity gate already ran
# upstream at install/upgrade time; a 60s-cadence network round-trip just to
# re-verify would be pure cost for zero added safety.
#
# Unlike the token-lib load above, there is NO inline duplicate-logic
# fallback here: an SSRF guard that silently degrades to a second, drift-
# prone copy is worse than one that refuses to run. If neither the installed
# nor the repo-relative (local dev/test) path resolves, die loudly.
if [[ -r "$_PEER_IP_GUARD_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_PEER_IP_GUARD_LIB"
elif [[ -r "$_PEER_IP_GUARD_LIB_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$_PEER_IP_GUARD_LIB_LOCAL"
else
    die "peer-ip-guard-lib.sh not found (checked $_PEER_IP_GUARD_LIB and $_PEER_IP_GUARD_LIB_LOCAL) — refusing to run without the SSRF guard"
fi

# ---------- load defaults.conf ----------
if [[ -r "$_DEFAULTS_CONF" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF"
elif [[ -r "$_DEFAULTS_CONF_LOCAL" ]]; then
    # shellcheck source=/dev/null
    source "$_DEFAULTS_CONF_LOCAL"
fi

OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API:-${OXPULSE_BACKEND_URL:-https://api.oxpulse.chat}}"
OXPULSE_BACKEND_API="${OXPULSE_BACKEND_API%/}"

# ---------- preflight ----------
command -v jq    >/dev/null 2>&1 || die "jq not found — install jq"
command -v curl  >/dev/null 2>&1 || die "curl not found"

[[ -r "$_NODE_CONFIG" ]] || die "node-config.json not found at $_NODE_CONFIG"

NODE_ID=$(jq -r '.node_id // empty' "$_NODE_CONFIG" 2>/dev/null)
[[ -n "$NODE_ID" ]] || die "node_id missing in $_NODE_CONFIG"

# ---------- installer version (defence-in-depth freshness signal) ----------
# Read installer bundle version from the VERSION file (same source as hydrate.sh).
# Canonical install path: /usr/local/share/oxpulse-partner-edge/VERSION.
# Local-dev / CI fallback: script-dir VERSION.
# Operator override: OXPULSE_INSTALLER_VERSION env (matches OXPULSE_BACKEND_API pattern).
# Test override: _VERSION_FILE env (set by tests to avoid hitting the real install path).
# If the file is unreadable or empty, the field is omitted from the payload;
# the server COALESCE-preserves the prior value — no DB write, no failure.
_VERSION_FILE="${_VERSION_FILE:-/usr/local/share/oxpulse-partner-edge/VERSION}"
_installer_version=""
if [[ -n "${OXPULSE_INSTALLER_VERSION:-}" ]]; then
    _installer_version="$OXPULSE_INSTALLER_VERSION"
elif [[ -r "$_VERSION_FILE" ]]; then
    _installer_version=$(awk '{print $1; exit}' "$_VERSION_FILE" 2>/dev/null || true)
fi

# ---------- load channel-health-lib.sh (P2 strangler extraction) ----------
# Provides probe_ch1-4, _resolve_coturn_probe_target, _elapsed_ms,
# _write_probe_mode_state, _post_channel, _check_upstream_transitions,
# _emit_serveability. Bears BOTH externally-depended wire contracts (see the
# lib's own header): the POST /api/partner/channel-health body shape, and the
# ^chN=(OK|DOWN)$ --serveability stdout upgrade.sh's auto-rollback settle gate
# greps. Sourced fail-closed from the installed lib dir (ADR-6: no per-tick
# network re-fetch — install-systemd.sh already copies + the release pipeline
# already checksums this file at install/upgrade time). Mirrors this exact
# script's own telegram-alert-lib.sh runtime-source precedent below (search
# "_check_upstream_transitions"), hardened to fail-closed here since these are
# load-bearing probe functions, not an optional feature.
_CHANNEL_HEALTH_LIB="${_CHANNEL_HEALTH_LIB:-}"
if [[ -z "$_CHANNEL_HEALTH_LIB" ]]; then
    for _chl_cand in \
        "$(dirname "$0")/lib/channel-health-lib.sh" \
        "${PREFIX_SBIN:-/usr/local/sbin}/channel-health-lib.sh"; do
        if [[ -r "$_chl_cand" ]]; then
            _CHANNEL_HEALTH_LIB="$_chl_cand"
            break
        fi
    done
fi
[[ -n "$_CHANNEL_HEALTH_LIB" && -r "$_CHANNEL_HEALTH_LIB" ]] || \
    die "channel-health-lib.sh not found (tried \$(dirname \$0)/lib and \${PREFIX_SBIN:-/usr/local/sbin}) — cannot probe channels without it"
# shellcheck source=lib/channel-health-lib.sh
source "$_CHANNEL_HEALTH_LIB"
unset _chl_cand

# ---------- load cross-probe lib (P3b mesh peer-probe) ----------
# _run_peer_probe_loop and its 7 helpers were extracted to lib/cross-probe-lib.sh
# (strangler-fig, no behaviour change). Source order: adjacent checkout (dev/CI)
# → installed sbin (already sha256-verified at install/upgrade time via
# lib-checksums.txt / SHA256SUMS; ADR-6 — we do NOT re-fetch/re-verify per 60s
# tick). FAIL-SOFT by design: a missing lib disables mesh probing with a loud
# warn but MUST NOT abort the script. A top-level `die` here would make
# `--serveability --dry-run` exit non-zero; upgrade.sh's settle gate would then
# read no `^ch[0-9]+=(OK|DOWN)$` lines, verdict SERVING_LOST, and AUTO-ROLLBACK a
# healthy box fleet-wide (the "cheburator" chicken-and-egg class, upgrade.sh:771).
# This lib is a mesh-probe FEATURE, not the SSRF guard (that is peer-ip-guard),
# so skipping it degrades a feature, not security. Unlike peer-ip-guard-lib.sh
# and channel-health-lib.sh above (both sourced fail-CLOSED — a missing SSRF
# guard or missing channel probes must die(), not silently degrade), this lib
# is sourced fail-SOFT: cross-probe is a mesh-observability feature layered on
# top of already-healthy channel probing, not a safety-critical dependency of it.
# Requires _host_is_internal (peer-ip-guard-lib.sh, sourced above) and
# _elapsed_ms (channel-health-lib.sh, sourced above) to already be in scope —
# this script must source peer-ip-guard-lib.sh and channel-health-lib.sh BEFORE
# this block (it does, above) or _probe_peer_coturn/_probe_peer_udp_stun will
# fail at runtime with an undefined-function error the first time a peer probe
# actually runs.
if source "${SCRIPT_DIR:-$(dirname "$0")}/lib/cross-probe-lib.sh" 2>/dev/null; then
    :
elif source "${PREFIX_SBIN:-/usr/local/sbin}/cross-probe-lib.sh" 2>/dev/null; then
    :
else
    warn "cross-probe-lib.sh not found (adjacent or ${PREFIX_SBIN:-/usr/local/sbin}) — mesh peer-probe disabled this run"
    # Fail-soft stub: the only top-level caller is `_run_peer_probe_loop || true`;
    # its 7 helpers are unreachable without it, so a no-op loop is sufficient.
    _run_peer_probe_loop() { return 0; }
fi

# ---------- main ----------
mapfile -t _PROVISIONED < <(jq -r '.channels[]?.id // empty' "$_NODE_CONFIG" 2>/dev/null || true)

# Serve-ability probe mode: emit chN=OK|DOWN and exit BEFORE the report/POST/
# peer-probe machinery. Safe on a box with no channels (emits nothing, exit 0).
if [[ "${SERVE_ONLY:-0}" -eq 1 ]]; then
    _emit_serveability
    exit 0
fi

if [[ "${#_PROVISIONED[@]}" -eq 0 ]]; then
    log "no channels in node-config.json — nothing to report"
    # A node with no local channels can still be a prober (P3b mesh producer);
    # run the peer-probe pass before exiting. ||true shields set -e (mirrors the
    # probe_ch4 ||-guard convention) — the loop self-skips on no token/roster.
    _run_peer_probe_loop || true
    _check_upstream_transitions
    exit 0
fi

_AUTH_FAIL=0

# Concurrency (real-tunnel rewrite): each provisioned channel's probe is
# backgrounded so a single stuck/blocked channel (e.g. ch1 blackholed by
# ТСПУ) cannot delay the others' reports. Every probe's own external call is
# bounded by its own hard timeout (curl --max-time via
# OXPULSE_CHANNEL_PROBE_TIMEOUT for ch1/ch2/ch3; probe_ch4 keeps its existing
# internal `timeout` calls) — nothing backgrounded here can hang forever.
# Results land in per-channel temp files under a private mktemp -d dir, then
# POST runs serially afterwards (POST already has its own bounded --max-time
# and gains nothing from concurrency; only the PROBE phase was ever the
# source of head-of-line blocking).
#
# NOTE: deliberately NOT using an EXIT trap for cleanup here — this dir is
# read-and-removed inline below, well before _run_peer_probe_loop runs, and
# that function unconditionally clears EXIT/TERM/INT traps on its normal
# return path (`trap - EXIT TERM INT`), which would silently clobber any
# trap registered here.
_CHAN_TMPROOT=$(mktemp -d) || die "mktemp -d failed for channel-probe concurrency"

declare -a _CHAN_NAMES=()
declare -a _CHAN_OUT=()
_chan_idx=0

for _chan in "${_PROVISIONED[@]}"; do
    # Channel ids in node-config may carry a node-specific suffix (e.g. "ch1-zvonilka").
    # Match on prefix: ch1* = Reality/VLESS, ch2* = AmneziaWG, ch3* = Hysteria2.
    # The server expects canonical names ch1/ch2/ch3, not the local variant.
    case "$_chan" in
        ch1*)
            _probe_fn=probe_ch1
            _fallback='{"channel_name":"ch1","channel_handshake_ok":false}'
            ;;
        ch2*)
            _probe_fn=probe_ch2
            _fallback='{"channel_name":"ch2","channel_handshake_ok":false}'
            ;;
        ch3*)
            _probe_fn=probe_ch3
            _fallback='{"channel_name":"ch3","channel_rtt_ms":0,"channel_handshake_ok":false}'
            ;;
        ch4*)
            _probe_fn=probe_ch4
            # The fallback here mirrors probe_ch4's own ||-guard convention:
            # probe_ch4 relies on being called through a shielded fallback to
            # remain safe under set -e; it must not be called bare elsewhere.
            _fallback='{"channel_name":"coturn","channel_rtt_ms":0,"channel_handshake_ok":false,"channel_probe_mode":"error"}'
            ;;
        ch0*|naive*|ch5*|ch6*)
            # ch0 = naive/socks fallback channel (install.sh PROTOCOL_ID_MAP
            # defaults unmapped protocols, incl. naive, to ch0). No probe_ch0
            # exists yet — this is a deployed-but-unprobed channel, not a
            # misroute, so it gets the honest "not yet wired" skip rather
            # than falling into the "unknown channel" catch-all below. The
            # real naive health probe is tracked separately (Escalation #3).
            log "$_chan not yet wired on edge — skipping"
            continue
            ;;
        *)
            warn "unknown channel '$_chan' — skipping"
            continue
            ;;
    esac

    _chan_out="$_CHAN_TMPROOT/$_chan_idx.json"
    _chan_idx=$((_chan_idx + 1))
    ( "$_probe_fn" 2>/dev/null || printf '%s' "$_fallback" ) > "$_chan_out" &
    _CHAN_NAMES+=("$_chan")
    _CHAN_OUT+=("$_chan_out")
done

# Block until every backgrounded probe above has written its result file.
# Bare `wait` (no PID args) waits for ALL background jobs and always returns
# 0 — it cannot itself trip `set -e`, so no `|| true` guard is needed.
wait

for _i in "${!_CHAN_NAMES[@]}"; do
    _payload=$(cat "${_CHAN_OUT[$_i]}" 2>/dev/null || true)
    if [[ -z "$_payload" ]]; then
        warn "${_CHAN_NAMES[$_i]}: empty probe result file — reporting as failed"
        _payload="{\"channel_name\":\"${_CHAN_NAMES[$_i]}\",\"channel_handshake_ok\":false}"
    fi
    if ! _post_channel "$_payload"; then
        _AUTH_FAIL=$((_AUTH_FAIL + 1))
    fi
done

rm -rf "$_CHAN_TMPROOT"

# P3b mesh producer — probe roster peers' TURNS:443 + report prober-attributed
# verdicts. Hung after the self-channel loop, before the auth-fail gate, so a
# peer-probe never masks a self-report auth failure. ||true shields set -e (the
# loop returns 0 on every path; self-skips on no token/roster).
_run_peer_probe_loop || true

# auth failures = exit 1 (timer logs; no infinite loop)
[[ "$_AUTH_FAIL" -eq 0 ]] || exit 1

_check_upstream_transitions
exit 0
