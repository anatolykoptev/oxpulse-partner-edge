#!/usr/bin/env bash
# upgrade.sh — pull a newer image tag, sync host-scripts, recreate services,
# verify, optionally roll back.
#
# Every apply (plain or --with-templates) now atomically upgrades BOTH:
#   • Docker image tags (caddy, sfu, xray containers via compose pull+up)
#   • Host-level scripts (oxpulse-channels-health-report, upgrade.sh, refresh,
#     sni-rotate, lib scripts, systemd units) fetched from the release tag
#
# This closes the gap where host-script changes (e.g. ch4 coturn probe in
# oxpulse-channels-health-report.sh, new systemd drop-ins) were silently skipped
# by upgrade.sh and only reached an edge via a full installer re-run.
# Example: v0.12.57 bundled BOTH sfu-siege-transport image change (#255) AND
# ch4 health-report change; old upgrade.sh deployed only the image.
#
# Usage:
#   oxpulse-partner-edge-upgrade                       # pull :latest + sync host-scripts
#   oxpulse-partner-edge-upgrade v0.2.0                # pin to specific tag
#   oxpulse-partner-edge-upgrade --check               # report pending upgrade, don't apply
#   oxpulse-partner-edge-upgrade --rollback            # restore previous tag + host-scripts
#   oxpulse-partner-edge-upgrade --templates-only      # re-render xray config from upstream template, no image pull
#   oxpulse-partner-edge-upgrade --with-templates      # re-render Caddyfile + healthcheck + pull new image (atomic)
#   oxpulse-partner-edge-upgrade --host-scripts-only   # sync host-scripts only; NO image pull/recreate
#   oxpulse-partner-edge-upgrade --ghcr-token=ghp_xxx  # persist GHCR PAT before pull (one-time)
#   oxpulse-partner-edge-upgrade --dry-run             # print plan, skip docker and file writes
#   oxpulse-partner-edge-upgrade --dry-run --skip-check=1,3  # skip specific conflict checks (1-8)
#   oxpulse-partner-edge-upgrade --allow-unverified    # skip SHA256SUMS check (dev/test only, NEVER on relay)
#   oxpulse-partner-edge-upgrade --no-integrity        # install.sh-parity alias for --allow-unverified
#
# Tag-form note: starting with v0.12.60, git tags, GitHub release tags, and GHCR
# image tags ALL use the same vX.Y.Z form — no component prefix. release-please-config.json
# has no "component" key, so release-please no longer prepends "partner-edge-".
# Releases ≤v0.12.59 used partner-edge-vX.Y.Z; upgrade.sh handles that old form
# gracefully via normalize_target() so edges mid-flight are not broken.
#
# --dry-run conflict checks (--with-templates only):
#   1 [CATASTROPHIC] Caddyfile validates against currently-running image
#   2 [WARNING]      docker-compose.yml structural drift (ports, env keys, services)
#   3 [CATASTROPHIC] Image tag direction (downgrade detection)
#   4 [INFO]         healthcheck.sh check-line diff
#   5 [INFO]         CADDYFILE_SHA before/after
#   6 [WARNING]      Unsubstituted placeholders in rendered Caddyfile
#   7 [CATASTROPHIC] GHCR token availability
#   8 [WARNING]      Disk space on /var/lib/docker
#
# GHCR auth: ghcr.io/anatolykoptev/partner-edge-* images are private. Provide
# a token via --ghcr-token=ghp_xxx (saved to /etc/oxpulse-partner-edge/ghcr.token
# mode 0600) or OXPULSE_GHCR_TOKEN env (one-shot, not persisted). Once saved,
# the token is reused on every subsequent run; rotate with --ghcr-token=<new>.
# See ghcr-auth-lib.sh for the full auth flow.
set -euo pipefail

PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
PREFIX_SBIN="${OXPULSE_PREFIX_SBIN:-/usr/local/sbin}"
PREFIX_BIN="${OXPULSE_PREFIX_BIN:-/usr/local/bin}"
PREFIX_LIBDIR="${OXPULSE_PREFIX_LIBDIR:-/usr/local/lib/partner-edge}"
PREFIX_SHARE="${OXPULSE_PREFIX_SHARE:-/usr/local/share}"
SYSTEMD_DIR="${OXPULSE_SYSTEMD_DIR:-/etc/systemd/system}"
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"
STATE_FILE="$PREFIX_LIB/install.env"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"
PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
PREV_CADDYFILE="$PREFIX_LIB/Caddyfile.prev"
PREV_HEALTHCHECK="$PREFIX_LIB/healthcheck.prev"
# Directory where pre-upgrade host-script snapshots are stored for rollback.
PREV_HOST_SCRIPTS_DIR="$PREFIX_LIB/host-scripts.prev"
HEALTHCHECK="${OXPULSE_HEALTHCHECK:-/usr/local/sbin/oxpulse-partner-edge-healthcheck}"
# Installed per-channel health reporter — the upgrade settle gate invokes it in
# a focused --serveability mode to REUSE the honest end-to-end probe_ch1/ch2/ch3.
CHANNELS_HEALTH_REPORT="${OXPULSE_CHANNELS_HEALTH_REPORT:-$PREFIX_SBIN/oxpulse-channels-health-report}"
# @RELEASE_TAG_PLACEHOLDER@ in the default below is substituted by release.yml to the release tag
# (vX.Y.Z starting at v0.12.60) so REPO_RAW fetches are pinned to the exact release
# ref, not main HEAD. Without this pin the bytes fetched from raw.githubusercontent.com
# do not match the SHA256SUMS released for that tag (main is always ahead of any tag).
# Tests and operator overrides can still use OXPULSE_REPO_RAW to point at a fixture.
OXPULSE_UPGRADE_TAG="${OXPULSE_UPGRADE_TAG:-@RELEASE_TAG@}"
# Phase 3 (Decision 4) — baseline-aware health gate.
# Default: 0 = use regression-based gate (no rollback on pre-existing reds).
# Set to 1 to restore the legacy "all-green-required" gate for diagnosis.
OXPULSE_ABSOLUTE_HEALTH_GATE="${OXPULSE_ABSOLUTE_HEALTH_GATE:-0}"
# Initialize OXPULSE_MIRROR_BASE to empty string so the strip at line 92 and
# the -n checks below are safe under set -u on edges with no mirror configured
# (e.g. zvonilka GitHub-direct edges where install.env lacks OXPULSE_MIRROR_BASE).
OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE:-}"

# Mirror awareness: OXPULSE_MIRROR_BASE is the plain-TLS mirror used by edges
# DPI-blocked from GitHub (e.g. zvonilka RU relays).  install.sh sets
# REPO_RAW=$MIRROR_BASE/raw when the mirror is set; upgrade.sh reads the
# persisted OXPULSE_MIRROR_BASE from install.env (written at install time) and
# applies the same polarity so that all host-script fetches work on mirror-
# installed edges without requiring operator env injection on every upgrade run.
#
# Resolution order (highest → lowest priority):
#   1. OXPULSE_REPO_RAW env  — operator/test override, wins unconditionally
#   2. OXPULSE_MIRROR_BASE env  — explicit mirror override for this run
#   3. OXPULSE_MIRROR_BASE from install.env  — persisted at install time
#   4. raw.githubusercontent.com pinned to OXPULSE_UPGRADE_TAG (or main for dev)
#
# RELEASES_BASE follows the same polarity: mirror serves release assets under
# the same path structure as GitHub releases ($MIRROR_BASE/$tag/<asset>).
# If only OXPULSE_RELEASES_BASE is set (test override), it wins over mirror.

# Load OXPULSE_MIRROR_BASE from install.env if not already in env.
# We do this before resolving REPO_RAW so the state file overrides the default.
if [[ -z "${OXPULSE_MIRROR_BASE:-}" && -r "${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}/install.env" ]]; then
    _state_mirror=$(grep '^OXPULSE_MIRROR_BASE=' \
        "${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}/install.env" \
        2>/dev/null | cut -d= -f2- | tr -d '"' || true)
    [[ -n "$_state_mirror" ]] && OXPULSE_MIRROR_BASE="$_state_mirror"
    unset _state_mirror
fi
OXPULSE_MIRROR_BASE="${OXPULSE_MIRROR_BASE%/}"

if [[ -n "${OXPULSE_REPO_RAW:-}" ]]; then
    REPO_RAW="$OXPULSE_REPO_RAW"
elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
    # Mirror installed: raw files come from $MIRROR_BASE/raw (same as install.sh).
    REPO_RAW="$OXPULSE_MIRROR_BASE/raw"
elif [[ ! "${OXPULSE_UPGRADE_TAG}" =~ ^v[0-9]+\. ]]; then
    # Placeholder not substituted or not a real vX.Y.Z tag. Fall back to main
    # so developer/test runs still work. Released upgrade.sh has OXPULSE_UPGRADE_TAG
    # set to the real tag (vX.Y.Z form) by release.yml sed substitution.
    REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
else
    REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${OXPULSE_UPGRADE_TAG}"
fi

# GitHub releases download base for the target tag.  Tests can override via
# OXPULSE_RELEASES_BASE to point at a local fixture server.
# Mirror polarity: if OXPULSE_MIRROR_BASE is set, releases are served from
# $MIRROR_BASE/<tag>/<asset> (operator must mirror the GitHub release layout).
# OXPULSE_RELEASES_BASE env wins unconditionally (test/operator override).
if [[ -n "${OXPULSE_RELEASES_BASE:-}" ]]; then
    RELEASES_BASE="$OXPULSE_RELEASES_BASE"
elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
    RELEASES_BASE="$OXPULSE_MIRROR_BASE"
else
    RELEASES_BASE="https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download"
fi
# shellcheck disable=SC2034  # NODE_CFG + XRAY_CFG used by channel-render-lib.sh (sourced via _source_lib)
NODE_CFG="$PREFIX_ETC/node-config.json"
# shellcheck disable=SC2034
XRAY_CFG="$PREFIX_ETC/xray-client.json"
# Allow tests to override docker binary (e.g. DOCKER_BIN=true for dry-run).
DOCKER_BIN="${DOCKER_BIN:-docker}"
# Allow tests to override systemctl (e.g. SYSTEMCTL_BIN=true to no-op).
SYSTEMCTL_BIN="${SYSTEMCTL_BIN:-systemctl}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { while IFS= read -r _line; do printf '\033[31mERR\033[0m %s\n' "$_line" >&2; done <<< "$*"; exit 1; }

# _lookup_expected_hash NAME MANIFEST_FILE — resolve NAME's expected sha256 from a
# checksum manifest (lib-checksums.txt or a release SHA256SUMS), field-exact matching
# column 2 (NOT a suffix grep — a suffix match would also hit an unrelated file whose
# name happens to end in NAME, e.g. "foo-name.sh" matching a manifest line for
# "name.sh"), and tolerating an optional "./" prefix in that column (the common
# `find`-generated manifest form). Shared by _source_lib and _stage_lib below so the
# "the two tier-3 resolvers must not diverge" contract is STRUCTURAL, not a comment
# promise (review HIGH — they had already drifted: awk field-exact here vs. grep
# suffix-anchored in _stage_lib, so a "./"-prefixed manifest line resolved in one and
# fail-closed-died in the other for the identical file). Always returns 0 — a missing
# manifest or no matching entry prints nothing, never a nonzero exit under `set -e`.
_lookup_expected_hash() {
    local name="$1" manifest="$2"
    [[ -n "$manifest" && -r "$manifest" ]] || return 0
    awk -v n="$name" '$2 == n || $2 == "./" n { print $1; exit }' "$manifest" 2>/dev/null
    return 0
}

# _source_lib NAME LOCAL_PATH INSTALLED_PATH REPO_RAW_PATH — source a shared library.
# Resolution order:
#   1. Adjacent to upgrade.sh (local checkout / same-dir download)
#   2. Installed sbin path (/usr/local/sbin/<name>)
#   3. Fetch from REPO_RAW (standalone upgrade.sh downloaded without adjacent libs)
# Tiers 1-2 are trusted local files. Tier 3 is a ROOT-run fetch of security-relevant
# code on a (frequently censored) edge, so it is TLS-pinned (--proto =https --tlsv1.2)
# and the fetched bytes are sha256-verified FAIL-CLOSED against the file's HOME
# MANIFEST before sourcing, mirroring install.sh:_install_lib_source and _stage_lib's
# tamper-evident contract. Home manifest:
#   • lib/*.sh  (fetched from $REPO_RAW/lib/) → lib-checksums.txt (committed at
#     REPO_RAW/lib/, so the remote fallback can fetch it alongside the module)
#   • repo-root *.sh                          → the per-tag release SHA256SUMS
#     (not committed to REPO_RAW; the remote fallback fetches it from RELEASES_BASE)
#
# THREAT MODEL — what this does and does NOT defend (be precise, do not overclaim):
#   • DEFENDED: a protocol-downgrade / plaintext-HTTP MITM (the TLS-pin refuses to
#     fall back to http://), and accidental/passive corruption or a partial/stale
#     tamper of the payload that leaves a LOCALLY-TRUSTED manifest intact.
#   • DEFENDED (manifest omission): a manifest that RESOLVES (curl 200 / readable
#     file) but has NO line for this file — what a truncated download, a captive
#     portal, or a stale/wrong-version manifest produces — is treated IDENTICALLY to
#     "no manifest at all": FAIL-CLOSED (die unless the escape hatch is set), NOT
#     sourced-with-a-warn. Every file this resolver fetches is committed to its home
#     manifest, so a missing entry is never the legit norm; closing it denies the
#     free "omit one line and the check is skipped" bypass (review HIGH). _stage_lib
#     and install.sh:_install_lib_source's tier-4 resolver now fail-closed on the
#     identical no-entry case too (review HIGH fix) — all three tier-3/tier-4
#     resolvers agree on this contract; _source_lib is not the odd one out anymore.
#   • STRONG only when the manifest is resolved LOCALLY (tier-1 adjacent checkout, or
#     tier-2 ${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/lib-checksums.txt IF an
#     operator has staged it there): then it is an INDEPENDENT trust anchor and the
#     sha256 is genuine tamper-evidence. Be precise about reachability: nothing in the
#     current release pipeline (release.yml) writes lib-checksums.txt into
#     INSTALL_LIB_DIR — the tier-2 anchor exists only if an operator manually copies it
#     there, which is not the documented/automated path. Do not read "tier-2 installed
#     tarball" as a common deployment shape.
#   • WEAK in the remote-fallback sub-case (no local manifest → manifest curl'd from
#     the SAME REPO_RAW/RELEASES_BASE origin as the payload): this is the NORMAL,
#     near-universal path for a real reconcile.sh curl|bash run (reconcile.sh is not
#     installed to disk, and tier-2 is unreachable absent manual staging per above).
#     Here manifest and payload share an origin, so this does NOT authenticate a
#     malicious REPO_RAW / OXPULSE_MIRROR_BASE or an active MITM presenting a cert the
#     TLS-pin accepts — such an adversary can serve a matching checksum. It reduces to
#     "TLS + transit-corruption detection", not origin authentication.
#   • RESIDUAL: full supply-chain authentication of a hostile origin needs a signature
#     rooted OUTSIDE that origin (a GPG-signed SHA256SUMS.asc, or refusing tier-3
#     without a locally-staged manifest). That is a larger, separate change (signing
#     infrastructure) not attempted here — this block deliberately does not claim to
#     close it.
# Fetched file is sourced from a temp dir, NOT installed to disk (sync_host_scripts
# does the verified install later in the run). A fork/dev/restricted-network operator
# who cannot supply a manifest passes --allow-unverified (or --no-integrity, or
# OXPULSE_UPGRADE_NO_INTEGRITY=1) to acknowledge the risk instead of hard-failing.
# Note: when OXPULSE_UPGRADE_TAG is the real tag (not the @RELEASE_TAG_UNSUBSTITUTED@ sentinel),
# REPO_RAW + SHA256SUMS are both pinned to that release — fetched bytes match the
# tag snapshot, not main HEAD.
_source_lib() {
    local name="$1" local_path="$2" installed_path="$3" raw_path="$4"
    if [[ -f "$local_path" ]]; then
        # shellcheck source=/dev/null
        source "$local_path"
        return 0
    elif [[ -f "$installed_path" ]]; then
        # shellcheck source=/dev/null
        source "$installed_path"
        return 0
    fi
    # Tier 3: TLS-pinned fetch + fail-closed sha256 verify for standalone runs.
    local _fetch_tmp _man="" _man_tmp="" _expected="" _actual _sd _cand
    _fetch_tmp=$(mktemp)
    # Clean up via the single cumulative EXIT trap (set up before the first _source_lib
    # call), NOT a function-local RETURN trap: die() calls exit, which does NOT fire a
    # RETURN trap, so the tier-3 die paths (fetch-fail / no-verified-checksum /
    # mismatch) + the manifest temp below would otherwise leak in /tmp on every failed
    # run — the hostile-network case this hardening targets (review LOW).
    _CLEANUP_PATHS+=("$_fetch_tmp")
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "$raw_path" -o "$_fetch_tmp" 2>/dev/null; then
        die "$name not found (tried: $local_path, $installed_path, $raw_path).
On a standalone upgrade.sh download ensure network access to REPO_RAW or stage
the lib files adjacent to upgrade.sh."
    fi
    # Resolve the file's home manifest (adjacent → installed → remote fallback).
    _sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    if [[ "$raw_path" == "$REPO_RAW/lib/"* ]]; then
        # lib/*.sh → lib-checksums.txt (committed, so remotely fetchable from REPO_RAW).
        for _cand in "${_sd}/lib/lib-checksums.txt" \
                     "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/lib-checksums.txt"; do
            [[ -r "$_cand" ]] && { _man="$_cand"; break; }
        done
        if [[ -z "$_man" ]]; then
            _man_tmp=$(mktemp); _CLEANUP_PATHS+=("$_man_tmp")
            curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
                "$REPO_RAW/lib/lib-checksums.txt" -o "$_man_tmp" 2>/dev/null && _man="$_man_tmp"
        fi
    else
        # repo-root *.sh → the release SHA256SUMS. Not committed to REPO_RAW, so the
        # remote fallback fetches the per-tag release asset. On a floating/dev tag
        # (sentinel or non-vX.Y.Z) there is no SHA256SUMS → _man stays empty →
        # fail-closed unless the operator set the escape hatch.
        [[ -r "${_sd}/SHA256SUMS" ]] && _man="${_sd}/SHA256SUMS"
        if [[ -z "$_man" && "${OXPULSE_UPGRADE_TAG}" =~ ^v[0-9]+\. ]]; then
            _man_tmp=$(mktemp); _CLEANUP_PATHS+=("$_man_tmp")
            curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
                "$RELEASES_BASE/${OXPULSE_UPGRADE_TAG}/SHA256SUMS" -o "$_man_tmp" 2>/dev/null && _man="$_man_tmp"
        fi
    fi
    # Verify FAIL-CLOSED. Resolve the expected checksum from whichever manifest we
    # found; a manifest that resolved but OMITS this file's line leaves _expected empty
    # and is handled the SAME as "no manifest at all" (see the manifest-omission bullet
    # in the header) — both fail-closed unless the escape hatch is set. The three
    # possible outcomes: (a) entry present + matches → source; (b) entry present +
    # mismatch → die; (c) no entry (no manifest, or manifest omits it) → die unless
    # OXPULSE_UPGRADE_NO_INTEGRITY.
    _expected=$(_lookup_expected_hash "$name" "$_man")
    if [[ -n "$_expected" ]]; then
        _actual=$(sha256sum "$_fetch_tmp" | awk '{print $1}')
        [[ "$_actual" != "$_expected" ]] && die "_source_lib: tier-3 checksum mismatch for $name — refusing to source untrusted code (expected ${_expected:0:16}… got ${_actual:0:16}…)"
    elif [[ "${OXPULSE_UPGRADE_NO_INTEGRITY:-0}" -eq 1 ]]; then
        warn "_source_lib: no verified checksum for $name (no manifest resolved, or the manifest that did has no entry for it) + OXPULSE_UPGRADE_NO_INTEGRITY set — sourcing UNVERIFIED (operator accepts risk)"
    else
        die "_source_lib: tier-3 fetch of $name without a verified checksum is unsafe — no manifest resolved, or the manifest that did resolve has no entry for it (a truncated / captive-portal / wrong-version manifest also produces this). Install from a release tarball or pass --allow-unverified (OXPULSE_UPGRADE_NO_INTEGRITY=1) to acknowledge the risk"
    fi
    warn "$name not found locally; fetched from $raw_path (standalone run)"
    warn "For verified install run 'oxpulse-partner-edge-upgrade' after the sync completes"
    # shellcheck source=/dev/null
    source "$_fetch_tmp"
    return 0
}

