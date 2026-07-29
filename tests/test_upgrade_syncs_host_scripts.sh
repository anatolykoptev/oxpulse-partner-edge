#!/bin/bash
# tests/test_upgrade_syncs_host_scripts.sh
#
# Regression guard: upgrade.sh MUST sync host-scripts (sbin scripts + systemd
# units) for the target tag, not just docker image tags.
#
# Gap closed: v0.12.57 bundled BOTH the sfu-siege-transport image change (#255)
# AND the ch4 coturn probe change in oxpulse-channels-health-report.sh.  The
# old upgrade.sh deployed only the image; the health-report script on existing
# edges kept the pre-ch4 version until a full installer re-run.
#
# Test strategy: extract sync_host_scripts / snapshot_host_scripts /
# restore_host_scripts from upgrade.sh and run them directly against a local
# HTTP fixture server (same pattern as test_upgrade_with_templates.sh).
# We verify:
#   1. Structural: upgrade.sh contains the required functions + integration calls.
#   2. sync applies a changed health-report script and reports "installed".
#   3. sync is a no-op (idempotent) when sha256 already matches.
#   4. snapshot + restore round-trip restores sbin files unchanged.
#   5. SHA256SUMS guard: a file whose sha256 doesn't match is rejected.
#   6. dry-run: no files written, log lines emitted.
#   7. Plain apply path wires snapshot + sync before pull (structural ordering).
#   8. Rollback path calls restore_host_scripts (structural).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ---------------------------------------------------------------------------
# Test 1: Structural — required symbols present in upgrade.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 1: structural guards ==="

bash -n "$UPGRADE" && pass "1a: syntax clean" || { fail "1a: syntax errors"; exit 1; }

grep -qE '^sync_host_scripts\(\)' "$UPGRADE" \
    && pass "1b: sync_host_scripts() defined" \
    || fail "1b: sync_host_scripts() not defined"

grep -qE '^snapshot_host_scripts\(\)' "$UPGRADE" \
    && pass "1c: snapshot_host_scripts() defined" \
    || fail "1c: snapshot_host_scripts() not defined"

grep -qE '^restore_host_scripts\(\)' "$UPGRADE" \
    && pass "1d: restore_host_scripts() defined" \
    || fail "1d: restore_host_scripts() not defined"

# sync_host_scripts must be called with RELEASE_TAG (not TARGET) in the apply path.
# The tag-form fix (2026-05-26) changed all call sites from "$TARGET" to "$RELEASE_TAG"
# so that the GitHub release URL form (partner-edge-vX.Y.Z) is used, not the docker
# image tag form (vX.Y.Z).
grep -q 'sync_host_scripts "$RELEASE_TAG"' "$UPGRADE" \
    && pass "1e: sync_host_scripts called with RELEASE_TAG in apply path" \
    || fail "1e: sync_host_scripts not called with RELEASE_TAG (tag-form regression)"

# snapshot_host_scripts must be called before image pull in apply path.
grep -q 'snapshot_host_scripts "$CURRENT"' "$UPGRADE" \
    && pass "1f: snapshot_host_scripts called with CURRENT tag" \
    || fail "1f: snapshot_host_scripts not called with CURRENT"

# restore_host_scripts must be called in rollback paths.
restore_count=$(grep -c 'restore_host_scripts' "$UPGRADE" || true)
[[ "$restore_count" -ge 3 ]] \
    && pass "1g: restore_host_scripts called in ≥3 rollback paths (found $restore_count)" \
    || fail "1g: restore_host_scripts called in only $restore_count path(s), need ≥3"

# HOST_SCRIPT_SBIN_FILES must include oxpulse-channels-health-report.
grep -q 'oxpulse-channels-health-report' "$UPGRADE" \
    && pass "1h: oxpulse-channels-health-report in managed file list" \
    || fail "1h: oxpulse-channels-health-report missing from managed file list"

# RELEASES_BASE env var must be present (for tests to override).
grep -q 'RELEASES_BASE' "$UPGRADE" \
    && pass "1i: RELEASES_BASE variable present" \
    || fail "1i: RELEASES_BASE not present"

# SYSTEMCTL_BIN env var must be present (for tests to override).
grep -q 'SYSTEMCTL_BIN' "$UPGRADE" \
    && pass "1j: SYSTEMCTL_BIN variable present (testability)" \
    || fail "1j: SYSTEMCTL_BIN not present"

# ---------------------------------------------------------------------------
# Fixture server: serve repo root so sync_host_scripts can curl files via
# REPO_RAW pointing at http://127.0.0.1:PORT (same pattern as
# test_upgrade_with_templates.sh).
# ---------------------------------------------------------------------------
SERVE_PORT=18761
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-hostscript-httpd.log 2>&1 &
HTTP_PID=$!

TMPDIR_ROOT=$(mktemp -d)
cleanup() {
    kill "$HTTP_PID" 2>/dev/null || true
    rm -rf "$TMPDIR_ROOT"
}
trap cleanup EXIT

sleep 1
curl -fsSL --max-time 5 \
    "http://127.0.0.1:$SERVE_PORT/oxpulse-channels-health-report.sh" >/dev/null \
    || { echo "FAIL: fixture HTTP server not serving oxpulse-channels-health-report.sh"; exit 1; }

