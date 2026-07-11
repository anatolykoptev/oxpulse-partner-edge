#!/bin/bash
# tests/test_upgrade_pull_scope_and_rollback.sh
#
# Two real bugs found during the v0.13.0 fleet rollout, live incident on edge-c
# (2026-07):
#
# BUG A — dead rollback under `set -e`. The plain-apply and --with-templates
# pull sites used `pull_out=$(...); pull_rc=$?` — a bare assignment as a
# plain top-level statement is NOT exempt from `set -e`; a failing pull
# killed the WHOLE script right there, before the failure branch below
# (print output, ghcr_pull_diagnose, restore_host_scripts, restore
# compose+state, die) ever ran. Observed on edge-c: script died mid-upgrade —
# compose + host-scripts already rewritten to v0.13.0, containers still on
# v0.12.72, no rollback, no error beyond the last log line "pulling new
# images". Fix: `if ! pull_out=$(...); then` (assignment-inside-if IS the
# `set -e` exemption).
#
# BUG B — pull/digest/recreate scope covered FOREIGN services. Partners add
# their own services to the same compose file (live example: `all-edge-c-gate`
# on edge-c — a local-only image). `docker compose pull` with no service args
# tries to pull EVERY service, foreign ones included, and fails the WHOLE
# pull with "pull access denied for all-edge-c-gate, repository does not
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

# B1d: capture_running_digests and resolve_pulled_digests must take an
# EXPLICIT caller-supplied service-array parameter (nameref $1) rather than
# deriving their own list internally — PR review round 2 MAJOR-1/MINOR: the
# service list is resolved ONCE, early, by resolve_edge_service_scope, and
# threaded through every caller instead of being recomputed per function.
capture_sig=$(awk '/^capture_running_digests\(\)/{f=1} f{print} f && /^}$/{exit}' "$UPGRADE")
resolve_sig=$(awk '/^resolve_pulled_digests\(\)/{f=1} f{print} f && /^}$/{exit}' "$UPGRADE")

echo "$capture_sig" | grep -qE 'local -n _crd_svcs="\$1"' \
    && pass "B1d-a: capture_running_digests takes an explicit service-array param (\$1), not a self-derived list" \
    || fail "B1d-a: capture_running_digests does not take an explicit service-array param"

echo "$resolve_sig" | grep -qE 'local -n _rpd_svcs="\$1"' \
    && pass "B1d-b: resolve_pulled_digests takes an explicit service-array param (\$1), not a self-derived list" \
    || fail "B1d-b: resolve_pulled_digests does not take an explicit service-array param"

# B1e: both apply paths must call resolve_edge_service_scope() and pass THAT
# same array into capture_running_digests / the pull / resolve_pulled_digests
# — reused, not recomputed (PR review round 2 MINOR: one docker compose
# config fetch per apply-path run, not one per caller).
early_guard_calls=$(grep -cE '^\s*resolve_edge_service_scope _(wt_)?edge_svcs$' "$UPGRADE" || true)
if [[ "$early_guard_calls" -eq 2 ]]; then
    pass "B1e: resolve_edge_service_scope() called exactly once per apply path (plain + with-templates)"
else
    fail "B1e: expected 2 resolve_edge_service_scope() call sites, found $early_guard_calls"
fi

capture_reuse=$(grep -cE '^\s*capture_running_digests _(wt_)?edge_svcs ' "$UPGRADE" || true)
if [[ "$capture_reuse" -eq 2 ]]; then
    pass "B1f: capture_running_digests is called with the early-resolved _edge_svcs / _wt_edge_svcs array in both apply paths"
else
    fail "B1f: expected 2 capture_running_digests(_edge_svcs, ...) call sites, found $capture_reuse"
fi

resolve_reuse=$(grep -cE '^\s*if ! resolve_pulled_digests _(wt_)?edge_svcs ' "$UPGRADE" || true)
if [[ "$resolve_reuse" -eq 2 ]]; then
    pass "B1g: resolve_pulled_digests is called with the early-resolved _edge_svcs / _wt_edge_svcs array in both apply paths"
else
    fail "B1g: expected 2 resolve_pulled_digests(_edge_svcs, ...) call sites, found $resolve_reuse"
fi

# ===========================================================================
# Section C — structural: MAJOR-1 early-guard placement, MAJOR-2 distinct
# die messages, MINOR single-fetch memoization, NIT quote-strip
# ===========================================================================
echo ""
echo "=== Section C: PR review round 2 — early guard, distinct die messages, memoization, quote-strip ==="