# _stage_lib NAME LOCAL_PATH INSTALLED_PATH REPO_RAW_PATH DEST_DIR — resolve a
# shared library FILE onto disk in DEST_DIR (does NOT source it). Sibling to
# _source_lib with the SAME 3-tier resolution (adjacent → installed → REPO_RAW),
# but PERSISTS the file so reconcile.sh's call-time transitive-dep resolvers
# (reconcile_firewall_surface / _reconcile_firewall_escalate — they [[ -f ]]-check
# then source ${LIB_DIR}/<name> at CALL time, not source time) find it even when
# upgrade.sh itself was curl|bash'd from /tmp with no adjacent lib/ dir.
# Fail-loud: die if the file cannot be resolved from any tier — a missing firewall
# lib must abort the upgrade, never silently leave the host unfirewalled (t14).
_stage_lib() {
    local name="$1" local_path="$2" installed_path="$3" raw_path="$4" dest_dir="$5"
    local dest="$dest_dir/$name"
    if [[ -f "$local_path" ]]; then
        cp -f "$local_path" "$dest" && return 0
    elif [[ -f "$installed_path" ]]; then
        cp -f "$installed_path" "$dest" && return 0
    fi
    # Tier 3: fetch from REPO_RAW. This is a ROOT-run fetch of security-relevant code
    # (host firewall + alert path) on a censorship box, and BUG1 now routes libs
    # through it MORE often (the curl|bash-from-/tmp path succeeds instead of dying),
    # so it is TLS-pinned (--proto =https --tlsv1.2 — blocks a protocol-downgrade MITM)
    # and the fetched bytes are sha256-verified against lib-checksums.txt before
    # staging, mirroring install.sh:_install_lib_source's tamper-evident contract on
    # this identical REPO_RAW pattern. (_source_lib carries the same fail-closed verify
    # as of the P0 resolver task — see its tier-3 block above.)
    local _fetch_tmp _ck _ck_tmp=""
    _fetch_tmp=$(mktemp)
    # EXIT-trap cleanup (set up before the first _stage_lib call), NOT a RETURN trap:
    # die() calls exit and never fires a RETURN trap, so the die paths below (fetch-fail
    # / no-manifest / mismatch) + the checksum temp would otherwise leak in /tmp (review LOW).
    _CLEANUP_PATHS+=("$_fetch_tmp")
    if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 "$raw_path" -o "$_fetch_tmp" 2>/dev/null; then
        die "$name could not be staged (tried: $local_path, $installed_path, $raw_path).
reconcile_firewall_surface needs it on-disk in LIB_DIR; ensure network access to
REPO_RAW or stage lib/ adjacent to upgrade.sh."
    fi
    # Locate lib-checksums.txt: adjacent checkout → installed tarball → fetch alongside.
    _ck=""
    local _sd _cand
    _sd="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    for _cand in "${_sd}/lib/lib-checksums.txt" \
                 "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/lib-checksums.txt"; do
        [[ -r "$_cand" ]] && { _ck="$_cand"; break; }
    done
    if [[ -z "$_ck" ]]; then
        _ck_tmp=$(mktemp); _CLEANUP_PATHS+=("$_ck_tmp")
        curl -fsSL --proto '=https' --tlsv1.2 --max-time 15 \
            "$REPO_RAW/lib/lib-checksums.txt" -o "$_ck_tmp" 2>/dev/null && _ck="$_ck_tmp"
    fi
    if [[ -z "$_ck" ]]; then
        # Fail-closed unless the operator acknowledged the risk (mirrors install.sh
        # --no-integrity). The escape hatch is pre-scanned into OXPULSE_UPGRADE_NO_INTEGRITY
        # before staging (args are not parsed yet at that point).
        if [[ "${OXPULSE_UPGRADE_NO_INTEGRITY:-0}" -eq 1 ]]; then
            warn "_stage_lib: no lib-checksums.txt (local or remote) + OXPULSE_UPGRADE_NO_INTEGRITY set — staging $name UNVERIFIED (operator accepts risk)"
        else
            die "_stage_lib: tier-3 fetch of $name without a lib-checksums.txt is unsafe — install from a release tarball or set OXPULSE_UPGRADE_NO_INTEGRITY=1 to acknowledge the risk"
        fi
    else
        local _actual _expected
        _actual=$(sha256sum "$_fetch_tmp" | awk '{print $1}')
        _expected=$(_lookup_expected_hash "$name" "$_ck")
        # Same fail-closed contract as _source_lib — both route through the shared
        # _lookup_expected_hash (review HIGH: the two tier-3 resolvers had already
        # DIVERGED on manifest-entry matching — awk field-exact here vs. grep
        # suffix-anchored in this function — so extracting one shared helper makes the
        # "must not diverge" invariant structural, not a comment promise): (a) entry
        # present + matches → stage; (b) entry present + mismatch → die; (c) manifest
        # resolved but OMITS this file → die unless the escape hatch is set. Case (c) is
        # the truncated / captive-portal / stale-manifest attack: a manifest that
        # resolves yet drops the entry would otherwise SILENTLY stage root-sourced code —
        # install-firewall.sh and telegram-alert-lib.sh are both sourced-and-executed as
        # ROOT by reconcile.sh's call-time resolvers, and the firewall lib's own t14
        # contract says a missing/unverified copy must never leave the host unfirewalled.
        # install.sh:_install_lib_source's tier-4 resolver now fails closed on the
        # no-entry case too (review HIGH fix) — all three tier-3/tier-4 resolvers agree.
        # Both staged libs HAVE lib-checksums.txt entries, so the legitimate tier-3 manifest
        # carries them — case (c) fires only on a tampered/truncated manifest, never a real
        # upgrade (tier-3 itself only runs on the standalone curl|bash path, not on an
        # installed edge where the libs resolve at tier-1/2).
        if [[ -n "$_expected" ]]; then
            [[ "$_actual" != "$_expected" ]] && die "_stage_lib: tier-3 checksum mismatch for $name — refusing to stage untrusted code (expected ${_expected:0:16}… got ${_actual:0:16}…)"
        elif [[ "${OXPULSE_UPGRADE_NO_INTEGRITY:-0}" -eq 1 ]]; then
            warn "_stage_lib: lib-checksums.txt has no entry for $name + OXPULSE_UPGRADE_NO_INTEGRITY set — staging UNVERIFIED (operator accepts risk)"
        else
            die "_stage_lib: tier-3 fetch of $name without a verified checksum is unsafe — the resolved lib-checksums.txt has no entry for it (a truncated / captive-portal / stale manifest also produces this). Install from a release tarball or set OXPULSE_UPGRADE_NO_INTEGRITY=1 to acknowledge the risk"
        fi
    fi
    cp -f "$_fetch_tmp" "$dest"
    warn "$name staged from $raw_path (standalone run) for reconcile transitive-dep resolution"
    return 0
}

# --- Single cumulative cleanup registry, drained by ONE EXIT trap ---------------
# bash EXIT traps are single-slot: a later `trap … EXIT` REPLACES an earlier one.
# Register throwaway paths in an array drained by this one EXIT trap; every later site
# (the _source_lib / _stage_lib tier-3 temp files, the lib-staging dir, the --dry-run
# conflict tmpdir) APPENDS instead of re-trapping (review MEDIUM #3). Established HERE,
# before the first _source_lib call, so the tier-3 die paths (fetch-fail /
# no-verified-checksum / mismatch) do not leak /tmp files: die() calls exit, which does
# NOT fire a function-local RETURN trap, so a RETURN trap could not have cleaned them
# (review LOW — tier-3 temp-file leak on hostile-network upgrade retries).
_CLEANUP_PATHS=()
_run_cleanup() {
    local _p
    [[ ${#_CLEANUP_PATHS[@]} -eq 0 ]] && return 0
    for _p in "${_CLEANUP_PATHS[@]}"; do [[ -n "$_p" ]] && rm -rf "$_p"; done
}
trap _run_cleanup EXIT

# A self-update re-exec CHILD (see _maybe_self_update_reexec) executes FROM the
# parent's throwaway tmpdir ($_new lives inside it). Register that dir here — after
# the cumulative registry + EXIT trap are established — so the child's EXIT trap
# removes it once bash has finished reading this script. Removing our own execution
# dir at EXIT is safe (bash is done with the file); an immediate rm inside the still-
# running child would race the interpreter. No-op in the parent / any normal run: the
# env var is only set across the one re-exec.
[[ -n "${OXPULSE_UPGRADE_REEXEC_TMPDIR:-}" ]] && _CLEANUP_PATHS+=("$OXPULSE_UPGRADE_REEXEC_TMPDIR")

# Integrity escape hatch for the tier-3 fetch verify in _source_lib (immediately below)
# AND _stage_lib (further down). Args are parsed later (args_parse), so pre-scan $@ here
# — BEFORE the first _source_lib call — and honor the env var. Mirrors install.sh's
# --no-integrity contract so a fork/dev/restricted-network operator is warned+continued
# instead of hard-failed. --allow-unverified is upgrade.sh's canonical flag; --no-integrity
# is an install.sh-parity alias; OXPULSE_UPGRADE_NO_INTEGRITY=1 is the env-var form. All
# three set this same flag, and ALLOW_UNVERIFIED (the SHA256SUMS host-script guard) is
# seeded from it below — so all three gate BOTH the tier-3 lib verify here AND that guard.
OXPULSE_UPGRADE_NO_INTEGRITY="${OXPULSE_UPGRADE_NO_INTEGRITY:-0}"
for _arg in "$@"; do
    case "$_arg" in
        --allow-unverified|--no-integrity) OXPULSE_UPGRADE_NO_INTEGRITY=1 ;;
    esac
done

# Source shared channel render functions (re_render_xray, future re_render_awg, etc.)
# shellcheck source=channel-render-lib.sh
_source_lib "channel-render-lib.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/channel-render-lib.sh" \
    "${PREFIX_SBIN:-/usr/local/sbin}/channel-render-lib.sh" \
    "$REPO_RAW/channel-render-lib.sh"

# Source ghcr auth helpers (ghcr_save_token / ghcr_login_from_file /
# ghcr_pull_diagnose / ghcr_configure_token).
_source_lib "ghcr-auth-lib.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/ghcr-auth-lib.sh" \
    "${PREFIX_SBIN:-/usr/local/sbin}/ghcr-auth-lib.sh" \
    "$REPO_RAW/ghcr-auth-lib.sh"

# Source reconcile engine primitives (Phase 1 — caddyfile surface).
# shellcheck source=lib/reconcile.sh
_source_lib "reconcile.sh" \
    "$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/lib/reconcile.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/reconcile.sh" \
    "$REPO_RAW/lib/reconcile.sh"

# --- BUG1 cure: pre-stage reconcile.sh's transitive deps + export LIB_DIR -------
# reconcile.sh resolves its CALL-time deps — install-firewall.sh (reconcile_firewall_surface)
# and telegram-alert-lib.sh (_reconcile_firewall_escalate) — via
# ${FIREWALL_LIB:-${LIB_DIR:-$(dirname BASH_SOURCE)}/<name>}. On a curl|bash edge
# reconcile.sh was fetched into /tmp and sourced from there, so dirname BASH_SOURCE
# = /tmp where install-firewall.sh is NOT co-located → reconcile_firewall_surface
# die()s and ABORTS the whole upgrade before any image pull, fleet-wide. Pre-stage
# the deps into a stable dir and point LIB_DIR at it. t14's fail-loud firewall
# contract is preserved: the die on a genuinely-missing file AFTER staging is still
# correct — this only closes the missing co-location on the fetch path.
#
# synthetic_green fix (P4 strangler-harden follow-up, review HIGH): the
# healthcheck-lib.sh / compose-lib.sh / host-scripts-lib.sh forwarders below use
# the SAME "co-located wins, else ${LIB_DIR:-...}/<name>" resolution as
# reconcile_firewall_surface, but the strangler-harden extraction tasks (p2/p3/p4)
# deliberately did NOT stage them here — leaving LIB_DIR populated with ONLY
# firewall+telegram. On every real invocation of the installed
# oxpulse-partner-edge-upgrade sbin (no adjacent lib/, same as this curl|bash
# case) the three forwarders' ${LIB_DIR} fallback found nothing: the healthcheck
# baseline gate silently disabled (fail-open), the compose digest-diff step
# hard-aborted (fail-closed die), and host-script snapshot/restore/sync
# no-op'd — while every bats test stayed green because it runs upgrade.sh from
# ITS CHECKOUT PATH, where dirname($0)/lib/ always resolves and the LIB_DIR
# fallback is never exercised. Stage all three here too, so LIB_DIR carries a
# checksum-verified copy of every forwarder's dependency regardless of how
# upgrade.sh itself was invoked — closing the gap for BOTH the curl|bash case
# this block already handled AND the (more common) installed-sbin case it did
# not. See lib-checksums.txt / Makefile / release.yml for the matching
# manifest entries these staging calls require.
# _CLEANUP_PATHS + the single EXIT trap were established above (before the first
# _source_lib call). The staging dir and every later temp site append to that array.
# (OXPULSE_UPGRADE_NO_INTEGRITY was pre-scanned above too, and is honored here by
# _stage_lib's tier-3 verify as well.)
_LIB_STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/oxpulse-lib-stage-XXXXXX")
_CLEANUP_PATHS+=("$_LIB_STAGE_DIR")
_UPGRADE_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
_stage_lib "install-firewall.sh" \
    "${_UPGRADE_SH_DIR}/lib/install-firewall.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/install-firewall.sh" \
    "$REPO_RAW/lib/install-firewall.sh" \
    "$_LIB_STAGE_DIR"
_stage_lib "telegram-alert-lib.sh" \
    "${_UPGRADE_SH_DIR}/lib/telegram-alert-lib.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/telegram-alert-lib.sh" \
    "$REPO_RAW/lib/telegram-alert-lib.sh" \
    "$_LIB_STAGE_DIR"
_stage_lib "healthcheck-lib.sh" \
    "${_UPGRADE_SH_DIR}/lib/healthcheck-lib.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/healthcheck-lib.sh" \
    "$REPO_RAW/lib/healthcheck-lib.sh" \
    "$_LIB_STAGE_DIR"
_stage_lib "compose-lib.sh" \
    "${_UPGRADE_SH_DIR}/lib/compose-lib.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/compose-lib.sh" \
    "$REPO_RAW/lib/compose-lib.sh" \
    "$_LIB_STAGE_DIR"
_stage_lib "host-scripts-lib.sh" \
    "${_UPGRADE_SH_DIR}/lib/host-scripts-lib.sh" \
    "${INSTALL_LIB_DIR:-/usr/local/lib/partner-edge}/host-scripts-lib.sh" \
    "$REPO_RAW/lib/host-scripts-lib.sh" \
    "$_LIB_STAGE_DIR"
export LIB_DIR="$_LIB_STAGE_DIR"
export FIREWALL_LIB="$_LIB_STAGE_DIR/install-firewall.sh"
export TELEGRAM_ALERT_LIB="$_LIB_STAGE_DIR/telegram-alert-lib.sh"
# Deliberately NOT exporting HEALTHCHECK_LIB / COMPOSE_LIB / HOST_SCRIPTS_LIB
# here: unlike FIREWALL_LIB/TELEGRAM_ALERT_LIB (whose reconcile.sh resolvers
# are the flat `${VAR:-${LIB_DIR:-...}}` — no separate co-located tier, so
# pre-setting the var is equivalent to relying on LIB_DIR), the three
# forwarders below resolve co-located-with-upgrade.sh FIRST and
# ${VAR:-...}/${LIB_DIR:-...} only as a fallback (priority deliberately
# inverted from firewall/telegram — see _upgrade_resolve_host_scripts_lib /
# _upgrade_resolve_compose_lib / _reconcile_resolve_healthcheck_lib). Their
# env-var tier exists ONLY for explicit operator/test override; exporting it
# unconditionally here would make it win over a trusted local dev checkout,
# inverting that intent. LIB_DIR alone (already exported above) is sufficient
# for their fallback tier to find the just-staged copies.
# ------------------------------------------------------------------------------

[[ $EUID -eq 0 || "${OXPULSE_SKIP_ROOT_CHECK:-0}" == "1" ]] || die "must run as root"
[[ -r "$COMPOSE_FILE" ]] || die "no installed bundle at $COMPOSE_FILE"
[[ -r "$STATE_FILE" ]]   || die "missing $STATE_FILE — reinstall instead of upgrade"

# Postcondition for pre-2026-05-06 deployments: install.sh used to render
# docker-compose.yml with SIGNALING_SFU_SECRET="" when /api/partner/register
# returned an empty signaling_sfu_secret (warn-and-continue). The SFU's
# /sfu/ws/{room_id} stays disabled in that state and group calls silently
# fail end-to-end. install.sh now dies in that case, but upgrade.sh runs
# on already-installed edges where the broken compose is on disk — refuse
# to upgrade those without operator intervention. /api/partner/register is
# not re-fetched on upgrade, so we cannot self-heal in place.
check_signaling_sfu_secret() {
	local secret_line
	secret_line=$(grep -E '^[[:space:]]*SIGNALING_SFU_SECRET:' "$COMPOSE_FILE" || true)
	if [[ -z "$secret_line" ]]; then
		die "$COMPOSE_FILE has no SIGNALING_SFU_SECRET line.
The SFU's browser WebSocket API is disabled — group calls silently fail
end-to-end. This installation pre-dates the 2026-05-06 fix. Resolve:
  1. On the central (motherly), confirm SIGNALING_SFU_SECRET is set,
     redeploy oxpulse-chat.
  2. Wipe ${PREFIX_ETC} and re-run install.sh on this host to fetch
     a fresh /api/partner/register response.
upgrade.sh cannot heal this in place because /api/partner/register
is not re-fetched on upgrade."
	fi
	# Match: SIGNALING_SFU_SECRET: ""  or  SIGNALING_SFU_SECRET:    (no value)
	if grep -qE '^[[:space:]]*SIGNALING_SFU_SECRET:[[:space:]]*("")?[[:space:]]*$' "$COMPOSE_FILE"; then
		die "$COMPOSE_FILE has empty SIGNALING_SFU_SECRET. The SFU's browser
WebSocket API is disabled — group calls silently fail end-to-end.
This installation pre-dates the 2026-05-06 fix. Resolve:
  1. On the central (motherly), confirm SIGNALING_SFU_SECRET is set,
     redeploy oxpulse-chat.
  2. Wipe ${PREFIX_ETC} and re-run install.sh on this host to fetch
     a fresh /api/partner/register response.
upgrade.sh cannot heal this in place because /api/partner/register
is not re-fetched on upgrade."
	fi
}

check_signaling_sfu_secret

# shellcheck disable=SC1090
. "$STATE_FILE"
CURRENT="${IMAGE_VERSION:-unknown}"
MODE=apply
TARGET=""
DRY_RUN=0
SKIPPED_CHECKS=""
# ALLOW_UNVERIFIED gates the SHA256SUMS host-script guard (further down). Seed it from
# the integrity escape hatch pre-scanned above so that OXPULSE_UPGRADE_NO_INTEGRITY=1 —
# set via the env var OR by the --allow-unverified / --no-integrity pre-scan — bypasses
# BOTH the tier-3 lib-resolver verify (_source_lib/_stage_lib) AND this host-script
# guard. That makes the env var and the two flags genuinely interchangeable, as the
# usage/header comments promise (a restricted-network/dev/fork operator who cannot
# verify libs cannot verify host scripts either). The CLI-flag case below re-affirms it.
ALLOW_UNVERIFIED="${OXPULSE_UPGRADE_NO_INTEGRITY:-0}"
# GHCR PAT supplied via --ghcr-token=ghp_xxx flag OR OXPULSE_GHCR_TOKEN env.
# Flag wins over env. Empty string disables the auth path (anonymous pull).
GHCR_TOKEN_ARG="${OXPULSE_GHCR_TOKEN:-}"
for arg in "$@"; do
	case "$arg" in
		--check)              MODE=check ;;
		--rollback)           MODE=rollback ;;
		--templates-only)     MODE=templates ;;
		--with-templates)     MODE=with_templates ;;
		--host-scripts-only)  MODE=host_scripts_only ;;
		--dry-run)            DRY_RUN=1 ;;
		--allow-unverified|--no-integrity)   ALLOW_UNVERIFIED=1 ;;
		--skip-check=*)
			_sc=" ${arg#--skip-check=} "
			SKIPPED_CHECKS="${_sc//,/ }"
			unset _sc ;;
		--ghcr-token=*)   GHCR_TOKEN_ARG="${arg#--ghcr-token=}" ;;
		v*|latest)        TARGET="$arg" ;;
		-h|--help)
			sed -n '2,29p' "$0"; exit 0 ;;
		*) die "unknown arg: $arg" ;;
	esac
