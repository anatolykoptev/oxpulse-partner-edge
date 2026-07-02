#!/bin/bash
# tests/test_upgrade_syncs_healthcheck.sh
#
# Regression guard: the plain (non --with-templates) upgrade path MUST sync
# healthcheck.sh, and the health-gate must measure with the SYNCED version —
# not a stale pre-upgrade copy.
#
# Cheburator incident (2026-07, hit 4 of 5 edges): healthcheck.sh was only
# ever updated by re_render_healthcheck(), which ran ONLY on --with-templates.
# sync_host_scripts() (the plain path) never included it. Consequence chain:
#   1. An edge stuck at an old healthcheck (e.g. hardcoded 127.0.0.1:9317 for
#      check 12) sees a PERMANENT false RED once its compose moves to a mesh
#      IP (SFU_METRICS_BIND) — the fix for that lives in a NEWER healthcheck
#      that never arrives via plain upgrade.
#   2. The old healthcheck also lacks --snapshot support, so
#      settle_healthcheck_with_retry falls back to the ABSOLUTE --local gate
#      ("healthcheck lacks --snapshot support") — where the pre-existing red
#      BLOCKS every single plain upgrade, forever (chicken-and-egg: the fix
#      can only arrive via the upgrade the bug prevents from succeeding).
# Fleet workaround used live: OXPULSE_HEALTHCHECK=/tmp/hc-v13.sh injection +
# manual install — this test guards the real fix so that folklore is retired.
#
# Test strategy: extract sync_host_scripts (+ its helper functions) from
# upgrade.sh, same pattern as test_upgrade_syncs_host_scripts.sh, plus one
# full end-to-end plain-upgrade run (same fixture style as
# test_upgrade_pull_scope_and_rollback.sh) to prove the ORDERING claim:
# the health baseline + settle gate are measured with the NEWLY-SYNCED
# healthcheck, not the pre-upgrade one.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Section A — structural
# ===========================================================================
echo ""
echo "=== Section A: structural — healthcheck.sh is a managed host-script ==="

bash -n "$UPGRADE" && pass "A1: syntax clean" || { fail "A1: syntax errors"; exit 1; }

# GNU grep -E does not reliably treat \t as a tab (POSIX ERE leaves it
# undefined) — extract the array body first, then a plain fixed-string match
# (avoids the anchor-fragility footgun hit earlier in this same file's
# sibling test, test_upgrade_pull_scope_and_rollback.sh Section C1d).
sbin_files_block=$(awk '/^_HOST_SCRIPT_SBIN_FILES=\(/{f=1} f{print} f && /^\)$/{exit}' "$UPGRADE")
echo "$sbin_files_block" | grep -qF 'oxpulse-partner-edge-healthcheck' \
    && pass "A2: oxpulse-partner-edge-healthcheck listed in _HOST_SCRIPT_SBIN_FILES" \
    || fail "A2: oxpulse-partner-edge-healthcheck NOT in _HOST_SCRIPT_SBIN_FILES — plain upgrade still never syncs it"

grep -qF 'oxpulse-partner-edge-healthcheck)       echo "healthcheck.sh"' "$UPGRADE" \
    && pass "A3: _host_script_remote_name maps it to healthcheck.sh" \
    || fail "A3: no remote-name mapping for oxpulse-partner-edge-healthcheck"

grep -qF 'oxpulse-partner-edge-healthcheck) sha256_asset_name="partner-edge-healthcheck.sh"' "$UPGRADE" \
    && pass "A4: sha256_asset_name mapping present (matches release.yml's staged asset name)" \
    || fail "A4: no sha256_asset_name mapping — checksum guard would silently no-op for it"

# A5: re_render_healthcheck() must be GONE — single source of truth is now
# sync_host_scripts, not a second fetch path.
if grep -qE '^re_render_healthcheck\(\)' "$UPGRADE"; then
    fail "A5: re_render_healthcheck() still defined — a second, redundant/mistimed fetch path for healthcheck.sh remains"
else
    pass "A5: re_render_healthcheck() removed — sync_host_scripts is the single fetch path"
fi

# A6: mode must default to 0755 (executable) for the healthcheck binary —
# it must NOT fall into the 0644 sourced-lib bucket.
mode_fn=$(awk '/^_host_script_mode\(\)/{f=1} f{print} f && /^}$/{exit}' "$UPGRADE")
echo "$mode_fn" | grep -qF 'oxpulse-partner-edge-healthcheck' \
    && fail "A6: oxpulse-partner-edge-healthcheck should NOT need a _host_script_mode() special case (falls to the 0755 default) — but it wrongly does" \
    || pass "A6: oxpulse-partner-edge-healthcheck falls through to the default 0755 mode (no 0644-lib special case)"

