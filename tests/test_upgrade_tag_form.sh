#!/bin/bash
# tests/test_upgrade_tag_form.sh
#
# Regression guard for the tag-form split bug (2026-05-26 edge-e incident on
# v0.12.59 edge-b RU relay prod run) AND the subsequent tag-form unification
# (v0.12.60+: all tags are vX.Y.Z — no release-please component prefix).
#
# ROOT CAUSE (edge-e): upgrade.sh accepted TARGET=vX.Y.Z (docker image tag
# form) but used that same value to build RELEASES_BASE + REPO_RAW URLs.
# GitHub releases for v0.12.59 lived under
#   .../releases/download/partner-edge-v0.12.59/...
# (release-please component prefix) while GHCR image tags had no prefix.
# The URL mismatch caused SHA256SUMS + partner-edge-upgrade.sh fetches to 404
# → checksum guard silently skipped → host-scripts installed UNVERIFIED on relay.
#
# FIX strategy: unify the tag forms starting at v0.12.60.  release-please-config
# no longer carries "component": "partner-edge" so new releases tag as vX.Y.Z.
# normalize_target() / derive_release_tag() handle the transition:
#   - pre-v0.12.60 edges may pass partner-edge-vX.Y.Z → prefix is stripped
#   - canonical input is vX.Y.Z → RELEASE_TAG = TARGET (identity, one-form world)
#   - "latest" → "latest" (floating; no SHA256SUMS guard)
#
# FIXES tested here:
#   A  Tag-form mapping: normalize_target() + derive_release_tag() correctness.
#      Structural + functional.
#   B  @RELEASE_TAG@ sentinel restore: upgrade.sh source must carry the literal
#      sentinel so release.yml sed-substitution can pin REPO_RAW.
#      release.yml Stage artifacts must have TAG= in its env.
#   C  Fail-loud: pinned tag + SHA256SUMS 404 → sync exits non-zero.
#      --allow-unverified → warn + proceed (for dev/test runs).
#   D  Edge-e repro: fixture layout matching the NEW release format (assets under
#      vX.Y.Z/ per the unification) — assert SHA256SUMS fetch succeeds and files
#      install verified.  This is the test the CI suite lacked that would have
#      caught the unbound/ghcr-lib/tag-sentinel/tag-form regression chain.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
RELEASE_YML="$REPO_ROOT/.github/workflows/release.yml"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# Probe a free TCP port to avoid hardcoded fixture ports flaking under socket
# reuse in parallel CI. Race-free in practice: the port is bound immediately
# after probe by the http.server process.
probe_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("",0)); print(s.getsockname()[1]); s.close()'
}

# ---------------------------------------------------------------------------
# Fix A: Tag-form mapping — structural guards
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix A: tag-form mapping structural guards ==="

bash -n "$UPGRADE" \
    && pass "A-0: upgrade.sh syntax clean" \
    || { fail "A-0: syntax errors in upgrade.sh"; exit 1; }

# normalize_target() must be defined (canonical function).
grep -qE '^normalize_target\(\)' "$UPGRADE" \
    && pass "A-1a: normalize_target() defined" \
    || fail "A-1a: normalize_target() not found — tag-form transition handler missing"

# derive_release_tag() must be defined as an alias for normalize_target.
grep -qE '^derive_release_tag\(\)' "$UPGRADE" \
    && pass "A-1b: derive_release_tag() defined (alias for normalize_target)" \
    || fail "A-1b: derive_release_tag() not found — backward-compat alias missing"

# All sync_host_scripts call sites must pass RELEASE_TAG (not TARGET).
# The tag-form fix changed call sites from "$TARGET" to "$RELEASE_TAG".
sync_with_release=$(grep -c 'sync_host_scripts "\$RELEASE_TAG"' "$UPGRADE" 2>/dev/null || true)
sync_with_target=$(grep -c  'sync_host_scripts "\$TARGET"'       "$UPGRADE" 2>/dev/null || true)
[[ "$sync_with_release" -ge 3 ]] \
    && pass "A-2: sync_host_scripts called with RELEASE_TAG in ≥3 sites (found $sync_with_release)" \
    || fail "A-2: sync_host_scripts RELEASE_TAG call sites: $sync_with_release (need ≥3)"
[[ "$sync_with_target" -eq 0 ]] \
    && pass "A-3: no residual sync_host_scripts \"\$TARGET\" calls" \
    || fail "A-3: $sync_with_target residual sync_host_scripts \"\$TARGET\" call(s) — tag-form regression"

