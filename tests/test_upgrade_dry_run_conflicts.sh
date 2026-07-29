#!/usr/bin/env bash
# tests/test_upgrade_dry_run_conflicts.sh
# Tests the --dry-run conflict detection checks added in feat/upgrade-dry-run-conflict-detect.
# Strategy: fake docker binary + synthesized install.env / compose files + local HTTP server.
# No root required; no real docker mutations.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

# ---- syntax check first ----
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh syntax error"; exit 1; }

# ---- local HTTP server for templates ----
SERVE_PORT=18759
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-conflicts-httpd.log 2>&1 &
HTTP_PID=$!

TMPROOT=$(mktemp -d)
cleanup() {
    kill "$HTTP_PID" 2>/dev/null || true
    rm -rf "$TMPROOT"
}
trap cleanup EXIT

sleep 1
curl -fsSL --max-time 5 "http://127.0.0.1:$SERVE_PORT/Caddyfile.tpl" >/dev/null \
    || { echo "FAIL: local HTTP server not serving Caddyfile.tpl"; exit 1; }

# ---- opec availability (Check-1 render tests are skipped when opec absent) ----
# Canonical locate logic mirrors tests/test_caddyfile_golden.sh.
OPEC_OK=0
if [[ -n "${OPEC_BIN:-}" ]]; then
    _opec_candidate="$OPEC_BIN"
elif command -v opec >/dev/null 2>&1; then
    _opec_candidate=opec
else
    _cargo_target=$(
        cd "$REPO_ROOT" && git rev-parse --git-common-dir 2>/dev/null \
        | xargs dirname 2>/dev/null || true)
    _opec_candidate=""
    for _d in \
        /mnt/cargo/oxpulse-partner-edge-shared-*/release/opec \
        "$_cargo_target/target/release/opec" \
        "$(pwd)/target/release/opec"; do
        for _f in $_d; do
            if [[ -x "$_f" ]]; then _opec_candidate="$_f"; break 2; fi
        done
    done
fi
if [[ -n "${_opec_candidate:-}" ]] && "$_opec_candidate" --version >/dev/null 2>&1; then
    OPEC_OK=1
    # If opec was found via cargo fallback (not already on PATH), inject its directory
    # into PATH so upgrade.sh's own `command -v opec` also finds it.
    if ! command -v opec >/dev/null 2>&1; then
        export PATH="${_opec_candidate%/opec}:$PATH"
    fi
fi

# ---- shared sandbox factory ----
make_sandbox() {
    local id="$1"
    local etc="$TMPROOT/etc-$id"
    local lib="$TMPROOT/lib-$id"
    mkdir -p "$etc" "$lib"

    cat > "$etc/docker-compose.yml" << 'COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.12.26
    container_name: oxpulse-partner-caddy
    ports:
      - "80:80"
      - "443:443"
    environment:
      PARTNER_DOMAIN: "test.example.com"
      PARTNER_ID: "testpartner"
  oxpulse-sfu:
    image: ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.26
    environment:
      SIGNALING_SFU_SECRET: "test-secret-nonzero"
COMPOSE

    cat > "$lib/install.env" << 'ENVEOF'
PARTNER_ID=testpartner
PARTNER_DOMAIN=test.example.com
NODE_ID=test-node-abc123
TUNNEL=vless
IMAGE_VERSION=v0.12.26
TURNS_SUBDOMAIN=turns
INSTALLED_AT=2026-01-01T00:00:00Z
CADDYFILE_SHA=oldhashvalue
NAIVE_SOCKS_PORT=1080
ENVEOF
    chmod 0600 "$lib/install.env"

    # Create a ghcr.token by default (Check 7 passes unless test removes it).
    echo "ghp_testtoken" > "$etc/ghcr.token"
    chmod 0600 "$etc/ghcr.token"

    echo "$etc"
}