# A7 (ordering, MAJOR): the baseline health-snapshot log line must appear
# AFTER "sync_host_scripts \"\$RELEASE_TAG\"" in BOTH apply paths — otherwise
# the baseline is captured with the OLD healthcheck even after this fix.
plain_sync_line=$(grep -n 'sync_host_scripts "$RELEASE_TAG"' "$UPGRADE" | tail -1 | cut -d: -f1 || true)
plain_baseline_line=$(grep -n 'capturing pre-change health baseline (plain-upgrade)' "$UPGRADE" | cut -d: -f1 || true)
if [[ -n "$plain_sync_line" && -n "$plain_baseline_line" && "$plain_sync_line" -lt "$plain_baseline_line" ]]; then
    pass "A7a: plain-apply path syncs host-scripts (line $plain_sync_line) BEFORE the health baseline (line $plain_baseline_line)"
else
    fail "A7a: plain-apply sync=$plain_sync_line baseline=$plain_baseline_line — sync does not precede the baseline capture"
fi

# NOTE: upgrade.sh has MULTIPLE 'sync_host_scripts "$RELEASE_TAG"' call sites
# (--host-scripts-only mode, an opec-probe fallback inside the --with-templates
# block, and the actual --with-templates Step 4 call) — `head -1` would grab
# the --host-scripts-only mode's call (textually first in the file, an
# unrelated code path), not the with-templates Step 4 call. Take the LAST
# occurrence that appears BEFORE the with-templates baseline marker instead —
# that relative ordering is the actual invariant under test, not "first
# occurrence in the file" (see tests/test_health_gate_baseline.sh S10 for the
# identical fix, hit by the same line-shift class of bug).
wt_baseline_line=$(grep -n 'capturing pre-change health baseline (--with-templates' "$UPGRADE" | cut -d: -f1 || true)
wt_sync_line=$(grep -n 'sync_host_scripts "$RELEASE_TAG"' "$UPGRADE" \
    | awk -F: -v maxline="${wt_baseline_line:-0}" '$1 < maxline { line = $1 } END { if (line != "") print line }')
if [[ -n "$wt_sync_line" && -n "$wt_baseline_line" && "$wt_sync_line" -lt "$wt_baseline_line" ]]; then
    pass "A7b: --with-templates path syncs host-scripts (line $wt_sync_line) BEFORE the health baseline (line $wt_baseline_line)"
else
    fail "A7b: --with-templates sync=$wt_sync_line baseline=$wt_baseline_line — sync does not precede the baseline capture"
fi

# ===========================================================================
# Section B — functional: sync_host_scripts (extracted) fetches + installs
# healthcheck.sh, replacing a stale pre-upgrade copy
# ===========================================================================
echo ""
echo "=== Section B: sync_host_scripts installs a changed healthcheck.sh ==="

B_TMPDIR=$(mktemp -d)
trap 'rm -rf "$B_TMPDIR"' EXIT

PREAMBLE="$B_TMPDIR/fn_preamble.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
PREFIX_BIN="${PREFIX_BIN:-${OXPULSE_PREFIX_BIN:-/usr/local/bin}}"
HELPERS
    awk '/^_HOST_SCRIPT_SBIN_FILES=\(/{found=1} found{print} found && /^\)$/{exit}' "$UPGRADE"
    awk '/^_host_script_remote_name\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_install_dir\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_mode\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^sync_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
} > "$PREAMBLE"
bash -n "$PREAMBLE" || { fail "B0: extracted preamble has syntax errors"; exit 1; }

# Minimal REPO_RAW fixture: only healthcheck.sh needs to exist — every other
# file in _HOST_SCRIPT_SBIN_FILES 404s and is skipped gracefully (existing
# sync_host_scripts contract: "could not fetch $fetch_url — skipping $f").
B_REPO="$B_TMPDIR/repo_raw"
mkdir -p "$B_REPO"
NEW_HC_CONTENT='#!/usr/bin/env bash
# NEW healthcheck.sh (fixture) — supports --snapshot.
if [[ "$1" == "--snapshot" ]]; then
    echo "check_99_hc_sync_marker=GREEN"
    exit 0
fi
exit 0
'
printf '%s' "$NEW_HC_CONTENT" > "$B_REPO/healthcheck.sh"