# ---------------------------------------------------------------------------
# Helper: build a self-contained preamble that defines all functions extracted
# from upgrade.sh.  Written to a file so it can be sourced inside subshells.
# ---------------------------------------------------------------------------
PREAMBLE="$TMPDIR_ROOT/fn_preamble.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
# Default PREFIX_BIN for preamble invocations (overridable via env).
PREFIX_BIN="${PREFIX_BIN:-${OXPULSE_PREFIX_BIN:-/usr/local/bin}}"
HELPERS

    # _HOST_SCRIPT_SBIN_FILES array
    awk '/^_HOST_SCRIPT_SBIN_FILES=\(/{found=1} found{print} found && /^\)$/{exit}' "$UPGRADE"

    # helper functions
    awk '/^_host_script_remote_name\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_install_dir\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_mode\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"

    # _HOST_SCRIPT_RESTART_UNITS array
    awk '/^_HOST_SCRIPT_RESTART_UNITS=\(/{found=1} found{print} found && /^\)$/{exit}' "$UPGRADE"

    # main exported functions — snapshot_host_scripts/restore_host_scripts/
    # sync_host_scripts are now thin lazy-source forwarders in upgrade.sh
    # (Phase 4 strangler-harden, task p4); the awk-extracted stubs above just
    # resolve+source lib/host-scripts-lib.sh, which this preamble-extraction
    # harness cannot do (BASH_SOURCE[0] inside a sourced-preamble function
    # points at $PREAMBLE, not the real upgrade.sh, so the forwarders'
    # co-located resolve can't find the lib). Append the REAL lib content —
    # its same-named function definitions land LAST in this file and
    # overwrite the forwarder stubs in the shell's function table (bash:
    # later definition wins), so sync_host_scripts/etc below run the actual
    # implementation directly, no lib-resolution needed in this harness.
    awk '/^snapshot_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^restore_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^sync_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    cat "$REPO_ROOT/lib/host-scripts-lib.sh"
} > "$PREAMBLE"

bash -n "$PREAMBLE" || { echo "FAIL: extracted preamble has syntax errors"; exit 1; }

# ---------------------------------------------------------------------------
# Test 2: sync installs a changed health-report script
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 2: sync installs a changed health-report script ==="

T2_SBIN="$TMPDIR_ROOT/t2/sbin"
T2_BIN="$TMPDIR_ROOT/t2/bin"
T2_LIBDIR="$TMPDIR_ROOT/t2/libdir"
T2_SYSTEMD="$TMPDIR_ROOT/t2/systemd"
mkdir -p "$T2_SBIN" "$T2_BIN" "$T2_LIBDIR" "$T2_SYSTEMD"

# Plant a stale sentinel (pre-ch4 version).
printf '#!/bin/bash\n# OLD VERSION - pre-ch4 coturn probe\n' \
    > "$T2_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T2_SBIN/oxpulse-channels-health-report"

OUT2=$(
    PREFIX_SBIN="$T2_SBIN" \
    PREFIX_BIN="$T2_BIN" \
    PREFIX_LIBDIR="$T2_LIBDIR" \
    SYSTEMD_DIR="$T2_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$SERVE_PORT/NOSUCHRELEASE" \
    ALLOW_UNVERIFIED=1 \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.99.0-test" 2>&1
) && RC2=0 || RC2=$?

if [[ $RC2 -eq 0 ]]; then
    pass "2a: sync_host_scripts exited 0"
else
    fail "2a: sync_host_scripts exited $RC2; output: $OUT2"
fi

if ! grep -q 'OLD VERSION' "$T2_SBIN/oxpulse-channels-health-report" 2>/dev/null; then
    pass "2b: health-report updated (stale sentinel replaced)"
else
    fail "2b: stale health-report still installed"
fi

echo "$OUT2" | grep 'installed oxpulse-channels-health-report' >/dev/null \
    && pass "2c: log confirms installation" \
    || fail "2c: expected 'installed' log line not found; output: $OUT2"

# ---------------------------------------------------------------------------
# Test 3: sync is a no-op when sha256 already matches (idempotency)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 3: idempotency — no-op when sha256 matches ==="

# After Test 2 the health-report in T2_SBIN is current (fetched from REPO_RAW).
BEFORE_SHA=$(sha256sum "$T2_SBIN/oxpulse-channels-health-report" | awk '{print $1}')

OUT3=$(
    PREFIX_SBIN="$T2_SBIN" \
    PREFIX_BIN="$T2_BIN" \
    PREFIX_LIBDIR="$T2_LIBDIR" \
    SYSTEMD_DIR="$T2_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$SERVE_PORT/NOSUCHRELEASE" \
    ALLOW_UNVERIFIED=1 \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.99.0-test" 2>&1
) && RC3=0 || RC3=$?

[[ $RC3 -eq 0 ]] && pass "3a: second sync exited 0" || fail "3a: second sync failed ($RC3)"

AFTER_SHA=$(sha256sum "$T2_SBIN/oxpulse-channels-health-report" | awk '{print $1}')
[[ "$BEFORE_SHA" == "$AFTER_SHA" ]] \
    && pass "3b: health-report sha256 unchanged (idempotent)" \
    || fail "3b: sha256 changed on second run: before=$BEFORE_SHA after=$AFTER_SHA"

echo "$OUT3" | grep 'up-to-date' >/dev/null \
    && pass "3c: second run logs 'up-to-date'" \
    || fail "3c: expected 'up-to-date' log; output: $OUT3"

# ---------------------------------------------------------------------------
# Test 4: snapshot + restore round-trip
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 4: snapshot + restore round-trip ==="

T4_SBIN="$TMPDIR_ROOT/t4/sbin"
T4_LIBDIR="$TMPDIR_ROOT/t4/libdir"
T4_SYSTEMD="$TMPDIR_ROOT/t4/systemd"
T4_SNAP="$TMPDIR_ROOT/t4/snap"
mkdir -p "$T4_SBIN" "$T4_LIBDIR" "$T4_SYSTEMD"

# Plant sentinel scripts.
printf '#!/bin/bash\n# SENTINEL health-report\n' > "$T4_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T4_SBIN/oxpulse-channels-health-report"
printf '#!/bin/bash\n# SENTINEL upgrade\n' > "$T4_SBIN/oxpulse-partner-edge-upgrade"
chmod 0755 "$T4_SBIN/oxpulse-partner-edge-upgrade"