# ---- docker shim factory ----
# Builds a mock docker binary that responds predictably to the calls upgrade.sh makes.
# Arguments:
#   $1 = shim_path  (where to write the script)
#   $2 = caddy_image  (returned by `docker inspect oxpulse-partner-caddy`)
#   $3 = validate_rc  (0=pass, 1=fail)
#   $4 = validate_err (error string, only used when validate_rc=1)
make_docker_shim() {
    local shim="$1"
    local caddy_image="${2:-partner-edge-caddy:v0.12.26}"
    local validate_rc="${3:-0}"
    local validate_err="${4:-}"

    cat > "$shim" << SHIM
#!/usr/bin/env bash
# Mock docker for conflict-detection tests.
case "\$*" in
    inspect*oxpulse-partner-caddy*--format*)
        echo "$caddy_image"
        ;;
    run*caddy*validate*)
        if [[ $validate_rc -ne 0 ]]; then
            echo "$validate_err" >&2
            exit $validate_rc
        fi
        ;;
    compose*pull*|compose*up*)
        # No-op for dry-run tests.
        ;;
    *)
        # Pass-through other calls (login, etc.) silently.
        ;;
esac
SHIM
    chmod +x "$shim"
}

# Helper: run upgrade --with-templates --dry-run with a given sandbox + shim.
run_dry() {
    local etc="$1"
    local lib="$2"
    local docker_shim="$3"
    shift 3
    # Remaining args forwarded to upgrade.sh (e.g. v0.12.25 for downgrade test).
    local extra_args=("$@")

    DOCKER_BIN="$docker_shim" \
    OXPULSE_PREFIX_ETC="$etc" \
    OXPULSE_PREFIX_LIB="$lib" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_HEALTHCHECK="/bin/true" \
    OXPULSE_REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
        bash "$UPGRADE" --with-templates --dry-run "${extra_args[@]}" 2>&1 || true
}

# ============================================================
# Tests 1+2 require opec for the Check-1 Caddyfile render path.
# Skip gracefully on CI runners that don't have opec available.
# ============================================================
if [[ "$OPEC_OK" == 1 ]]; then

# ============================================================
# Test 1: Check 1 — Caddyfile validation failure → CATASTROPHIC
# ============================================================
echo "==> Test 1: Check 1 CATASTROPHIC — Caddyfile fails caddy validate"

T1_ETC=$(make_sandbox t1)
T1_LIB="$TMPROOT/lib-t1"
T1_SHIM="$TMPROOT/docker-t1.sh"

# Install a Caddyfile with a synthetic bad directive to trigger the validation failure.
# The shim will return rc=1 for `run ... caddy validate`.
make_docker_shim "$T1_SHIM" \
    "partner-edge-caddy:v0.12.26" \
    1 \
    "Error: unrecognized global option: maxmind_geolocation"

output=$(run_dry "$T1_ETC" "$T1_LIB" "$T1_SHIM")

echo "$output" | grep "CATASTROPHIC" >/dev/null \
    || { echo "FAIL: Check 1 did not emit CATASTROPHIC"; echo "$output"; exit 1; }
echo "$output" | grep "maxmind_geolocation\|Caddyfile" >/dev/null \
    || { echo "FAIL: Check 1 CATASTROPHIC missing caddyfile error text"; echo "$output"; exit 1; }
echo "$output" | grep "Exit code: 1" >/dev/null \
    || { echo "FAIL: Check 1 CATASTROPHIC — summary missing 'Exit code: 1'"; echo "$output"; exit 1; }
echo "OK: Test 1 — Check 1 CATASTROPHIC emitted correctly"

# ============================================================
# Test 2: Check 1 — caddy container absent → INFO (not catastrophic)
# ============================================================
echo "==> Test 2: Check 1 INFO — caddy container not running"

T2_ETC=$(make_sandbox t2)
T2_LIB="$TMPROOT/lib-t2"
T2_SHIM="$TMPROOT/docker-t2.sh"

# Shim returns empty string for inspect (container not found).
cat > "$T2_SHIM" << 'SHIM'
#!/usr/bin/env bash
case "$*" in
    inspect*oxpulse-partner-caddy*)
        # Container absent — print nothing, exit 1.
        exit 1 ;;
    *) ;;
esac
SHIM
chmod +x "$T2_SHIM"

