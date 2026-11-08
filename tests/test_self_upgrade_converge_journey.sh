#!/bin/bash
# tests/test_self_upgrade_converge_journey.sh
#
# Journey regression for the pillow 0.16.40 -> 0.16.41 self-upgrade incident
# (2026-11-08): a node whose self-update re-exec does NOT fire must still
# converge in the SAME run, must not be left half-synced, and must be retried
# by the next refresh tick — not silently pinned to a version marker it never
# reached.
#
# What happened on pillow (reproduced here):
#   1. _maybe_self_update_reexec silently bailed (warn-only early return —
#      fetch/exec failure), so the OLD upgrade.sh process kept running.
#   2. sync_host_scripts fetched SHA256SUMS for the TARGET tag from
#      RELEASES_BASE, but payload bytes from REPO_RAW — which is pinned to
#      the RUNNING script's own baked tag (the OLD release). Every file that
#      changed between the releases failed the sha guard and was SKIPPED.
#   3. Only partner-edge-upgrade.sh came from RELEASES_BASE, so the NEW
#      upgrade.sh still landed on disk -> _assert_self_update_converged die()d.
#   4. IMAGE_VERSION had already been sed-written to the state file BEFORE the
#      gate -> refresh saw desired==installed and never retried -> node stuck
#      on 0.16.40 while reporting 0.16.41.
#
# Fixes under test:
#   F1: sync_host_scripts fetches each synced file from the TARGET release's
#       own asset set ($RELEASES_BASE/$tag/<asset>) whenever the tag's
#       SHA256SUMS armed the checksum guard — fetched bytes satisfy the
#       verifier by construction, independent of which script version runs.
#   F2: _assert_self_update_converged re-execs the just-installed,
#       SHA256SUMS-verified sbin copy with the original args (sentinel-guarded)
#       instead of die()ing and asking a human to re-run.
#   F3: IMAGE_VERSION / compose image-tag seds run AFTER the gate, so a
#       gate-level failure leaves the marker at the OLD version and the next
#       refresh tick retries (and so the re-exec'd child does not read
#       CURRENT==TARGET and exit "nothing to do").
#   F4: refresh's _maybe_self_upgrade records the attempted desired tag and
#       emits partner_edge_self_upgrade_retry_total on a re-attempt — the
#       retry is visible, never silent.
#
# Falsification: J1 goes RED if the gate loses its re-exec (revert to die) OR
# if the sbin fetch reverts to REPO_RAW (old-tag bytes -> sha-skip -> die).
# J4 goes RED if the marker seds move back above the gate. J5 goes RED if the
# retry marker/metric is removed.
#
# REAL-CODE MANDATE: the running (parent) and released (child) scripts both
# inline the REAL functions awk-extracted from upgrade.sh +
# lib/host-scripts-lib.sh. Only curl/systemctl are stubbed (offline fixture).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
HSL="$REPO_ROOT/lib/host-scripts-lib.sh"
REFRESH="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== self-upgrade convergence journey (pillow 0.16.40->0.16.41 incident) ==="

for f in "$UPGRADE" "$HSL" "$REFRESH"; do
    [[ -f "$f" ]] || { fail "P0: $f not found"; exit 1; }
done
bash -n "$UPGRADE" && pass "S0: upgrade.sh parses" || { fail "S0: syntax"; exit 1; }
bash -n "$HSL"     && pass "S0b: host-scripts-lib.sh parses" || { fail "S0b: syntax"; exit 1; }

FIX=$(mktemp -d)
trap 'rm -rf "$FIX"' EXIT