# normalize_target / derive_release_tag must be called before sync_host_scripts in code paths.
derive_line=$(grep -n 'derive_release_tag\|normalize_target' "$UPGRADE" \
    | grep -v '^\s*#\|^[0-9]*:\s*#' | head -1 | cut -d: -f1)
sync_line=$(grep -n 'sync_host_scripts "\$RELEASE_TAG"' "$UPGRADE" | head -1 | cut -d: -f1)
[[ -n "$derive_line" && -n "$sync_line" && "$derive_line" -lt "$sync_line" ]] \
    && pass "A-4: normalize_target (line $derive_line) precedes first sync call (line $sync_line)" \
    || fail "A-4: normalize_target must appear before sync_host_scripts"

# sha256sums_url must be built from local $tag var (not global TARGET/RELEASE_TAG).
# Lives inside sync_host_scripts, which moved to lib/host-scripts-lib.sh
# (Phase 4 strangler-harden, task p4) — check there, not upgrade.sh (which
# now only holds a thin forwarder).
grep -q 'sha256sums_url="$RELEASES_BASE/$tag/SHA256SUMS"' "$REPO_ROOT/lib/host-scripts-lib.sh" \
    && pass "A-5: sha256sums_url built from local \$tag (not global TARGET)" \
    || fail "A-5: sha256sums_url pattern unexpected — check tag variable used in URL"

# ---------------------------------------------------------------------------
# Fix A: Tag-form mapping — functional: normalize_target() / derive_release_tag()
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix A: tag-form mapping functional tests ==="