done

# If operator supplied a fresh token, persist + login NOW. Catches the
# "PAT expired between releases" class of failure before we even try pull.
if [[ -n "$GHCR_TOKEN_ARG" ]]; then
	ghcr_configure_token "$GHCR_TOKEN_ARG" || die "failed to save/login with supplied --ghcr-token (see warning above)"
	unset GHCR_TOKEN_ARG  # don't keep secret in env longer than necessary
fi

# Phase 2 (ADR-002): forward-migrate STATE_FILE to schema v1 before any surface
# renders or preflight checks run. migrate_state() is idempotent on v1 states.
# This replaces the scattered "re-run install.sh" die()s: the migration derives
# missing non-secret structural keys (CADDYFILE_SHA, BACKEND_API, TURNS_SUBDOMAIN,
# NAIVE_SOCKS_PORT) from the live system where unambiguous; fails with one
# actionable die naming the single key it cannot derive.
# Skip on --check and DRY_RUN modes: read-only paths must not mutate state.
if [[ "$DRY_RUN" -eq 0 && "$MODE" != check ]]; then
	migrate_state
	# Re-source state so the current shell sees any keys that were just written.
	# shellcheck disable=SC1090
	. "$STATE_FILE"
fi

V01_TO_V02=0

# FIX 5: exclusive lock to prevent two concurrent upgrade.sh invocations from
# corrupting the .prev backup chain. Both operators writing .prev simultaneously
# would interleave state and leave rollback pointing at partially-applied config.

# Helper: resolve_default_target sets TARGET if empty, preferring VERSION file
# over 'latest' to keep upgrade target deterministic with the installer release.
# Audit 2026-05-22 F2 — operator may invoke `oxpulse-partner-edge-upgrade`
# without args; without this helper, that pulled :latest from GHCR even when
# the installer pinned to a specific tag. Now we honor the same pin unless
# the operator explicitly types `latest`.
resolve_default_target() {
	if [[ -n "$TARGET" ]]; then return 0; fi
	local version_file
	version_file="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION"
	if [[ -r "$version_file" ]]; then
		TARGET=$(awk '{print $1; exit}' "$version_file")
		log "TARGET defaulted to $TARGET from VERSION file"
		return 0
	fi
	warn "TARGET unspecified and VERSION file missing — defaulting to 'latest' (floating tag, not recommended)"
	TARGET=latest
}

# Helper: normalize_target handles the tag-form transition.
#
# Starting with v0.12.60, git/release/image tags are ALL vX.Y.Z — one form,
# no component prefix.  release-please-config.json has no "component" key.
#
# Edges running a pre-v0.12.60 installer may call upgrade.sh with an old-form
# target (partner-edge-vX.Y.Z).  Strip the prefix so those edges can upgrade
# cleanly to the new tag format without operator intervention.
#
# Resolution order:
#   partner-edge-vX.Y.Z → strip prefix → vX.Y.Z (transition: old-form input)
#   vX.Y.Z              → unchanged             (canonical new form)
#   latest              → unchanged             (floating; SHA256SUMS guard skipped)
#
# Sets RELEASE_TAG = TARGET (same value; no dual forms post-v0.12.60).
# Always called after resolve_default_target.
normalize_target() {
	case "$TARGET" in
		partner-edge-v*)
			# Transition: old-form input from pre-v0.12.60 installer. Strip prefix.
			TARGET="${TARGET#partner-edge-}"
			warn "old tag form detected — treating as $TARGET (releases ≥v0.12.60 use vX.Y.Z)"
			;;
	esac
	# One-form world: RELEASE_TAG = TARGET (git tag = image tag = release tag).
	RELEASE_TAG="$TARGET"
}

# Alias kept for callers that still use the old name (host-scripts-only path etc.)
derive_release_tag() { normalize_target; }

# Skip for read-only modes: --dry-run and --check never mutate state.
if [[ "$DRY_RUN" -eq 0 && "$MODE" != check ]]; then
	LOCK_FILE="$PREFIX_LIB/upgrade.lock"
	exec 9>"$LOCK_FILE"
	flock -n 9 || die "another upgrade.sh is running (lock: $LOCK_FILE). If stuck, check the pid and remove the lock file."
fi

# --templates-only: re-render channel client configs from upstream templates, skip image ops.
if [[ "$MODE" == templates ]]; then
	log "--templates-only: refreshing channel client configs from upstream templates"
	re_render_xray
	# Phase 1.7 — render hy2 too if creds available
	if [[ -n "${HY2_AUTH_PASS:-${OXPULSE_HY2_AUTH_PASS:-}}" \
	   && -n "${HY2_OBFS_PASS:-${OXPULSE_HY2_OBFS_PASS:-}}" ]]; then
		HY2_AUTH_PASS="${HY2_AUTH_PASS:-$OXPULSE_HY2_AUTH_PASS}"
		HY2_OBFS_PASS="${HY2_OBFS_PASS:-$OXPULSE_HY2_OBFS_PASS}"
		export HY2_AUTH_PASS HY2_OBFS_PASS
		re_render_hysteria2
		log "hy2 channel refreshed"
	else
		log "hy2 credentials not in env — skipping (set OXPULSE_HY2_AUTH_PASS + OXPULSE_HY2_OBFS_PASS)"
	fi
	log "done"
	exit 0
fi

# re_render_healthcheck() was removed (cheburator chicken-and-egg incident
# fix, 2026-07): it was the ONLY thing that ever updated healthcheck.sh, and
# it only ran on --with-templates — the plain apply path never delivered
# healthcheck.sh at all. It also ran AFTER the --with-templates baseline
# snapshot, so even that path measured its "before" state with the OLD
# healthcheck. sync_host_scripts (see _HOST_SCRIPT_SBIN_FILES above) is now
# the single source of truth for healthcheck.sh in BOTH apply paths, and
# already runs before each path's baseline snapshot.

# ---------------------------------------------------------------------------
# HOST-SCRIPT SYNC — fetch sbin scripts + systemd units for the target tag,
# verify against SHA256SUMS from the GitHub release, install atomically, and
# daemon-reload + restart only the affected timer/service units.
#
# Design constraints:
#   • Never regenerate identity (reality.*, AWG, service token) — scripts and
#     units only, never config files under PREFIX_ETC.
#   • Idempotent: sha256 match → skip (no restart, no daemon-reload noise).
#   • Mirrors install-systemd.sh install logic; reuses its path conventions.
#   • DOES NOT restart coturn/sfu/xray — those are the image path's concern.
# ---------------------------------------------------------------------------

# Sbin files managed by the host-script sync.  This mirrors EXPECTED_SBIN_FILES
# in install-systemd.sh and must be kept in sync when scripts are added/removed.
#
# NOTE on path variants:
#   • Most files → $PREFIX_SBIN (/usr/local/sbin)
#   • oxpulse-xray-update.sh → $PREFIX_BIN (/usr/local/bin) per install-systemd.sh:265
#     (ExecStart=/usr/local/bin/oxpulse-xray-update.sh in oxpulse-xray-update.service)
#
# Both are synced here so that oxpulse-xray-update.timer and
# oxpulse-geoip-refresh.timer, which are restarted by _HOST_SCRIPT_RESTART_UNITS,
# fire up-to-date script bodies (not stale pre-upgrade copies).
_HOST_SCRIPT_SBIN_FILES=(
	oxpulse-partner-edge-upgrade
	oxpulse-partner-edge-hydrate
	oxpulse-partner-edge-refresh
	oxpulse-partner-edge-sni-rotate
	oxpulse-channels-health-report
	oxpulse-geoip-refresh
	oxpulse-xray-update.sh
	channel-render-lib.sh
	ghcr-auth-lib.sh
	render-channel-lib.sh
	oxpulse-token-lib.sh
	telegram-alert-lib.sh
	# Split-routing scripts (PR #280; RU profile only, ship to all edges for idempotency).
	oxpulse-partner-edge-split-routing
	oxpulse-partner-edge-split-disable
	oxpulse-partner-edge-ru-subnets-update
	# Hysteria2 CH3 activation helper (Phase 1.7 standalone entry point).
	oxpulse-partner-edge-enable-hy2
	# healthcheck.sh (cheburator chicken-and-egg incident, 2026-07): previously
	# updated ONLY by re_render_healthcheck() on --with-templates. The plain
	# apply path (sync_host_scripts, this array) never delivered it, so a
	# plain-upgraded edge kept running its ORIGINAL healthcheck forever —
	# permanently missing fixes to checks (e.g. an SFU_METRICS_BIND mesh-IP
	# fix) and, on any pre-v0.12.60-ish edge, permanently lacking --snapshot
	# support (settle_healthcheck_with_retry then falls back to the absolute
	# --local gate, which a pre-existing red blocks FOREVER — every plain
	# upgrade auto-rolls-back, and the healthcheck that would fix both can
	# never arrive because only --with-templates delivered it). Now delivered
	# here — same fetch+sha256-verify+idempotent-install+atomic-rename path
	# as every other host-script, single source of truth (see
	# _host_script_remote_name / sha256_asset_name mappings below).
	oxpulse-partner-edge-healthcheck
)

# Remote path in the release bundle for each sbin file.  Maps installed name →
# REPO_RAW-relative fetch path (the name under which the file lives in the repo
# and is published to raw.githubusercontent.com).
_host_script_remote_name() {
	local installed_name="$1"
	case "$installed_name" in
		oxpulse-partner-edge-upgrade)    echo "upgrade.sh" ;;
		oxpulse-partner-edge-hydrate)    echo "hydrate.sh" ;;
		oxpulse-partner-edge-refresh)    echo "oxpulse-partner-edge-refresh.sh" ;;
		oxpulse-partner-edge-sni-rotate) echo "oxpulse-partner-edge-sni-rotate.sh" ;;
		oxpulse-channels-health-report)  echo "oxpulse-channels-health-report.sh" ;;
		oxpulse-geoip-refresh)           echo "scripts/oxpulse-geoip-refresh.sh" ;;
		oxpulse-xray-update.sh)          echo "scripts/oxpulse-xray-update.sh" ;;
		channel-render-lib.sh)           echo "channel-render-lib.sh" ;;
		ghcr-auth-lib.sh)                echo "ghcr-auth-lib.sh" ;;
		render-channel-lib.sh)           echo "lib/render-channel-lib.sh" ;;
		oxpulse-token-lib.sh)            echo "oxpulse-token-lib.sh" ;;
		telegram-alert-lib.sh)           echo "lib/telegram-alert-lib.sh" ;;
		oxpulse-partner-edge-split-routing)    echo "oxpulse-partner-edge-split-routing.sh" ;;
		oxpulse-partner-edge-split-disable)    echo "oxpulse-partner-edge-split-disable.sh" ;;
		oxpulse-partner-edge-ru-subnets-update) echo "oxpulse-partner-edge-ru-subnets-update" ;;
		oxpulse-partner-edge-enable-hy2)        echo "oxpulse-partner-edge-enable-hy2" ;;
		oxpulse-partner-edge-healthcheck)       echo "healthcheck.sh" ;;
		*)                               echo "$installed_name" ;;
	esac
}

# Installation directory for each sbin file.  Most go to PREFIX_SBIN;
# oxpulse-xray-update.sh goes to PREFIX_BIN (/usr/local/bin) because its
# systemd unit has ExecStart=/usr/local/bin/oxpulse-xray-update.sh.
_host_script_install_dir() {
	local installed_name="$1"
	case "$installed_name" in
		oxpulse-xray-update.sh) echo "$PREFIX_BIN" ;;
		*)                       echo "$PREFIX_SBIN" ;;
	esac
}

# Permissions for each sbin file (executable scripts vs sourced libs).
_host_script_mode() {
	local installed_name="$1"
	case "$installed_name" in
		channel-render-lib.sh|ghcr-auth-lib.sh|render-channel-lib.sh|oxpulse-token-lib.sh)
			echo "0644" ;;
		*)  echo "0755" ;;
	esac
}

# Systemd units that must be restarted after a host-script change.
# We restart only the units that exec the scripts we sync — NOT coturn/sfu/xray.
_HOST_SCRIPT_RESTART_UNITS=(
	oxpulse-channels-health-report.timer
	oxpulse-partner-edge-refresh.timer
	oxpulse-partner-edge-sni-rotate.timer
	oxpulse-xray-update.timer
	oxpulse-geoip-refresh.timer
	# Split-routing (PR #280): restart timer + re-apply oneshot on script update.
	oxpulse-partner-edge-ru-subnets-update.timer
	oxpulse-partner-edge-split-routing.service
	# awg-params-agent: restart after unit sync so the daemon picks up the new
	# OXPULSE_RESTART_UNIT_AFTER_APPLY env var (post-apply split-routing hook).
	oxpulse-awg-params-agent.service
)

# Systemd unit files synced by sync_host_scripts (Step 5).
# Adding a unit here is sufficient to have it fetched, checksum-verified, and installed
# on every upgrade.  No need to touch sync_host_scripts internals.
_HOST_SCRIPT_SYSTEMD_FILES=(
	oxpulse-partner-edge.service
	oxpulse-partner-edge-hydrate.service
	oxpulse-partner-edge-refresh.service
	oxpulse-partner-edge-refresh.timer
	oxpulse-partner-edge-sni-rotate.service
	oxpulse-partner-edge-sni-rotate.timer
	oxpulse-xray-update.service
	oxpulse-xray-update.timer
	oxpulse-geoip-refresh.service
	oxpulse-geoip-refresh.timer
	oxpulse-channels-health-report.service
	oxpulse-channels-health-report.timer
	# Split-routing (PR #280).
	oxpulse-partner-edge-split-routing.service
	oxpulse-partner-edge-ru-subnets-update.service
	oxpulse-partner-edge-ru-subnets-update.timer
	# awg-params-agent service unit: must be synced so OXPULSE_RESTART_UNIT_AFTER_APPLY
	# (post-apply split-routing hook) reaches existing boxes on upgrade.
	oxpulse-awg-params-agent.service
)

# snapshot_host_scripts / restore_host_scripts / sync_host_scripts — thin
# forwarders (Phase 4 strangler-harden) — the real implementations moved to
# lib/host-scripts-lib.sh under these SAME names. _upgrade_resolve_host_scripts_lib
# is a lazy, call-time resolve+source (in the spirit of lib/reconcile.sh's
# _reconcile_resolve_healthcheck_lib for lib/healthcheck-lib.sh) rather than an
# eager _source_lib call alongside reconcile.sh's, so callers who never call these
# three functions are not forced to co-locate/stage the lib at source time.
#
# lib/host-scripts-lib.sh (along with healthcheck-lib.sh and compose-lib.sh) IS
# now a _stage_lib target (see the BUG1-cure block above) — fixing the
# synthetic_green gap where these three forwarders' ${LIB_DIR} fallback found
# nothing on an installed/curl|bash box (no adjacent lib/), while every bats
# test masked it by running upgrade.sh from its checkout path. Co-located-with-
# upgrade.sh still takes priority over ${LIB_DIR:-...} (a trusted local dev
# checkout wins over the network-staged copy — see _reconcile_resolve_healthcheck_lib's
# header comment in lib/reconcile.sh for the identical priority-inversion
# reasoning); the LIB_DIR fallback below resolves FLAT (${LIB_DIR}/<name>, no
# /lib/ subdir) to match how _stage_lib actually stages files — a prior
# resolver bug had this as ${LIB_DIR}/lib/<name>, which never matched the flat
# staging dir even once LIB_DIR was populated. HOST_SCRIPTS_LIB env override
# supported for testability, mirroring COMPOSE_LIB/HEALTHCHECK_LIB.
#
# On the first call, sourcing lib/host-scripts-lib.sh defines the REAL
# snapshot_host_scripts/restore_host_scripts/sync_host_scripts under these same
# names, replacing the forwarders below in the shell's function table — the
# trailing "$@" call then runs that real implementation. Every later call
# resolves the name straight to the real implementation; the forwarder body
# never runs again. None of these three functions take nameref array params, so
# (unlike lib/compose-lib.sh's capture_running_digests/resolve_pulled_digests)
# a plain self-overwrite is used instead of a nameref-prefixed real-impl name —
# there is no nameref-collision risk to design around here.
#
# Each forwarder `unset -f`s all three names immediately before sourcing the
# lib: lib/host-scripts-lib.sh has its own double-source guard
# (_HOST_SCRIPTS_LIB_LOADED), so if it was ever sourced directly BEFORE these
# forwarders run (not reachable in today's wiring, but a footgun any future
# eager/re-source trips), the guard would otherwise short-circuit `. "$_hsl"`
# WITHOUT redefining the functions — leaving the forwarder calling itself
# forever ("maximum function nesting level exceeded"). Unsetting first turns
# that into a clean "command not found" instead of an infinite recursion.
_upgrade_resolve_host_scripts_lib() {
	if [[ -n "${HOST_SCRIPTS_LIB:-}" ]]; then
		printf '%s' "$HOST_SCRIPTS_LIB"
		return 0
	fi
	local _colocated
	_colocated="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)/lib/host-scripts-lib.sh"
	if [[ -f "$_colocated" ]]; then
		printf '%s' "$_colocated"
		return 0
	fi
	printf '%s' "${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/host-scripts-lib.sh"
}

