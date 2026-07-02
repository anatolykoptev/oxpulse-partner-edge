#!/bin/bash
# tests/test_upgrade_pull_scope_and_rollback.sh
#
# Two real bugs found during the v0.13.0 fleet rollout, live incident on rvpn
# (2026-07):
#
# BUG A — dead rollback under `set -e`. The plain-apply and --with-templates
# pull sites used `pull_out=$(...); pull_rc=$?` — a bare assignment as a
# plain top-level statement is NOT exempt from `set -e`; a failing pull
# killed the WHOLE script right there, before the failure branch below
# (print output, ghcr_pull_diagnose, restore_host_scripts, restore
# compose+state, die) ever ran. Observed on rvpn: script died mid-upgrade —
# compose + host-scripts already rewritten to v0.13.0, containers still on
# v0.12.72, no rollback, no error beyond the last log line "pulling new
# images". Fix: `if ! pull_out=$(...); then` (assignment-inside-if IS the
# `set -e` exemption).
#
# BUG B — pull/digest/recreate scope covered FOREIGN services. Partners add
# their own services to the same compose file (live example: `all-rvpn-gate`
# on rvpn — a local-only image). `docker compose pull` with no service args
# tries to pull EVERY service, foreign ones included, and fails the WHOLE
# pull with "pull access denied for all-rvpn-gate, repository does not
# exist". This script only manages ghcr.io/anatolykoptev/partner-edge-*
# images — pull, digest comparison, and recreate must be scoped to those.
#
# Mocking pattern follows tests/test_upgrade_zero_downtime.sh Section E
# (fake $DOCKER_BIN recording calls to a log file, fixture compose file +
# install.env, stub sbin libs, --allow-unverified + OXPULSE_REPO_RAW=
# file:///dev/null to skip the real network fetch path).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Section A — structural: the dead-rollback pattern must be gone
# ===========================================================================
echo ""
echo "=== Section A: BUG A — guarded pull assignment (if ! var=\$(...); then) ==="

bash -n "$UPGRADE" \
    && pass "A1: upgrade.sh passes bash -n (no syntax errors)" \
    || { fail "A1: upgrade.sh has syntax errors"; exit 1; }

# A2: the bare `pull_rc=$?` capture-after-the-fact pattern must be gone —
# it is dead code under set -e (the assignment on the PRECEDING line already
# either succeeded or killed the script before this line could run).
if grep -qF 'pull_rc=$?' "$UPGRADE"; then
    fail "A2: 'pull_rc=\$?' still present — the dead-rollback pattern was not removed"
else
    pass "A2: no 'pull_rc=\$?' capture-after-assignment pattern remains"
fi

# A3: both pull sites (plain-apply + --with-templates) must use the guarded
# `if ! pull_out=$(...); then` form.
guarded_pull_count=$(grep -cE '^\s*if ! pull_out=\$\(' "$UPGRADE" || true)
if [[ "$guarded_pull_count" -eq 2 ]]; then
    pass "A3: both pull sites (plain-apply + --with-templates) use the guarded 'if ! pull_out=\$(...); then' form"
else
    fail "A3: expected 2 guarded pull sites, found $guarded_pull_count"
fi

# ===========================================================================
# Section B — structural: partner-edge service scoping helper + usage
# ===========================================================================
echo ""
echo "=== Section B: BUG B — partner-edge service scoping ==="

grep -qE '^list_partner_edge_services\(\)' "$UPGRADE" \
    && pass "B1a: list_partner_edge_services() defined" \
    || fail "B1a: list_partner_edge_services() not defined"

# B1b: die when the compose file has zero partner-edge services (compose
# corrupted, not "nothing to pull").
grep -qE 'partner-edge-\* services found in \$COMPOSE_FILE.*corrupted' "$UPGRADE" \
    && pass "B1b: die-on-zero-partner-edge-services guard present" \
    || fail "B1b: no die guard for zero partner-edge services in \$COMPOSE_FILE"

# B1c: both main pull sites must pass an explicit scoped service array, not
# a bare 'compose pull' with no args.
scoped_pull_count=$(grep -cE 'compose pull "\$\{_(wt_)?edge_svcs\[@\]\}"' "$UPGRADE" || true)
if [[ "$scoped_pull_count" -eq 2 ]]; then
    pass "B1c: both main pull sites scope to an explicit partner-edge service array"
else
    fail "B1c: expected 2 scoped main-pull call sites, found $scoped_pull_count"
fi