# C1: resolve_edge_service_scope() must appear BEFORE the tag-rewrite sed in
# BOTH apply paths (the first irreversible mutation) — MAJOR-1.
plain_guard_line=$(grep -n '^resolve_edge_service_scope _edge_svcs$' "$UPGRADE" | tail -1 | cut -d: -f1 || true)
plain_sed_line=$(grep -n 'sed -i -E "s|(ghcr\\.io/anatolykoptev/partner-edge-\[a-z\]+):' "$UPGRADE" | tail -1 | cut -d: -f1 || true)
if [[ -n "$plain_guard_line" && -n "$plain_sed_line" && "$plain_guard_line" -lt "$plain_sed_line" ]]; then
    pass "C1a: plain-apply path resolves the service scope (line $plain_guard_line) BEFORE the tag-rewrite sed (line $plain_sed_line)"
else
    fail "C1a: plain-apply guard=$plain_guard_line sed=$plain_sed_line — guard does not precede the first mutation"
fi

wt_guard_line=$(grep -n '^\s*resolve_edge_service_scope _wt_edge_svcs$' "$UPGRADE" | head -1 | cut -d: -f1 || true)
wt_sed_line=$(grep -n 'sed -i -E "s|(ghcr\\.io/anatolykoptev/partner-edge-\[a-z\]+):' "$UPGRADE" | head -1 | cut -d: -f1 || true)
if [[ -n "$wt_guard_line" && -n "$wt_sed_line" && "$wt_guard_line" -lt "$wt_sed_line" ]]; then
    pass "C1b: --with-templates path resolves the service scope (line $wt_guard_line) BEFORE the tag-rewrite sed (line $wt_sed_line)"
else
    fail "C1b: --with-templates guard=$wt_guard_line sed=$wt_sed_line — guard does not precede the first mutation"
fi

# C1c/d: the guard must also precede sync_host_scripts and (with-templates)
# reconcile_all — the other irreversible mutations named in the review.
plain_sync_line=$(grep -n '^sync_host_scripts "\$RELEASE_TAG"$' "$UPGRADE" | tail -1 | cut -d: -f1 || true)
[[ -n "$plain_guard_line" && -n "$plain_sync_line" && "$plain_guard_line" -lt "$plain_sync_line" ]] \
    && pass "C1c: plain-apply guard precedes sync_host_scripts" \
    || fail "C1c: plain-apply guard does not precede sync_host_scripts (guard=$plain_guard_line sync=$plain_sync_line)"

wt_reconcile_line=$(grep -n 'reconcile_all "\$_manifest_path_wt"' "$UPGRADE" | head -1 | cut -d: -f1 || true)
[[ -n "$wt_guard_line" && -n "$wt_reconcile_line" && "$wt_guard_line" -lt "$wt_reconcile_line" ]] \
    && pass "C1d: --with-templates guard precedes reconcile_all (caddy hot-reload)" \
    || fail "C1d: --with-templates guard does not precede reconcile_all (guard=$wt_guard_line reconcile=$wt_reconcile_line)"

# C2: MAJOR-2 — two DISTINCT die messages for the two failure modes.
grep -qF 'docker compose config failed — check $COMPOSE_FILE for a broken service definition' "$UPGRADE" \
    && pass "C2a: distinct die message for 'compose config itself failed' (broken foreign service)" \
    || fail "C2a: missing distinct die message for a compose-config parse/validation failure"

grep -qF 'compose config parsed but zero ghcr.io/anatolykoptev/partner-edge-* services found' "$UPGRADE" \
    && pass "C2b: distinct die message for 'config parsed but zero partner-edge images'" \
    || fail "C2b: missing distinct die message for zero partner-edge services"

# C3: MINOR — one shared fetch_compose_config() helper; no leftover raw
# `$DOCKER_BIN compose config` invocations scattered outside it (each one
# is a redundant docker child process this fix was supposed to eliminate).
grep -qE '^fetch_compose_config\(\)' "$UPGRADE" \
    && pass "C3a: fetch_compose_config() helper defined" \
    || fail "C3a: fetch_compose_config() helper not defined"

raw_config_calls=$(grep -cE '\$DOCKER_BIN compose config( |$)' "$UPGRADE" || true)
if [[ "$raw_config_calls" -eq 1 ]]; then
    pass "C3b: exactly one raw '\$DOCKER_BIN compose config' invocation in the whole file (inside fetch_compose_config itself — every other caller goes through it)"