snapshot_host_scripts() {
	local _hsl
	_hsl="$(_upgrade_resolve_host_scripts_lib)"
	if [[ ! -f "$_hsl" ]]; then
		warn "snapshot_host_scripts: lib/host-scripts-lib.sh not found at $_hsl"
		return 1
	fi
	unset -f snapshot_host_scripts restore_host_scripts sync_host_scripts
	# shellcheck source=lib/host-scripts-lib.sh
	. "$_hsl"
	snapshot_host_scripts "$@"
}

restore_host_scripts() {
	local _hsl
	_hsl="$(_upgrade_resolve_host_scripts_lib)"
	if [[ ! -f "$_hsl" ]]; then
		warn "restore_host_scripts: lib/host-scripts-lib.sh not found at $_hsl"
		return 1
	fi
	unset -f snapshot_host_scripts restore_host_scripts sync_host_scripts
	# shellcheck source=lib/host-scripts-lib.sh
	. "$_hsl"
	restore_host_scripts "$@"
}

# ---------------------------------------------------------------------------
# PARTNER-EDGE SERVICE SCOPING
#
# Partners may add their OWN services to the SAME compose file (live example,
# rvpn v0.13.0 incident 2026-07: `all-rvpn-gate`, a local-only image with no
# ghcr.io upstream). This script only manages ghcr.io/anatolykoptev/
# partner-edge-* images (see the tag-rewrite sed a few hundred lines down) —
# a blanket `docker compose pull` with no service args tries to pull EVERY
# service, foreign ones included, and fails the WHOLE pull with "pull access
# denied for all-rvpn-gate, repository does not exist". Every pull, digest
# comparison, and recreate below must be scoped to services we actually own;
# a foreign service must never be pulled OR recreated.
#
# fetch_compose_config — one `docker compose config` invocation; prints the
# rendered YAML on stdout on success, or the docker/compose error text on
# stdout when it fails (same two-state-primitive contract as
# write_secret_atomic — caller decides how to report). A foreign service
# with ANY invalid definition fails VALIDATION for the WHOLE file (PR review
# round 2 MAJOR-2) — a materially different operator problem than "config
# parsed fine but has zero of our images" (compose file corrupted / all
# services foreign). Callers that die must distinguish the two.
# ---------------------------------------------------------------------------
fetch_compose_config() {
	cd "$PREFIX_ETC" && $DOCKER_BIN compose config 2>&1
}

# _parse_compose_config_images CONFIG_TEXT MAP_NAME — parse EVERY service's
# image ref from ONE already-fetched `docker compose config` snapshot in a
# SINGLE awk pass (PR review round 2 MINOR: list_partner_edge_services +
# the old per-service _compose_service_image spawned ~3+4N `docker compose
# config` child processes per upgrade — a full config fetch+parse per
# service, repeated by every caller, and a TOCTOU risk between calls).
# Populates MAP_NAME[svc]=image for every service in the file (foreign ones
# included — filtering happens in _partner_edge_services_from_map). Strips
# quotes from the image value (PR review round 2 NIT: a quoted
# `image: "ghcr.io/..."` value otherwise misses the bare
# ghcr.io/anatolykoptev/partner-edge-* glob match — mirrors the quote-strip
# already used for compose bind-mount parsing elsewhere in this file).
_parse_compose_config_images() {
	local _cfg="$1"
	local -n _pcc_map="$2"
	local svc img
	while IFS=$'\t' read -r svc img; do
		[[ -n "$svc" ]] || continue
		_pcc_map["$svc"]="$img"
	done < <(printf '%s\n' "$_cfg" | awk '
		/^services:/{in_services=1; next}
		in_services && /^  [^ ]/{
			gsub(/:$/,""); current_svc=$0; gsub(/^  /,"",current_svc)
			next
		}
		in_services && current_svc != "" && /image:/{
			img=$0
			sub(/.*image:[[:space:]]*/,"",img)
			gsub(/"/,"",img)
			print current_svc "\t" img
		}
	')
}

# _partner_edge_services_from_map MAP_NAME — print (one per line) the
# service names from an already-parsed svc->image map whose image belongs
# to us (ghcr.io/anatolykoptev/partner-edge-*).
_partner_edge_services_from_map() {
	local -n _pesm_map="$1"
	local svc
	for svc in "${!_pesm_map[@]}"; do
		[[ "${_pesm_map[$svc]}" == ghcr.io/anatolykoptev/partner-edge-* ]] && printf '%s\n' "$svc"
	done
}

# list_partner_edge_services — fresh-fetch + parse + filter in one call, for
# callers that don't already hold a config snapshot: the rollback-recovery
# call sites (do_rollback_templates, --rollback mode, mid-upgrade recovery
# pulls), which run after the compose file has just been restored from
# .prev — a cached early-guard snapshot would be stale there. Best-effort: a
# fetch failure or zero-match returns an empty list; those callers already
# treat empty as "warn + skip pull" (non-fatal recovery context). The
# PRIMARY (early-guard) call site — resolve_edge_service_scope below —
# distinguishes the two failure modes instead, since it's the one that dies.
list_partner_edge_services() {
	local _cfg
	_cfg=$(fetch_compose_config) || return 0
	local -A _images
	_parse_compose_config_images "$_cfg" _images
	_partner_edge_services_from_map _images
}

# resolve_edge_service_scope ARRAY_NAME — the MAJOR-1/MAJOR-2 early guard
# (PR review round 2 on #333). Fetches + parses compose config ONCE and
# populates ARRAY_NAME with the partner-edge-* service list, dying
# immediately — with a message distinguishing WHICH failure mode (MAJOR-2)
# — if either step fails.
#
# MUST be called before ANY mutation (tag-rewrite / sync_host_scripts /
# reconcile_all + caddy hot-reload) in each apply path: dying here leaves
# NOTHING to restore, since no backup has been taken yet and no file has
# been touched. This check previously ran AFTER those mutations (right
# before the pull), so an empty/corrupted scope died with compose +
# host-scripts (+ live caddy, --with-templates) already rewritten to the
# new version and containers still on the old one — no rollback, the exact
# split-state class this PR exists to prevent.
resolve_edge_service_scope() {
	local -n _res_svcs="$1"
	local _cfg
	if ! _cfg=$(fetch_compose_config); then
		die "docker compose config failed — check $COMPOSE_FILE for a broken service definition (a partner-added foreign service with invalid config fails validation for the WHOLE file):
$_cfg"
	fi
	local -A _images
	_parse_compose_config_images "$_cfg" _images
	mapfile -t _res_svcs < <(_partner_edge_services_from_map _images)
	[[ "${#_res_svcs[@]}" -gt 0 ]] \
		|| die "compose config parsed but zero ghcr.io/anatolykoptev/partner-edge-* services found in $COMPOSE_FILE — compose file looks corrupted, refusing to proceed"
}

# ---------------------------------------------------------------------------
# PER-CONTAINER DIGEST-SKIP — zero-downtime recreate
#
# capture_running_digests / resolve_pulled_digests are thin forwarders (Phase
# 3 strangler-harden) — the real implementations moved to lib/compose-lib.sh
# as compose_diff_recreate_capture_running_digests /
# compose_diff_recreate_resolve_pulled_digests. Kept under these ORIGINAL
# names + the same nameref-param signature so every existing call site in
# this file, and tests/test_upgrade_pull_scope_and_rollback.sh's structural
# checks (B1a/B1b/B1d/B1f/B1g), stay unmodified. See lib/compose-lib.sh's
# header for the full rationale, including why fetch_compose_config (right
# below) and _parse_compose_config_images stay here instead of moving too.
#
# _upgrade_resolve_compose_lib / _upgrade_source_compose_lib: lazy, call-time
# resolve+source (in the spirit of lib/reconcile.sh's
# _reconcile_resolve_healthcheck_lib for lib/healthcheck-lib.sh) rather than
# an eager _source_lib call alongside reconcile.sh's, so callers who never
# call capture_running_digests/resolve_pulled_digests are not forced to
# co-locate/stage the lib at source time.
#
# lib/compose-lib.sh (along with healthcheck-lib.sh and host-scripts-lib.sh)
# IS now a _stage_lib target (see the BUG1-cure block above) — fixing the
# synthetic_green gap where this resolver's ${LIB_DIR} fallback found nothing
# on an installed/curl|bash box (no adjacent lib/) and _upgrade_source_compose_lib's
# die() hard-aborted every such upgrade at the digest-diff step, while every
# bats test masked it by running upgrade.sh from its checkout path.
# Co-located-with-upgrade.sh still takes priority over ${LIB_DIR:-...} (a
# trusted local dev checkout wins over the network-staged copy — see
# _reconcile_resolve_healthcheck_lib's header comment in lib/reconcile.sh for
# the identical priority-inversion reasoning); the LIB_DIR fallback below
# resolves FLAT (${LIB_DIR}/<name>, no /lib/ subdir) to match how _stage_lib
# actually stages files — a prior resolver bug had this as
# ${LIB_DIR}/lib/<name>, which never matched the flat staging dir even once
# LIB_DIR was populated.
_upgrade_resolve_compose_lib() {
	if [[ -n "${COMPOSE_LIB:-}" ]]; then
		printf '%s' "$COMPOSE_LIB"
		return 0
	fi
	local _colocated
	_colocated="$(cd "$(dirname "${BASH_SOURCE[0]:-}")" 2>/dev/null && pwd)/lib/compose-lib.sh"
	if [[ -f "$_colocated" ]]; then
		printf '%s' "$_colocated"
		return 0
	fi
	printf '%s' "${LIB_DIR:-$(dirname "${BASH_SOURCE[0]:-}")}/compose-lib.sh"
}

# _upgrade_source_compose_lib: deliberately does NOT `unset -f` capture_running_digests/
# resolve_pulled_digests before sourcing, unlike the healthcheck-lib.sh /
# host-scripts-lib.sh forwarders (see their header comments for the
# lib-sourced-before-forwarder infinite-recursion footgun those unsets guard
# against). Those two are SELF-overwriting forwarders — sourcing the lib
# redefines a function under the SAME name the forwarder itself calls again,
# so an `unset -f` only ever fires on the one (redundant) execution path that
# would otherwise recurse. capture_running_digests/resolve_pulled_digests are
# DIFFERENT: this file's forwarder is called from TWO separate call sites per
# upgrade (before-digests, then after-digests), both routing through this
# shared helper — an `unset -f` here would remove the CALLING forwarder's own
# name from the function table after the first call, breaking the second
# call with "command not found" (caught empirically: it broke
# tests/test_upgrade_pull_scope_and_rollback.sh and 3 other suites during
# this fix's own verification). lib/compose-lib.sh's real functions use
# DIFFERENT names (compose_diff_recreate_*) than these forwarders, so the
# self-overwrite recursion those two unsets guard against is not reachable
# here regardless.
_upgrade_source_compose_lib() {
	local _cl
	_cl="$(_upgrade_resolve_compose_lib)"
	[[ -f "$_cl" ]] || die "lib/compose-lib.sh not found at $_cl — capture_running_digests/resolve_pulled_digests need it"
	# shellcheck source=lib/compose-lib.sh
	. "$_cl"
}

# capture_running_digests EDGE_SVCS_ARRAY_NAME MAP_NAME — snapshot the
# imageID (sha256:...) of every currently-running container for the
# CALLER-SUPPLIED service list (already scoped to partner-edge-* by
# resolve_edge_service_scope). Does not touch compose config at all — only
# queries running containers by name.
#
# Usage:
#   declare -A before_digests
#   capture_running_digests _edge_svcs before_digests
#
# Each key is the compose service name; value is the running imageID or ""
# if the container is absent / not running (first-pull or stopped).
# ---------------------------------------------------------------------------
capture_running_digests() {
	local -n _crd_svcs="$1"
	local -n _crd_map="$2"
	_upgrade_source_compose_lib
	compose_diff_recreate_capture_running_digests _crd_svcs _crd_map
}

# resolve_pulled_digests EDGE_SVCS_ARRAY_NAME MAP_NAME — after compose pull,
# resolve the imageID for the currently configured image of each
# CALLER-SUPPLIED service (partner-edge-* only). Fetches ONE fresh
# `docker compose config` — the file's tags changed since the early-guard
# snapshot, so a fresh read is structurally unavoidable here — and parses
# ALL images in a single pass.
#
# Fail-safe: if an individual service's image digest cannot be resolved,
# stores "" which causes the caller to fall back to recreating that
# service. Because the service list itself is already scoped to ours, this
# fail-safe can no longer recreate a foreign service.
#
# Returns 1 if the fresh compose-config fetch itself fails. PR review round
# 2 MAJOR-1: this is a POST-MUTATION call site (compose + host-scripts are
# already rewritten by the time this runs) — the caller MUST restore
# host-scripts + compose/state before dying, mirroring the pull-failure
# branch, not just `die` outright.
resolve_pulled_digests() {
	local -n _rpd_svcs="$1"
	local -n _rpd_map="$2"
	_upgrade_source_compose_lib
	compose_diff_recreate_resolve_pulled_digests _rpd_svcs _rpd_map
}

# recreate_changed_services BEFORE_MAP_NAME AFTER_MAP_NAME
#
# Compares before/after digests per service.  Services whose imageID changed
# (or whose before digest was empty — first pull, container absent) are
# recreated with `docker compose up -d --no-deps <svc>`.
# If ALL services are unchanged, exits 0 without calling compose up at all
# (true zero-downtime for no-op version bumps).
#
# Returns: 0 = success (all changed services restarted), non-zero = compose failure.
# On failure the caller is responsible for rollback; this function does NOT roll back.
recreate_changed_services() {
	local -n _rcs_before="$1"
	local -n _rcs_after="$2"

	local changed_services=()
	local svc

	# Union of all service names from both maps.
	local all_svcs=()
	for svc in "${!_rcs_before[@]}"; do all_svcs+=("$svc"); done
	for svc in "${!_rcs_after[@]}"; do
		# Add only if not already present.
		local found=0
		local s
		for s in "${all_svcs[@]}"; do [[ "$s" == "$svc" ]] && found=1 && break; done
		[[ "$found" -eq 0 ]] && all_svcs+=("$svc")
	done

	for svc in "${all_svcs[@]}"; do
		local before="${_rcs_before[$svc]:-}"
		local after="${_rcs_after[$svc]:-}"

		if [[ -z "$before" || -z "$after" || "$before" != "$after" ]]; then
			# Empty digest (first pull / missing container / resolve failure) → fail-safe: recreate.
			if [[ -z "$after" ]]; then
				warn "digest-skip: could not resolve post-pull digest for '$svc' — recreating (fail-safe)"
			elif [[ -z "$before" ]]; then
				log "digest-skip: '$svc' has no running container before pull — recreating"
			else
				log "digest-skip: '$svc' digest changed ($before → $after) — recreating"
			fi
			changed_services+=("$svc")
		else
			log "digest-skip: '$svc' digest unchanged ($after) — skipping recreate (zero-downtime)"
		fi
	done

	if [[ "${#changed_services[@]}" -eq 0 ]]; then
		log "digest-skip: no service image changed — zero-downtime, no recreate"
		return 0
	fi

	log "recreating changed services: ${changed_services[*]}"
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --no-deps "${changed_services[@]}")
}

# settle_healthcheck_with_retry — poll healthcheck after container recreation.
#
# Phase 3 (Decision 4): baseline-aware gate.
#   - If OXPULSE_ABSOLUTE_HEALTH_GATE=0 (default): gate passes when no
#     REGRESSION is detected (GREEN in baseline → RED in post).  Pre-existing
#     reds (RED in both baseline and post) are reported as drift but do NOT
#     block the upgrade.  This fixes the cheburator loop where permanent reds
#     on check 12 (SFU /metrics mesh-IP false-negative) and checks 13/14
#     (xray canary tunnel/upstream degraded) caused every --with-templates
#     upgrade to auto-rollback even when the change was correct.
#   - If OXPULSE_ABSOLUTE_HEALTH_GATE=1: fall back to the old "all green
#     required" behavior (REVERSIBLE — set for diagnosis or on bare installs
#     where no baseline is available).
#
# The baseline-aware path auto-detects whether the installed healthcheck.sh
# supports --snapshot (emits name=GREEN|RED lines).  If not (legacy binary or
# test stub), falls back to the absolute --local gate transparently.
#
# Background: xray Reality tunnel establishment on first connection takes up to
# 8s (uTLS cipher randomisation per connection, measured on rvpn during the
# v0.12.20 upgrade incident 2026-05-09).  A single `sleep 10` leaves only a 2s
# slack margin, which is exceeded on a loaded edge, producing a false-negative
# healthcheck failure and an automatic rollback.
#
# This function polls healthcheck.sh --local every POLL_INTERVAL seconds, up to
# MAX_ATTEMPTS times (total budget ≈ MAX_ATTEMPTS × POLL_INTERVAL).
#
# Defaults (env-configurable via OXPULSE_UPGRADE_HEALTH_TIMEOUT):
#   OXPULSE_UPGRADE_HEALTH_TIMEOUT=30  — total poll budget in seconds
#   POLL_INTERVAL=3                    — seconds between attempts
#   MAX_ATTEMPTS=10                    — budget/interval (rounded up); at
#                                        3s × 10 = 30s we have 4× the observed
#                                        worst-case (8s) plus a 6s margin for a
#                                        loaded edge — safe for production.
#
# Args:
#   $1  label (default: "post-upgrade")
#   $2  baseline_snapshot_file (optional; used for regression gate)
#
# Returns 0 when gate passes; non-zero if rollback required.
#
# Self-contained: snapshot/regression helpers inlined so F4 awk extraction works.
settle_healthcheck_with_retry() {
	local label="${1:-post-upgrade}"            # context for log messages
	local _baseline_snap="${2:-}"               # Phase 3: pre-change snapshot file
	local _serve_baseline="${3:-}"              # P3-serveability: pre-change chN=OK|DOWN snapshot
	local budget="${OXPULSE_UPGRADE_HEALTH_TIMEOUT:-30}"
	local interval=3
	local max_attempts=$(( (budget + interval - 1) / interval ))  # ceil(budget/interval)

	# ---------------------------------------------------------------------------
	# _settle_hc_snapshot BINARY OUTFILE — inline snapshot helper.
	# Runs BINARY --snapshot; returns 0 if output contains >=1 name=GREEN|RED line.
	# Returns 1 if binary is not executable, exits non-zero, or produces no valid
	# snapshot lines (= legacy binary that does not support --snapshot).
	# ---------------------------------------------------------------------------
	_settle_hc_snapshot() {
		local _bin="$1" _out="$2"
		[[ -x "$_bin" ]] || return 1
		# Do NOT gate on the --snapshot exit code. A healthcheck that emits valid
		# per-check lines but exits non-zero when a check is RED (older deployed
		# versions / the exit 1/exit 2 edge paths in healthcheck.sh) still produced
		# a usable snapshot. The grep below is the authoritative "did we get a
		# parseable snapshot" signal. Gating on the exit code made a valid-but-red
		# probe read as "no --snapshot support" → absolute-gate fallback → FALSE
		# rollback on pre-existing reds (BUG3).
		"$_bin" --snapshot > "$_out" 2>/dev/null || true
		grep -qE '^[A-Za-z0-9_]+=GREEN$|^[A-Za-z0-9_]+=RED$' "$_out" 2>/dev/null || return 1
		return 0
	}

	# ---------------------------------------------------------------------------
	# _settle_hc_regressions BASELINE_FILE POST_FILE — inline regression diff.
	# Returns 0 if no GREEN→RED transitions; 1 if any regression found.
	# Returns 0 if baseline is absent (fresh install — skip diff).
	# ---------------------------------------------------------------------------
	_settle_hc_regressions() {
		local _bl="$1" _po="$2"
		[[ -f "$_bl" && -s "$_bl" ]] || { log "settle_healthcheck: no baseline — skipping regression diff"; return 0; }
		local _reg=0 _drift=0 _healed=0 _id _bst _pst
		while IFS='=' read -r _id _bst || [[ -n "$_id" ]]; do
			[[ -z "$_id" ]] && continue
			[[ "$_bst" != "GREEN" && "$_bst" != "RED" ]] && continue
			_pst=$(grep "^${_id}=" "$_po" 2>/dev/null | head -1 | cut -d= -f2 || true)
			[[ -z "$_pst" ]] && continue
			if [[ "$_bst" == "GREEN" && "$_pst" == "RED" ]]; then
				log "settle_healthcheck: REGRESSION — ${_id} GREEN→RED"
				_reg=$(( _reg + 1 ))
			elif [[ "$_bst" == "RED" && "$_pst" == "RED" ]]; then
				log "settle_healthcheck: DRIFT (pre-existing) — ${_id} red in both"
				_drift=$(( _drift + 1 ))
			elif [[ "$_bst" == "RED" && "$_pst" == "GREEN" ]]; then
				log "settle_healthcheck: HEALED — ${_id} RED→GREEN"
				_healed=$(( _healed + 1 ))
			fi
		done < "$_bl"
		if [[ "$_reg" -gt 0 ]]; then
			warn "settle_healthcheck: ${_reg} regression(s) — rollback"
			[[ "$_drift" -gt 0 ]] && log "settle_healthcheck: ${_drift} pre-existing red(s) (drift, not blocking)"
			return 1
		fi
		[[ "$_drift"  -gt 0 ]] && warn "settle_healthcheck: ${_drift} pre-existing red(s) (drift findings — not blocking)"
		[[ "$_healed" -gt 0 ]] && log "settle_healthcheck: ${_healed} healed check(s)"
		log "settle_healthcheck: no regressions"
		return 0
	}

	# _settle_emit_rollback_metric KIND VALUE - record the settle outcome as a
	# Prometheus textfile gauge so the fleet can tell a cold-start (transient)
	# rollback CONDITION apart from a REAL one ("was the rollback real?" - the
	# signal the fleet lacked when the v0.14.2 canary false-rolled-back). Reuses
	# the shared reconcile textfile writer when it is in scope (own .prom file,
	# atomic tmp+mv, world-readable, non-fatal); skipped silently otherwise (e.g.
	# the awk-extracted unit harness that sources only this function).
	_settle_emit_rollback_metric() {
		declare -F _reconcile_emit_prom_gauge >/dev/null 2>&1 || return 0
		_reconcile_emit_prom_gauge "partner_edge_settle.prom" \
			"partner_edge_settle_rollback" "${2:-0}" "kind=\"${1:-unknown}\"" 2>/dev/null || true
	}

	# Absolute gate mode (legacy / escape hatch).
	if [[ "${OXPULSE_ABSOLUTE_HEALTH_GATE:-0}" == "1" ]]; then
		log "settle_healthcheck: using absolute gate (OXPULSE_ABSOLUTE_HEALTH_GATE=1)"
		local _attempt=1
		while [[ "$_attempt" -le "$max_attempts" ]]; do
			log "healthcheck attempt $_attempt/$max_attempts (${label})…"
			if "$HEALTHCHECK" --local; then
				log "healthcheck passed on attempt $_attempt/$max_attempts (${label})"
				return 0
			fi
			if [[ "$_attempt" -lt "$max_attempts" ]]; then
				log "healthcheck not yet passing — retrying in ${interval}s"
				sleep "$interval"
			fi
			_attempt=$(( _attempt + 1 ))
		done
		warn "healthcheck still failing after $max_attempts attempt(s) (budget=${budget}s) — ${label}"
		return 1
	fi

	# Phase 3 baseline-aware gate (default).
	# Detect --snapshot support: probe with a temp file BEFORE the retry loop.
	# This probe does NOT count toward the retry budget.
	local _probe_tmp
	_probe_tmp=$(mktemp)
	local _snap_supported=0
	_settle_hc_snapshot "$HEALTHCHECK" "$_probe_tmp" && _snap_supported=1
	rm -f "$_probe_tmp"

	if [[ "$_snap_supported" -eq 0 ]]; then
		# Legacy binary (no --snapshot support): fall back to absolute --local gate.
		log "settle_healthcheck: healthcheck lacks --snapshot support — using --local gate (${label})"
		local _attempt=1
		while [[ "$_attempt" -le "$max_attempts" ]]; do
			log "healthcheck attempt $_attempt/$max_attempts (${label})…"
			if "$HEALTHCHECK" --local; then
				log "healthcheck passed on attempt $_attempt/$max_attempts (${label})"
				return 0
			fi
			if [[ "$_attempt" -lt "$max_attempts" ]]; then
				log "healthcheck not yet passing — retrying in ${interval}s"
				sleep "$interval"
			fi
			_attempt=$(( _attempt + 1 ))
		done
		warn "healthcheck still failing after $max_attempts attempt(s) (budget=${budget}s) — ${label}"
		return 1
	fi

	# --snapshot supported: poll until the post snapshot both PARSES and shows no
	# regression vs the (warm, pre-reconcile) baseline. A container recreated by
	# --with-templates (sfu + coturn image digests change on every upgrade; here
	# also xray-client + caddy) is COLD at the first post-snapshot, so a transient
	# GREEN->RED read (e.g. check_14_canary_upstream while xray warms) must NOT
	# trigger rollback. We RE-POLL on a detected regression (same budget as the
	# parse retry) until it CLEARS (transient -> pass) or the budget is exhausted
	# (persistent -> REAL regression -> rollback). This makes the post measurement
	# symmetric with the warm baseline and preserves the real rollback path.
	#
	# ADJUDICATED (this settle gate re-polls the FUNCTIONAL healthcheck rather than
	# gating on docker `State.Health.Status==healthy` before diffing): the functional
	# healthcheck.sh --snapshot is a STRICTLY STRONGER end-to-end signal — a GREEN check
	# proves the tunnel actually serves (Reality/TLS/relay reachability), not merely that
	# the container's own HEALTHCHECK reports healthy. It also covers services that
	# declare NO docker HEALTHCHECK (adding a `State.Health.Status` gate would introduce
	# an "absent healthcheck" edge case on the critical path for zero coverage this
	# re-poll does not already give), and it needs no `docker inspect` round-trip. So the
	# docker-health gate is deliberately NOT added; the re-poll-until-clear supersedes it.
	local _post_snap
	_post_snap=$(mktemp)
	# shellcheck disable=SC2064
	trap "rm -f '$_post_snap'" RETURN

	local _attempt=1
	local _stable=0        # 1 once we captured >=1 parseable post snapshot
	local _regressed=1     # 1 = a regression is currently present (until it clears)
	local _saw_transient=0 # 1 if we tolerated a cold-start regression that later cleared
	while [[ "$_attempt" -le "$max_attempts" ]]; do
		log "healthcheck attempt $_attempt/$max_attempts (${label})..."
		if _settle_hc_snapshot "$HEALTHCHECK" "$_post_snap"; then
			_stable=1
			if _settle_hc_regressions "${_baseline_snap}" "$_post_snap"; then
				_regressed=0
				break
			fi
			# Parseable snapshot WITH a regression: treat as a cold-start
			# transient and re-poll until the budget is exhausted.
			_saw_transient=1
		fi
		if [[ "$_attempt" -lt "$max_attempts" ]]; then
			log "settle_healthcheck: not settled (snapshot unstable or transient regression) - retrying in ${interval}s"
			sleep "$interval"
		fi
		_attempt=$(( _attempt + 1 ))
	done

	if [[ "$_stable" -eq 0 ]]; then
		warn "settle_healthcheck: snapshot failed after $max_attempts attempt(s) (${label})"
		_settle_emit_rollback_metric snapshot_fail 1
		return 1
	fi

	if [[ "$_regressed" -ne 0 ]]; then
		# A snapshot regression persisted through the whole budget. Before rolling
		# back, adjudicate ACTUAL serve-ability across the box's PROVISIONED channels
		# by reusing the honest end-to-end probes. The xray-only canary (check_13/14)
		# or check_07 going RED is NOT a serve-ability loss on a multi-homed box:
		# Caddy's tunnel_upstream fails over to awg/hy2 and real users keep being
		# served (live-verified on zvonilka). This can only SUPPRESS a false rollback,
		# never create one — INDETERMINATE (no serve data / reporter absent / the
		# awk-extracted isolation harness) and LOST (every serving channel went dark)
		# both fall through to the real rollback below, preserving single-homed and
		# current behavior.
		# Strict first: if ANY non-channel-serve check regressed (coturn/API/
		# containers/cert/…), that is a real problem beyond channel routing — roll
		# back exactly as before. Only when the persisting regression is ENTIRELY
		# channel-serve checks do we defer to the honest per-channel serve-ability
		# quorum below (so a genuine non-channel breakage is never masked by failover).
		if declare -F _settle_nonchannel_regression >/dev/null 2>&1 \
			&& _settle_nonchannel_regression "$_baseline_snap" "$_post_snap"; then
			warn "settle_healthcheck: regression persisted after $max_attempts attempt(s) (budget=${budget}s) — non-channel check, rollback (${label})"
			_settle_emit_rollback_metric real 1
			return 1
		fi
		local _serve_verdict="INDETERMINATE" _serve_post
		if declare -F _settle_serveability_adjudicate >/dev/null 2>&1 \
			&& declare -F _settle_serveability_snapshot >/dev/null 2>&1 \
			&& [[ -n "$_serve_baseline" && -s "$_serve_baseline" ]]; then
			_serve_post=$(mktemp)
			if _settle_serveability_snapshot "$_serve_post"; then
				_serve_verdict=$(_settle_serveability_adjudicate "$_serve_baseline" "$_serve_post")
			fi
			rm -f "$_serve_post"
		fi
		case "$_serve_verdict" in
			SERVING*)
				warn "settle_healthcheck: snapshot regression present, but the box still serves real users via >=1 provisioned channel (${_serve_verdict}) — NOT rolling back (${label})"
				_settle_emit_rollback_metric serveability_intact 0
				_settle_serveability_alert "$_serve_verdict" "$label"
				return 0
				;;
			*)
				warn "settle_healthcheck: regression persisted after $max_attempts attempt(s) (budget=${budget}s) — rollback (${label}) [serveability=${_serve_verdict}]"
				_settle_emit_rollback_metric real 1
				return 1
				;;
		esac
	fi

	if [[ "$_saw_transient" -eq 1 ]]; then
		log "settle_healthcheck: cold-start regression cleared by attempt $_attempt/$max_attempts - tolerated, no rollback (${label})"
		_settle_emit_rollback_metric transient_cleared 1
	else
		log "settle_healthcheck: post snapshot clean on attempt $_attempt/$max_attempts (${label})"
		_settle_emit_rollback_metric none 0
	fi
	return 0
}