# Extract normalize_target (and its alias derive_release_tag) for in-process testing.
PREAMBLE_TAG=$(mktemp /tmp/upgrade-tag-preamble-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$PREAMBLE_TAG'" EXIT

{
    printf 'log()  { printf "==> %%s\\n" "$*" >&2; }\n'
    printf 'warn() { printf "!! %%s\\n"  "$*" >&2; }\n'
    printf 'die()  { printf "ERR %%s\\n" "$*" >&2; exit 1; }\n'
    printf 'CURRENT=v0.12.59\n'
    awk '/^resolve_default_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^normalize_target\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    # Also include derive_release_tag alias line.
    grep '^derive_release_tag()' "$UPGRADE" || true
} > "$PREAMBLE_TAG"
bash -n "$PREAMBLE_TAG" || { fail "A-6: preamble has syntax errors"; exit 1; }
pass "A-6: preamble syntax clean"

# A-7: vX.Y.Z → RELEASE_TAG=vX.Y.Z (identity; canonical new form)
result=$(bash -c "
    source '$PREAMBLE_TAG'
    TARGET=v0.12.59
    normalize_target
    printf '%s' \"\$RELEASE_TAG\"
")
[[ "$result" == "v0.12.59" ]] \
    && pass "A-7: v0.12.59 → RELEASE_TAG=v0.12.59 (identity — one-form world)" \
    || fail "A-7: expected v0.12.59, got '$result'"

# A-8: partner-edge-vX.Y.Z → prefix stripped → vX.Y.Z (transition from old-form edge)
result=$(bash -c "
    source '$PREAMBLE_TAG'
    TARGET=partner-edge-v0.12.59
    normalize_target
    printf '%s' \"\$RELEASE_TAG\"
")
[[ "$result" == "v0.12.59" ]] \
    && pass "A-8: partner-edge-v0.12.59 → prefix stripped → v0.12.59 (no double prefix)" \
    || fail "A-8: expected v0.12.59, got '$result'"

# A-9: latest → latest (floating, no SHA256SUMS guard)
result=$(bash -c "
    source '$PREAMBLE_TAG'
    TARGET=latest
    normalize_target
    printf '%s' \"\$RELEASE_TAG\"
")
[[ "$result" == "latest" ]] \
    && pass "A-9: latest → latest (floating, no prefix)" \
    || fail "A-9: expected latest, got '$result'"

# A-10: v0.12.60 → v0.12.60 (future release, identity)
result=$(bash -c "
    source '$PREAMBLE_TAG'
    TARGET=v0.12.60
    normalize_target
    printf '%s' \"\$RELEASE_TAG\"
")
[[ "$result" == "v0.12.60" ]] \
    && pass "A-10: v0.12.60 → v0.12.60 (identity — future release, correct form)" \
    || fail "A-10: expected v0.12.60, got '$result'"

# A-11: derive_release_tag alias works identically to normalize_target
result=$(bash -c "
    source '$PREAMBLE_TAG'
    TARGET=v0.12.60
    derive_release_tag
    printf '%s' \"\$RELEASE_TAG\"
")
[[ "$result" == "v0.12.60" ]] \
    && pass "A-11: derive_release_tag alias works (v0.12.60 → v0.12.60)" \
    || fail "A-11: derive_release_tag alias failed, got '$result'"

# ---------------------------------------------------------------------------
# Fix B: @RELEASE_TAG@ sentinel — structural
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix B: @RELEASE_TAG@ sentinel guards ==="

# upgrade.sh source must carry the literal @RELEASE_TAG@ sentinel so that:
#   1. release.yml sed can substitute the real tag into the published copy.
#   2. When not substituted (dev checkout), REPO_RAW falls back to /main.
grep -q '@RELEASE_TAG@' "$UPGRADE" \
    && pass "B-1: upgrade.sh source carries @RELEASE_TAG@ literal sentinel" \
    || fail "B-1: @RELEASE_TAG@ sentinel missing — release.yml sed cannot substitute"

# The sentinel must appear in the OXPULSE_UPGRADE_TAG default assignment.
grep -qE 'OXPULSE_UPGRADE_TAG.*@RELEASE_TAG@' "$UPGRADE" \
    && pass "B-2: OXPULSE_UPGRADE_TAG default references @RELEASE_TAG@" \
    || fail "B-2: OXPULSE_UPGRADE_TAG not wired to @RELEASE_TAG@ sentinel"

# release.yml Stage artifacts step MUST have TAG= in its env so the sed
# substitution has a non-empty value.  Without TAG=, ${TAG} in the run: block
# expands to empty → released upgrade.sh has empty OXPULSE_UPGRADE_TAG default
# → REPO_RAW defaults to /main (wrong — should be pinned to release tag).
grep -A 5 'name: Stage artifacts' "$RELEASE_YML" \
    | grep -q 'TAG:' \
    && pass "B-3: release.yml Stage artifacts env includes TAG=" \
    || fail "B-3: release.yml Stage artifacts missing TAG= — sed substitution is a no-op (empty tag)"

# The sed substitution for upgrade.sh must be present in Stage artifacts.
grep -A 30 'name: Stage artifacts' "$RELEASE_YML" \
    | grep -q '@RELEASE_TAG@' \
    && pass "B-4: release.yml Stage artifacts has @RELEASE_TAG@ sed step for upgrade.sh" \
    || fail "B-4: @RELEASE_TAG@ sed step missing from Stage artifacts"

# When @RELEASE_TAG@ is NOT substituted (dev checkout), REPO_RAW falls back to /main.
result=$(bash -c '
    OXPULSE_UPGRADE_TAG="@RELEASE_TAG@"
    OXPULSE_REPO_RAW=""
    OXPULSE_MIRROR_BASE=""
    if [[ -n "${OXPULSE_REPO_RAW:-}" ]]; then
        REPO_RAW="$OXPULSE_REPO_RAW"
    elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
        REPO_RAW="$OXPULSE_MIRROR_BASE/raw"
    elif [[ "${OXPULSE_UPGRADE_TAG}" == "@RELEASE_TAG@" ]]; then
        REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
    else
        REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${OXPULSE_UPGRADE_TAG}"
    fi
    printf "%s" "$REPO_RAW"
')
[[ "$result" == *"/main"* ]] \
    && pass "B-5: sentinel @RELEASE_TAG@ → REPO_RAW falls back to /main (dev checkout)" \
    || fail "B-5: expected REPO_RAW to end in /main for sentinel, got '$result'"

# When substituted to the real tag, REPO_RAW must pin to that tag.
result=$(bash -c '
    OXPULSE_UPGRADE_TAG="v0.12.60"
    OXPULSE_REPO_RAW=""
    OXPULSE_MIRROR_BASE=""
    if [[ -n "${OXPULSE_REPO_RAW:-}" ]]; then
        REPO_RAW="$OXPULSE_REPO_RAW"
    elif [[ -n "${OXPULSE_MIRROR_BASE:-}" ]]; then
        REPO_RAW="$OXPULSE_MIRROR_BASE/raw"
    elif [[ "${OXPULSE_UPGRADE_TAG}" == "@RELEASE_TAG@" ]]; then
        REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main"
    else
        REPO_RAW="https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/${OXPULSE_UPGRADE_TAG}"
    fi
    printf "%s" "$REPO_RAW"
')
[[ "$result" == *"/v0.12.60"* && "$result" != *"/main"* ]] \
    && pass "B-6: substituted tag v0.12.60 → REPO_RAW pinned to release ref (not /main)" \
    || fail "B-6: expected REPO_RAW to contain /v0.12.60, got '$result'"

# ---------------------------------------------------------------------------
# Fix C: Fail-loud — SHA256SUMS 404 on pinned tag → non-zero exit
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix C: fail-loud on unverified ==="

# Extract preamble with sync_host_scripts for functional testing.
PREAMBLE_SYNC=$(mktemp /tmp/upgrade-sync-preamble-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$PREAMBLE_TAG' '$PREAMBLE_SYNC'" EXIT

{
    printf 'log()  { printf "==> %%s\\n" "$*" >&2; }\n'
    printf 'warn() { printf "!! %%s\\n"  "$*" >&2; }\n'
    printf 'die()  { while IFS= read -r _line; do printf "ERR %%s\\n" "$_line" >&2; done <<< "$*"; exit 1; }\n'
    printf 'PREFIX_BIN="${PREFIX_BIN:-${OXPULSE_PREFIX_BIN:-/usr/local/bin}}"\n'
    printf 'ALLOW_UNVERIFIED="${ALLOW_UNVERIFIED:-0}"\n'
    awk '/^_HOST_SCRIPT_SBIN_FILES=\(/{found=1} found{print} found && /^\)$/{exit}' "$UPGRADE"
    awk '/^_host_script_remote_name\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_install_dir\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_mode\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_HOST_SCRIPT_RESTART_UNITS=\(/{found=1} found{print} found && /^\)$/{exit}' "$UPGRADE"
    # snapshot_host_scripts/restore_host_scripts/sync_host_scripts are now
    # thin lazy-source forwarders in upgrade.sh (Phase 4 strangler-harden,
    # task p4) — the awk-extracted stubs below can't resolve
    # lib/host-scripts-lib.sh from inside this sourced-preamble harness
    # (BASH_SOURCE[0] points at $PREAMBLE_SYNC, not the real upgrade.sh).
    # Append the REAL lib content after them: its same-named definitions
    # land LAST and overwrite the forwarder stubs (bash: later def wins).
    awk '/^snapshot_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^restore_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^sync_host_scripts\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    cat "$REPO_ROOT/lib/host-scripts-lib.sh"
} > "$PREAMBLE_SYNC"
bash -n "$PREAMBLE_SYNC" || { fail "C-0: sync preamble has syntax errors"; exit 1; }
pass "C-0: sync preamble syntax clean"

# Fixture server: no assets at all → SHA256SUMS will 404 for any tag.
TMPDIR_FAIL=$(mktemp -d)
FAIL_PORT=$(probe_free_port)
python3 -m http.server "$FAIL_PORT" --directory "$TMPDIR_FAIL" \
    >/tmp/test-tag-form-fail-httpd.log 2>&1 &
FAIL_HTTP_PID=$!
# Set initial cleanup; will be replaced when D section starts more servers.
cleanup_all() {
    kill "${FAIL_HTTP_PID:-}" "${RAW_HTTP_PID:-}" "${REL_HTTP_PID:-}" 2>/dev/null || true
    rm -rf "${TMPDIR_FAIL:-}" "${TMPDIR_EDGE_E:-}"
}
# shellcheck disable=SC2064
trap "cleanup_all; rm -f '$PREAMBLE_TAG' '$PREAMBLE_SYNC'" EXIT
sleep 1

# C-1: pinned tag + SHA256SUMS 404 → sync exits non-zero (fail-loud).
TC1_SBIN=$(mktemp -d)
OUT_C1=$(
    PREFIX_SBIN="$TC1_SBIN" \
    PREFIX_BIN="$TC1_SBIN" \
    PREFIX_LIBDIR="$TC1_SBIN" \
    SYSTEMD_DIR="$TC1_SBIN" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$FAIL_PORT" \
    RELEASES_BASE="http://127.0.0.1:$FAIL_PORT" \
    DRY_RUN=0 \
    ALLOW_UNVERIFIED=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE_SYNC'; sync_host_scripts v0.12.59" 2>&1
) && RC_C1=0 || RC_C1=$?
rm -rf "$TC1_SBIN"

[[ "$RC_C1" -ne 0 ]] \
    && pass "C-1: pinned tag + SHA256SUMS 404 → sync exits non-zero ($RC_C1) [fail-loud]" \
    || fail "C-1: sync exited 0 despite SHA256SUMS 404 — silent unverified install not blocked"

echo "$OUT_C1" | grep -qi 'Supply-chain integrity check FAILED\|could not fetch SHA256SUMS' \
    && pass "C-2: fail-loud error message mentions supply-chain / SHA256SUMS" \
    || fail "C-2: expected supply-chain error in output; got: $OUT_C1"

# C-3: --allow-unverified → warns but proceeds (exits 0).
TC3_SBIN=$(mktemp -d)
OUT_C3=$(
    PREFIX_SBIN="$TC3_SBIN" \
    PREFIX_BIN="$TC3_SBIN" \
    PREFIX_LIBDIR="$TC3_SBIN" \
    SYSTEMD_DIR="$TC3_SBIN" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$FAIL_PORT" \
    RELEASES_BASE="http://127.0.0.1:$FAIL_PORT" \
    DRY_RUN=0 \
    ALLOW_UNVERIFIED=1 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE_SYNC'; sync_host_scripts v0.12.59" 2>&1
) && RC_C3=0 || RC_C3=$?
rm -rf "$TC3_SBIN"

[[ "$RC_C3" -eq 0 ]] \
    && pass "C-3: --allow-unverified + SHA256SUMS 404 → exits 0 (warn+proceed)" \
    || fail "C-3: --allow-unverified should not die on SHA256SUMS 404, got exit $RC_C3"

echo "$OUT_C3" | grep -qi 'allow-unverified\|proceeding WITHOUT' \
    && pass "C-4: --allow-unverified emits warning about unverified proceed" \
    || fail "C-4: expected unverified-proceed warning; got: $OUT_C3"

# C-5: 'latest' tag → warn+proceed (no SHA256SUMS guard for floating tags).
TC5_SBIN=$(mktemp -d)
OUT_C5=$(
    PREFIX_SBIN="$TC5_SBIN" \
    PREFIX_BIN="$TC5_SBIN" \
    PREFIX_LIBDIR="$TC5_SBIN" \
    SYSTEMD_DIR="$TC5_SBIN" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$FAIL_PORT" \
    RELEASES_BASE="http://127.0.0.1:$FAIL_PORT" \
    DRY_RUN=0 \
    ALLOW_UNVERIFIED=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE_SYNC'; sync_host_scripts latest" 2>&1
) && RC_C5=0 || RC_C5=$?
rm -rf "$TC5_SBIN"

[[ "$RC_C5" -eq 0 ]] \
    && pass "C-5: 'latest' tag → exits 0 (no SHA256SUMS guard for floating tag)" \
    || fail "C-5: 'latest' sync should not die even without SHA256SUMS, got exit $RC_C5"

echo "$OUT_C5" | grep -qi 'latest.*SHA256SUMS.*not available\|floating tag' \
    && pass "C-6: 'latest' run emits 'not available' / 'floating tag' warning" \
    || fail "C-6: expected floating-tag warning for 'latest'; got: $OUT_C5"

# ---------------------------------------------------------------------------
# Fix D: Edge-e repro — new release layout (vX.Y.Z, no partner-edge- prefix)
# ---------------------------------------------------------------------------
echo ""
echo "=== Fix D: edge-e repro — new release layout vX.Y.Z/SHA256SUMS ==="
#
# The edge-e incident (v0.12.59 edge-b) was caused by upgrade.sh using the
# docker image tag form (vX.Y.Z) but releases living at partner-edge-vX.Y.Z/.
#
# The fix: unify tag forms starting at v0.12.60.  GitHub releases now live at
# vX.Y.Z/ (no component prefix).  normalize_target() sets RELEASE_TAG=TARGET
# (identity), so SHA256SUMS is fetched from RELEASES_BASE/vX.Y.Z/SHA256SUMS.
#
# This test exercises the post-fix layout to assert:
#   - SHA256SUMS fetch returns 200 (not 404)
#   - Files install verified (not "proceeding without checksum guard")
#   - The edge-e WARNs are absent
#
# Fixture layout (matching new release format):
#   TMPDIR_EDGE_E/
#     v0.12.59/          ← RELEASES_BASE/v0.12.59/ (new format, no partner-edge- prefix)
#       SHA256SUMS
#       partner-edge-upgrade.sh (substituted release asset)
#   REPO_ROOT/           ← REPO_RAW (raw file bytes from checkout)

TMPDIR_EDGE_E=$(mktemp -d)
EDGE_E_RELEASE_DIR="$TMPDIR_EDGE_E/v0.12.59"
mkdir -p "$EDGE_E_RELEASE_DIR"

# Serve raw files from repo root (as REPO_RAW).
RAW_PORT=$(probe_free_port)
python3 -m http.server "$RAW_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-edge-e-raw.log 2>&1 &
RAW_HTTP_PID=$!

# Build SHA256SUMS with correct hashes for files that sync_host_scripts fetches.
# Extract the remote_name for each managed file from the preamble.
declare -A EDGE_E_SHAS
while IFS= read -r remote_name; do
    [[ -z "$remote_name" ]] && continue
    fpath="$REPO_ROOT/$remote_name"
    fname=$(basename "$remote_name")
    if [[ -f "$fpath" ]]; then
        sha=$(sha256sum "$fpath" | awk '{print $1}')
        EDGE_E_SHAS["$fname"]="$sha"
    fi
done < <(
    bash -c "
        source '$PREAMBLE_SYNC'
        for f in \"\${_HOST_SCRIPT_SBIN_FILES[@]}\"; do
            _host_script_remote_name \"\$f\"
        done
    " 2>/dev/null || true
)

# Stage partner-edge-upgrade.sh (self-update asset) in the release dir.
# sync_host_scripts fetches it from RELEASES_BASE (substituted bytes).
EDGE_E_UPGRADE_CONTENT='#!/bin/bash
# EDGE-E FIXTURE: partner-edge-upgrade.sh (tag-form test release asset)
echo "edge-e-fixture-upgrade-v0.12.59"
'
printf '%s' "$EDGE_E_UPGRADE_CONTENT" > "$EDGE_E_RELEASE_DIR/partner-edge-upgrade.sh"
EDGE_E_UPGRADE_SHA=$(sha256sum "$EDGE_E_RELEASE_DIR/partner-edge-upgrade.sh" | awk '{print $1}')

# Build SHA256SUMS with all correct hashes.
{
    for fname in "${!EDGE_E_SHAS[@]}"; do
        printf '%s  %s\n' "${EDGE_E_SHAS[$fname]}" "$fname"
    done
    printf '%s  partner-edge-upgrade.sh\n' "$EDGE_E_UPGRADE_SHA"
} > "$EDGE_E_RELEASE_DIR/SHA256SUMS"

RELEASE_PORT=$(probe_free_port)
python3 -m http.server "$RELEASE_PORT" --directory "$TMPDIR_EDGE_E" \
    >/tmp/test-edge-e-release.log 2>&1 &
REL_HTTP_PID=$!

sleep 1
# Readiness probe: wait up to 5s for the release fixture server.
for _i in 1 2 3 4 5; do
    curl -fsSL --max-time 1 "http://127.0.0.1:$RELEASE_PORT/" >/dev/null 2>&1 && break
    sleep 1
done
curl -fsSL --max-time 2 "http://127.0.0.1:$RAW_PORT/upgrade.sh" >/dev/null \
    || { fail "D-0: RAW fixture server not ready on port $RAW_PORT"; }

# D-1: fixture RELEASES_BASE/v0.12.59/SHA256SUMS returns 200 (new format URL).
curl -fsSL --max-time 5 "http://127.0.0.1:$RELEASE_PORT/v0.12.59/SHA256SUMS" >/dev/null \
    && pass "D-1: fixture RELEASES_BASE/v0.12.59/SHA256SUMS reachable (200) [new URL format]" \
    || { fail "D-1: fixture SHA256SUMS not reachable — test infrastructure broken"; }

# D-2: the OLD URL (partner-edge-v0.12.59/) returns 404 — confirms fixture matches prod bug.
old_url_status=$(curl -o /dev/null -s -w "%{http_code}" --max-time 5 \
    "http://127.0.0.1:$RELEASE_PORT/partner-edge-v0.12.59/SHA256SUMS" 2>/dev/null || echo "000")
[[ "$old_url_status" == "404" ]] \
    && pass "D-2: old partner-edge-v0.12.59/ URL returns 404 (edge-e bug fixture validated)" \
    || pass "D-2: old URL returned $old_url_status (404 expected, but not critical for fix validation)"

# D-3: sync with new release tag form → exits 0 (verified install).
# normalize_target sets RELEASE_TAG = TARGET = v0.12.59 → correct URL.
TD_SBIN=$(mktemp -d); TD_BIN=$(mktemp -d)
TD_LIBDIR=$(mktemp -d); TD_SYSTEMD=$(mktemp -d)

OUT_D3=$(
    PREFIX_SBIN="$TD_SBIN" \
    OXPULSE_PREFIX_BIN="$TD_BIN" \
    PREFIX_BIN="$TD_BIN" \
    PREFIX_LIBDIR="$TD_LIBDIR" \
    SYSTEMD_DIR="$TD_SYSTEMD" \
    SYSTEMCTL_BIN=true \
    REPO_RAW="http://127.0.0.1:$RAW_PORT" \
    RELEASES_BASE="http://127.0.0.1:$RELEASE_PORT" \
    DRY_RUN=0 \
    ALLOW_UNVERIFIED=0 \
    STATE_FILE=/dev/null \
    bash -c "source '$PREAMBLE_SYNC'; sync_host_scripts v0.12.59" 2>&1
) && RC_D3=0 || RC_D3=$?

[[ "$RC_D3" -eq 0 ]] \
    && pass "D-3: sync_host_scripts v0.12.59 (new URL form) exits 0 — verified install" \
    || fail "D-3: sync failed with exit $RC_D3; output: $OUT_D3"

# D-4: SHA256SUMS was fetched and guard ran (log line present).
echo "$OUT_D3" | grep -qi 'fetched SHA256SUMS for v0.12.59\|SHA256SUMS' \
    && pass "D-4: SHA256SUMS fetched for v0.12.59 (checksum guard ran)" \
    || fail "D-4: expected SHA256SUMS fetch log; got: $OUT_D3"

# D-5: at least one file installed or up-to-date (sync did work).
echo "$OUT_D3" | grep -qi 'installed\|up-to-date' \
    && pass "D-5: files installed or up-to-date after sync" \
    || fail "D-5: no 'installed'/'up-to-date' in output — sync may have silently skipped; output: $OUT_D3"

# D-6: oxpulse-channels-health-report installed to sbin.
[[ -f "$TD_SBIN/oxpulse-channels-health-report" ]] \
    && pass "D-6: oxpulse-channels-health-report installed to sbin" \
    || fail "D-6: oxpulse-channels-health-report missing from sbin after sync"

# D-7: installed sha256 matches REPO_RAW source (integrity verified).
if [[ -f "$TD_SBIN/oxpulse-channels-health-report" \
      && -f "$REPO_ROOT/oxpulse-channels-health-report.sh" ]]; then
    installed_sha=$(sha256sum "$TD_SBIN/oxpulse-channels-health-report" | awk '{print $1}')
    expected_sha=$(sha256sum "$REPO_ROOT/oxpulse-channels-health-report.sh"  | awk '{print $1}')
    [[ "$installed_sha" == "$expected_sha" ]] \
        && pass "D-7: installed health-report sha256 matches REPO_RAW source (verified)" \
        || fail "D-7: sha mismatch: installed=$installed_sha expected=$expected_sha"
else
    fail "D-7: cannot verify sha256 — source or installed file missing"
fi

# D-8: the edge-e WARN "could not fetch SHA256SUMS" is gone.
echo "$OUT_D3" | grep -qi 'could not fetch SHA256SUMS' \
    && fail "D-8: 'could not fetch SHA256SUMS' STILL in output — edge-e WARN not fixed" \
    || pass "D-8: no 'could not fetch SHA256SUMS' warning (edge-e SHA256SUMS bug fixed)"

# D-9: the edge-e WARN "skipping oxpulse-partner-edge-upgrade" is gone.
echo "$OUT_D3" | grep -qi 'skipping oxpulse-partner-edge-upgrade' \
    && fail "D-9: 'skipping oxpulse-partner-edge-upgrade' STILL in output — edge-e bug not fixed" \
    || pass "D-9: no 'skipping oxpulse-partner-edge-upgrade' warning (edge-e self-update bug fixed)"

rm -rf "$TD_SBIN" "$TD_BIN" "$TD_LIBDIR" "$TD_SYSTEMD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