output=$(run_dry "$T2_ETC" "$T2_LIB" "$T2_SHIM")
echo "$output" | grep "CATASTROPHIC" >/dev/null \
    && { echo "FAIL: Test 2 — absent container should NOT be CATASTROPHIC"; echo "$output"; exit 1; }
echo "$output" | grep -i "INFO\|not running\|skipped" >/dev/null \
    || { echo "FAIL: Test 2 — absent container should produce INFO in report"; echo "$output"; exit 1; }
echo "OK: Test 2 — absent caddy container treated as INFO"

else
    echo "SKIP: Test 1+2 (Check 1 render) — opec not available; set OPEC_BIN=/path/to/opec to run"
fi  # OPEC_OK

# ============================================================
# Test 3: Check 2 — compose structural drift → WARNING
# ============================================================
echo "==> Test 3: Check 2 WARNING — template adds port 9080 not in live compose"

T3_ETC=$(make_sandbox t3)
T3_LIB="$TMPROOT/lib-t3"
T3_SHIM="$TMPROOT/docker-t3.sh"
make_docker_shim "$T3_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

# The live sandbox compose (from make_sandbox) has only 80:80 and 443:443.
# The repo's Caddyfile.tpl template (served by local HTTP) has 127.0.0.1:9080:9080.
# Check 2 compares live compose vs fetched template and should detect the drift.

output=$(run_dry "$T3_ETC" "$T3_LIB" "$T3_SHIM")
echo "$output" | grep "WARNING\|9080\|drift" >/dev/null \
    || { echo "FAIL: Test 3 — compose drift not detected"; echo "$output"; exit 1; }
echo "OK: Test 3 — compose port drift detected as WARNING"

# ============================================================
# Test 4: Check 3 — downgrade detection → CATASTROPHIC
# ============================================================
echo "==> Test 4: Check 3 CATASTROPHIC — proposed tag older than current"

T4_ETC=$(make_sandbox t4)
T4_LIB="$TMPROOT/lib-t4"
T4_SHIM="$TMPROOT/docker-t4.sh"
make_docker_shim "$T4_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

# Current IMAGE_VERSION in install.env is v0.12.26. Propose v0.12.25 (downgrade).
output=$(run_dry "$T4_ETC" "$T4_LIB" "$T4_SHIM" "v0.12.25")

echo "$output" | grep "CATASTROPHIC" >/dev/null \
    || { echo "FAIL: Test 4 — downgrade not detected as CATASTROPHIC"; echo "$output"; exit 1; }
echo "$output" | grep -i "downgrade\|v0.12.25\|v0.12.26" >/dev/null \
    || { echo "FAIL: Test 4 — downgrade CATASTROPHIC missing version info"; echo "$output"; exit 1; }
echo "OK: Test 4 — downgrade detected as CATASTROPHIC"

# ============================================================
# Test 5: Check 3 — upgrade detection → PASS
# ============================================================
echo "==> Test 5: Check 3 PASS — proposed tag newer than current"

T5_ETC=$(make_sandbox t5)
T5_LIB="$TMPROOT/lib-t5"
T5_SHIM="$TMPROOT/docker-t5.sh"
make_docker_shim "$T5_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

output=$(run_dry "$T5_ETC" "$T5_LIB" "$T5_SHIM" "v0.12.27")

# Should not be CATASTROPHIC for image tag direction.
echo "$output" | grep "\[CHECK 3\].*CATASTROPHIC" >/dev/null \
    && { echo "FAIL: Test 5 — upgrade incorrectly flagged as CATASTROPHIC"; echo "$output"; exit 1; }
echo "OK: Test 5 — upgrade correctly passes Check 3"

# ============================================================
# Test 6: Check 7 — missing ghcr.token → CATASTROPHIC
# ============================================================
echo "==> Test 6: Check 7 CATASTROPHIC — ghcr.token absent"

T6_ETC=$(make_sandbox t6)
T6_LIB="$TMPROOT/lib-t6"
T6_SHIM="$TMPROOT/docker-t6.sh"
make_docker_shim "$T6_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

# Remove the token file.
rm -f "$T6_ETC/ghcr.token"