# ---------------------------------------------------------------------------
# Serve-ability adjudication (P3 — multi-homed false-rollback fix).
#
# These three TOP-LEVEL helpers are called by settle_healthcheck_with_retry via
# declare -F guards, so the awk-extracted, self-contained settle fn stays valid
# in the Section-F isolation harness (guards are no-ops there → current
# rollback behavior). They reuse the installed channel reporter and never touch
# the pinned _settle_hc_snapshot / _settle_hc_regressions helpers.
# ---------------------------------------------------------------------------

# _settle_nonchannel_regression BASELINE POST — returns 0 (true) iff a NON-channel
# healthcheck check regressed GREEN→RED. Those are real box problems beyond channel
# routing (coturn secret, API, containers, cert, SFU, TCP443, …) and must roll back
# regardless of multi-homed failover. The DEFERRED channel-serve checks — the
# single-channel liveness/canary checks that falsely trip when one channel (xray/
# hy2) is ТСПУ-blocked while others still serve — are the ONLY checks whose
# GREEN→RED is adjudicated by the honest per-channel serve-ability quorum instead.
# awg (ch2) has no healthcheck check, so an awg change only shows in the probe.
_settle_nonchannel_regression() {
	local _bl="$1" _po="$2" _id _bst _pst
	[[ -f "$_bl" && -s "$_bl" ]] || return 1
	while IFS="=" read -r _id _bst || [[ -n "$_id" ]]; do
		[[ "$_bst" == "GREEN" ]] || continue
		case "$_id" in
			check_07_xray_tunnel|check_13_canary_tunnel|check_14_canary_upstream|check_16_hy2|check_18_hy2_tcp)
				continue ;;
		esac
		_pst=$(grep "^${_id}=" "$_po" 2>/dev/null | head -1 | cut -d= -f2 || true)
		[[ "$_pst" == "RED" ]] && return 0
	done < "$_bl"
	return 1
}

# _settle_serveability_snapshot OUTFILE — capture a per-channel serve-ability
# snapshot (chN=OK|DOWN) by invoking the installed reporter's focused
# --serveability mode, which reuses the honest end-to-end probe_ch1/ch2/ch3.
# Writes only parseable chN=OK|DOWN lines to OUTFILE. Returns 0 iff >=1 line was
# captured (mode supported + >=1 provisioned serve channel); 1 otherwise (legacy
# reporter without the mode, reporter absent, or no serve channels) — the caller
# then keeps the snapshot-only behavior. --dry-run is passed too so a legacy
# reporter that does not know --serveability never POSTs (its JSON is grep-filtered
# out). Never trips set -e; each probe is curl --max-time bound, so it cannot hang.
_settle_serveability_snapshot() {
	local _out="$1"
	local _bin="${CHANNELS_HEALTH_REPORT:-$PREFIX_SBIN/oxpulse-channels-health-report}"
	: > "$_out"
	[[ -x "$_bin" ]] || return 1
	"$_bin" --serveability --dry-run 2>/dev/null | grep -E '^ch[0-9]+=(OK|DOWN)$' > "$_out" 2>/dev/null || true
	[[ -s "$_out" ]] || return 1
	return 0
}

# _settle_serveability_adjudicate BASELINE POST — pure OR-quorum serve-ability
# diff over two chN=OK|DOWN snapshots. Echoes ONE verdict token the settle gate
# cases on; always returns 0 (verdict on stdout, not the exit code).
#
#   SERVING_FULL                  no provisioned serve channel regressed
#   SERVING_PARTIAL regressed=<l> >=1 regressed but >=1 still serves
#                                 (degraded — operator alert, NO rollback)
#   LOST regressed=<l>            every channel serving pre-upgrade is now down
#                                 (box would go dark → real rollback)
#   INDETERMINATE                 no channel served pre-upgrade — nothing to
#                                 adjudicate; defer to the base snapshot gate
#
# The "any channel serving → serve-able" OR-quorum deliberately MIRRORS the
# server-side oracle compute_health_signal_perchannel() in oxpulse-chat
# crates/server/src/partner_registry/health_poller.rs (Wave 3b.2):
#   healthy = (any of ch1/ch2/ch3 handshake_ok=true) AND (coturn ok/absent)
# Both consume the SAME per-channel handshake_ok signal (probe_ch1/ch2/ch3);
# keeping the boolean shape identical stops the edge gate and the server oracle
# silently drifting apart (the two-copies-diverge class behind the v0.13→v0.14.x
# xray-recreate regression). coturn (ch4) is excluded — a TURN relay, not a
# user-facing serve channel, matching the oracle's separate fail-open coturn path.
_settle_serveability_adjudicate() {
	local _bl="$1" _po="$2"
	local _serving_post=0 _baseline_serving=0 _regressed=0 _regressed_list="" _id _st _pst
	# Post serve count (OR-quorum numerator).
	while IFS="=" read -r _id _st || [[ -n "$_id" ]]; do
		[[ "$_id" =~ ^ch[0-9]+$ ]] || continue
		[[ "$_st" == "OK" ]] && _serving_post=$(( _serving_post + 1 ))
	done < "$_po"
	# Baseline serve count + regressions (OK pre-upgrade, DOWN post-upgrade).
	while IFS="=" read -r _id _st || [[ -n "$_id" ]]; do
		[[ "$_id" =~ ^ch[0-9]+$ ]] || continue
		[[ "$_st" == "OK" ]] || continue
		_baseline_serving=$(( _baseline_serving + 1 ))
		_pst=$(grep "^${_id}=" "$_po" 2>/dev/null | head -1 | cut -d= -f2 || true)
		if [[ "$_pst" == "DOWN" ]]; then
			_regressed=$(( _regressed + 1 ))
			_regressed_list="${_regressed_list:+$_regressed_list,}$_id"
		fi
	done < "$_bl"

	if [[ "$_baseline_serving" -eq 0 ]]; then
		printf 'INDETERMINATE'
		return 0
	fi
	if [[ "$_serving_post" -ge 1 ]]; then
		if [[ "$_regressed" -ge 1 ]]; then
			printf 'SERVING_PARTIAL regressed=%s' "$_regressed_list"
		else
			printf 'SERVING_FULL'
		fi
		return 0
	fi
	printf 'LOST regressed=%s' "$_regressed_list"
	return 0
}

# _settle_serveability_alert VERDICT LABEL — partial-degradation alert (WARNING).
# A provisioned channel stopped serving post-upgrade but the box still serves via
# another channel (no rollback happened), so the operator should still know.
# SERVING_FULL is clean (no alert); LOST already logs + metrics the real rollback.
# Severity vocabulary is critical|warning|info only (the dozor webhook classifies
# by lexical match). Reuses tg_alert (telegram-alert-lib, sourced via reconcile.sh);
# a silent no-op if the alert lib is not in scope.
_settle_serveability_alert() {
	local _verdict="$1" _label="$2"
	case "$_verdict" in SERVING_PARTIAL*) ;; *) return 0 ;; esac
	declare -F tg_alert >/dev/null 2>&1 || return 0
	local _host _regressed
	_host=$(hostname -s 2>/dev/null || echo edge)
	_regressed="${_verdict#SERVING_PARTIAL regressed=}"
	tg_alert "[$_host] WARNING partner-edge ${_label}: partial channel degradation after upgrade — channel(s) ${_regressed} stopped serving end-to-end, but the box still serves real users via another provisioned channel (Caddy multi-homed failover), so NO rollback. Investigate ${_regressed}." || true
}