SENTINEL_SHA=$(sha256sum "$T4_SBIN/oxpulse-channels-health-report" | awk '{print $1}')

# Snapshot.
PREFIX_SBIN="$T4_SBIN" \
PREFIX_LIBDIR="$T4_LIBDIR" \
SYSTEMD_DIR="$T4_SYSTEMD" \
PREV_HOST_SCRIPTS_DIR="$T4_SNAP" \
SYSTEMCTL_BIN=true \
bash -c "source '$PREAMBLE'; snapshot_host_scripts v0.old" 2>/dev/null \
    && pass "4a: snapshot_host_scripts exited 0" \
    || fail "4a: snapshot_host_scripts failed"

[[ -d "$T4_SNAP/sbin" ]] \
    && pass "4b: snapshot sbin dir created" \
    || fail "4b: snapshot sbin dir missing"

[[ -f "$T4_SNAP/sbin/oxpulse-channels-health-report" ]] \
    && pass "4c: health-report captured in snapshot" \
    || fail "4c: health-report not in snapshot"

# Overwrite with "new" content to simulate a failed upgrade.
printf '#!/bin/bash\n# NEW VERSION (failed upgrade)\n' \
    > "$T4_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T4_SBIN/oxpulse-channels-health-report"

# Restore.
PREFIX_SBIN="$T4_SBIN" \
PREFIX_LIBDIR="$T4_LIBDIR" \
SYSTEMD_DIR="$T4_SYSTEMD" \
PREV_HOST_SCRIPTS_DIR="$T4_SNAP" \
SYSTEMCTL_BIN=true \
bash -c "source '$PREAMBLE'; restore_host_scripts" 2>/dev/null \
    && pass "4d: restore_host_scripts exited 0" \
    || fail "4d: restore_host_scripts failed"

RESTORED_SHA=$(sha256sum "$T4_SBIN/oxpulse-channels-health-report" | awk '{print $1}')
[[ "$RESTORED_SHA" == "$SENTINEL_SHA" ]] \
    && pass "4e: restored health-report matches original sentinel sha256" \
    || fail "4e: sha mismatch: original=$SENTINEL_SHA restored=$RESTORED_SHA"

# ---------------------------------------------------------------------------
# Test 5: SHA256SUMS guard rejects a tampered file
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 5: SHA256SUMS guard rejects tampered file ==="

T5_SBIN="$TMPDIR_ROOT/t5/sbin"
T5_BIN="$TMPDIR_ROOT/t5/bin"
T5_LIBDIR="$TMPDIR_ROOT/t5/libdir"
T5_SYSTEMD="$TMPDIR_ROOT/t5/systemd"
T5_RELEASE="$TMPDIR_ROOT/t5/release/v0.test"
mkdir -p "$T5_SBIN" "$T5_BIN" "$T5_LIBDIR" "$T5_SYSTEMD" "$T5_RELEASE"

# Build a SHA256SUMS with a bogus hash for health-report.
FAKE_HASH="0000000000000000000000000000000000000000000000000000000000000000"
printf '%s  oxpulse-channels-health-report.sh\n' "$FAKE_HASH" > "$T5_RELEASE/SHA256SUMS"
printf '%s  partner-edge-upgrade.sh\n'            "$FAKE_HASH" >> "$T5_RELEASE/SHA256SUMS"

# Serve SHA256SUMS from a dedicated fixture server.
SHA_PORT=18762
python3 -m http.server "$SHA_PORT" --directory "$TMPDIR_ROOT/t5/release" \
    >/tmp/test-sha256-httpd.log 2>&1 &
SHA_HTTP_PID=$!
sleep 1

# Plant a sentinel that must survive (guard should reject the fetched file).
printf '#!/bin/bash\n# SENTINEL before sync\n' > "$T5_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T5_SBIN/oxpulse-channels-health-report"

OUT5=$(
    PREFIX_SBIN="$T5_SBIN" \
    PREFIX_BIN="$T5_BIN" \
    PREFIX_LIBDIR="$T5_LIBDIR" \
    SYSTEMD_DIR="$T5_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$SHA_PORT" \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.test" 2>&1
) || true

kill "$SHA_HTTP_PID" 2>/dev/null || true

# The sentinel must still be in place.
if grep -q 'SENTINEL before sync' "$T5_SBIN/oxpulse-channels-health-report" 2>/dev/null; then
    pass "5a: SHA mismatch → health-report not overwritten"
else
    fail "5a: health-report overwritten despite SHA mismatch"
fi

echo "$OUT5" | grep 'MISMATCH' >/dev/null \
    && pass "5b: MISMATCH warning logged" \
    || fail "5b: no MISMATCH warning; output: $OUT5"

# ---------------------------------------------------------------------------
# Test 6: dry-run — no file writes, descriptive log lines emitted
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 6: dry-run ==="

T6_SBIN="$TMPDIR_ROOT/t6/sbin"
T6_BIN="$TMPDIR_ROOT/t6/bin"
mkdir -p "$T6_SBIN" "$T6_BIN"

OUT6=$(
    PREFIX_SBIN="$T6_SBIN" \
    PREFIX_BIN="$T6_BIN" \
    PREFIX_LIBDIR="$TMPDIR_ROOT/t6/libdir" \
    SYSTEMD_DIR="$TMPDIR_ROOT/t6/systemd" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$SERVE_PORT/NOSUCHRELEASE" \
    DRY_RUN=1 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.99.0-test" 2>&1
) && RC6=0 || RC6=$?

[[ $RC6 -eq 0 ]] && pass "6a: dry-run exited 0" || fail "6a: dry-run failed ($RC6)"

sbin_count=$(find "$T6_SBIN" -maxdepth 1 -type f 2>/dev/null | wc -l)
[[ "$sbin_count" -eq 0 ]] \
    && pass "6b: no files written to sbin in dry-run" \
    || fail "6b: dry-run wrote $sbin_count file(s)"

