#!/bin/bash
# tests/test_upgrade_converges_systemd_units.sh
#
# sync_host_scripts must converge a node's systemd surface: deliver the
# TEMPLATED units it could never deliver before, and bring the managed set to
# ENABLED — without disabling anything and without starting the compose unit
# mid-upgrade.
#
# Measured cause (fleet fingerprint, 2026-08-07, 5 of 5 nodes, 86 axes):
#   • oxpulse-partner-cert-watch.{path,service} carry {{TURNS_SUBDOMAIN}} and
#     {{PARTNER_DOMAIN}} placeholders, so they were excluded from the verbatim
#     checksum-copy loop and shipped ONLY by a fresh install. rvpn-seed and
#     zvonilka-cc7cf842800b have never had them — a renewed TURNS certificate
#     never signals coturn on either box.
#   • Nothing on any apply path ever ran `systemctl enable`. The same two nodes
#     have oxpulse-partner-edge.service DISABLED: their containers do not come
#     back after a reboot.
#
# Runs the REAL sync_host_scripts out of lib/host-scripts-lib.sh against a
# local HTTP fixture and a systemctl stub that records every invocation, in the
# harness pattern established by tests/test_upgrade_syncs_host_scripts.sh.
#
# Asserts:
#   E1: cert-watch units are installed, with both placeholders substituted.
#   E2: no "{{" survives in any installed unit.
#   E3: TURNS_SUBDOMAIN absent -> units NOT installed, and the reason is logged
#       (fail-closed: an inert watcher reads as converged, an absent one does not).
#   E4: a disabled managed unit is enabled, and is-enabled is re-checked after.
#   E5: oxpulse-partner-edge.service is enabled but NEVER started (`--now`/start)
#       — it is `docker compose up -d`, and this runs before the image pull.
#   E6: .timer and .path units ARE started, so they arm without a reboot.
#   E7: `systemctl disable` is never invoked, for any unit.
#   E8: an unmanaged unit enabled by the operator (split-routing, cheburator's
#       RU profile) is left untouched.
#   E9: a second run is a no-op — no repeat enable for already-enabled units.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
LIB="$REPO_ROOT/lib/host-scripts-lib.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

for f in "$UPGRADE" "$LIB"; do
    [[ -f "$f" ]] || { echo "FAIL: $f not found"; exit 1; }
done

bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }
bash -n "$LIB"     || { echo "FAIL: host-scripts-lib.sh has syntax errors"; exit 1; }

# 18775 belongs to test_upgrade_self_update_converge.sh — ports are hand-picked
# across this suite, so check before claiming one.
SERVE_PORT=18781
python3 -m http.server "$SERVE_PORT" --directory "$REPO_ROOT" \
    >/tmp/test-unit-converge-httpd.log 2>&1 &
HTTP_PID=$!

TMPROOT=$(mktemp -d)
cleanup() { kill "$HTTP_PID" 2>/dev/null || true; rm -rf "$TMPROOT"; }
trap cleanup EXIT

sleep 1
curl -fsSL --max-time 5 \
    "http://127.0.0.1:$SERVE_PORT/systemd/oxpulse-partner-cert-watch.path" >/dev/null \
    || { echo "FAIL: fixture HTTP server not serving systemd/ units"; exit 1; }

# ---------------------------------------------------------------------------
# Preamble: the arrays + helpers from upgrade.sh, then the real lib. Its
# same-named definitions land last and win over the lazy-source forwarders,
# so sync_host_scripts below is the actual implementation.
#
# Arrays are extracted by PATTERN, not by name: a hand-listed extraction is the
# same defect class this whole file exists to close — a new _HOST_SCRIPT_* array
# would be silently absent, expand to nothing, and every assertion below would
# pass having exercised nothing.
# ---------------------------------------------------------------------------
PREAMBLE="$TMPROOT/preamble.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
PREFIX_BIN="${PREFIX_BIN:-/usr/local/bin}"
HELPERS
    awk '/^_HOST_SCRIPT_[A-Z_]+=\(/{f=1} f{print} f&&/^\)$/{f=0}' "$UPGRADE"
    awk '/^_host_script_remote_name\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_install_dir\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    awk '/^_host_script_mode\(\)/{found=1} found{print} /^}$/ && found{exit}' "$UPGRADE"
    cat "$LIB"
} > "$PREAMBLE"

bash -n "$PREAMBLE" || { echo "FAIL: extracted preamble has syntax errors"; exit 1; }

# Preamble fitness: the three arrays this file reasons about must be in it.
for arr in _HOST_SCRIPT_SYSTEMD_FILES _HOST_SCRIPT_SYSTEMD_TEMPLATED_FILES _HOST_SCRIPT_ENABLE_UNITS; do
    grep -q "^${arr}=(" "$PREAMBLE" \
        || { echo "FAIL: preamble is missing $arr — every assertion below would be vacuous"; exit 1; }
done