else
    fail "C3b: expected exactly 1 raw '\$DOCKER_BIN compose config' invocation (inside fetch_compose_config), found $raw_config_calls"
fi

grep -qE '^_parse_compose_config_images\(\)' "$UPGRADE" \
    && pass "C3c: _parse_compose_config_images() single-pass parser defined (replaces per-service re-fetch loop)" \
    || fail "C3c: _parse_compose_config_images() not defined"

# C4: NIT — image-match strips quotes before the ghcr.io glob match.
parse_fn_section=$(awk '/^_parse_compose_config_images\(\)/{f=1} f{print} f && /^}$/{exit}' "$UPGRADE")
echo "$parse_fn_section" | grep -qE 'gsub\(/"/,"",img\)' \
    && pass "C4: _parse_compose_config_images strips quotes from the image value before the ghcr.io glob match" \
    || fail "C4: no quote-strip found in _parse_compose_config_images — a quoted image: value would miss the ghcr.io/anatolykoptev/partner-edge-* glob"

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
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:%s\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n  all-edge-c-gate:\n    image: local/all-edge-c-gate:latest\n' \
    "$D_CURRENT" > "$D_TMPDIR/etc/docker-compose.yml"

D_FAKE_DOCKER="$D_TMPDIR/docker"
cat > "$D_FAKE_DOCKER" << 'DFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then
    printf 'sfu\nall-edge-c-gate\n'
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
    # fails exactly like the edge-c incident.
    if [[ "$*" =~ compose\ pull$ ]]; then
        echo "Error response from daemon: pull access denied for all-edge-c-gate, repository does not exist or may require 'docker login'" >&2
        exit 1
    fi
    # Scoped invocation with the foreign service still in the arg list —
    # must also fail (defence in depth for this test).
    if [[ "$*" == *"all-edge-c-gate"* ]]; then
        echo "Error response from daemon: pull access denied for all-edge-c-gate, repository does not exist or may require 'docker login'" >&2
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

if [[ -n "$D_PULL_LINE" && "$D_PULL_LINE" != *"all-edge-c-gate"* ]]; then
    pass "D1: pull command never mentions the foreign service (all-edge-c-gate); recorded: '$D_PULL_LINE'"
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

if grep -qE 'compose up.*all-edge-c-gate|compose up -d --no-deps.*all-edge-c-gate' "$D_LOG"; then
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
# Section F — functional: MAJOR-1, the guard fires BEFORE any mutation
# ===========================================================================
echo ""
echo "=== Section F: zero-partner-edge-services guard fires BEFORE any mutation (compose + host-scripts untouched) ==="
echo "    FALSIFICATION NOTE: this section must be RED against PR head bf806c4 — the guard used to run"
echo "    AFTER the tag-rewrite sed + sync_host_scripts, so compose/host-scripts were already mutated by the time it fired."

F_TMPDIR=$(mktemp -d)
_make_fixture "$F_TMPDIR"
F_LOG="$F_TMPDIR/docker_calls.log"

F_CURRENT=v0.12.72
F_TARGET=v0.13.0

# SCHEMA_VERSION=1 pre-set so migrate_state (which runs unconditionally,
# before MODE dispatch — unrelated to this fix) is a no-op and doesn't
# perturb the install.env byte-identity check below.
printf 'IMAGE_VERSION=%s\nSIGNALING_SFU_SECRET=testsecret\nSCHEMA_VERSION=1\n' "$F_CURRENT" > "$F_TMPDIR/var/install.env"
# Compose file with ONLY a foreign service — zero ghcr.io/anatolykoptev/
# partner-edge-* images. This is the "config parsed but zero partner-edge
# images" failure mode (MAJOR-2), distinct from a compose-config parse
# failure but exercising the SAME early-guard call site.
printf 'services:\n  all-edge-c-gate:\n    image: local/all-edge-c-gate:latest\n    environment:\n      SIGNALING_SFU_SECRET: "testsecret"\n' \
    > "$F_TMPDIR/etc/docker-compose.yml"

F_FAKE_DOCKER="$F_TMPDIR/docker"
cat > "$F_FAKE_DOCKER" << 'FFAKE'
#!/bin/bash
printf '%s\n' "$*" >> "${DOCKER_CALL_LOG}"
if [[ "$*" == *"config --services"* ]]; then
    printf 'all-edge-c-gate\n'
    exit 0
fi
if [[ "$*" == *"compose config"* && "$*" != *"--services"* ]]; then
    cat "${COMPOSE_FILE_PATH}"
    exit 0