# B1d: capture_running_digests and resolve_pulled_digests must source their
# service list from list_partner_edge_services, not the raw
# 'compose config --services' (which returns foreign services too).
digest_fns_section=$(awk '/^capture_running_digests\(\)/{f=1} f{print} f && /^resolve_pulled_digests\(\)/{c++} c==1 && /^}$/{exit}' "$UPGRADE")
scoped_calls=$(echo "$digest_fns_section" | grep -c 'services=\$(list_partner_edge_services)' || true)
if [[ "$scoped_calls" -eq 2 ]]; then
    pass "B1d: capture_running_digests + resolve_pulled_digests both scope via list_partner_edge_services"
else
    fail "B1d: expected 2 scoped digest-map service listings, found $scoped_calls"
fi

# ===========================================================================
# Section C — functional fixture helpers
# ===========================================================================

# _make_fixture DIR — lays out the standard PREFIX_ETC/LIB/SBIN/... tree +
# stub sbin libs (mirrors test_upgrade_zero_downtime.sh Section E).
_make_fixture() {
    local dir="$1"
    mkdir -p "$dir/etc" "$dir/var" "$dir/sbin" "$dir/bin" "$dir/libdir" "$dir/systemd" "$dir/share"
    printf '# stub\nre_render_xray() { return 0; }\nre_render_hysteria2() { return 0; }\n' \
        > "$dir/sbin/channel-render-lib.sh"
    printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' \
        > "$dir/sbin/ghcr-auth-lib.sh"
    printf '#!/bin/bash\nexit 0\n' > "$dir/sbin/healthcheck"
    chmod 0755 "$dir/sbin/healthcheck"
}

# _run_upgrade DIR DOCKER_BIN CURRENT TARGET DOCKER_CALL_LOG COMPOSE_FILE_PATH
_run_upgrade() {
    local dir="$1" fake_docker="$2" current="$3" target="$4" call_log="$5" compose_path="$6"
    OXPULSE_PREFIX_ETC="$dir/etc" \
    OXPULSE_PREFIX_LIB="$dir/var" \
    OXPULSE_PREFIX_SBIN="$dir/sbin" \
    OXPULSE_PREFIX_BIN="$dir/bin" \
    OXPULSE_PREFIX_LIBDIR="$dir/libdir" \
    OXPULSE_PREFIX_SHARE="$dir/share" \
    OXPULSE_SYSTEMD_DIR="$dir/systemd" \
    OXPULSE_HEALTHCHECK="$dir/sbin/healthcheck" \
    OXPULSE_SKIP_ROOT_CHECK=1 \
    OXPULSE_UPGRADE_TAG="$current" \
    DOCKER_BIN="$fake_docker" \
    DOCKER_CALL_LOG="$call_log" \
    COMPOSE_FILE_PATH="$compose_path" \
    SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW="file:///dev/null" \
    bash "$UPGRADE" --allow-unverified "$target" 2>&1
}

# ===========================================================================
# Section D — functional: BUG B, foreign service never pulled OR recreated
# ===========================================================================
echo ""
echo "=== Section D: pull receives ONLY partner-edge services; foreign service never in recreate set ==="

D_TMPDIR=$(mktemp -d)
_make_fixture "$D_TMPDIR"
D_LOG="$D_TMPDIR/docker_calls.log"

D_CURRENT=v0.12.72
D_TARGET=v0.13.0

printf 'IMAGE_VERSION=%s\nSIGNALING_SFU_SECRET=testsecret\n' "$D_CURRENT" > "$D_TMPDIR/var/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:%s\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n  all-rvpn-gate:\n    image: local/all-rvpn-gate:latest\n' \
    "$D_CURRENT" > "$D_TMPDIR/etc/docker-compose.yml"

D_FAKE_DOCKER="$D_TMPDIR/docker"
cat > "$D_FAKE_DOCKER" << 'DFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\nall-rvpn-gate\n'
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
if [[ "$*" == *"compose pull"* ]]; then
    # Old (unscoped) invocation: bare 'compose pull' with no service args —
    # tries to pull EVERYTHING, including the foreign local-only image, and
    # fails exactly like the rvpn incident.
    if [[ "$*" =~ compose\ pull$ ]]; then
        echo "Error response from daemon: pull access denied for all-rvpn-gate, repository does not exist or may require 'docker login'" >&2
        exit 1
    fi
    # Scoped invocation with the foreign service still in the arg list —
    # must also fail (defence in depth for this test).
    if [[ "$*" == *"all-rvpn-gate"* ]]; then
        echo "Error response from daemon: pull access denied for all-rvpn-gate, repository does not exist or may require 'docker login'" >&2
        exit 1
    fi
    exit 0
fi
# compose up / anything else: succeed.
exit 0
DFAKE
chmod +x "$D_FAKE_DOCKER"

D_OUT=$(_run_upgrade "$D_TMPDIR" "$D_FAKE_DOCKER" "$D_CURRENT" "$D_TARGET" "$D_LOG" "$D_TMPDIR/etc/docker-compose.yml") \
    && D_RC=0 || D_RC=$?