# ---------------------------------------------------------------------------
# Extract the real functions both fixture scripts inline.
# ---------------------------------------------------------------------------
extract() { # $1 = fn name -> stdout body
    awk -v n="$1()" 'index($0, n) == 1 { f=1 } f{print} /^}$/ && f{exit}' "$UPGRADE"
}
SHOULD_FN="$FIX/fn_should.sh";      extract '_should_self_update'            > "$SHOULD_FN"
REEXEC_FN="$FIX/fn_reexec.sh";      extract '_maybe_self_update_reexec'      > "$REEXEC_FN"
GATE_FN="$FIX/fn_gate.sh";          extract '_assert_self_update_converged'  > "$GATE_FN"
LOOKUP_FN="$FIX/fn_lookup.sh";      extract '_lookup_expected_hash'          > "$LOOKUP_FN"
ALERT_FN="$FIX/fn_alert.sh";        extract '_self_update_converge_alert'    > "$ALERT_FN" || true
RSN_FN="$FIX/fn_rsn.sh";            extract '_host_script_remote_name'       > "$RSN_FN"
DIR_FN="$FIX/fn_dir.sh";            extract '_host_script_install_dir'       > "$DIR_FN"
MODE_FN="$FIX/fn_mode.sh";          extract '_host_script_mode'              > "$MODE_FN"

for pair in "$SHOULD_FN:_should_self_update" "$REEXEC_FN:_maybe_self_update_reexec" \
            "$GATE_FN:_assert_self_update_converged" "$LOOKUP_FN:_lookup_expected_hash" \
            "$RSN_FN:_host_script_remote_name" "$DIR_FN:_host_script_install_dir" \
            "$MODE_FN:_host_script_mode"; do
    f="${pair%%:*}"; sig="${pair##*:}"
    if [[ -s "$f" ]] && grep -q "^${sig}()" "$f" && bash -n "$f"; then
        pass "S1: extracted $sig() parses"
    else
        fail "S1: extraction of $sig() empty/unparseable — awk drifted"; exit 1
    fi
done

# The _HOST_SCRIPT_* arrays (pattern-extracted so a newly added array cannot
# silently vacate the journey — same idiom as test_upgrade_syncs_host_scripts).
ARRAYS_FN="$FIX/fn_arrays.sh"
awk '/^_HOST_SCRIPT_[A-Z_]+=\(/{f=1} f{print} f && /^\)$/{f=0}' "$UPGRADE" > "$ARRAYS_FN"
grep -q '_HOST_SCRIPT_SBIN_FILES=' "$ARRAYS_FN" \
    && pass "S2: extracted _HOST_SCRIPT_* arrays" || { fail "S2: array extraction empty"; exit 1; }

# ---------------------------------------------------------------------------
# Fixture: an installed OLD node (v9.9.8) + a release bundle (v9.9.9) whose
# host scripts changed. REPO_RAW (fixture://raw) serves the OLD tag's tree —
# the stale payload pillow actually got; RELEASES_BASE (fixture://rel) serves
# the new release's asset set + SHA256SUMS.
# ---------------------------------------------------------------------------
NODE="$FIX/node"
mkdir -p "$NODE/sbin" "$NODE/bin" "$NODE/etc" "$NODE/libdir" \
         "$NODE/share/oxpulse-partner-edge" "$NODE/systemd" "$NODE/lib" "$NODE/snap"
SBIN="$NODE/sbin"
STATE_FILE="$NODE/lib/install.env"
SHARE_VER="$NODE/share/oxpulse-partner-edge/VERSION"

printf 'IMAGE_VERSION=v9.9.8\nBACKEND_API=https://backend.example.invalid\n' > "$STATE_FILE"
printf '9.9.8\n' > "$SHARE_VER"
printf '#!/bin/bash\n# OLD channel-render-lib (v9.9.8)\n' > "$SBIN/channel-render-lib.sh"
printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:v9.9.8\n' \
    > "$NODE/etc/docker-compose.yml"

REL="$FIX/release/v9.9.9"; RAW="$FIX/raw"
mkdir -p "$REL" "$RAW"

# OLD-tag raw tree (what REPO_RAW serves when the running script is v9.9.8).
printf '#!/bin/bash\n# OLD channel-render-lib (v9.9.8)\n' > "$RAW/channel-render-lib.sh"
printf '9.9.8\n' > "$RAW/VERSION"