# ---------------------------------------------------------------------------
# systemctl stub: records argv, answers is-enabled from a state dir.
# ---------------------------------------------------------------------------
STUB="$TMPROOT/systemctl"
cat > "$STUB" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
    is-enabled)
        u="${1:-}"
        if [[ -f "$SYSTEMCTL_STATE/$u" ]]; then cat "$SYSTEMCTL_STATE/$u"; exit 0; fi
        exit 1
        ;;
    enable)
        for u in "$@"; do
            [[ "$u" == --* ]] && continue
            printf 'enabled\n' > "$SYSTEMCTL_STATE/$u"
        done
        ;;
    disable)
        for u in "$@"; do
            [[ "$u" == --* ]] && continue
            printf 'disabled\n' > "$SYSTEMCTL_STATE/$u"
        done
        ;;
esac
exit 0
STUB
chmod +x "$STUB"

TURNS=api-deadbe
DOMAIN=edge.example.net

# run_sync <case-dir> [env assignments...] — returns combined output.
# Each case gets its own SYSTEMD_DIR, systemctl state, and call log.
run_sync() {
    local case_dir="$1"; shift
    mkdir -p "$case_dir"/{sbin,bin,libdir,systemd,state,etc,share}
    : > "$case_dir/systemctl.log"
    env \
        PREFIX_SBIN="$case_dir/sbin" \
        PREFIX_BIN="$case_dir/bin" \
        PREFIX_LIBDIR="$case_dir/libdir" \
        PREFIX_ETC="$case_dir/etc" \
        PREFIX_SHARE="$case_dir/share" \
        SYSTEMD_DIR="$case_dir/systemd" \
        SYSTEMCTL_BIN="$STUB" \
        SYSTEMCTL_LOG="$case_dir/systemctl.log" \
        SYSTEMCTL_STATE="$case_dir/state" \
        REPO_RAW="http://127.0.0.1:$SERVE_PORT" \
        RELEASES_BASE="http://127.0.0.1:$SERVE_PORT/NOSUCHRELEASE" \
        ALLOW_UNVERIFIED=1 \
        DRY_RUN=0 \
        STATE_FILE="$case_dir/install.env" \
        "$@" \
        bash -c "source '$PREAMBLE'; sync_host_scripts v0.99.0-test" 2>&1
}

# ---------------------------------------------------------------------------
# Case A: full convergence from a bare node.
# ---------------------------------------------------------------------------
echo ""
echo "=== Case A: bare node — deliver templated units, enable the managed set ==="

A="$TMPROOT/a"
mkdir -p "$A"
cat > "$A/install.env" <<EOF
PARTNER_DOMAIN=$DOMAIN
TURNS_SUBDOMAIN=$TURNS
BACKEND_API=https://api.oxpulse.chat
EOF

# The operator's own choice, which convergence must not touch (E8).
mkdir -p "$A/state"
printf 'enabled\n' > "$A/state/oxpulse-partner-edge-split-routing.service"

OUT_A=$(run_sync "$A") && RC_A=0 || RC_A=$?
[[ $RC_A -eq 0 ]] && pass "A0: sync_host_scripts exited 0" \
                  || fail "A0: sync_host_scripts exited $RC_A; output: $OUT_A"

# --- E1: cert-watch units installed with placeholders resolved --------------
cw_path="$A/systemd/oxpulse-partner-cert-watch.path"
cw_svc="$A/systemd/oxpulse-partner-cert-watch.service"

if [[ -f "$cw_path" && -f "$cw_svc" ]]; then
    pass "E1a: both cert-watch units installed by the upgrade path"
else
    fail "E1a: cert-watch units missing after sync (path=$([[ -f $cw_path ]] && echo yes || echo no) service=$([[ -f $cw_svc ]] && echo yes || echo no))"
fi

if grep -qF "$TURNS.$DOMAIN" "$cw_path" 2>/dev/null; then
    pass "E1b: {{TURNS_SUBDOMAIN}}/{{PARTNER_DOMAIN}} substituted from STATE"
else
    fail "E1b: rendered .path does not contain '$TURNS.$DOMAIN' — substitution did not happen"
fi

# --- E2: no unresolved placeholder in ANY installed unit --------------------
resid=""
for u in "$A"/systemd/*; do
    [[ -f "$u" ]] || continue
    grep -qF '{{' "$u" && resid="$resid $(basename "$u")"
done
if [[ -z "$resid" ]]; then
    pass "E2: no unresolved {{placeholder}} in any installed unit"
else
    fail "E2: units installed with unresolved placeholders:$resid"
fi

# --- E4 / E5 / E6: enable + start policy -----------------------------------
LOG_A="$A/systemctl.log"

enabled_missing=""
while IFS= read -r u; do
    [[ -n "$u" ]] || continue
    grep -qx "enable $u" "$LOG_A" || enabled_missing="$enabled_missing $u"
done < <(awk '
    /^_HOST_SCRIPT_ENABLE_UNITS=\(/ { inarr=1; next }
    inarr && /^\)/ { exit }
    inarr { sub(/#.*/, ""); gsub(/[[:space:]]/, ""); if (length($0)) print }
' "$UPGRADE")