echo "$OUT6" | grep 'dry-run' >/dev/null \
    && pass "6c: [dry-run] log line emitted" \
    || fail "6c: no [dry-run] log; output: $OUT6"

# ---------------------------------------------------------------------------
# Test 7: plain apply path wires snapshot + sync before pull (structural)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 7: plain apply path ordering (structural) ==="

# The apply section starts after resolve_default_target (after the
# --with-templates/rollback/check branches exit).
apply_section=$(awk '/^resolve_default_target$/{found=1} found{print}' "$UPGRADE")

echo "$apply_section" | grep 'snapshot_host_scripts' >/dev/null \
    && pass "7a: snapshot_host_scripts in apply section" \
    || fail "7a: snapshot_host_scripts missing from apply section"

echo "$apply_section" | grep 'sync_host_scripts' >/dev/null \
    && pass "7b: sync_host_scripts in apply section" \
    || fail "7b: sync_host_scripts missing from apply section"

# Ordering: snapshot must appear before sync.
snap_line=$(echo "$apply_section" | grep -n 'snapshot_host_scripts' | head -1 | cut -d: -f1)
sync_line=$(echo "$apply_section" | grep -n 'sync_host_scripts' | head -1 | cut -d: -f1)
if [[ -n "$snap_line" && -n "$sync_line" && "$snap_line" -lt "$sync_line" ]]; then
    pass "7c: snapshot (line $snap_line) before sync (line $sync_line)"
else
    fail "7c: ordering wrong — snap=${snap_line:-missing} sync=${sync_line:-missing}"
fi

# restore_host_scripts appears in ≥2 rollback arms within the apply section.
apply_restore=$(echo "$apply_section" | grep -c 'restore_host_scripts' || true)
[[ "$apply_restore" -ge 2 ]] \
    && pass "7d: restore_host_scripts in ≥2 rollback arms of apply path" \
    || fail "7d: only $apply_restore restore call(s) in apply path, need ≥2"

# ---------------------------------------------------------------------------
# Test 8: --rollback branch calls restore_host_scripts (structural)
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 8: rollback branch (structural) ==="