D_PULL_LINE=$(grep 'compose pull' "$D_LOG" | head -1 || true)

if [[ -n "$D_PULL_LINE" && "$D_PULL_LINE" != *"all-rvpn-gate"* ]]; then
    pass "D1: pull command never mentions the foreign service (all-rvpn-gate); recorded: '$D_PULL_LINE'"
else
    fail "D1: pull command included the foreign service or was never recorded; recorded: '$D_PULL_LINE'; output: $D_OUT"
fi

if [[ "$D_PULL_LINE" == *"sfu"* ]]; then
    pass "D2: pull command explicitly includes the partner-edge service (sfu)"
else
    fail "D2: pull command did not include 'sfu'; recorded: '$D_PULL_LINE'"
fi

if [[ "$D_RC" -eq 0 ]]; then
    pass "D3: upgrade succeeds end-to-end once the foreign service is excluded from the pull (exit 0)"
else
    fail "D3: upgrade did not exit 0 despite a correctly scoped pull (exit $D_RC); output: $D_OUT"
fi

if grep -qE 'compose up.*all-rvpn-gate|compose up -d --no-deps.*all-rvpn-gate' "$D_LOG"; then
    fail "D4: a recreate ('compose up') call included the foreign service"
else
    pass "D4: no recreate ('compose up') call ever mentions the foreign service"
fi

rm -rf "$D_TMPDIR"

# ===========================================================================
# Section E — functional: BUG A, the failure branch actually RUNS
# ===========================================================================
echo ""
echo "=== Section E: pull failure -> rollback branch runs (host-scripts + compose/state restored, exit non-zero) ==="
echo "    FALSIFICATION NOTE: this section must be RED against the pre-fix commit — see PR body for the stash/restore proof."

E_TMPDIR=$(mktemp -d)
_make_fixture "$E_TMPDIR"
E_LOG="$E_TMPDIR/docker_calls.log"

E_CURRENT=v0.12.72
E_TARGET=v0.13.0

printf 'IMAGE_VERSION=%s\nSIGNALING_SFU_SECRET=testsecret\n' "$E_CURRENT" > "$E_TMPDIR/var/install.env"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:%s\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    "$E_CURRENT" > "$E_TMPDIR/etc/docker-compose.yml"

E_FAKE_DOCKER="$E_TMPDIR/docker"
cat > "$E_FAKE_DOCKER" << 'EFAKE'
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
if [[ "$*" == *"compose pull"* ]]; then
    # Always fails — simulates a genuine ghcr auth/network failure, NOT a
    # scoping issue (this fixture has only one, correctly-owned service).
    echo "Error response from daemon: unauthorized: authentication required" >&2
    exit 1
fi
exit 0
EFAKE
chmod +x "$E_FAKE_DOCKER"

E_OUT=$(_run_upgrade "$E_TMPDIR" "$E_FAKE_DOCKER" "$E_CURRENT" "$E_TARGET" "$E_LOG" "$E_TMPDIR/etc/docker-compose.yml") \
    && E_RC=0 || E_RC=$?

if [[ "$E_RC" -ne 0 ]]; then
    pass "E1: upgrade exits non-zero on a genuine pull failure"
else
    fail "E1: upgrade exited 0 despite the pull failing — should never happen"
fi

if echo "$E_OUT" | grep -qF 'pull failed — previous config and host-scripts restored'; then
    pass "E2: the failure branch's die message ran (proves the branch was REACHED, not dead code under set -e)"
else
    fail "E2: die message 'pull failed — previous config and host-scripts restored' NOT found — the failure branch likely never ran (BUG A); output: $E_OUT"
fi

if echo "$E_OUT" | grep -qF 'host-scripts restored from snapshot'; then
    pass "E3: restore_host_scripts actually ran (logged 'host-scripts restored from snapshot')"
else
    fail "E3: 'host-scripts restored from snapshot' not logged — restore_host_scripts did not run; output: $E_OUT"
fi

# The compose file must be back to CURRENT (not left on TARGET) — proves the
# `cp -a "$PREV_COMPOSE_FILE" "$COMPOSE_FILE"` restoration line executed.
E_FINAL_TAG=$(grep 'image:.*partner-edge' "$E_TMPDIR/etc/docker-compose.yml" 2>/dev/null \
    | grep -oE ':[^ "]+$' | head -1 | tr -d ':' || true)
if [[ "$E_FINAL_TAG" == "$E_CURRENT" ]]; then
    pass "E4: compose file restored to \$CURRENT ($E_CURRENT) after the failed pull — rollback ran, not left on \$TARGET"
else
    fail "E4: compose file tag after failed pull was '$E_FINAL_TAG', expected '$E_CURRENT' (rollback did not restore compose)"
fi

rm -rf "$E_TMPDIR"

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