# NEW release assets (what the target tag's bundle carries).
printf '#!/bin/bash\n# NEW channel-render-lib (v9.9.9)\n' > "$REL/channel-render-lib.sh"
printf '9.9.9\n' > "$REL/VERSION"
printf '#!/bin/bash\n# NEW refresh (v9.9.9)\n' > "$REL/oxpulse-partner-edge-refresh.sh"
printf '[Timer]\nOnCalendar=daily\n' > "$REL/oxpulse-partner-edge-refresh.timer"

# ---------------------------------------------------------------------------
# Shared fixture-script preamble: stubs + all real functions. Emit into a file
# reused by both the "old" (running) and "new" (release-asset) wrappers.
# ---------------------------------------------------------------------------
PREAMBLE="$FIX/preamble.sh"
{
    cat <<'STUBS'
#!/bin/bash
set -uo pipefail
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n' "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
RETRY_OPTS=()
# Offline curl stub: fixture://rel/<path> -> $FIX_RELEASE/<path>,
# fixture://raw/<path> -> $FIX_RAW/<path>. The FIRST fetch of
# */partner-edge-upgrade.sh fails — the pillow re-exec bail (a transient
# failure the warn()-and-continue path covers); later fetches serve.
curl() {
    local out="" url="" i a=("$@")
    for ((i=0; i<${#a[@]}; i++)); do
        case "${a[i]}" in
            -o) out="${a[i+1]}" ;;
            *"://"*) url="${a[i]}" ;;
        esac
    done
    local path="${url#*://*/}"
    case "$url" in
        fixture://rel/*)
            if [[ "$path" == */partner-edge-upgrade.sh ]]; then
                local cf="$FIX_COUNT_FILE" n=0
                [[ -f "$cf" ]] && n=$(cat "$cf" 2>/dev/null || echo 0)
                n=$((n + 1)); printf '%s' "$n" > "$cf"
                [[ "$n" -eq 1 ]] && return 1
            fi
            [[ -f "$FIX_RELEASE/$path" ]] && { cp -f "$FIX_RELEASE/$path" "$out"; return 0; }
            return 1 ;;
        fixture://raw/*)
            [[ -f "$FIX_RAW/$path" ]] && { cp -f "$FIX_RAW/$path" "$out"; return 0; }
            return 1 ;;
        *) return 1 ;;
    esac
}
STUBS
    cat "$LOOKUP_FN" "$SHOULD_FN" "$REEXEC_FN" "$GATE_FN" "$ALERT_FN"
    cat "$ARRAYS_FN" "$RSN_FN" "$DIR_FN" "$MODE_FN"
    cat "$HSL"
    cat <<'TAIL'
# Faithful minimal copy of the real apply-path ordering under test
# (reexec -> snapshot -> sync -> gate -> version markers). The ordering is
# asserted structurally against upgrade.sh itself in J4; this tail only has
# to reproduce it, not define it.
_apply_tail() {
    _maybe_self_update_reexec "$@"
    snapshot_host_scripts "$CURRENT" || true
    log "syncing host-scripts to $RELEASE_TAG (image tag=$TARGET)"
    sync_host_scripts "$RELEASE_TAG"
    _assert_self_update_converged "$@"
    sed -i -E "s|(ghcr\.io/anatolykoptev/partner-edge-[a-z]+):[^\"[:space:]]+|\1:${TARGET}|g" "$COMPOSE_FILE"
    sed -i -E "s|^IMAGE_VERSION=.*|IMAGE_VERSION=${TARGET}|" "$STATE_FILE"
}
TAIL
} > "$PREAMBLE"
bash -n "$PREAMBLE" || { fail "preamble syntax"; exit 1; }

# The NEW ("released") upgrade.sh: same real code; its tail marks the child ran.
CHILD="$REL/partner-edge-upgrade.sh"
{
    cat "$PREAMBLE"
    cat <<'CHILDTAIL'
TARGET=v9.9.9; RELEASE_TAG=v9.9.9; MODE=apply; DRY_RUN=0
CURRENT="${IMAGE_VERSION:-unknown}"
_apply_tail "$@"
printf 'CHILD_DONE reexeced=%s args=%s\n' "${OXPULSE_UPGRADE_REEXECED:-0}" "$*" > "$FIX_CHILD_MARKER"
CHILDTAIL
} > "$CHILD"
chmod 0755 "$CHILD"