# Extract the rollback block.
rollback_section=$(awk '
    /^if \[\[ "\$MODE" == rollback \]\]; then/{found=1}
    found{print}
    found && /^fi$/{exit}
' "$UPGRADE")

echo "$rollback_section" | grep 'restore_host_scripts' >/dev/null \
    && pass "8a: restore_host_scripts in --rollback branch" \
    || fail "8a: restore_host_scripts missing from --rollback branch"

echo "$rollback_section" | grep 'PREV_HOST_SCRIPTS_DIR' >/dev/null \
    && pass "8b: PREV_HOST_SCRIPTS_DIR referenced in rollback guard" \
    || fail "8b: PREV_HOST_SCRIPTS_DIR not in rollback guard"

# ---------------------------------------------------------------------------
# Test 9: SHA256SUMS coverage completeness — every _HOST_SCRIPT_SBIN_FILES
# entry must have a corresponding entry in release.yml sha256sum staging.
# Guards against "add file to sync but forget to add to SHA256SUMS" — the
# exact gap that allowed oxpulse-channels-health-report.sh to slip through.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 9: SHA256SUMS staging coverage completeness (release.yml) ==="

RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"
[[ -f "$RELEASE_YML" ]] || { fail "9: release.yml not found"; }

if [[ -f "$RELEASE_YML" ]]; then
    # Extract the full sha256sum argument list from release.yml.
    sha256_staged=$(grep -A200 'sha256sum \\' "$RELEASE_YML" | grep -v 'sha256sum \\' \
        | awk '/> SHA256SUMS/{exit} {print}' | tr -d ' \\' | grep -v '^$')

    # Every sbin file must appear in sha256sum staging under its SHA256SUMS asset name.
    # Mapping mirrors sha256_asset_name logic in upgrade.sh (including the two new
    # scripts added for MAJOR-2: oxpulse-xray-update.sh and oxpulse-geoip-refresh.sh).
    declare -A sbin_to_asset=(
        [oxpulse-partner-edge-upgrade]="partner-edge-upgrade.sh"
        [oxpulse-partner-edge-hydrate]="hydrate.sh"
        [oxpulse-partner-edge-refresh]="oxpulse-partner-edge-refresh.sh"
        [oxpulse-partner-edge-sni-rotate]="oxpulse-partner-edge-sni-rotate.sh"
        [oxpulse-channels-health-report]="oxpulse-channels-health-report.sh"
        [oxpulse-geoip-refresh]="oxpulse-geoip-refresh.sh"
        [oxpulse-xray-update.sh]="oxpulse-xray-update.sh"
        [channel-render-lib.sh]="channel-render-lib.sh"
        [ghcr-auth-lib.sh]="ghcr-auth-lib.sh"
        [render-channel-lib.sh]="render-channel-lib.sh"
        [oxpulse-token-lib.sh]="oxpulse-token-lib.sh"
        [telegram-alert-lib.sh]="telegram-alert-lib.sh"
        [channel-health-lib.sh]="channel-health-lib.sh"
        [metric-sink-lib.sh]="metric-sink-lib.sh"
        [surgical-restart-lib.sh]="surgical-restart-lib.sh"
        [xprb-refresh-lib.sh]="xprb-refresh-lib.sh"
    )

    for sbin_name in "${!sbin_to_asset[@]}"; do
        asset="${sbin_to_asset[$sbin_name]}"
        if echo "$sha256_staged" | grep -F "$asset" >/dev/null; then
            pass "9-sbin: $sbin_name → $asset in SHA256SUMS staging"
        else
            fail "9-sbin: $sbin_name → $asset MISSING from SHA256SUMS staging in release.yml"
        fi
    done

    # Every synced systemd unit must appear in sha256sum staging.
    synced_units=(
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
    )
    for unit in "${synced_units[@]}"; do
        if echo "$sha256_staged" | grep -F "$unit" >/dev/null; then
            pass "9-unit: $unit in SHA256SUMS staging"
        else
            fail "9-unit: $unit MISSING from SHA256SUMS staging in release.yml"
        fi
    done
fi

# ---------------------------------------------------------------------------
# Test 10: functional rollback via DOCKER_BIN — compose up failure triggers
# restore_host_scripts through the actual upgrade.sh apply failure arm.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 10: compose up failure → restore_host_scripts (functional via DOCKER_BIN) ==="

T10_SBIN="$TMPDIR_ROOT/t10/sbin"
T10_BIN="$TMPDIR_ROOT/t10/bin"
T10_LIBDIR="$TMPDIR_ROOT/t10/libdir"
T10_SYSTEMD="$TMPDIR_ROOT/t10/systemd"
T10_SNAP="$TMPDIR_ROOT/t10/snap"
T10_ETC="$TMPDIR_ROOT/t10/etc"
T10_LIB="$TMPDIR_ROOT/t10/var"
T10_SHARE="$TMPDIR_ROOT/t10/share"
mkdir -p "$T10_SBIN" "$T10_BIN" "$T10_LIBDIR" "$T10_SYSTEMD" "$T10_SNAP" "$T10_ETC" "$T10_LIB" "$T10_SHARE"

# Plant sentinel (pre-upgrade state).
PRE_SHA_SENTINEL="# SENTINEL pre-upgrade-health-report"
printf '#!/bin/bash\n%s\n' "$PRE_SHA_SENTINEL" > "$T10_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T10_SBIN/oxpulse-channels-health-report"
PRE_UPGRADE_SHA=$(sha256sum "$T10_SBIN/oxpulse-channels-health-report" | awk '{print $1}')

# Build minimal install.env (upgrade.sh sources this for CURRENT and mirror state).
printf 'IMAGE_VERSION=v0.10.0-pre\n' > "$T10_LIB/install.env"

# Fake docker binary: succeeds on pull/inspect/config, fails on compose up.
# compose config --services: returns a real service name so capture_running_digests
# and resolve_pulled_digests populate maps and recreate_changed_services is invoked.
# docker inspect: returns an old digest (simulates running container).
# After pull, resolve_pulled_digests calls compose config + docker inspect again —
# return a NEW digest so the service is considered changed and recreate is attempted.
FAKE_DOCKER="$TMPDIR_ROOT/t10/docker"
cat > "$FAKE_DOCKER" << 'DOCKER_FAKE'
#!/bin/bash
# Simulate docker compose up failure (non-zero exit).
if [[ "$*" == *" up "* || "$*" == *" up" ]]; then
    echo "Error: simulated compose up failure" >&2
    exit 1
fi
# compose config --services: return our service list.
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\n'
    exit 0
fi
# compose config (full, no --services): partner-edge service scoping
# (list_partner_edge_services / _compose_service_image) now needs this to
# resolve each service's image and decide ownership — capture_running_digests
# didn't need it before that fix; it does now. Return the same compose
# content the test wrote to $T10_ETC/docker-compose.yml.
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    cat "${T10_COMPOSE_FILE:-/dev/null}"
    exit 0
fi
# compose ps --quiet sfu: return a fake container ID (simulates running container).
if [[ "$*" == *"ps --quiet"* ]]; then
    printf 'fakectr1234567890\n'
    exit 0
fi
# reconcile.sh's NAIVE_SOCKS_PORT Tier-3 fallback (unrelated to this test) also
# calls `docker inspect oxpulse-partner-naive --format {{range ...}}` early
# in the run. It must NOT consume the digest state-file toggle below — that
# would desync the pre/post-pull digest pairing this test depends on. Handle
# it first, as a no-op naive-container-not-found response, untouched by the
# toggle.
if [[ "$*" == *"oxpulse-partner-naive"* ]]; then
    exit 1
fi
# docker inspect (sfu digest resolution): return different digests
# pre/post-pull so recreate is triggered. We use a state file to toggle
# between old and new digest.
if [[ "$*" == *"inspect"* ]]; then
    STATE_FILE="${DOCKER_STATE_FILE:-/tmp/docker_state_t10}"
    if [[ -f "$STATE_FILE" ]]; then
        printf 'sha256:newdigest9999999999999999999999999999999999999999999999999999999\n'
    else
        printf 'sha256:olddigest1111111111111111111111111111111111111111111111111111111\n'
        touch "$STATE_FILE"
    fi
    exit 0
fi
# compose pull: succeed and "advance" state so next inspect returns new digest.
# (State file already created on first inspect call above.)
exit 0
DOCKER_FAKE
chmod +x "$FAKE_DOCKER"

# Fake minimal compose file so upgrade.sh can read it.
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.10.0-pre\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$T10_ETC/docker-compose.yml"

# Fake lib stubs so upgrade.sh sources successfully.
T10_CHANNEL_RENDER_LIB="$T10_SBIN/channel-render-lib.sh"
printf '# stub\nre_render_xray() { return 0; }\n' > "$T10_CHANNEL_RENDER_LIB"
T10_GHCR_LIB="$T10_SBIN/ghcr-auth-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
    > "$T10_GHCR_LIB"
T10_HEALTHCHECK="$T10_SBIN/healthcheck"
printf '#!/bin/bash\nexit 0\n' > "$T10_HEALTHCHECK"
chmod 0755 "$T10_HEALTHCHECK"

# State file for the fake docker digest toggle.
T10_DOCKER_STATE="$TMPDIR_ROOT/t10/docker_state"

# Drive the actual compose-up-failure arm of upgrade.sh.
# This exercises: snapshot → sync → pull (succeeds) → up (fails) → restore_host_scripts.
# --allow-unverified skips the SHA256SUMS guard so the test focuses on the
# compose-up-failure rollback path, not supply-chain verification.
OUT10=$(
    OXPULSE_PREFIX_ETC="$T10_ETC" \
    OXPULSE_PREFIX_LIB="$T10_LIB" \
    OXPULSE_PREFIX_SBIN="$T10_SBIN" \
    OXPULSE_PREFIX_BIN="$T10_BIN" \
    OXPULSE_PREFIX_LIBDIR="$T10_LIBDIR" \
    OXPULSE_PREFIX_SHARE="$T10_SHARE" \
    OXPULSE_SYSTEMD_DIR="$T10_SYSTEMD" \
    OXPULSE_HEALTHCHECK="$T10_HEALTHCHECK" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    T10_COMPOSE_FILE="$T10_ETC/docker-compose.yml" \
    DOCKER_BIN="$FAKE_DOCKER" \
    DOCKER_STATE_FILE="$T10_DOCKER_STATE" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$SERVE_PORT/NOSUCHRELEASE" \
    OXPULSE_UPGRADE_TAG=v0.10.0-pre \
    bash "$UPGRADE" --allow-unverified v0.99.0-test 2>&1
) && RC10=0 || RC10=$?

# upgrade.sh must exit non-zero (compose up failed → rolled back → die).
if [[ $RC10 -ne 0 ]]; then
    pass "10a: upgrade.sh exited non-zero on compose up failure ($RC10)"
else
    fail "10a: upgrade.sh unexpectedly succeeded despite compose up failure"
fi

# restore_host_scripts must have been called: sentinel restored.
RESTORED_SHA10=$(sha256sum "$T10_SBIN/oxpulse-channels-health-report" 2>/dev/null | awk '{print $1}' || true)
if [[ "$RESTORED_SHA10" == "$PRE_UPGRADE_SHA" ]]; then
    pass "10b: health-report restored to pre-upgrade sentinel sha256"
else
    fail "10b: restored sha=$RESTORED_SHA10 pre-upgrade sha=$PRE_UPGRADE_SHA — restore_host_scripts not called or incomplete; output: $OUT10"
fi

grep -q "$PRE_SHA_SENTINEL" "$T10_SBIN/oxpulse-channels-health-report" 2>/dev/null \
    && pass "10c: sentinel string present after compose failure restore" \
    || fail "10c: sentinel string missing; output: $OUT10"

# ---------------------------------------------------------------------------
# Test 11: SHA256SUMS guard happy path — correct hash → file INSTALLS
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 11: SHA256SUMS guard happy path — match → installs ==="

T11_SBIN="$TMPDIR_ROOT/t11/sbin"
T11_BIN="$TMPDIR_ROOT/t11/bin"
T11_LIBDIR="$TMPDIR_ROOT/t11/libdir"
T11_SYSTEMD="$TMPDIR_ROOT/t11/systemd"
T11_RELEASE="$TMPDIR_ROOT/t11/release/v0.happy"
mkdir -p "$T11_SBIN" "$T11_BIN" "$T11_LIBDIR" "$T11_SYSTEMD" "$T11_RELEASE"

# Fetch the real health-report from the fixture server (same bytes sync would fetch).
T11_ACTUAL_FILE="$T11_RELEASE/oxpulse-channels-health-report.sh"
curl -fsSL --max-time 10 \
    "http://127.0.0.1:$SERVE_PORT/oxpulse-channels-health-report.sh" \
    -o "$T11_ACTUAL_FILE" \
    || { fail "11: could not fetch health-report from fixture server"; }

# Compute the correct sha256 of those actual bytes.
T11_CORRECT_HASH=$(sha256sum "$T11_ACTUAL_FILE" | awk '{print $1}')

# Build SHA256SUMS with the CORRECT hash so the guard should PASS.
{
    printf '%s  oxpulse-channels-health-report.sh\n' "$T11_CORRECT_HASH"
    printf '%s  partner-edge-upgrade.sh\n'            "0000000000000000000000000000000000000000000000000000000000000000"
} > "$T11_RELEASE/SHA256SUMS"

# Serve from a dedicated fixture server.
# Serve the PARENT dir so $RELEASES_BASE/v0.happy/SHA256SUMS resolves (200),
# exercising the real guard-accept path — not the 404 fallthrough that skips it.
T11_SHA_PORT=18763
python3 -m http.server "$T11_SHA_PORT" --directory "$TMPDIR_ROOT/t11/release" \
    >/tmp/test-sha256-happy-httpd.log 2>&1 &
T11_SHA_HTTP_PID=$!
sleep 1

# Plant a stale sentinel — must be REPLACED when guard passes.
printf '#!/bin/bash\n# STALE sentinel for test 11\n' > "$T11_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T11_SBIN/oxpulse-channels-health-report"

OUT11=$(
    PREFIX_SBIN="$T11_SBIN" \
    OXPULSE_PREFIX_BIN="$T11_BIN" \
    PREFIX_LIBDIR="$T11_LIBDIR" \
    SYSTEMD_DIR="$T11_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$T11_SHA_PORT" \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts v0.happy" 2>&1
) && RC11=0 || RC11=$?

kill "$T11_SHA_HTTP_PID" 2>/dev/null || true

# The stale sentinel MUST be replaced (guard passed → file installed).
if ! grep -q 'STALE sentinel' "$T11_SBIN/oxpulse-channels-health-report" 2>/dev/null; then
    pass "11a: SHA match → health-report installed (stale sentinel replaced)"
else
    fail "11a: health-report NOT replaced despite correct SHA; output: $OUT11"
fi

# Verify log says 'installed' not 'skipping'.
echo "$OUT11" | grep 'installed oxpulse-channels-health-report' >/dev/null \
    && pass "11b: log confirms 'installed' on SHA match" \
    || fail "11b: expected 'installed' log; output: $OUT11"

# Verify the installed file matches the expected bytes.
T11_INSTALLED_HASH=$(sha256sum "$T11_SBIN/oxpulse-channels-health-report" | awk '{print $1}')
[[ "$T11_INSTALLED_HASH" == "$T11_CORRECT_HASH" ]] \
    && pass "11c: installed sha256 matches expected ($T11_CORRECT_HASH)" \
    || fail "11c: sha mismatch: installed=$T11_INSTALLED_HASH expected=$T11_CORRECT_HASH"

[[ $RC11 -eq 0 ]] && pass "11d: sync_host_scripts exited 0" || fail "11d: sync exited $RC11; output: $OUT11"

# ---------------------------------------------------------------------------
# Test 12: mirror awareness — OXPULSE_MIRROR_BASE in install.env → REPO_RAW
# and RELEASES_BASE resolve through mirror, not GitHub.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 12: mirror awareness — install.env OXPULSE_MIRROR_BASE honoured ==="

T12_STATE="$TMPDIR_ROOT/t12/install.env"
mkdir -p "$(dirname "$T12_STATE")"
# Write a mirror URL pointing at our fixture server.
MIRROR_URL="http://127.0.0.1:$SERVE_PORT"
printf 'IMAGE_VERSION=v0.12.0\nOXPULSE_MIRROR_BASE=%s\n' "$MIRROR_URL" > "$T12_STATE"

# Verify the preamble's _host_script_remote_name mirrors the upgrade.sh logic
# (structural only — we verified functional mirror routing by setting OXPULSE_REPO_RAW
# in tests 2/3 to the fixture server, which exercises the same curl code path).
grep -q 'OXPULSE_MIRROR_BASE' "$UPGRADE" \
    && pass "12a: OXPULSE_MIRROR_BASE referenced in upgrade.sh" \
    || fail "12a: OXPULSE_MIRROR_BASE missing from upgrade.sh"

# Verify install.sh writes OXPULSE_MIRROR_BASE to install.env when set.
grep -q 'OXPULSE_MIRROR_BASE' "$(dirname "$UPGRADE")/install.sh" \
    && pass "12b: install.sh references OXPULSE_MIRROR_BASE" \
    || fail "12b: install.sh does not reference OXPULSE_MIRROR_BASE"

# Confirm the install.env write path is present in install.sh (functional guard).
grep -q "printf 'OXPULSE_MIRROR_BASE=" "$(dirname "$UPGRADE")/install.sh" \
    && pass "12c: install.sh persists OXPULSE_MIRROR_BASE to install.env" \
    || fail "12c: install.sh missing OXPULSE_MIRROR_BASE persist block"

# Verify upgrade.sh reads OXPULSE_MIRROR_BASE from install.env via grep.
grep -q "grep '^OXPULSE_MIRROR_BASE='" "$UPGRADE" \
    && pass "12d: upgrade.sh reads OXPULSE_MIRROR_BASE from install.env" \
    || fail "12d: upgrade.sh missing install.env OXPULSE_MIRROR_BASE read"

# ---------------------------------------------------------------------------
# Test 13: single-tag form — no partner-edge- prefix constructed in fetch URLs.
# Guards the fix: releases ≥v0.12.60 use vX.Y.Z everywhere (git/release/image).
# Verifies that a canonical vX.Y.Z input reaches RELEASES_BASE/$tag/SHA256SUMS
# without any partner-edge- prefix being prepended.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 13: single-tag form — vX.Y.Z fetches without partner-edge- prefix ==="

T13_RELEASE_DIR="$TMPDIR_ROOT/t13/release"
T13_TAG="v0.12.60"
T13_RELEASE_ASSET_DIR="$T13_RELEASE_DIR/$T13_TAG"
mkdir -p "$T13_RELEASE_ASSET_DIR"
T13_SBIN="$TMPDIR_ROOT/t13/sbin"
T13_BIN="$TMPDIR_ROOT/t13/bin"
T13_LIBDIR="$TMPDIR_ROOT/t13/libdir"
T13_SYSTEMD="$TMPDIR_ROOT/t13/systemd"
mkdir -p "$T13_SBIN" "$T13_BIN" "$T13_LIBDIR" "$T13_SYSTEMD"

# Fetch real health-report bytes from fixture server (what sync would fetch).
T13_ACTUAL_FILE="$T13_RELEASE_ASSET_DIR/oxpulse-channels-health-report.sh"
curl -fsSL --max-time 10 \
    "http://127.0.0.1:$SERVE_PORT/oxpulse-channels-health-report.sh" \
    -o "$T13_ACTUAL_FILE" \
    || { fail "13: could not fetch health-report from fixture server"; }

# Compute correct sha256 and build SHA256SUMS at the BARE vX.Y.Z path.
# If upgrade.sh were adding partner-edge- prefix, it would fetch from
# $RELEASES_BASE/partner-edge-v0.12.60/SHA256SUMS (404) and die.
T13_HASH=$(sha256sum "$T13_ACTUAL_FILE" | awk '{print $1}')
printf '%s  oxpulse-channels-health-report.sh\n' "$T13_HASH" > "$T13_RELEASE_ASSET_DIR/SHA256SUMS"
printf '%s  partner-edge-upgrade.sh\n' "0000000000000000000000000000000000000000000000000000000000000000" \
    >> "$T13_RELEASE_ASSET_DIR/SHA256SUMS"

T13_PORT=18764
python3 -m http.server "$T13_PORT" --directory "$T13_RELEASE_DIR" \
    >/tmp/test-single-tag-httpd.log 2>&1 &
T13_HTTP_PID=$!
sleep 1

# Plant stale sentinel — must be replaced if SHA256SUMS is fetched from the
# bare vX.Y.Z path (no prefix).
printf '#!/bin/bash\n# STALE sentinel for test 13\n' > "$T13_SBIN/oxpulse-channels-health-report"
chmod 0755 "$T13_SBIN/oxpulse-channels-health-report"

OUT13=$(
    PREFIX_SBIN="$T13_SBIN" \
    OXPULSE_PREFIX_BIN="$T13_BIN" \
    PREFIX_LIBDIR="$T13_LIBDIR" \
    SYSTEMD_DIR="$T13_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
    RELEASES_BASE="http://127.0.0.1:$T13_PORT" \
    DRY_RUN=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE'; sync_host_scripts $T13_TAG" 2>&1
) && RC13=0 || RC13=$?

kill "$T13_HTTP_PID" 2>/dev/null || true

[[ $RC13 -eq 0 ]] \
    && pass "13a: sync_host_scripts exited 0 with bare vX.Y.Z tag ($T13_TAG)" \
    || fail "13a: sync_host_scripts failed (RC=$RC13) — possible partner-edge- prefix still added; output: $OUT13"

if ! grep -q 'STALE sentinel' "$T13_SBIN/oxpulse-channels-health-report" 2>/dev/null; then
    pass "13b: health-report installed (SHA256SUMS fetched from bare vX.Y.Z path)"
else
    fail "13b: health-report NOT installed — SHA256SUMS may have been fetched from wrong path; output: $OUT13"
fi

echo "$OUT13" | grep 'installed oxpulse-channels-health-report' >/dev/null \
    && pass "13c: log confirms 'installed' on SHA match (single-tag form)" \
    || fail "13c: expected 'installed' log; output: $OUT13"

# Structural: normalize_target must exist and map vX.Y.Z → RELEASE_TAG=TARGET.
grep -qE '^normalize_target\(\)' "$UPGRADE" \
    && pass "13d: normalize_target() defined in upgrade.sh" \
    || fail "13d: normalize_target() missing from upgrade.sh"

# No partner-edge-v construction in RELEASE_TAG assignment inside normalize_target.
normalize_fn=$(awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE")
if echo "$normalize_fn" | grep -E 'RELEASE_TAG.*partner-edge-' >/dev/null; then
    fail "13e: normalize_target still constructs RELEASE_TAG with partner-edge- prefix"
else
    pass "13e: normalize_target does NOT prepend partner-edge- to RELEASE_TAG"
fi

# ---------------------------------------------------------------------------
# Test 14: transition — old partner-edge-vX.Y.Z input is stripped gracefully.
# An edge using a pre-v0.12.60 installer that somehow passes partner-edge-v0.12.59
# as TARGET must not 404 on assets but instead normalize to v0.12.59.
# ---------------------------------------------------------------------------
echo ""
echo "=== Test 14: transition — old partner-edge-vX.Y.Z input normalized gracefully ==="

# Structural: normalize_target must handle partner-edge-v* input.
normalize_fn=$(awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE")

# Must strip partner-edge- prefix and set TARGET to bare vX.Y.Z.
echo "$normalize_fn" | grep -E 'partner-edge-v\*|partner-edge-\)' >/dev/null \
    && pass "14a: normalize_target() has partner-edge-v* case" \
    || fail "14a: normalize_target() missing partner-edge-v* transition case"

echo "$normalize_fn" | grep -E 'TARGET=.*#partner-edge-|TARGET=.*\{TARGET#' >/dev/null \
    && pass "14b: normalize_target() strips partner-edge- prefix from TARGET" \
    || fail "14b: normalize_target() missing prefix-strip assignment"

# Functional: drive normalize_target + derive_release_tag via a subshell.
RESULT14=$(bash -c "
log() { printf '==> %s\n' \"\$*\" >&2; }
warn() { printf '!! %s\n' \"\$*\" >&2; }
TARGET='partner-edge-v0.12.59'
$(awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE")
normalize_target
printf '%s %s\n' \"\$TARGET\" \"\$RELEASE_TAG\"
" 2>/dev/null)

RESULT14_TARGET=$(echo "$RESULT14" | awk '{print $1}')
RESULT14_RTAG=$(echo "$RESULT14" | awk '{print $2}')

[[ "$RESULT14_TARGET" == "v0.12.59" ]] \
    && pass "14c: old-form TARGET='partner-edge-v0.12.59' normalized to 'v0.12.59'" \
    || fail "14c: TARGET normalization wrong: got '$RESULT14_TARGET' expected 'v0.12.59'"

[[ "$RESULT14_RTAG" == "v0.12.59" ]] \
    && pass "14d: RELEASE_TAG='v0.12.59' (identity with normalized TARGET)" \
    || fail "14d: RELEASE_TAG wrong: got '$RESULT14_RTAG' expected 'v0.12.59'"

# And a canonical vX.Y.Z input must pass through unchanged.
RESULT14B=$(bash -c "
log() { printf '==> %s\n' \"\$*\" >&2; }
warn() { printf '!! %s\n' \"\$*\" >&2; }
TARGET='v0.12.60'
$(awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE")
normalize_target
printf '%s %s\n' \"\$TARGET\" \"\$RELEASE_TAG\"
" 2>/dev/null)

RESULT14B_TARGET=$(echo "$RESULT14B" | awk '{print $1}')
RESULT14B_RTAG=$(echo "$RESULT14B" | awk '{print $2}')

[[ "$RESULT14B_TARGET" == "v0.12.60" ]] \
    && pass "14e: canonical TARGET='v0.12.60' unchanged after normalize_target" \
    || fail "14e: canonical TARGET mangled: got '$RESULT14B_TARGET'"

[[ "$RESULT14B_RTAG" == "v0.12.60" ]] \
    && pass "14f: RELEASE_TAG='v0.12.60' = TARGET (single-tag identity)" \
    || fail "14f: RELEASE_TAG wrong for canonical input: got '$RESULT14B_RTAG'"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]