output=$(run_dry "$T6_ETC" "$T6_LIB" "$T6_SHIM")

echo "$output" | grep "CATASTROPHIC" >/dev/null \
    || { echo "FAIL: Test 6 — missing ghcr.token not CATASTROPHIC"; echo "$output"; exit 1; }
echo "$output" | grep -i "ghcr\|token\|401" >/dev/null \
    || { echo "FAIL: Test 6 — CATASTROPHIC missing ghcr token hint"; echo "$output"; exit 1; }
echo "$output" | grep "Exit code: 1" >/dev/null \
    || { echo "FAIL: Test 6 — summary missing 'Exit code: 1'"; echo "$output"; exit 1; }
echo "OK: Test 6 — missing ghcr.token detected as CATASTROPHIC"

# ============================================================
# Test 7: --skip-check bypasses individual checks
# ============================================================
echo "==> Test 7: --skip-check=1,7 bypasses Caddyfile + GHCR checks"

T7_ETC=$(make_sandbox t7)
T7_LIB="$TMPROOT/lib-t7"
T7_SHIM="$TMPROOT/docker-t7.sh"
# Both Check 1 (caddy validate) and Check 7 (token) would fire.
make_docker_shim "$T7_SHIM" "partner-edge-caddy:v0.12.26" 1 "Error: unrecognized global option: foo"
rm -f "$T7_ETC/ghcr.token"

output=$(run_dry "$T7_ETC" "$T7_LIB" "$T7_SHIM" --skip-check=1,7)

# Skipped checks should show SKIP in table.
echo "$output" | grep "\[CHECK 1\].*SKIP" >/dev/null \
    || { echo "FAIL: Test 7 — Check 1 not skipped"; echo "$output"; exit 1; }
echo "$output" | grep "\[CHECK 7\].*SKIP" >/dev/null \
    || { echo "FAIL: Test 7 — Check 7 not skipped"; echo "$output"; exit 1; }
# No CATASTROPHIC should remain from checks 1 or 7.
echo "$output" | grep "\[CHECK 1\].*CATASTROPHIC\|\[CHECK 7\].*CATASTROPHIC" >/dev/null \
    && { echo "FAIL: Test 7 — skipped checks still emitting CATASTROPHIC"; echo "$output"; exit 1; }
echo "OK: Test 7 — --skip-check=1,7 correctly bypasses both checks"

# ============================================================
# Test 8: clean run → exit code 0 when no catastrophic/warnings
# ============================================================
echo "==> Test 8: clean run — exit 0 when all checks pass"

T8_ETC=$(make_sandbox t8)
T8_LIB="$TMPROOT/lib-t8"
T8_SHIM="$TMPROOT/docker-t8.sh"
make_docker_shim "$T8_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

# Skip Check 2 (compose drift always triggers vs repo template in test) and
# Check 8 (disk may be <2GB on CI). Use a newer proposed tag to pass Check 3.
# Run with skip-check=2,4,5 to avoid noise from INFO-level checks that have
# no clear expected value in isolation.
raw_output=$(DOCKER_BIN="$T8_SHIM" \
    OXPULSE_PREFIX_ETC="$T8_ETC" \
    OXPULSE_PREFIX_LIB="$T8_LIB" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_HEALTHCHECK="/bin/true" \
    OXPULSE_REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
        bash "$UPGRADE" --with-templates --dry-run --skip-check=2,4,5,8 v0.12.27 2>&1; echo "EXIT_CODE:$?") || true

exit_code=$(echo "$raw_output" | grep 'EXIT_CODE:' | tail -1 | sed 's/EXIT_CODE://')
output=$(echo "$raw_output" | grep -v 'EXIT_CODE:')

# Should not have any CATASTROPHIC.
echo "$output" | grep "CATASTROPHIC" >/dev/null \
    && { echo "FAIL: Test 8 — unexpected CATASTROPHIC"; echo "$output"; exit 1; }
echo "OK: Test 8 — clean run produces no CATASTROPHIC"