B_SBIN="$B_TMPDIR/sbin"
mkdir -p "$B_SBIN"
OLD_HC_CONTENT='#!/usr/bin/env bash
# OLD healthcheck.sh (pre-upgrade stub) — no --snapshot support at all.
exit 0
'
printf '%s' "$OLD_HC_CONTENT" > "$B_SBIN/oxpulse-partner-edge-healthcheck"
chmod 0755 "$B_SBIN/oxpulse-partner-edge-healthcheck"
OLD_SHA=$(sha256sum "$B_SBIN/oxpulse-partner-edge-healthcheck" | awk '{print $1}')

B_OUT=$(
    PREFIX_SBIN="$B_SBIN" \
    PREFIX_BIN="$B_TMPDIR/bin" \
    PREFIX_LIBDIR="$B_TMPDIR/libdir" \
    SYSTEMD_DIR="$B_TMPDIR/systemd" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="file://$B_REPO" \
    RELEASES_BASE="file://$B_REPO/NOSUCHRELEASE" \
    ALLOW_UNVERIFIED=1 \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.99.0-test" 2>&1
) && B_RC=0 || B_RC=$?

[[ "$B_RC" -eq 0 ]] \
    && pass "B1: sync_host_scripts exited 0" \
    || fail "B1: sync_host_scripts exited $B_RC; output: $B_OUT"

echo "$B_OUT" | grep -qF 'installed oxpulse-partner-edge-healthcheck' \
    && pass "B2: sync_host_scripts reports it installed oxpulse-partner-edge-healthcheck" \
    || fail "B2: no 'installed oxpulse-partner-edge-healthcheck' log line; output: $B_OUT"

NEW_SHA_ON_DISK=$(sha256sum "$B_SBIN/oxpulse-partner-edge-healthcheck" | awk '{print $1}')
if [[ "$NEW_SHA_ON_DISK" != "$OLD_SHA" ]]; then
    pass "B3: installed healthcheck content CHANGED (stale pre-upgrade stub replaced)"
else
    fail "B3: installed healthcheck content unchanged — still the old stub (sha=$OLD_SHA)"
fi

EXPECTED_NEW_SHA=$(printf '%s' "$NEW_HC_CONTENT" | sha256sum | awk '{print $1}')
[[ "$NEW_SHA_ON_DISK" == "$EXPECTED_NEW_SHA" ]] \
    && pass "B4: installed content matches the fixture's NEW healthcheck.sh exactly" \
    || fail "B4: installed content does not match the fixture's NEW healthcheck.sh (sha mismatch)"

# The newly-installed binary must actually support --snapshot now.
if "$B_SBIN/oxpulse-partner-edge-healthcheck" --snapshot 2>/dev/null | grep -qE '^check_99_hc_sync_marker=GREEN$'; then
    pass "B5: the synced healthcheck supports --snapshot and emits the fixture marker"
else
    fail "B5: the synced healthcheck does not support --snapshot as expected"
fi

[[ -f "$B_SBIN/oxpulse-partner-edge-healthcheck" ]] && [[ "$(stat -c '%a' "$B_SBIN/oxpulse-partner-edge-healthcheck" 2>/dev/null || stat -f '%A' "$B_SBIN/oxpulse-partner-edge-healthcheck" 2>/dev/null)" == "755" ]] \
    && pass "B6: installed mode is 0755 (executable)" \
    || fail "B6: installed mode is not 0755"

rm -rf "$B_TMPDIR"
trap - EXIT

# ===========================================================================
# Section C — functional, end-to-end: the settle/baseline gate measures with
# the SYNCED healthcheck, not a stale pre-upgrade one (the ordering claim,
# proven at runtime, not just by source-line position)
# ===========================================================================
echo ""
echo "=== Section C: end-to-end plain upgrade — settle gate uses the NEWLY-synced healthcheck ==="
echo "    FALSIFICATION NOTE: must be RED against current main — healthcheck.sh isn't in"
echo "    _HOST_SCRIPT_SBIN_FILES there, so the OLD (no-snapshot) stub stays installed and"
echo "    settle_healthcheck_with_retry falls back to the --local gate every time."

_make_fixture() {
    local dir="$1"
    mkdir -p "$dir/etc" "$dir/var" "$dir/sbin" "$dir/bin" "$dir/libdir" "$dir/systemd" "$dir/share"
    printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
        > "$dir/sbin/channel-render-lib.sh"
    printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
        > "$dir/sbin/ghcr-auth-lib.sh"
}

C_TMPDIR=$(mktemp -d)
trap 'rm -rf "$C_TMPDIR"' EXIT
_make_fixture "$C_TMPDIR"

C_CURRENT=v0.12.72
C_TARGET=v0.13.0