# _maybe_self_update_reexec ARGS... - self-update guard (canonical: Go GOTOOLCHAIN
# counter, rustup --self-replace sentinel). The running process is the on-disk
# upgrade.sh the operator launched; a fix that ships INSIDE upgrade.sh (e.g. the
# settle cold-start gate above) would otherwise only take effect on the operator's
# SECOND run, because Step 4's sync_host_scripts installs the new bytes to disk but
# the current process keeps executing the OLD ones. Worse, a settle false-rollback
# restores the old upgrade.sh too, so a box can loop forever on the buggy version.
#
# This fetches the NEW upgrade.sh for RELEASE_TAG to a SHA-verified temp file and,
# if it differs from the running script, re-execs it exactly ONCE (sentinel-guarded)
# so the fix lands in a SINGLE operator invocation.
#
# ROLLBACK SAFETY (hard requirement - RU relays): we exec a TEMP copy and touch
# NOTHING on disk here. snapshot_host_scripts + the compose/state backup (Step 1 of
# each apply path) therefore still run against the pristine OLD on-disk state in the
# re-exec'd child, so the atomic-rollback path is fully preserved. The child's own
# Step 4 sync_host_scripts installs the new code to disk for future runs.
#
# FAIL-SAFE: any fetch/verify miss SKIPS the re-exec - the current (old) process
# proceeds (degraded to the historical two-run convergence), never a broken or an
# unverified-code exec. Scope: real apply paths only (apply / with_templates), a
# pinned tag (a floating 'latest' has no per-tag SHA256SUMS to verify against).
#
# THREAT MODEL (this fetches upgrade.sh + SHA256SUMS same-origin and execs the result
# as ROOT on match — the SAME threat surface as _source_lib's tier-3, so it inherits
# the SAME bound; see the _source_lib THREAT MODEL block above for the full statement):
#   • DEFENDED: protocol-downgrade / plaintext-HTTP MITM (curl is TLS-pinned
#     --proto =https --tlsv1.2), and passive/transit corruption of the payload (the
#     sha256 must match a SHA256SUMS that resolved).
#   • WEAK / NOT authenticated: manifest and payload share the RELEASES_BASE origin, so
#     a hostile mirror / OXPULSE_MIRROR_BASE (or an active MITM presenting a cert the
#     pin accepts) can serve a matching checksum. This is "TLS + transit-corruption
#     detection", NOT origin authentication.
#   • RESIDUAL: closing the hostile-origin case needs a signature rooted OUTSIDE that
#     origin (a GPG/minisign-signed SHA256SUMS.asc) — a fleet-wide, separate change
#     shared by all four fetch+verify sites; deliberately not attempted here.
#   • ESCAPE HATCH: ALLOW_UNVERIFIED (from --allow-unverified / --no-integrity /
#     OXPULSE_UPGRADE_NO_INTEGRITY, seeded at top level) SKIPS the sha256 gate for the
#     fork/dev/restricted-network operator — same opt-in contract as the lib resolvers.
_maybe_self_update_reexec() {
	[[ "${OXPULSE_UPGRADE_REEXECED:-0}" == 1 ]] && return 0   # child of a prior re-exec
	[[ "${DRY_RUN:-0}" -eq 1 ]] && return 0
	[[ "${OXPULSE_UPGRADE_NO_SELF_UPDATE:-0}" == 1 ]] && return 0   # operator/CI opt-out
	case "${MODE:-apply}" in apply|with_templates) ;; *) return 0 ;; esac
	local _tag="${RELEASE_TAG:-}"
	[[ -z "$_tag" || "$_tag" == latest ]] && return 0
	local _running="${BASH_SOURCE[0]:-$0}"
	[[ -r "$_running" ]] || return 0

	# Only self-update when running the INSTALLED sbin copy - never silently
	# replace a dev/CI/manual invocation (e.g. `bash ./upgrade.sh`) with the
	# released version. This is also what keeps the integration suite (which runs
	# the repo copy, not the installed path) off the network self-update path.
	local _installed="${OXPULSE_INSTALLED_UPGRADE_PATH:-${PREFIX_SBIN:-/usr/local/sbin}/oxpulse-partner-edge-upgrade}"
	local _rp_run _rp_inst
	_rp_run=$(realpath -m "$_running" 2>/dev/null || printf '%s' "$_running")
	_rp_inst=$(realpath -m "$_installed" 2>/dev/null || printf '%s' "$_installed")
	[[ "$_rp_run" == "$_rp_inst" ]] || return 0

	local _tmpdir _new _sums _expected _actual _running_sha
	_tmpdir=$(mktemp -d 2>/dev/null) || return 0
	_new="$_tmpdir/partner-edge-upgrade.sh"

	# Fetch the substituted upgrade.sh release asset for the pinned tag (TLS-pinned).
	if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
		"$RELEASES_BASE/$_tag/partner-edge-upgrade.sh" -o "$_new" 2>/dev/null; then
		rm -rf "$_tmpdir"; return 0
	fi

	# Verify against the release SHA256SUMS unless integrity is explicitly waived.
	if [[ "${ALLOW_UNVERIFIED:-0}" != 1 ]]; then
		_sums="$_tmpdir/SHA256SUMS"
		if ! curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
			"$RELEASES_BASE/$_tag/SHA256SUMS" -o "$_sums" 2>/dev/null; then
			warn "self-update: no SHA256SUMS for $_tag - skipping re-exec (converges next run)"
			rm -rf "$_tmpdir"; return 0
		fi
		# Resolve the expected hash via the shared _lookup_expected_hash (defined
		# above) so a SHA256SUMS line that carries the common `find`-generated
		# "./partner-edge-upgrade.sh" column form still matches — an inline
		# bare-name awk silently missed it, leaving _expected empty and fail-closing
		# the self-update forever (review HIGH: same "./"-prefix drift the tier-3 lib
		# resolvers already paid down; do not reinvent it here).
		_expected=$(_lookup_expected_hash "partner-edge-upgrade.sh" "$_sums")
		_actual=$(sha256sum "$_new" 2>/dev/null | awk '{print $1}')
		if [[ -z "$_expected" || "$_expected" != "$_actual" ]]; then
			warn "self-update: SHA256 mismatch/absent for upgrade.sh@$_tag - refusing to re-exec unverified code"
			rm -rf "$_tmpdir"; return 0
		fi
	else
		_actual=$(sha256sum "$_new" 2>/dev/null | awk '{print $1}')
	fi

	# Already running the target bytes? Nothing to converge.
	_running_sha=$(sha256sum "$_running" 2>/dev/null | awk '{print $1}')
	if [[ -z "$_actual" || "$_actual" == "$_running_sha" ]]; then
		rm -rf "$_tmpdir"; return 0
	fi

	chmod +x "$_new" 2>/dev/null || true
	log "self-update: running upgrade.sh differs from the $_tag release - re-exec into the new version once so infra fixes apply this run"
	export OXPULSE_UPGRADE_REEXECED=1
	export OXPULSE_UPGRADE_REEXEC_TMPDIR="$_tmpdir"
	# Release the upgrade-lock fd (if held) so the re-exec'd child reacquires cleanly.
	{ exec 9>&-; } 2>/dev/null || true
	# Throwaway-tmpdir hygiene (this dir is created on EVERY real fleet self-update):
	#   • exec SUCCESS → the process image is replaced; the re-exec'd CHILD re-registers
	#     this dir at top level (via OXPULSE_UPGRADE_REEXEC_TMPDIR) and its cumulative
	#     EXIT trap sweeps it once bash is done reading the script from inside it.
	#   • exec FAILURE → a non-interactive shell aborts on a failed exec AND does NOT
	#     fire the EXIT trap (both verified), so it would both kill the whole upgrade and
	#     leak the tmpdir. `shopt -s execfail` makes the shell CONTINUE into the recovery
	#     block instead; `|| true` stops `set -e` from re-promoting exec's non-zero return
	#     into that same abort. Recovery degrades to the historical two-run convergence
	#     and removes the tmpdir. (On success we never reach `shopt -u`; the child re-parse
	#     starts with execfail at its default, so nothing leaks into the new image.)
	shopt -s execfail
	# shellcheck disable=SC2093  # intentional: on success exec replaces the process; the
	# lines below are the exec-FAILED recovery path, reachable because execfail is set.
	exec "$_new" "$@" || true
	shopt -u execfail
	warn "self-update: re-exec of $_new failed - continuing with the current process (converges next run)"
	rm -rf "$_tmpdir" 2>/dev/null || true
	unset OXPULSE_UPGRADE_REEXECED OXPULSE_UPGRADE_REEXEC_TMPDIR
	return 0
}

# sync_host_scripts TAG — forwarder; see snapshot_host_scripts/restore_host_scripts's
# header comment above (_upgrade_resolve_host_scripts_lib) for the lazy-source,
# self-overwrite rationale. Real implementation: lib/host-scripts-lib.sh.
sync_host_scripts() {
	local _hsl
	_hsl="$(_upgrade_resolve_host_scripts_lib)"
	if [[ ! -f "$_hsl" ]]; then
		warn "sync_host_scripts: lib/host-scripts-lib.sh not found at $_hsl"
		return 1
	fi
	unset -f snapshot_host_scripts restore_host_scripts sync_host_scripts
	# shellcheck source=lib/host-scripts-lib.sh
	. "$_hsl"
	sync_host_scripts "$@"
}

# ---------------------------------------------------------------------------
# do_rollback_templates — restore Caddyfile, healthcheck, and install.env
# from .prev backups. Called by --rollback when template backups exist, and
# auto-triggered after --with-templates healthcheck failure.
# ---------------------------------------------------------------------------
do_rollback_templates() {
	local restored=0

	if [[ -f "$PREV_CADDYFILE" ]]; then
		install -m 0644 "$PREV_CADDYFILE" "$PREFIX_ETC/Caddyfile"
		log "restored Caddyfile from backup"
		restored=1
	fi
	if [[ -f "$PREV_HEALTHCHECK" ]]; then
		install -m 0755 "$PREV_HEALTHCHECK" "$HEALTHCHECK"
		log "restored healthcheck from backup"
		restored=1
	fi
	if [[ -f "$PREV_STATE_FILE" ]]; then
		cp -a "$PREV_STATE_FILE" "$STATE_FILE"
		log "restored install.env from backup"
		restored=1
	fi
	if [[ -f "$PREV_COMPOSE_FILE" ]]; then
		cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
		log "restored docker-compose.yml from backup"
		restored=1
	fi

	[[ "$restored" -eq 1 ]] || die "no .prev backup files found — nothing to restore"

	# FIX 4: ensure the previous image is in local cache before the caller does
	# compose up. If the previous tag was a floating tag that has since been
	# evicted from the local cache, compose up would use whatever is cached —
	# possibly stale or wrong. Pull is best-effort; failure is non-fatal because
	# the image may still be present from the original pull.
	#
	# Scoped to partner-edge-* services only (foreign-service pull-scope fix,
	# rvpn v0.13.0 incident) — COMPOSE_FILE was JUST restored from .prev above,
	# so re-derive the service list against the restored file.
	local -a _rollback_edge_svcs
	mapfile -t _rollback_edge_svcs < <(list_partner_edge_services)

	if [[ "${#_rollback_edge_svcs[@]}" -eq 0 ]]; then
		warn "rollback: no ghcr.io/anatolykoptev/partner-edge-* services found in restored $COMPOSE_FILE — skipping cache-warm pull"
	else
		log "rollback: ensuring previous image is in local cache (${_rollback_edge_svcs[*]})"
		(cd "$PREFIX_ETC" && ghcr_login_from_file || true; $DOCKER_BIN compose pull "${_rollback_edge_svcs[@]}") \
			|| warn "rollback pull failed — proceeding with cached image"
	fi
}

maybe_v01_to_v02_preflight() {
	[[ "$CURRENT" =~ ^v0\.1($|\.) ]] || return 0
	[[ "$TARGET"  =~ ^v0\.2($|\.) ]] || return 0

	log "detected v0.1.x → v0.2.x migration — running DNS preflight"

	# Phase 2 (ADR-002): migrate_state() already ran above and derived any missing
	# structural keys from the live system.  If TURNS_SUBDOMAIN or PARTNER_DOMAIN
	# are still absent after migration, the state is genuinely unrecoverable without
	# operator input — fail with a precise message (no "re-run install.sh" catch-all).
	[[ -n "${TURNS_SUBDOMAIN:-}" ]] || die "TURNS_SUBDOMAIN missing from $STATE_FILE — migrate_state could not derive it. Provide it: echo 'TURNS_SUBDOMAIN=api-<hex>' >> $STATE_FILE"
	[[ -n "${PARTNER_DOMAIN:-}"  ]] || die "PARTNER_DOMAIN missing from $STATE_FILE — migrate_state could not derive it. Provide it: echo 'PARTNER_DOMAIN=<your-domain>' >> $STATE_FILE"

	PUBLIC_IP=$(curl -fsS --max-time 5 https://ifconfig.me 2>/dev/null || curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || true)
	[[ -n "$PUBLIC_IP" ]] || die "could not determine public IP (both ifconfig.me and api.ipify.org failed)"

	command -v dig >/dev/null 2>&1 || die "'dig' is not installed — install dnsutils (Debian/Ubuntu: 'apt-get install dnsutils'; RHEL/Rocky/Alma/CentOS: 'dnf install bind-utils') and retry"
	DIG_IPS=$(dig +short +time=3 +tries=1 "${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN}" A | grep -E '^[0-9.]+$' | sort -u)
	if ! grep -Fxq "$PUBLIC_IP" <<< "$DIG_IPS"; then
		die "DNS preflight failed:
  expected A-record for ${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN} to include ${PUBLIC_IP}
  got: ${DIG_IPS:-<no record>}
  fix: add A-record '${TURNS_SUBDOMAIN}.${PARTNER_DOMAIN} -> ${PUBLIC_IP}' at your DNS provider, then re-run upgrade"
	fi

	V01_TO_V02=1
}

maybe_v01_to_v02_preflight

# ---- --rollback mode ----
if [[ "$MODE" == rollback ]]; then
	# Template rollback: restore Caddyfile/healthcheck if .prev files exist.
	_have_template_prev=0
	[[ -f "$PREV_CADDYFILE" || -f "$PREV_HEALTHCHECK" ]] && _have_template_prev=1

	# Image rollback: compose.prev + state.prev must exist.
	_have_image_prev=0
	[[ -r "$PREV_STATE_FILE" && -r "$PREV_COMPOSE_FILE" ]] && _have_image_prev=1

	_have_host_scripts_prev=0
	[[ -d "$PREV_HOST_SCRIPTS_DIR/sbin" ]] && _have_host_scripts_prev=1

	[[ "$_have_template_prev" -eq 1 || "$_have_image_prev" -eq 1 || "$_have_host_scripts_prev" -eq 1 ]] \
		|| die "no previous version recorded — nothing to roll back to"

	log "rolling back to previous state"
	do_rollback_templates  # restores Caddyfile, healthcheck, compose, install.env .prev files
	restore_host_scripts   # restores sbin scripts + systemd units from snapshot

	if [[ "$DRY_RUN" -eq 0 ]]; then
		# Scoped to partner-edge-* services only (foreign-service pull-scope
		# fix, rvpn v0.13.0 incident) — do_rollback_templates already restored
		# COMPOSE_FILE from .prev above.
		mapfile -t _rollback_mode_edge_svcs < <(list_partner_edge_services)
		if [[ "${#_rollback_mode_edge_svcs[@]}" -eq 0 ]]; then
			warn "rollback: no ghcr.io/anatolykoptev/partner-edge-* services found in restored $COMPOSE_FILE — skipping pull"
		else
			(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_rollback_mode_edge_svcs[@]}")
		fi
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate)
		sleep 10
		if "$HEALTHCHECK" --local; then
			log "rollback complete"
			exit 0
		else
			die "rollback applied but healthcheck still failing — manual recovery required"
		fi
	else
		log "[dry-run] would docker compose pull + up -d after rollback"
		exit 0
	fi
fi

# ---- --host-scripts-only mode ----
# Sync sbin scripts + systemd units for the target tag and restart affected
# timers.  Does NOT pull images or recreate containers — guaranteed zero-
# downtime.  Use for host-script-only releases (e.g. ch4 coturn probe) on
# edges where the container image is pinned and must not be disturbed.
if [[ "$MODE" == host_scripts_only ]]; then
	resolve_default_target
	derive_release_tag
	log "--host-scripts-only: syncing host-scripts to $RELEASE_TAG (containers untouched)"
	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] would call sync_host_scripts $RELEASE_TAG"
		log "[dry-run] would restart: ${_HOST_SCRIPT_RESTART_UNITS[*]}"
		log "[dry-run] image pull and container recreate: not performed (--host-scripts-only)"
		exit 0
	fi
	sync_host_scripts "$RELEASE_TAG"
	log "--host-scripts-only complete (release_tag=$RELEASE_TAG target=$TARGET); no image pull or container recreate"
	exit 0
fi

# ---------------------------------------------------------------------------
# Conflict detection helpers — used only by run_conflict_checks().
# Each _check_N function sets CHECK_STATUS[N] and appends to CHECK_DETAIL[N].
# Severity: CATASTROPHIC | WARNING | INFO | PASS | SKIP
# ---------------------------------------------------------------------------

# _check_skip N — returns 0 (true = skip) if check N is in SKIPPED_CHECKS
_check_skip() {
	[[ " $SKIPPED_CHECKS " == *" $1 "* ]]
}

# Check 1: Caddyfile validates against currently-running caddy image.
_conflict_check_1() {
	CHECK_STATUS[1]="PASS"
	CHECK_DETAIL[1]=""

	local rendered_caddy="$1"

	# If caddy container is not running, treat as INFO (not catastrophic — e.g. fresh install).
	local current_image
	current_image=$($DOCKER_BIN inspect oxpulse-partner-caddy \
		--format '{{.Config.Image}}' 2>/dev/null || true)
	if [[ -z "$current_image" ]]; then
		CHECK_STATUS[1]="INFO"
		CHECK_DETAIL[1]="  Container oxpulse-partner-caddy not running — validation skipped (INFO only)."
		return
	fi

	if [[ ! -f "$rendered_caddy" ]]; then
		CHECK_STATUS[1]="INFO"
		CHECK_DETAIL[1]="  Rendered Caddyfile not available — caddy not in live compose (SFU-only node?)."
		return
	fi

	# Locate cover dir from live compose for the volume mount.
	# FIX 1: extract the HOST-side path (left of ':') not the container path.
	# Repro: echo '      - ./cover:/srv/cover:ro' | grep -oP 'cover:\s*\K[^[:space:]]+'
	#        outputs /srv/cover:ro (container path) — causes docker: invalid volume spec.
	local cover_dir
	cover_dir=$(grep -oP '^\s*-\s*\K[^[:space:]:]+(?=:/srv/cover)' "$COMPOSE_FILE" 2>/dev/null | head -1 || true)
	# Resolve relative paths against the compose file directory.
	if [[ -n "$cover_dir" && "$cover_dir" =~ ^\./ ]]; then
		cover_dir="$(dirname "$COMPOSE_FILE")/${cover_dir#./}"
	fi
	# FIX 2: use an empty tmpdir fallback rather than /tmp (which would mount
	# unrelated host content over /srv/cover, giving false caddy validate results).
	if [[ -z "$cover_dir" || ! -d "$cover_dir" ]]; then
		cover_dir=$(mktemp -d)
		# shellcheck disable=SC2064
		trap "rm -rf '$cover_dir'" RETURN
	fi

	local validate_out validate_rc
	validate_rc=0
	validate_out=$($DOCKER_BIN run --rm \
		-v "${rendered_caddy}:/etc/caddy/Caddyfile:ro" \
		-v "${cover_dir}:/srv/cover:ro" \
		"$current_image" \
		caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1) || validate_rc=$?

	if [[ $validate_rc -ne 0 ]]; then
		CHECK_STATUS[1]="CATASTROPHIC"
		local err_line
		err_line=$(printf '%s' "$validate_out" | grep -m1 'Error\|error\|unrecognized' || echo "$validate_out" | tail -1)
		CHECK_DETAIL[1]="  Image: $current_image
  Error: $err_line
  Hint:  This would crashloop caddy on apply. Either upgrade image first
         (oxpulse-partner-edge-upgrade --image-only) or pin to compatible Caddyfile."
	fi
}