if [[ -z "$enabled_missing" ]]; then
    pass "E4a: every managed unit was enabled"
else
    fail "E4a: managed units never enabled:$enabled_missing"
fi

# is-enabled must be consulted AFTER enable (IR-5: exit 0 is not evidence).
if awk '/^enable oxpulse-partner-edge.service$/{seen=1} seen && /^is-enabled oxpulse-partner-edge.service$/{found=1} END{exit !found}' "$LOG_A"; then
    pass "E4b: is-enabled re-checked after enable (IR-5 verification)"
else
    fail "E4b: no is-enabled call follows the enable — an enable that silently did nothing would read as success"
fi

if grep -qE '^(start|enable --now) oxpulse-partner-edge\.service$' "$LOG_A"; then
    fail "E5: oxpulse-partner-edge.service was STARTED — it is 'docker compose up -d', and this runs before the image pull; that composes up against tags not on the box yet"
else
    pass "E5: oxpulse-partner-edge.service enabled but never started"
fi

started_missing=""
for u in oxpulse-partner-cert-watch.path oxpulse-partner-edge-refresh.timer \
         oxpulse-xray-update.timer oxpulse-geoip-refresh.timer; do
    grep -qx "start $u" "$LOG_A" || started_missing="$started_missing $u"
done
if [[ -z "$started_missing" ]]; then
    pass "E6: timer and path units started, so they arm without a reboot"
else
    fail "E6: timer/path units enabled but never started:$started_missing — a newly-enabled timer does nothing until the next boot"
fi

# --- E7: never disable -----------------------------------------------------
if grep -qE '^disable ' "$LOG_A"; then
    fail "E7: systemctl disable was invoked — convergence must be enable-only: $(grep -E '^disable ' "$LOG_A" | tr '\n' ' ')"
else
    pass "E7: systemctl disable never invoked"
fi

# --- E8: unmanaged operator choice survives --------------------------------
if [[ "$(cat "$A/state/oxpulse-partner-edge-split-routing.service")" == "enabled" ]]; then
    pass "E8: operator-enabled split-routing left untouched (manifest: unmanaged)"
else
    fail "E8: split-routing state changed — cheburator's RU profile would be torn down on its next upgrade"
fi

# ---------------------------------------------------------------------------
# Case B: STATE has no TURNS_SUBDOMAIN — fail closed.
# ---------------------------------------------------------------------------
echo ""
echo "=== Case B: TURNS_SUBDOMAIN absent — refuse rather than install an inert unit ==="

B="$TMPROOT/b"
mkdir -p "$B"
cat > "$B/install.env" <<EOF
PARTNER_DOMAIN=$DOMAIN
BACKEND_API=https://api.oxpulse.chat
EOF

OUT_B=$(run_sync "$B" TURNS_SUBDOMAIN= ) && RC_B=0 || RC_B=$?
[[ $RC_B -eq 0 ]] && pass "B0: sync_host_scripts still exited 0 (a missing optional surface is not an upgrade failure)" \
                  || fail "B0: sync_host_scripts exited $RC_B; output: $OUT_B"

if [[ -f "$B/systemd/oxpulse-partner-cert-watch.path" ]]; then
    fail "E3a: cert-watch .path installed with no TURNS_SUBDOMAIN — it would watch a path ending in '..crt' forever while systemctl reports it enabled"
else
    pass "E3a: cert-watch unit NOT installed when it cannot be rendered"
fi

if [[ "$OUT_B" == *TURNS_SUBDOMAIN* ]]; then
    pass "E3b: the refusal names the missing key"
else
    fail "E3b: nothing in the output explains why the unit is absent; output: $OUT_B"
fi

if grep -qx "enable oxpulse-partner-cert-watch.path" "$B/systemctl.log"; then
    fail "E3c: enable attempted on a unit that was never installed"
else
    pass "E3c: no enable attempted for the undeliverable unit"
fi

# ---------------------------------------------------------------------------
# Case C: idempotency — a second run enables nothing again.
#
# _probe_opec_for_upgrade calls sync_host_scripts a second time within one
# upgrade, so a non-idempotent enable step would churn systemd every run.
# ---------------------------------------------------------------------------
echo ""
echo "=== Case C: second run is a no-op ==="

OUT_C=$(run_sync "$A") && RC_C=0 || RC_C=$?
[[ $RC_C -eq 0 ]] && pass "C0: second sync exited 0" \
                  || fail "C0: second sync exited $RC_C; output: $OUT_C"

reenabled=$(grep -cE '^enable ' "$A/systemctl.log" || true)
if [[ "$reenabled" -eq 0 ]]; then
    pass "E9: no unit re-enabled on the second run (already converged)"
else
    fail "E9: $reenabled enable call(s) on an already-converged node: $(grep -E '^enable ' "$A/systemctl.log" | tr '\n' ' ')"
fi

echo ""
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: all $PASS systemd-convergence checks passed"
    exit 0
else
    echo "FAIL: $FAIL of $((PASS+FAIL)) systemd-convergence checks failed"
    exit 1
fi