# The OLD ("running"/installed) upgrade.sh: same real code, stale bytes marker.
PARENT="$SBIN/oxpulse-partner-edge-upgrade"
{
    cat "$PREAMBLE"
    cat <<'PARENTTAIL'
TARGET=v9.9.9; RELEASE_TAG=v9.9.9; MODE=apply; DRY_RUN=0
CURRENT="${IMAGE_VERSION:-unknown}"
_apply_tail "$@"
printf 'PARENT_DONE\n' >&2
PARENTTAIL
} > "$PARENT"
chmod 0755 "$PARENT"

# SHA256SUMS for the release fixture — real hashes of the served assets.
{
    (cd "$REL" && sha256sum partner-edge-upgrade.sh channel-render-lib.sh \
        VERSION oxpulse-partner-edge-refresh.sh oxpulse-partner-edge-refresh.timer)
} > "$REL/SHA256SUMS"

# ---------------------------------------------------------------------------
# J1 — THE JOURNEY: old install + release with changed host scripts + a re-exec
#      that does NOT fire (first-asset-fetch failure). ONE upgrade run must
#      converge to the new version anyway.
# ---------------------------------------------------------------------------
echo ""
echo "--- J1: one self-upgrade run converges despite a failed re-exec ---"

env -i PATH="$PATH" HOME="$HOME" \
    FIX_RELEASE="$FIX/release" FIX_RAW="$FIX/raw" \
    FIX_COUNT_FILE="$FIX/fetch_count" FIX_CHILD_MARKER="$FIX/child_ran" \
    RELEASES_BASE="fixture://rel" REPO_RAW="fixture://raw" \
    PREFIX_SBIN="$SBIN" PREFIX_BIN="$NODE/bin" PREFIX_LIBDIR="$NODE/libdir" \
    PREFIX_ETC="$NODE/etc" PREFIX_SHARE="$NODE/share" \
    PREV_HOST_SCRIPTS_DIR="$NODE/snap" \
    SYSTEMD_DIR="$NODE/systemd" SYSTEMCTL_BIN=true \
    STATE_FILE="$STATE_FILE" COMPOSE_FILE="$NODE/etc/docker-compose.yml" \
    IMAGE_VERSION=v9.9.8 \
    OXPULSE_INSTALLED_UPGRADE_PATH="$PARENT" \
    bash "$PARENT" v9.9.9 > "$FIX/j1_out" 2>&1 && J1_RC=0 || J1_RC=$?

if [[ "$J1_RC" -eq 0 ]] && [[ -f "$FIX/child_ran" ]] \
    && grep -q 'CHILD_DONE reexeced=1' "$FIX/child_ran"; then
    pass "J1a: gate re-exec'd the freshly installed release script (child ran, rc=0)"
else
    fail "J1a: run did not converge — rc=$J1_RC child_marker=$( [[ -f "$FIX/child_ran" ]] && cat "$FIX/child_ran" || echo absent ); output: $(cat "$FIX/j1_out")"
fi

# The re-exec must have happened at the GATE, not the early self-update step:
# the first-asset-fetch failure is what skipped the early re-exec.
grep -q 're-exec' "$FIX/j1_out" \
    && pass "J1b: a re-exec step logged in the run" \
    || fail "J1b: no re-exec evidence in output: $(cat "$FIX/j1_out")"

# Changed host scripts must carry the NEW release bytes (the pillow skip).
grep -q 'NEW channel-render-lib (v9.9.9)' "$SBIN/channel-render-lib.sh" \
    && pass "J1c: channel-render-lib.sh converged to the target release bytes" \
    || fail "J1c: channel-render-lib.sh left at old bytes: $(cat "$SBIN/channel-render-lib.sh")"

grep -q '^9.9.9$' "$SHARE_VER" \
    && pass "J1d: share VERSION converged to 9.9.9" \
    || fail "J1d: share VERSION = $(cat "$SHARE_VER")"