# Check 2: docker-compose.yml structural drift (ports, env keys, services).
_conflict_check_2() {
	CHECK_STATUS[2]="PASS"
	CHECK_DETAIL[2]=""

	local compose_tpl="$1"

	[[ -f "$compose_tpl" ]] || { CHECK_STATUS[2]="INFO"; CHECK_DETAIL[2]="  Compose template not fetched — skipped."; return; }
	[[ -f "$COMPOSE_FILE"  ]] || { CHECK_STATUS[2]="INFO"; CHECK_DETAIL[2]="  Live compose not found — skipped."; return; }

	local issues
	issues=$(python3 - "$COMPOSE_FILE" "$compose_tpl" << 'PYEOF'
import sys, re

def load_yaml_simple(path):
    """Minimal YAML structural parser — only extracts service names, port lists, and env keys."""
    import subprocess
    result = subprocess.run(
        ['python3', '-c', '''
import sys, yaml, json
with open(sys.argv[1]) as f:
    data = yaml.safe_load(f)
svcs = data.get("services", {}) or {}
out = {}
for svc, cfg in svcs.items():
    cfg = cfg or {}
    ports = [str(p) for p in (cfg.get("ports") or [])]
    env = cfg.get("environment") or {}
    if isinstance(env, list):
        keys = sorted(e.split("=")[0] for e in env)
    else:
        keys = sorted(env.keys())
    out[svc] = {"ports": sorted(ports), "env_keys": keys}
print(json.dumps(out))
''', sys.argv[1]],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        return None, result.stderr.strip()
    import json
    return json.loads(result.stdout), None

import json, subprocess, sys

live_path = sys.argv[1]
tpl_path  = sys.argv[2]

live_data, live_err = load_yaml_simple(live_path)
tpl_data,  tpl_err  = load_yaml_simple(tpl_path)

if live_err:
    print(f"WARN: cannot parse live compose: {live_err}")
    sys.exit(0)
if tpl_err:
    print(f"WARN: cannot parse template compose: {tpl_err}")
    sys.exit(0)

issues = []
# New services in template
for svc in sorted(tpl_data):
    if svc not in live_data:
        issues.append(f"  Service '{svc}' in template but NOT in live compose (new service added by template).")

# Structural drift per existing service
for svc in sorted(tpl_data):
    if svc not in live_data:
        continue
    live = live_data[svc]
    tmpl = tpl_data[svc]

    live_ports = set(live["ports"])
    tmpl_ports = set(tmpl["ports"])
    # Filter out placeholder-bearing ports (not substituted in template)
    tmpl_ports_real = {p for p in tmpl_ports if "{{" not in p and "__" not in p}
    new_ports = tmpl_ports_real - live_ports
    if new_ports:
        for p in sorted(new_ports):
            remediation = f'sudo sed -i \'/- "{list(live_ports)[0] if live_ports else "443:443"}"/a\\\\      - "{p}"\' /etc/oxpulse-partner-edge/docker-compose.yml'
            issues.append(
                f"  Service '{svc}': template adds port {p!r} not in live compose.\n"
                f"  Will NOT propagate via --with-templates. Manual remediation:\n"
                f"    {remediation}"
            )

    live_keys = set(live["env_keys"])
    tmpl_keys = {k for k in tmpl["env_keys"] if "{{" not in k and "__" not in k}
    new_keys = tmpl_keys - live_keys
    if new_keys:
        issues.append(
            f"  Service '{svc}': template adds env keys {sorted(new_keys)!r} not in live compose.\n"
            f"  Will NOT propagate via --with-templates. Requires manual patch or full reinstall."
        )

for i in issues:
    print(i)
PYEOF
)
	if [[ -n "$issues" ]]; then
		CHECK_STATUS[2]="WARNING"
		CHECK_DETAIL[2]="$issues"
	fi
}

# Check 3: Image tag direction — detect downgrade.
_conflict_check_3() {
	CHECK_STATUS[3]="PASS"
	CHECK_DETAIL[3]=""

	local proposed="$1"

	# If proposed is latest, we can't compare meaningfully.
	if [[ "$proposed" == "latest" ]]; then
		if [[ "$CURRENT" =~ ^v[0-9] ]]; then
			CHECK_STATUS[3]="WARNING"
			CHECK_DETAIL[3]="  Proposed tag is 'latest'; current is '$CURRENT'. Cannot compare — manual review recommended."
		fi
		return
	fi

	# Both must match vMAJOR.MINOR.PATCH for semver comparison.
	local _semver_re='^v([0-9]+)\.([0-9]+)\.([0-9]+)'
	if [[ "$CURRENT" =~ $_semver_re ]] && [[ "$proposed" =~ $_semver_re ]]; then
		local cur_maj cur_min cur_pat prop_maj prop_min prop_pat
		[[ "$CURRENT"  =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; cur_maj=${BASH_REMATCH[1]}; cur_min=${BASH_REMATCH[2]}; cur_pat=${BASH_REMATCH[3]}
		[[ "$proposed" =~ ^v([0-9]+)\.([0-9]+)\.([0-9]+) ]]; prop_maj=${BASH_REMATCH[1]}; prop_min=${BASH_REMATCH[2]}; prop_pat=${BASH_REMATCH[3]}

		local cur_int prop_int
		cur_int=$(( cur_maj * 1000000 + cur_min * 1000 + cur_pat ))
		prop_int=$(( prop_maj * 1000000 + prop_min * 1000 + prop_pat ))

		if (( prop_int < cur_int )); then
			CHECK_STATUS[3]="CATASTROPHIC"
			CHECK_DETAIL[3]="  Proposed $proposed < current $CURRENT — this is a DOWNGRADE.
  Downgrades may break persisted state or replay incompatible config.
  If intentional, use --skip-check=3."
		fi
	else
		CHECK_STATUS[3]="WARNING"
		CHECK_DETAIL[3]="  Cannot parse versions for semver comparison: current='$CURRENT' proposed='$proposed'.
  Manual review recommended."
	fi
}

# Check 4: healthcheck.sh check-count diff.
_conflict_check_4() {
	CHECK_STATUS[4]="INFO"
	CHECK_DETAIL[4]=""

	local proposed_hc="$1"

	[[ -f "$proposed_hc" ]] || { CHECK_DETAIL[4]="  Proposed healthcheck not fetched — skipped."; return; }
	[[ -f "$HEALTHCHECK"  ]] || { CHECK_DETAIL[4]="  Live healthcheck not found — skipped."; return; }

	local live_checks proposed_checks
	live_checks=$(grep -cE '^check ' "$HEALTHCHECK" 2>/dev/null || true)
	live_checks=${live_checks:-0}
	proposed_checks=$(grep -cE '^check ' "$proposed_hc" 2>/dev/null || true)
	proposed_checks=${proposed_checks:-0}

	local added removed
	if (( proposed_checks >= live_checks )); then
		added=$(( proposed_checks - live_checks ))
		removed=0
	else
		added=0
		removed=$(( live_checks - proposed_checks ))
	fi

	CHECK_DETAIL[4]="  live=$live_checks proposed=$proposed_checks (+${added} added, -${removed} removed)"
}

# Check 5: CADDYFILE_SHA drift.
_conflict_check_5() {
	CHECK_STATUS[5]="INFO"
	local current_sha proposed_sha
	current_sha="${CADDYFILE_SHA:-unknown}"
	proposed_sha="$1"
	if [[ "$current_sha" == "$proposed_sha" ]]; then
		CHECK_DETAIL[5]="  SHA unchanged: $current_sha"
	else
		CHECK_DETAIL[5]="  Current SHA: $current_sha
  Proposed SHA: $proposed_sha
  Change: yes — apply will update install.env"
	fi
}

# Check 6: Unsubstituted placeholders in rendered Caddyfile.
_conflict_check_6() {
	CHECK_STATUS[6]="PASS"
	CHECK_DETAIL[6]=""

	local rendered_caddy="$1"
	[[ -f "$rendered_caddy" ]] || { CHECK_STATUS[6]="INFO"; CHECK_DETAIL[6]="  Rendered Caddyfile not available — skipped."; return; }

	local placeholders
	placeholders=$(grep -oE '\{\{[A-Z0-9_]+\}\}|__[A-Z0-9_]+__' "$rendered_caddy" 2>/dev/null | sort -u || true)
	if [[ -n "$placeholders" ]]; then
		CHECK_STATUS[6]="WARNING"
		local items
		items=$(printf '%s\n' "$placeholders" | sed 's/^/  Unsubstituted: /')
		CHECK_DETAIL[6]="$items
  Each placeholder above was not found in install.env — render incomplete."
	fi
}

# Check 7: GHCR token availability.
_conflict_check_7() {
	CHECK_STATUS[7]="PASS"
	CHECK_DETAIL[7]=""

	if [[ ! -r "$PREFIX_ETC/ghcr.token" ]]; then
		CHECK_STATUS[7]="CATASTROPHIC"
		CHECK_DETAIL[7]="  No GHCR token at $PREFIX_ETC/ghcr.token.
  docker compose pull will 401 for private images.
  Provide via: oxpulse-partner-edge-upgrade --ghcr-token=ghp_..."
	fi
}

# Check 8: Disk space on /var/lib/docker.
_conflict_check_8() {
	CHECK_STATUS[8]="PASS"
	CHECK_DETAIL[8]=""

	local avail_kb avail_gb
	avail_kb=$(df /var/lib/docker 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)
	avail_gb=$(( avail_kb / 1024 / 1024 ))

	if (( avail_gb < 2 )); then
		CHECK_STATUS[8]="WARNING"
		CHECK_DETAIL[8]="  Only ${avail_gb}GB free on /var/lib/docker (need ≥2GB for image pull).
  Free space: docker system prune -f"
	else
		CHECK_DETAIL[8]="  ${avail_gb}GB free on /var/lib/docker"
	fi
}

# ---------------------------------------------------------------------------
# run_conflict_checks — run all 8 checks, print structured report, exit with
# appropriate code: 1=catastrophic, 2=warning-only, 0=clean.
#
# Arguments:
#   $1 = rendered Caddyfile path (opec render caddy, DRY_RUN dry-render)
#   $2 = proposed compose template path (fetched but not applied)
#   $3 = proposed healthcheck path (fetched but not applied)
#   $4 = proposed Caddyfile SHA (pre-sub sha of the opec dry-render)
#   $5 = proposed image tag (TARGET)
# ---------------------------------------------------------------------------
run_conflict_checks() {
	local rendered_caddy="$1"
	local proposed_compose="$2"
	local proposed_hc="$3"
	local proposed_sha="$4"
	local proposed_tag="$5"

	declare -a CHECK_STATUS
	declare -a CHECK_DETAIL

	# Run all checks, skip if requested.
	if _check_skip 1; then CHECK_STATUS[1]="SKIP"; CHECK_DETAIL[1]="  (skipped via --skip-check)";
	else _conflict_check_1 "$rendered_caddy"; fi

	if _check_skip 2; then CHECK_STATUS[2]="SKIP"; CHECK_DETAIL[2]="  (skipped via --skip-check)";
	else _conflict_check_2 "$proposed_compose"; fi

	if _check_skip 3; then CHECK_STATUS[3]="SKIP"; CHECK_DETAIL[3]="  (skipped via --skip-check)";
	else _conflict_check_3 "$proposed_tag"; fi

	if _check_skip 4; then CHECK_STATUS[4]="SKIP"; CHECK_DETAIL[4]="  (skipped via --skip-check)";
	else _conflict_check_4 "$proposed_hc"; fi

	if _check_skip 5; then CHECK_STATUS[5]="SKIP"; CHECK_DETAIL[5]="  (skipped via --skip-check)";
	else _conflict_check_5 "$proposed_sha"; fi

	if _check_skip 6; then CHECK_STATUS[6]="SKIP"; CHECK_DETAIL[6]="  (skipped via --skip-check)";
	else _conflict_check_6 "$rendered_caddy"; fi

	if _check_skip 7; then CHECK_STATUS[7]="SKIP"; CHECK_DETAIL[7]="  (skipped via --skip-check)";
	else _conflict_check_7; fi

	if _check_skip 8; then CHECK_STATUS[8]="SKIP"; CHECK_DETAIL[8]="  (skipped via --skip-check)";
	else _conflict_check_8; fi

	# Print summary table.
	printf '\n=== upgrade --dry-run: conflict report ===\n'
	printf 'Mode: --with-templates\n'
	printf 'Repo: %s\n' "$REPO_RAW"
	printf '\n'

	local label
	local -A LABEL_MAP=(
		[1]="Caddyfile validation vs current image"
		[2]="Compose structural drift              "
		[3]="Image tag direction                   "
		[4]="healthcheck.sh diff                   "
		[5]="CADDYFILE_SHA drift                   "
		[6]="Env var coverage                      "
		[7]="GHCR token                            "
		[8]="Disk space                            "
	)

	for i in 1 2 3 4 5 6 7 8; do
		label="${LABEL_MAP[$i]}"
		local status="${CHECK_STATUS[$i]}"
		case "$status" in
			CATASTROPHIC) printf '[CHECK %d] %s  \033[31mCATASTROPHIC\033[0m\n' "$i" "$label" ;;
			WARNING)      printf '[CHECK %d] %s  \033[33mWARNING\033[0m\n'      "$i" "$label" ;;
			INFO)         printf '[CHECK %d] %s  INFO\n'                         "$i" "$label" ;;
			PASS)         printf '[CHECK %d] %s  \033[32mPASS\033[0m\n'         "$i" "$label" ;;
			SKIP)         printf '[CHECK %d] %s  SKIP\n'                         "$i" "$label" ;;
		esac
	done

	# Print detail blocks for non-PASS/SKIP checks.
	local has_details=0
	for i in 1 2 3 4 5 6 7 8; do
		local st="${CHECK_STATUS[$i]}"
		local det="${CHECK_DETAIL[$i]}"
		if [[ -n "$det" && "$st" != "PASS" ]]; then
			if [[ "$has_details" -eq 0 ]]; then
				printf '\n--- Details ---\n'
				has_details=1
			fi
			printf '\n[CHECK %d - %s]\n' "$i" "$st"
			printf '%s\n' "$det"
		fi
	done

	# Count severities.
	local catastrophic_count=0 warning_count=0
	for i in 1 2 3 4 5 6 7 8; do
		case "${CHECK_STATUS[$i]}" in
			CATASTROPHIC) (( catastrophic_count += 1 )) || true ;;
			WARNING)      (( warning_count += 1 ))      || true ;;
		esac
	done

	printf '\n=== summary ===\n'
	if [[ $catastrophic_count -gt 0 ]]; then
		printf '%d catastrophic, %d warnings. Exit code: 1.\n' "$catastrophic_count" "$warning_count"
		return 1
	elif [[ $warning_count -gt 0 ]]; then
		printf '0 catastrophic, %d warnings. Exit code: 2.\n' "$warning_count"
		return 2
	else
		printf '0 catastrophic, 0 warnings. Exit code: 0.\n'
		return 0
	fi
}