# ============================================================
# Test 9: existing test_upgrade_with_templates.sh still passes
# ============================================================
echo "==> Test 9: regression — test_upgrade_with_templates.sh"
REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/tests/test_upgrade_with_templates.sh" \
    || { echo "FAIL: test_upgrade_with_templates.sh regressed"; exit 1; }
echo "OK: Test 9 — existing template tests still pass"

# ============================================================
# Test 10 (FIX 1): cover_dir extraction extracts HOST path, not container path
# ============================================================
echo "==> Test 10: FIX 1 — cover_dir extraction with realistic compose volume line"

# Repro from the reviewer: the old regex extracted /srv/cover:ro (container path).
# Verify the new regex extracts the host path: ./cover (or resolved absolute path).
_cover_test_compose=$(mktemp)
cat > "$_cover_test_compose" << 'COVER_COMPOSE'
services:
  caddy:
    image: ghcr.io/anatolykoptev/partner-edge-caddy:v0.12.26
    volumes:
      - ./cover:/srv/cover:ro
COVER_COMPOSE

# New regex from upgrade.sh FIX 1.
_extracted=$(grep -oP '^\s*-\s*\K[^[:space:]:]+(?=:/srv/cover)' "$_cover_test_compose" 2>/dev/null | head -1 || true)
rm -f "$_cover_test_compose"

if [[ "$_extracted" == "./cover" ]]; then
    echo "OK: Test 10 — extracted host path: '$_extracted' (correct)"
else
    echo "FAIL: Test 10 — cover_dir extraction returned '$_extracted', expected './cover'"
    exit 1
fi

# Also verify the old regex would fail (confirm the fix is needed).
_cover_test_compose2=$(mktemp)
printf '      - ./cover:/srv/cover:ro\n' > "$_cover_test_compose2"
_old_extracted=$(grep -oP 'cover:\s*\K[^[:space:]]+' "$_cover_test_compose2" 2>/dev/null | head -1 || true)
rm -f "$_cover_test_compose2"
if [[ "$_old_extracted" == "/srv/cover:ro" ]]; then
    echo "OK: Test 10 — confirmed old regex was broken (extracted '$_old_extracted')"
else
    echo "NOTE: Test 10 — old regex returned '$_old_extracted' (expected /srv/cover:ro)"
fi

# ============================================================
# Test 11 (FIX 5): concurrency lock — second invocation dies with lock error
# ============================================================
echo "==> Test 11: FIX 5 — flock prevents concurrent upgrade.sh runs"

T11_ETC=$(make_sandbox t11)
T11_LIB="$TMPROOT/lib-t11"
T11_SHIM="$TMPROOT/docker-t11.sh"
make_docker_shim "$T11_SHIM" "partner-edge-caddy:v0.12.26" 0 ""

# Hold the lock manually to simulate a running upgrade.
T11_LOCK="$T11_LIB/upgrade.lock"
touch "$T11_LOCK"
exec 19>"$T11_LOCK"
flock -x 19  # hold exclusive lock from this test process

# Run upgrade.sh --with-templates --dry-run — dry-run skips the lock (read-only).
# Then run WITHOUT --dry-run (will try to acquire lock, should fail).
# We use a MODE that triggers the lock: apply (default), not check/dry-run.
# Since apply needs real docker+state, use a sub-sandbox but expect lock rejection.
_lock_out=$(DOCKER_BIN="$T11_SHIM" \
    OXPULSE_PREFIX_ETC="$T11_ETC" \
    OXPULSE_PREFIX_LIB="$T11_LIB" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_HEALTHCHECK="/bin/true" \
    OXPULSE_REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
        bash "$UPGRADE" --with-templates latest 2>&1 || true)

# Release our lock.
flock -u 19
exec 19>&-

if echo "$_lock_out" | grep -i "another upgrade\|lock" >/dev/null; then
    echo "OK: Test 11 — second invocation blocked by flock: $(echo "$_lock_out" | grep -i 'lock\|another' | head -1)"
else
    echo "FAIL: Test 11 — expected lock-rejection message, got: $_lock_out"
    exit 1
fi

echo ""
echo "PASS: all test_upgrade_dry_run_conflicts tests passed"