grep -q '^IMAGE_VERSION=v9.9.9$' "$STATE_FILE" \
    && pass "J1e: install.env IMAGE_VERSION written on convergence" \
    || fail "J1e: IMAGE_VERSION = $(grep '^IMAGE_VERSION=' "$STATE_FILE" || echo missing)"

# No payload file may be left at the OLD tag's bytes after a converged sync.
if grep -q 'v9.9.8' "$SBIN/channel-render-lib.sh" "$SHARE_VER" 2>/dev/null; then
    fail "J1f: old-tag bytes survived a converged sync"
else
    pass "J1f: no old-tag bytes left behind by the sync"
fi

# ---------------------------------------------------------------------------
# J2 — scoped: under an armed sha guard the sbin payload must come from the
#      TARGET release bundle, not REPO_RAW. Asserts the fetch origin itself:
#      with the fixture, a REPO_RAW fetch yields OLD bytes that fail the sha
#      guard, so 'MISMATCH' in the log == the wrong origin was used.
# ---------------------------------------------------------------------------
echo ""
echo "--- J2: verified sync fetches payload from the target release bundle ---"

J2_SBIN="$FIX/j2/sbin"; mkdir -p "$J2_SBIN"
printf '#!/bin/bash\n# STALE installed channel-render-lib\n' > "$J2_SBIN/channel-render-lib.sh"
: > "$FIX/count2"
J2_OUT=$(
    env FIX_RELEASE="$FIX/release" FIX_RAW="$FIX/raw" FIX_COUNT_FILE="$FIX/count2" \
        RELEASES_BASE="fixture://rel" REPO_RAW="fixture://raw" \
        PREFIX_SBIN="$J2_SBIN" PREFIX_BIN="$FIX/j2/bin" PREFIX_LIBDIR="$FIX/j2/libdir" \
        PREFIX_ETC="$FIX/j2/etc" PREFIX_SHARE="$FIX/j2/share" \
        SYSTEMD_DIR="$FIX/j2/systemd" SYSTEMCTL_BIN=true \
        STATE_FILE=/dev/null DRY_RUN=0 \
        bash -c "source '$PREAMBLE'; sync_host_scripts v9.9.9" 2>&1
) || true
if grep -q 'NEW channel-render-lib (v9.9.9)' "$J2_SBIN/channel-render-lib.sh" \
    && ! grep -q 'MISMATCH for channel-render-lib' <<<"$J2_OUT"; then
    pass "J2: changed file verified + installed from the target release bundle (no wrong-origin skip)"
else
    fail "J2: target-tag payload not used — $(grep -c 'MISMATCH' <<<"$J2_OUT" || true) mismatches, installed: $(cat "$J2_SBIN/channel-render-lib.sh"); out: $J2_OUT"
fi

# ---------------------------------------------------------------------------
# J3 — the gate still dies LOUD when even the installed re-exec cannot run
#      (broken installed bytes): die + alert attempt, never a silent proceed.
# ---------------------------------------------------------------------------
echo ""
echo "--- J3: terminal gate failure still dies + alerts ---"

GATE_WRAP="$FIX/gate_wrap"
{
    cat <<'PRE'
#!/bin/bash
set -uo pipefail
log(){ :; }
warn(){ echo "WARN: $*" >&2; }
die(){ echo "DIE: $1" >&2; exit 1; }
RETRY_OPTS=()
_self_update_converge_alert(){ echo "ALERT: $1" >&2; }
PRE
    cat "$LOOKUP_FN" "$SHOULD_FN" "$GATE_FN"
    printf '_assert_self_update_converged "$@"\n'
    printf 'echo "GATE_SURVIVED"\n'
} > "$GATE_WRAP"
chmod +x "$GATE_WRAP"
GATE_WRAP_SHA=$(sha256sum "$GATE_WRAP" | awk '{print $1}')
ZERO_SHA="0000000000000000000000000000000000000000000000000000000000000000"