# ---- --with-templates mode ----
if [[ "$MODE" == with_templates ]]; then
	resolve_default_target
	derive_release_tag
	log "--with-templates: atomic Caddyfile + healthcheck + image upgrade (target=$TARGET release_tag=$RELEASE_TAG)"

	if [[ "$DRY_RUN" -eq 1 ]]; then
		log "[dry-run] plan:"
		log "  1. backup Caddyfile, healthcheck.sh, install.env, docker-compose.yml"
		log "  2. fetch + render Caddyfile.tpl → $PREFIX_ETC/Caddyfile"
		log "  3. fetch healthcheck.sh → $HEALTHCHECK"
		log "  4. patch image tags to $TARGET in $COMPOSE_FILE"
		log "  5. docker compose pull"
		log "  6. docker compose up -d"
		log "  7. healthcheck; auto-rollback on failure"

		# ------ Conflict detection ------
		# Fetch compose template and healthcheck into a temp dir for structural analysis.
		# The Caddyfile is dry-rendered below via opec render caddy (the same single
		# render authority reconcile_caddy_surface uses at apply time) into this tmpdir,
		# so the conflict checks see exactly what a real converge would install.
		_conflict_tmpdir=$(mktemp -d)
		# Append to the cumulative cleanup array instead of a single-slot EXIT trap,
		# which would clobber the staging-dir cleanup registered earlier (MEDIUM #3).
		_CLEANUP_PATHS+=("$_conflict_tmpdir")

		# Fetch healthcheck for Check 4.
		_proposed_hc="$_conflict_tmpdir/healthcheck.sh"
		curl -fsSL --max-time 30 "$REPO_RAW/healthcheck.sh" -o "$_proposed_hc" 2>/dev/null || true

		# Fetch compose template for Check 2.
		_proposed_compose="$_conflict_tmpdir/docker-compose.yml.tpl"
		curl -fsSL --max-time 30 "$REPO_RAW/docker-compose.yml.tpl" -o "$_proposed_compose" 2>/dev/null || true

		# Render Caddyfile directly for Check 1 and Check 6 via reconcile_caddy_surface
		# (opec render caddy — single render authority, Phase 1). DRY_RUN=1 so the surface
		# function writes rendered output but does NOT atomic_swap to the installed path.
		_rendered_caddy="$_conflict_tmpdir/Caddyfile"
		_proposed_sha="unknown"
		if grep -qE '^\s+caddy:' "$COMPOSE_FILE" 2>/dev/null && \
		   [[ -n "${PARTNER_DOMAIN:-}" ]] && [[ -n "${TURNS_SUBDOMAIN:-}" ]]; then
			_caddyfile_tpl="$_conflict_tmpdir/Caddyfile.tpl"
			if curl -fsSL --max-time 30 "$REPO_RAW/Caddyfile.tpl" 					-o "$_caddyfile_tpl" 2>/dev/null; then
				# Set up env for opec (same resolution as reconcile_caddy_surface).
				_setup_caddy_render_env "$_caddyfile_tpl"
				command -v opec >/dev/null 2>&1 && \
					opec render caddy --tpl "$_caddyfile_tpl" --out "$_rendered_caddy" 2>/dev/null || {
						warn "[dry-run] opec not available or render failed — Caddyfile conflict check skipped"
					}
				if [[ -f "$_rendered_caddy" ]]; then
					_proposed_sha=$(sha256sum "$_rendered_caddy" | awk '{print $1}')
					sed -i "s|__CADDYFILE_SHA__|${_proposed_sha}|g" "$_rendered_caddy"
				fi
			fi
		fi

		# Run all conflict checks; capture exit code without triggering set -e.
		_conflict_exit=0
		run_conflict_checks \
			"$_rendered_caddy" \
			"$_proposed_compose" \
			"$_proposed_hc" \
			"$_proposed_sha" \
			"$TARGET" || _conflict_exit=$?

		exit "$_conflict_exit"
	fi

	# FIX 2: self-update - before ANY backup/mutation, re-exec into the freshly
	# released upgrade.sh (once) if the running copy is stale, so an in-upgrade.sh
	# fix (e.g. the settle cold-start gate) lands this run. Rollback-safe: execs a
	# temp copy, disk untouched (see _maybe_self_update_reexec).
	_maybe_self_update_reexec "$@"

	# Phase 3 (Decision 4): baseline captured AFTER sync_host_scripts (Step 5) so the
	# new --snapshot-capable healthcheck.sh is in place before the snapshot is taken.
	# Declared here (empty) so Step 1–5 rollback paths can reference ${_wt_baseline_snap:-}
	# without an unbound-variable error under set -u.
	_wt_baseline_snap=""

	# MAJOR-1/MAJOR-2 early guard (PR review round 2 on #333) — resolve the
	# partner-edge-* service scope BEFORE any mutation. See
	# resolve_edge_service_scope()'s docstring: dying here leaves nothing to
	# restore. _wt_edge_svcs is reused below for the pull, digest capture,
	# and post-pull digest resolution — one compose-config fetch, not one
	# per caller.
	declare -a _wt_edge_svcs
	resolve_edge_service_scope _wt_edge_svcs

	# Step 1: backup current state before any mutation (images + templates + host-scripts).
	[[ -f "$PREFIX_ETC/Caddyfile" ]]  && cp -a "$PREFIX_ETC/Caddyfile" "$PREV_CADDYFILE"
	[[ -f "$HEALTHCHECK" ]]           && cp -a "$HEALTHCHECK" "$PREV_HEALTHCHECK"
	cp -a "$STATE_FILE"   "$PREV_STATE_FILE"
	cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"
	snapshot_host_scripts "$CURRENT"

	# Phase 2 (Task 6): opec-presence + caddy-render-capable probe BEFORE reconcile.
	# Unlike install.sh (which always runs _ensure_opec_binary at startup), upgrade.sh
	# had no probe — a box with missing/stale opec would die mid-reconcile with a
	# cryptic error from reconcile_caddy_surface.  Probe here with a clear message.
	_probe_opec_for_upgrade() {
		# Check opec present and understands `render caddy`.
		if ! command -v opec >/dev/null 2>&1; then
			# Try to fetch via sync_host_scripts if RELEASE_TAG is available.
			if [[ -n "${RELEASE_TAG:-}" ]]; then
				log "opec not found — attempting to fetch via sync_host_scripts $RELEASE_TAG"
				sync_host_scripts "$RELEASE_TAG" || true
			fi
			# Re-check after potential install.
			command -v opec >/dev/null 2>&1 || \
				die "opec not on PATH — required for --with-templates Caddyfile render. Re-run install.sh or install opec manually: see https://github.com/anatolykoptev/oxpulse-partner-edge/releases"
		fi
		# Capability probe: opec must support `render caddy` (added in Phase 1).
		if ! opec render caddy --help >/dev/null 2>&1; then
			log "opec does not support 'render caddy' — attempting to update via sync_host_scripts"
			[[ -n "${RELEASE_TAG:-}" ]] && sync_host_scripts "$RELEASE_TAG" || true
			opec render caddy --help >/dev/null 2>&1 || \
				die "opec binary is too old (missing 'render caddy' subcommand). Update opec: re-run install.sh or copy opec-$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/') from the release bundle."
		fi
	}
	_probe_opec_for_upgrade

	# Step 2: fetch manifest + templates. die()s on fetch failure — no state has been
	# mutated yet (backups exist but originals are untouched). Manifest drives reconcile_all.
	_manifest_path_wt=""
	_manifest_tmpdir_wt=$(mktemp -d)
	# shellcheck disable=SC2064
	trap "rm -rf '$_manifest_tmpdir_wt'" RETURN
	if ! curl -fsSL --max-time 30 "$REPO_RAW/manifest.yaml" \
			-o "$_manifest_tmpdir_wt/manifest.yaml" 2>/dev/null; then
		die "could not fetch manifest.yaml from $REPO_RAW — aborting (no changes applied)"
	fi
	_manifest_path_wt="$_manifest_tmpdir_wt/manifest.yaml"

	# Step 3: patch image tags in compose (same as plain image upgrade).
	sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
		"$COMPOSE_FILE"
	sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"

	# Step 4: sync host-scripts for the release tag (health-report, sbin libs, units).
	# Must run BEFORE the baseline snapshot so the newly-installed healthcheck.sh
	# (with --snapshot support) is used. sync_host_scripts does NOT recreate containers,
	# so the baseline still reflects the pre-change container/service state.
	log "syncing host-scripts to $RELEASE_TAG (image tag=$TARGET)"
	sync_host_scripts "$RELEASE_TAG"

	# Step 5: capture baseline health snapshot BEFORE reconcile_all (MAJOR-2 fix).
	# Correct order: sync_host_scripts → baseline → reconcile_all → pull/recreate → post.
	# Prior order had baseline AFTER reconcile_all: a caddy-reload-induced breakage was
	# recorded INTO the baseline, so health_regressions saw no delta and skipped rollback.
	# Skip on fresh install (HEALTHCHECK absent); health_regressions skips diff when
	# baseline file is absent (first-run path: no rollback on new reds).
	_wt_baseline_snap=$(mktemp)
	if [[ -x "$HEALTHCHECK" ]]; then
		log "capturing pre-change health baseline (--with-templates, post host-script sync, pre-reconcile)"
		health_snapshot "$HEALTHCHECK" "$_wt_baseline_snap" || true
	else
		log "healthcheck binary absent — skipping pre-change baseline (first install?)"
		rm -f "$_wt_baseline_snap"; _wt_baseline_snap=""
	fi
	# P3-serveability: pre-change per-channel serve-ability baseline (chN=OK|DOWN)
	# captured at the SAME pre-change point as the health baseline and registered
	# for EXIT cleanup, so the settle gate can tell a real serve-ability loss from a
	# single-channel (e.g. xray-only) regression. Best-effort — an empty file (a
	# reporter without --serveability) disables the serve-ability gate for this run.
	_wt_serve_baseline=$(mktemp)
	_CLEANUP_PATHS+=("$_wt_serve_baseline")
	_settle_serveability_snapshot "$_wt_serve_baseline" || true

	# Step 6: reconcile all surfaces (Phase 4a engine).
	# Phase 4a wires caddyfile only; apply_caddy_reloads fires a targeted caddy hot-reload
	# (no peer containers down). Caddyfile.tpl is fetched inside reconcile_all via REPO_RAW.
	# reconcile_caddy_surface (opec render caddy) is the single Caddyfile render authority
	# for both apply paths; the legacy re_render_caddy shell renderer was deleted (Phase 5
	# strangler completion — it had 0 production callers once this became the live path).
	#
	# healthcheck.sh is NOT re-rendered here anymore (cheburator incident fix):
	# sync_host_scripts (Step 4, above) now delivers it — that call already
	# runs BEFORE the Step 5 baseline snapshot, so the standalone
	# re_render_healthcheck() call that used to live here was not just
	# redundant but WRONG: it ran AFTER the baseline (Step 5), meaning the
	# baseline was captured with the OLD healthcheck and only the post-change
	# measurement used the new one — silent phantom-regression risk on every
	# --with-templates upgrade. Deleted; sync_host_scripts is the single
	# source of truth for healthcheck.sh in both apply paths now.
	export RECONCILE_TMPDIR="$_manifest_tmpdir_wt"
	reconcile_all "$_manifest_path_wt"
	unset RECONCILE_TMPDIR

	# Step 7 (formerly Step 6): pull new images.

	# Step 8: pull new images (with per-service digest capture for zero-downtime recreate).
	ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"
	declare -A _wt_before_digests
	capture_running_digests _wt_edge_svcs _wt_before_digests

	# _wt_edge_svcs was resolved by the early guard above (before any
	# mutation) — reused here, not recomputed (PR review round 2 MINOR).
	log "pulling images (tag=$TARGET): ${_wt_edge_svcs[*]}"
	# BUG FIX (dead rollback under set -e): `if ! var=$(...); then` — a bare
	# `var=$(...)` assignment as a plain top-level statement is NOT exempt
	# from `set -e`; a failing pull killed the WHOLE script right here,
	# before the rollback branch below ever ran (rvpn v0.13.0 incident: the
	# script died mid-upgrade with compose+host-scripts already rewritten to
	# the new version, containers still on the old one, no rollback, no
	# diagnostic beyond the last log line). Wrapping the assignment as an
	# `if` condition IS the exemption — bash does not apply errexit to a
	# command whose status is being tested.
	if ! pull_out=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_wt_edge_svcs[@]}" 2>&1); then
		printf '%s\n' "$pull_out" >&2
		if ! ghcr_pull_diagnose "$pull_out"; then
			warn "ghcr: pull failed but not for an auth reason (see output above)"
		fi
		warn "pull failed — rolling back"
		do_rollback_templates
		restore_host_scripts
		die "pull failed — rolled back to previous state"
	fi

	# Step 7: recreate only services whose image digest changed (zero-downtime).
	declare -A _wt_after_digests
	if ! resolve_pulled_digests _wt_edge_svcs _wt_after_digests; then
		# PR review round 2 MAJOR-1: this is a POST-MUTATION call site — mirror
		# the pull-failure branch above (restore, don't just die outright).
		warn "post-pull compose config resolution failed — rolling back"
		do_rollback_templates
		restore_host_scripts
		die "post-pull compose config resolution failed — rolled back to previous state"
	fi
	if ! recreate_changed_services _wt_before_digests _wt_after_digests; then
		warn "compose up failed — rolling back"
		do_rollback_templates
		restore_host_scripts
		mapfile -t _wt_rb_edge_svcs < <(list_partner_edge_services)
		if [[ "${#_wt_rb_edge_svcs[@]}" -gt 0 ]]; then
			(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_wt_rb_edge_svcs[@]}") || true
		fi
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d) || true
		die "--with-templates upgrade rolled back due to compose up failure"
	fi

	# Step 8: verify with retry — Phase 3 baseline-aware gate.
	# Pass baseline snapshot so gate diffs pre-change vs post-change.
	if ! settle_healthcheck_with_retry "with-templates-upgrade" "${_wt_baseline_snap:-}" "${_wt_serve_baseline:-}"; then
		warn "healthcheck regression after --with-templates upgrade — rolling back"
		rm -f "${_wt_baseline_snap:-}"
		do_rollback_templates
		restore_host_scripts
		mapfile -t _wt_rb2_edge_svcs < <(list_partner_edge_services)
		if [[ "${#_wt_rb2_edge_svcs[@]}" -gt 0 ]]; then
			(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_wt_rb2_edge_svcs[@]}") || true
		fi
		(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d) || true
		if ! "$HEALTHCHECK" --local; then
			die "--with-templates rolled back but healthcheck still failing — manual recovery required"
		fi
		die "--with-templates upgrade rolled back due to post-upgrade healthcheck regression"
	fi
	rm -f "${_wt_baseline_snap:-}"

	log "--with-templates upgrade to $TARGET complete"
	re_render_xray
	exit 0
fi

resolve_default_target
derive_release_tag
log "current=$CURRENT target=$TARGET release_tag=$RELEASE_TAG"

if [[ "$CURRENT" == "$TARGET" && "$MODE" != rollback ]]; then
	log "already on $TARGET — nothing to do"
	exit 0
fi
if [[ "$MODE" == check ]]; then
	echo "UPGRADE_AVAILABLE current=$CURRENT target=$TARGET"
	exit 10
fi

# ---- --dry-run gate for the full image upgrade path ----
# BUG FIX: The plain apply path previously ran every mutating operation
# (compose tag rewrite, host-script sync, compose pull, container recreate,
# healthcheck, rollback) unconditionally even with --dry-run, causing a real
# prod recreate + rollback cycle on ruoxp during a dry-run upgrade v0.12.45→v0.12.61
# (~49s downtime). The --with-templates path already exited early at its own
# dry-run block above; this gate covers the plain apply path.
#
# In dry-run: read-only inspection (capture_running_digests calls docker inspect,
# which is safe) is intentionally skipped too — printing the plan is sufficient.
if [[ "$DRY_RUN" -eq 1 ]]; then
	log "[dry-run] plan for full image upgrade $CURRENT → $TARGET:"
	log "  1. backup $COMPOSE_FILE → $PREV_COMPOSE_FILE"
	log "  2. backup $STATE_FILE → $PREV_STATE_FILE"
	log "  3. snapshot host-scripts ($CURRENT)"
	log "  4. rewrite compose image tags: *:$CURRENT → *:$TARGET"
	log "     (sed -E 's|(ghcr.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\\1:$TARGET|g')"
	log "  5. update IMAGE_VERSION=$TARGET in $STATE_FILE"
	log "  6. sync host-scripts to $RELEASE_TAG"
	log "  7. docker compose pull (images rewritten to $TARGET before pull)"
	log "  8. recreate services whose digest changed (running → $TARGET)"
	log "  9. settle-retry healthcheck (poll ${OXPULSE_UPGRADE_HEALTH_TIMEOUT:-30}s budget, 3s interval)"
	log "  10. on failure: rollback compose + host-scripts + compose pull + up"
	log "[dry-run] no docker pull, no container recreate, no rollback performed"
	exit 0
fi

# MAJOR-1/MAJOR-2 early guard (PR review round 2 on #333) — resolve the
# partner-edge-* service scope BEFORE any mutation. See
# resolve_edge_service_scope()'s docstring: dying here leaves nothing to
# restore. _edge_svcs is reused below for the pull, digest capture, and
# post-pull digest resolution — one compose-config fetch, not one per caller.
# FIX 2: self-update - before ANY backup/mutation, re-exec into the freshly
# released upgrade.sh (once) if the running copy is stale (see with-templates
# path). Rollback-safe: temp-exec, disk untouched.
_maybe_self_update_reexec "$@"

declare -a _edge_svcs
resolve_edge_service_scope _edge_svcs

# ---- Backup current config + host-scripts before mutating ----
cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"
cp -a "$STATE_FILE"   "$PREV_STATE_FILE"
snapshot_host_scripts "$CURRENT"

# BUG FIX (tag-rewrite): rewrite image tags to TARGET in the compose file
# BEFORE docker compose pull so that pull fetches the correct target images.
# The regex captures the full image name up to the colon and replaces the
# tag portion with TARGET. This must happen before any pull invocation so
# that both the pull and the subsequent `compose up` use the target tag, not
# the currently-running tag.
sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" \
	"$COMPOSE_FILE"
sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"
log "compose image tags rewritten to $TARGET (pre-pull)"

# Sync host-scripts for the release tag before pulling images so that a
# failed image pull leaves the host-scripts already at the new version —
# rollback restores both atomically from the snapshot taken above.
# RELEASE_TAG = TARGET = vX.Y.Z (single tag form starting at v0.12.60).
log "syncing host-scripts to $RELEASE_TAG (image tag=$TARGET)"
sync_host_scripts "$RELEASE_TAG"

# Refresh ghcr auth from stored token (no-op if file absent).
ghcr_login_from_file || warn "ghcr: login from stored token failed; will attempt pull anyway"

# Phase 3 (Decision 4): capture baseline health snapshot BEFORE pull.
# Must happen before image pull to capture the pre-change state.
_baseline_snapshot=$(mktemp)
if [[ -x "$HEALTHCHECK" ]]; then
	log "capturing pre-change health baseline (plain-upgrade)"
	health_snapshot "$HEALTHCHECK" "$_baseline_snapshot" || true
else
	log "healthcheck binary absent — skipping pre-change baseline"
	rm -f "$_baseline_snapshot"; _baseline_snapshot=""
fi
# P3-serveability: pre-change per-channel serve-ability baseline (chN=OK|DOWN),
# registered for EXIT cleanup — lets the settle gate tell a real serve-ability
# loss from a single-channel (e.g. xray-only) regression. Best-effort (empty file
# = reporter without --serveability = serve-ability gate disabled this run).
_serve_baseline_snapshot=$(mktemp)
_CLEANUP_PATHS+=("$_serve_baseline_snapshot")
_settle_serveability_snapshot "$_serve_baseline_snapshot" || true

# Capture per-service image digests BEFORE pull so we can skip recreating
# services whose image did not actually change (e.g. no-op version bump where
# the sfu image is byte-for-byte identical across tags).
# NOTE: capture uses `docker inspect` on running containers — read-only, safe.
declare -A _before_digests
capture_running_digests _edge_svcs _before_digests

# _edge_svcs was resolved by the early guard above (before any mutation) —
# reused here, not recomputed (PR review round 2 MINOR).
log "pulling new images (tag=$TARGET): ${_edge_svcs[*]}"
# BUG FIX (dead rollback under set -e): `if ! var=$(...); then` — see the
# --with-templates pull above for the full rationale. A bare `pull_out=$(...)`
# assignment as a plain statement is NOT exempt from `set -e`; a failing pull
# killed the WHOLE script right here on rvpn, before this rollback branch
# ever ran — compose+host-scripts ended up at v0.13.0, containers stuck on
# v0.12.72, no rollback, no diagnostic beyond the last log line.
if ! pull_out=$(cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_edge_svcs[@]}" 2>&1); then
	# Print pull output so operator can see context.
	printf '%s\n' "$pull_out" >&2
	# If denied pattern → friendly hint (prints suggestion to use --ghcr-token=).
	if ! ghcr_pull_diagnose "$pull_out"; then
		warn "ghcr: pull failed but not for an auth reason (see output above)"
	fi
	# Restore host-scripts to pre-upgrade state since image pull failed.
	restore_host_scripts
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	die "pull failed — previous config and host-scripts restored"
fi

# Resolve post-pull digests and recreate only services that changed.
# resolve_pulled_digests reads the (already-rewritten) compose file to get
# the TARGET image references, then inspects local Docker state after pull.
# This correctly compares running-digest (before_digests) vs TARGET-digest
# (after_digests), so only services whose TARGET image differs from what is
# currently running are recreated (zero-downtime for no-op version bumps).
# fail-safe: if digest resolution fails for a service, recreate_changed_services
# treats an empty after-digest as "unknown → recreate" (not "skip").
declare -A _after_digests
if ! resolve_pulled_digests _edge_svcs _after_digests; then
	# PR review round 2 MAJOR-1: this is a POST-MUTATION call site — mirror
	# the pull-failure branch above (restore, don't just die outright).
	printf '%s\n' "post-pull compose config resolution failed" >&2
	restore_host_scripts
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	die "post-pull compose config resolution failed — previous config and host-scripts restored"
fi

if ! recreate_changed_services _before_digests _after_digests; then
	warn "up failed — rolling back to $CURRENT"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	restore_host_scripts
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate) || true
	die "upgrade rolled back"
fi

# Wait for services to stabilize after container recreation, with retry.
# settle_healthcheck_with_retry polls every 3s up to OXPULSE_UPGRADE_HEALTH_TIMEOUT
# seconds (default 30s = 10 attempts × 3s).  The budget is 4× the documented
# worst-case xray Reality establishment time (~8s on rvpn v0.12.20 incident),
# with added margin for a loaded edge.  A single sleep 10 was replaced because
# the 2s slack was insufficient on loaded edges (see function definition comment).
# Phase 3: pass baseline snapshot for regression-aware gate.
if ! settle_healthcheck_with_retry "plain-upgrade" "${_baseline_snapshot:-}" "${_serve_baseline_snapshot:-}"; then
	warn "healthcheck regression after upgrade — rolling back"
	rm -f "${_baseline_snapshot:-}"
	cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"
	cp -a "$PREV_STATE_FILE"   "$STATE_FILE"
	restore_host_scripts
	mapfile -t _rb_edge_svcs < <(list_partner_edge_services)
	if [[ "${#_rb_edge_svcs[@]}" -gt 0 ]]; then
		(ghcr_login_from_file || true; cd "$PREFIX_ETC" && $DOCKER_BIN compose pull "${_rb_edge_svcs[@]}")
	fi
	(cd "$PREFIX_ETC" && $DOCKER_BIN compose up -d --force-recreate) || true
	die "upgrade rolled back due to post-upgrade healthcheck regression"
fi
rm -f "${_baseline_snapshot:-}"

log "upgraded to $TARGET successfully"

re_render_xray

if [[ "$V01_TO_V02" -eq 1 ]]; then
	log "v0.1→v0.2: re-seeding templates via hydrate --reseed"
	/usr/local/sbin/oxpulse-partner-edge-hydrate --reseed \
		|| warn "hydrate --reseed exited non-zero — upgrade succeeded, but re-run 'oxpulse-partner-edge-hydrate --reseed' manually to ensure templates are current"
fi