printf 'IMAGE_VERSION=%s\nSIGNALING_SFU_SECRET=testsecret\nSCHEMA_VERSION=1\n' "$C_CURRENT" \
    > "$C_TMPDIR/var/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:%s\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    "$C_CURRENT" > "$C_TMPDIR/etc/docker-compose.yml"

# OLD pre-upgrade healthcheck: understands --local (exit 0) but NOT
# --snapshot (the exact "lacks --snapshot support" incident condition).
printf '#!/usr/bin/env bash\nif [[ "$1" == "--snapshot" ]]; then exit 1; fi\nexit 0\n' \
    > "$C_TMPDIR/sbin/oxpulse-partner-edge-healthcheck"
chmod 0755 "$C_TMPDIR/sbin/oxpulse-partner-edge-healthcheck"

# NEW healthcheck fixture served via REPO_RAW: supports both --local and
# --snapshot.
C_REPO="$C_TMPDIR/repo_raw"
mkdir -p "$C_REPO"
printf '#!/usr/bin/env bash\nif [[ "$1" == "--snapshot" ]]; then echo "check_99_hc_sync_marker=GREEN"; exit 0; fi\nexit 0\n' \
    > "$C_REPO/healthcheck.sh"

C_FAKE_DOCKER="$C_TMPDIR/docker"
cat > "$C_FAKE_DOCKER" << 'CFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\n'
    exit 0
fi
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    cat "${COMPOSE_FILE_PATH}"
    exit 0
fi
if [[ "$*" == *"ps --quiet"* ]]; then
    printf 'fakectr123\n'
    exit 0
fi
if [[ "$*" == *"inspect"* ]]; then
    printf 'sha256:samedigest0000000000000000000000000000000000000000000000000000\n'
    exit 0
fi
exit 0
CFAKE
chmod +x "$C_FAKE_DOCKER"

C_LOG="$C_TMPDIR/docker_calls.log"

C_OUT=$(
    OXPULSE_PREFIX_ETC="$C_TMPDIR/etc" \
    OXPULSE_PREFIX_LIB="$C_TMPDIR/var" \
    OXPULSE_PREFIX_SBIN="$C_TMPDIR/sbin" \
    OXPULSE_PREFIX_BIN="$C_TMPDIR/bin" \
    OXPULSE_PREFIX_LIBDIR="$C_TMPDIR/libdir" \
    OXPULSE_PREFIX_SHARE="$C_TMPDIR/share" \
    OXPULSE_SYSTEMD_DIR="$C_TMPDIR/systemd" \
    OXPULSE_HEALTHCHECK="$C_TMPDIR/sbin/oxpulse-partner-edge-healthcheck" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG="$C_CURRENT" \
    DOCKER_BIN="$C_FAKE_DOCKER" \
    DOCKER_CALL_LOG="$C_LOG" \
    COMPOSE_FILE_PATH="$C_TMPDIR/etc/docker-compose.yml" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="file://$C_REPO" \
    OXPULSE_RELEASES_BASE="file://$C_TMPDIR/no-such-releases-dir" \
    bash "$UPGRADE" --allow-unverified "$C_TARGET" 2>&1
) && C_RC=0 || C_RC=$?

[[ "$C_RC" -eq 0 ]] \
    && pass "C1: end-to-end plain upgrade succeeds" \
    || fail "C1: upgrade did not exit 0 (got $C_RC); output: $C_OUT"

C_INSTALLED_SHA=$(sha256sum "$C_TMPDIR/sbin/oxpulse-partner-edge-healthcheck" 2>/dev/null | awk '{print $1}')
C_NEW_SHA=$(sha256sum "$C_REPO/healthcheck.sh" | awk '{print $1}')
if [[ "$C_INSTALLED_SHA" == "$C_NEW_SHA" ]]; then
    pass "C2: the installed healthcheck now matches the NEW fixture (sync replaced the stale stub)"
else
    fail "C2: installed healthcheck does not match the NEW fixture — sync did not run/replace it"
fi

if echo "$C_OUT" | grep -qF 'lacks --snapshot support'; then
    fail "C3: settle_healthcheck fell back to the --local gate ('lacks --snapshot support') — the OLD healthcheck was still in use at settle time, the exact chicken-and-egg bug"
else
    pass "C3: settle_healthcheck did NOT fall back to the --local gate — the NEWLY-synced (snapshot-capable) healthcheck was used"
fi

if echo "$C_OUT" | grep -qF 'no regressions'; then
    pass "C4: the baseline-aware regression gate ran and reported no regressions (full happy path, using the synced healthcheck throughout)"
else
    fail "C4: expected 'no regressions' from the baseline-aware gate; output: $C_OUT"
fi

rm -rf "$C_TMPDIR"
trap - EXIT

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