fi
# Any pull/up/ps/inspect call at this point is a MAJOR-1 regression — the
# guard should have died before any of these could ever be reached.
if [[ "$*" == *" pull"* || "$*" == *" up"* || "$*" == *"ps --quiet"* ]]; then
    echo "REGRESSION: docker invoked after zero-partner-edge guard should have died: $*" >&2
    exit 1
fi
exit 0
FFAKE
chmod +x "$F_FAKE_DOCKER"

# Snapshot pre-run state to compare against post-run.
F_COMPOSE_SHA_BEFORE=$(sha256sum "$F_TMPDIR/etc/docker-compose.yml" | awk '{print $1}')
F_HOSTSCRIPT_SHA_BEFORE=$(sha256sum "$F_TMPDIR/sbin/ghcr-auth-lib.sh" | awk '{print $1}')
F_STATE_SHA_BEFORE=$(sha256sum "$F_TMPDIR/var/install.env" | awk '{print $1}')

F_OUT=$(_run_upgrade "$F_TMPDIR" "$F_FAKE_DOCKER" "$F_CURRENT" "$F_TARGET" "$F_LOG" "$F_TMPDIR/etc/docker-compose.yml") \
    && F_RC=0 || F_RC=$?

[[ "$F_RC" -ne 0 ]] \
    && pass "F1: upgrade exits non-zero when the compose file has zero partner-edge services" \
    || fail "F1: upgrade exited 0 despite zero partner-edge services — the guard did not fire"

echo "$F_OUT" | grep -qF 'compose config parsed but zero ghcr.io/anatolykoptev/partner-edge-* services found' \
    && pass "F2: the distinct zero-services die message fired" \
    || fail "F2: expected die message not found; output: $F_OUT"

F_COMPOSE_SHA_AFTER=$(sha256sum "$F_TMPDIR/etc/docker-compose.yml" | awk '{print $1}')
if [[ "$F_COMPOSE_SHA_AFTER" == "$F_COMPOSE_SHA_BEFORE" ]]; then
    pass "F3 (MAJOR-1): compose file is BYTE-IDENTICAL after the guard fired — the tag-rewrite sed never ran"
else
    fail "F3 (MAJOR-1): compose file CHANGED despite the guard firing — a mutation ran before the die (sha before=$F_COMPOSE_SHA_BEFORE after=$F_COMPOSE_SHA_AFTER)"
fi

F_STATE_SHA_AFTER=$(sha256sum "$F_TMPDIR/var/install.env" | awk '{print $1}')
if [[ "$F_STATE_SHA_AFTER" == "$F_STATE_SHA_BEFORE" ]]; then
    pass "F4 (MAJOR-1): install.env is BYTE-IDENTICAL after the guard fired — IMAGE_VERSION was never rewritten"
else
    fail "F4 (MAJOR-1): install.env CHANGED despite the guard firing (sha before=$F_STATE_SHA_BEFORE after=$F_STATE_SHA_AFTER)"
fi

F_HOSTSCRIPT_SHA_AFTER=$(sha256sum "$F_TMPDIR/sbin/ghcr-auth-lib.sh" | awk '{print $1}')
if [[ "$F_HOSTSCRIPT_SHA_AFTER" == "$F_HOSTSCRIPT_SHA_BEFORE" ]]; then
    pass "F5 (MAJOR-1): host-script is BYTE-IDENTICAL after the guard fired — sync_host_scripts never ran"
else
    fail "F5 (MAJOR-1): host-script CHANGED despite the guard firing — sync_host_scripts ran before the die (sha before=$F_HOSTSCRIPT_SHA_BEFORE after=$F_HOSTSCRIPT_SHA_AFTER)"
fi

if grep -qE ' pull| up|ps --quiet' "$F_LOG" 2>/dev/null; then
    fail "F6 (MAJOR-1): docker was invoked for pull/up/ps despite the guard firing before any mutation; calls: $(cat "$F_LOG")"
else
    pass "F6 (MAJOR-1): docker was NEVER invoked for pull/up/ps — the guard died before reaching any of those steps"
fi

[[ -f "$F_TMPDIR/var/install.env.prev" ]] \
    && fail "F7 (MAJOR-1): PREV_STATE_FILE (install.env.prev) exists — backup ran, meaning execution proceeded past where a die-before-mutation guard should have stopped it" \
    || pass "F7 (MAJOR-1): no install.env.prev backup was created — confirms the guard fired at the very top, before even the backup step"

rm -rf "$F_TMPDIR"

# ===========================================================================
echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]] || exit 1