# Divergent + the installed copy cannot even exec (EACCES) -> alert + die. The
# non-exec copy must BE the running path for _should_self_update's realpath
# match (same file in both roles — production shape).
J3_INST="$FIX/gate_wrap_noexec"
cp "$GATE_WRAP" "$J3_INST"; chmod 0644 "$J3_INST"
J3_OUT=$(env RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 PREFIX_SBIN="$FIX" \
    OXPULSE_INSTALLED_UPGRADE_PATH="$J3_INST" \
    OXPULSE_UPGRADE_PRESYNC_RUNNING_SHA="$ZERO_SHA" \
    bash "$J3_INST" v9.9.9 2>&1 || true)
if grep -q 'DIE: self-update did not converge' <<<"$J3_OUT" \
    && grep -q 'ALERT:' <<<"$J3_OUT" \
    && ! grep -q 'GATE_SURVIVED' <<<"$J3_OUT"; then
    pass "J3: unrecoverable divergence dies with the alert fired"
else
    fail "J3: expected alert + die on unrecoverable divergence; got: $J3_OUT"
fi

# Escape hatch still converts the divergence to warn+proceed.
J3B_OUT=$(env RELEASE_TAG=v9.9.9 MODE=apply DRY_RUN=0 PREFIX_SBIN="$FIX" \
    OXPULSE_INSTALLED_UPGRADE_PATH="$GATE_WRAP" \
    OXPULSE_UPGRADE_PRESYNC_RUNNING_SHA="$ZERO_SHA" \
    OXPULSE_UPGRADE_NO_CONVERGE_GATE=1 \
    bash "$GATE_WRAP" v9.9.9 2>&1 || true)
if grep -q 'WARN: self-update did NOT converge' <<<"$J3B_OUT" \
    && grep -q 'GATE_SURVIVED' <<<"$J3B_OUT"; then
    pass "J3b: OXPULSE_UPGRADE_NO_CONVERGE_GATE=1 still downgrades to warn+proceed"
else
    fail "J3b: escape hatch broken; got: $J3B_OUT"
fi

# ---------------------------------------------------------------------------
# J4 — structural: in BOTH apply paths the version-marker writes
#      (IMAGE_VERSION sed + compose image-tag sed) sit AFTER the convergence
#      gate. A gate that fires before the marker is what made pillow report
#      "installed=0.16.41" while running 0.16.40 — and what would make a
#      re-exec'd child see CURRENT==TARGET and exit "nothing to do".
# ---------------------------------------------------------------------------
echo ""
echo "--- J4: version markers are written only after the convergence gate ---"

gate_lines=$(grep -nE '^[[:space:]]*_assert_self_update_converged( |$)' "$UPGRADE" | cut -d: -f1)
first_gate=$(printf '%s\n' "$gate_lines" | sort -n | sed -n '1p')
last_gate=$(printf '%s\n' "$gate_lines" | sort -n | tail -1)
# No marker sed may appear BEFORE the first gate; each marker must appear at
# least once AFTER the last gate.
iv_pre=$(grep -nE 'sed -i -E "s\|\^IMAGE_VERSION=' "$UPGRADE" | awk -F: -v g="$first_gate" '$1<g{n++}END{print n+0}')
iv_post=$(grep -nE 'sed -i -E "s\|\^IMAGE_VERSION=' "$UPGRADE" | awk -F: -v g="$last_gate" '$1>g{n++}END{print n+0}')
comp_pre=$(grep -nE 'sed -i -E "s\|\(ghcr' "$UPGRADE" | awk -F: -v g="$first_gate" '$1<g{n++}END{print n+0}')
comp_post=$(grep -nE 'sed -i -E "s\|\(ghcr' "$UPGRADE" | awk -F: -v g="$last_gate" '$1>g{n++}END{print n+0}')
if [[ "$iv_pre" -eq 0 && "$comp_pre" -eq 0 && "$iv_post" -ge 1 && "$comp_post" -ge 1 ]]; then
    pass "J4: IMAGE_VERSION + compose tag seds sit after the convergence gate in both apply paths"
else
    fail "J4: marker placement wrong (iv_pre=$iv_pre comp_pre=$comp_pre iv_post=$iv_post comp_post=$comp_post; gates: $gate_lines)"
fi

# Both gate call sites must pass the original args through for the re-exec.
gate_with_args=$(grep -cE '^[[:space:]]*_assert_self_update_converged "\$@"' "$UPGRADE" || true)
[[ "$gate_with_args" -eq 2 ]] \
    && pass "J4b: both apply paths call the gate with \"\$@\" (re-exec args preserved)" \
    || fail "J4b: expected 2 gate call sites passing \"\$@\", got $gate_with_args"

# The gate must exec the installed copy, not just die.
grep -q 'exec "$_installed" "$@"' "$UPGRADE" \
    && pass "J4c: gate re-execs the installed verified copy" \
    || fail "J4c: gate has no re-exec of \$_installed — divergence can only die"

# ---------------------------------------------------------------------------
# J5 — refresh-side retry: _maybe_self_upgrade records the attempted desired
#      tag; a re-attempt of the same tag emits partner_edge_self_upgrade_retry_total
#      and the marker clears once desired==installed.
# ---------------------------------------------------------------------------
echo ""
echo "--- J5: refresh retries a failed self-upgrade visibly ---"

L2="$FIX/l2.sh"
{
    echo 'log() { printf "==> %s\n" "$*" >&2; }'
    echo 'emit_metric() { printf "METRIC %s\n" "$1" >> "$METRICS"; }'
    echo 'emit_gauge() { printf "GAUGE %s\n" "$1" >> "$METRICS"; }'
    awk '/^_self_upgrade_is_ge\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
    awk '/^_maybe_self_upgrade\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH"
} > "$L2"
bash -n "$L2" || { fail "J5: refresh extract syntax"; exit 1; }

J5_BIN="$FIX/j5bin"; mkdir -p "$J5_BIN"
cat > "$J5_BIN/oxpulse-partner-edge-upgrade" <<STUB
#!/usr/bin/env bash
exit 0
STUB
cat > "$J5_BIN/systemd-run" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$FIX/j5_sdrun"
exit 0
STUB
cat > "$J5_BIN/systemctl" <<STUB
#!/usr/bin/env bash
[ "\$1" = show ] && echo inactive
exit 0
STUB
chmod +x "$J5_BIN/oxpulse-partner-edge-upgrade" "$J5_BIN/systemd-run" "$J5_BIN/systemctl"

J5_LIB="$FIX/j5lib"; mkdir -p "$J5_LIB"
printf 'IMAGE_VERSION=v9.9.8\n' > "$J5_LIB/install.env"

run_l2() {  # $1=desired_release
    METRICS="$FIX/j5_metrics"; : > "$METRICS"
    ( set -euo pipefail; export PATH="$J5_BIN:$PATH" PREFIX_LIB="$J5_LIB" METRICS
      source "$L2"; _maybe_self_upgrade 200 "{\"desired_release\":\"$1\"}" ) 2>&1
}

run_l2 "9.9.9" >/dev/null 2>&1 || true
run_l2 "9.9.9" > "$FIX/j5_out2" 2>&1 || true
if grep -q 'self_upgrade_retry' "$FIX/j5_metrics" \
    && grep -q 'retry' "$FIX/j5_out2"; then
    pass "J5a: a re-attempt of the same desired tag is logged + metered (never silent)"
else
    fail "J5a: no retry signal on re-attempt; metrics: $(cat "$FIX/j5_metrics" 2>/dev/null); out: $(cat "$FIX/j5_out2")"
fi

# Simulate convergence: installed catches up -> marker clears, no retry metric.
printf 'IMAGE_VERSION=v9.9.9\n' > "$J5_LIB/install.env"
run_l2 "9.9.9" >/dev/null 2>&1 || true
if ! grep -q 'self_upgrade_retry' "$FIX/j5_metrics"; then
    pass "J5b: converged state emits no retry metric (marker cleared)"
else
    fail "J5b: retry metric still emitted after convergence"
fi

echo ""
echo "=== self-upgrade converge journey: $PASS passed, $FAIL failed ==="
[[ "$FAIL" -eq 0 ]]
