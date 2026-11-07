#!/usr/bin/env bash
# Edge side of the two-phase VLESS uuid rotation (partner-cli rotate-reality-uuid):
#   refresh.sh  _reconcile_served_uuid  — detect served != rendered, start the gated re-render
#   upgrade.sh  --render-only           — gated re-render + outcome check (uuid actually applied)
# Plain-bash extract-and-stub idiom of tests/test_fleet_self_upgrade.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
REFRESH="$ROOT/oxpulse-partner-edge-refresh.sh"
UPGRADE="$ROOT/upgrade.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

U_OLD="a1b2c3d4-e5f6-4789-a012-b3c4d5e6f7a8"
U_NEW="fae87c2c-de37-4997-bb6f-3feb05dc6bf0"

bash -n "$REFRESH" && bash -n "$UPGRADE" && pass "A0: scripts parse" || { fail "A0: syntax"; exit 1; }

TMPD=$(mktemp -d)
[ -n "$TMPD" ] && [ -d "$TMPD" ] || { echo "mktemp failed"; exit 1; }
trap 'rm -r "${TMPD:?}"' EXIT
BIN="$TMPD/bin"; mkdir -p "$BIN"

# ── extract the refresh function ───────────────────────────────────────────────
FN="$TMPD/fn.sh"
awk '/^_reconcile_served_uuid\(\)/{f=1} f{print} /^}$/ && f{exit}' "$REFRESH" > "$FN"
[ -s "$FN" ] && bash -n "$FN" && pass "A1: _reconcile_served_uuid extracted" || { fail "A1: extract"; exit 1; }

# ── stubs ──────────────────────────────────────────────────────────────────────
# curl: serves served.json; fails when CURL_FAIL=1
cat > "$BIN/curl" <<STUB
#!/usr/bin/env bash
[ "\${CURL_FAIL:-0}" = 1 ] && exit 22
cat "$TMPD/served.json"
STUB
# systemd-run: records argv
cat > "$BIN/systemd-run" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMPD/sdrun"
exit "\${SDRUN_RC:-0}"
STUB
# systemctl show -p ActiveState --value <unit>: state from STATE_<unit, dashes → underscores>
cat > "$BIN/systemctl" <<STUB
#!/usr/bin/env bash
if [ "\$1" = show ]; then
  unit="\${@: -1}"; unit="\${unit%.service}"; var="STATE_\${unit//-/_}"
  echo "\${!var:-inactive}"
fi
exit 0
STUB
chmod +x "$BIN/curl" "$BIN/systemd-run" "$BIN/systemctl"

reset_dir() { rm -f "${TMPD:?}/sdrun" "${TMPD:?}/gauge" "${TMPD:?}/out"; rm -r "${TMPD:?}/etc" "${TMPD:?}/lib" 2>/dev/null; mkdir -p "${TMPD:?}/etc" "${TMPD:?}/lib"; }

setup_node() {  # $1=rendered uuid, $2=served uuid, $3=reality.uuid content ("" → no file)
    reset_dir
    printf 'stkn_test\n' > "$TMPD/etc/token"
    printf '{"outbounds":[{"settings":{"vnext":[{"users":[{"id":"%s"}]}]}}]}\n' "$1" > "$TMPD/etc/xray-client.json"
    printf '{"node_id":"n1","reality_uuid":"%s"}\n' "$2" > "$TMPD/served.json"
    if [ -n "$3" ]; then printf '%s\n' "$3" > "$TMPD/etc/reality.uuid"; chmod 600 "$TMPD/etc/reality.uuid"; fi
    return 0
}

run_fn() {  # runs the function in a subshell with stubs; its log goes to $TMPD/out
    (
        export PATH="$BIN:$PATH"
        PREFIX_ETC="$TMPD/etc"; PREFIX_LIB="$TMPD/lib"; PREFIX_SBIN="$ROOT"
        NODE_ID="n1"; BACKEND_URL="https://hub.invalid"
        log() { printf '%s\n' "$*"; }
        emit_gauge() { printf '%s=%s\n' "$1" "$3" >> "$TMPD/gauge"; }
        emit_metric() { printf 'METRIC %s\n' "$1" >> "$TMPD/gauge"; }
        write_secret_atomic() { printf '%s' "$2" > "$1" && chmod "$3" "$1"; }
        # shellcheck disable=SC1090
        source "$FN"
        _reconcile_served_uuid
    ) > "$TMPD/out" 2>&1
}
sdrun_count() { if [ -f "$TMPD/sdrun" ]; then wc -l < "$TMPD/sdrun" | tr -d ' '; else echo 0; fi; }

echo "=== refresh: _reconcile_served_uuid ==="
# D1 — drift → one gated re-render, via --render-only, as its own unit; no uuid in the log
setup_node "$U_OLD" "$U_NEW" ""
run_fn
[ "$(sdrun_count)" = 1 ] && pass "D1a: drift starts exactly one transient unit" || fail "D1a: drift did not start the gated re-render (count=$(sdrun_count))"
grep -q -e '--render-only' "$TMPD/sdrun" 2>/dev/null && pass "D1b: it runs the upgrade script with --render-only" || fail "D1b: --render-only missing from the unit command"
grep -q -e '--unit=oxpulse-partner-edge-render-only' "$TMPD/sdrun" 2>/dev/null && pass "D1c: detached as its own unit" || fail "D1c: not a dedicated unit"
grep -q 'partner_edge_reality_uuid_applied=0' "$TMPD/gauge" 2>/dev/null && pass "D1d: applied gauge reads 0 on drift" || fail "D1d: gauge not 0"
if grep -q -e "$U_OLD" -e "$U_NEW" "$TMPD/out"; then fail "D1e: a uuid leaked into the log"; else pass "D1e: no uuid in the log"; fi

# D2 — no drift → nothing started, gauge 1
setup_node "$U_NEW" "$U_NEW" ""
run_fn
[ "$(sdrun_count)" = 0 ] && pass "D2a: no drift → no re-render" || fail "D2a: re-render started without drift"
grep -q 'partner_edge_reality_uuid_applied=1' "$TMPD/gauge" 2>/dev/null && pass "D2b: applied gauge reads 1" || fail "D2b: gauge not 1"

# D3 — a render-only or self-upgrade already running → do not stack another
for unit in oxpulse_partner_edge_render_only oxpulse_partner_edge_self_upgrade; do
    setup_node "$U_OLD" "$U_NEW" ""
    ( export "STATE_$unit=active"; run_fn )
    [ "$(sdrun_count)" = 0 ] && pass "D3: $unit active → not stacked" || fail "D3: started while $unit active"
done

# D4 — fetch failure, invalid served uuid, missing token, non-standard xray schema: fail-soft no-ops
setup_node "$U_OLD" "$U_NEW" ""
( export CURL_FAIL=1; run_fn ); rc=$?
[ "$rc" = 0 ] && [ "$(sdrun_count)" = 0 ] && pass "D4a: fetch failure is a soft no-op" || fail "D4a: fetch failure not soft (rc=$rc)"
setup_node "$U_OLD" "not-a-uuid" ""
run_fn
[ "$(sdrun_count)" = 0 ] && pass "D4b: invalid served uuid ignored" || fail "D4b: acted on an invalid uuid"
setup_node "$U_OLD" "" ""
run_fn
[ "$(sdrun_count)" = 0 ] && pass "D4c: no served uuid ignored" || fail "D4c: acted on an absent uuid"
setup_node "$U_OLD" "$U_NEW" ""; rm -f "$TMPD/etc/token"
run_fn
[ "$(sdrun_count)" = 0 ] && pass "D4d: unregistered node (no token) skipped" || fail "D4d: acted without a token"
setup_node "$U_OLD" "$U_NEW" ""; printf '{"outbounds":[]}\n' > "$TMPD/etc/xray-client.json"
run_fn
[ "$(sdrun_count)" = 0 ] && pass "D4e: custom xray schema skipped" || fail "D4e: acted on a non-standard xray-client.json"

# D5 — systemd-run failure is logged and non-fatal
setup_node "$U_OLD" "$U_NEW" ""
( export SDRUN_RC=1; run_fn ); rc=$?
[ "$rc" = 0 ] && grep -q 'could not start' "$TMPD/out" && pass "D5: systemd-run failure non-fatal and logged" || fail "D5: systemd-run failure not handled (rc=$rc)"

# D6/D7 — after convergence the identity file follows the served uuid; untouched while drifted
stat_mode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
setup_node "$U_NEW" "$U_NEW" "$U_OLD"
run_fn
[ "$(tr -d '\n' < "$TMPD/etc/reality.uuid")" = "$U_NEW" ] && pass "D6a: stale reality.uuid aligned to the served uuid" || fail "D6a: reality.uuid left stale (a re-registration would resend the retired uuid)"
[ "$(stat_mode "$TMPD/etc/reality.uuid")" = 600 ] && pass "D6b: rewritten file is 0600" || fail "D6b: mode is $(stat_mode "$TMPD/etc/reality.uuid")"
# a world-readable identity file (some edges are 0644 from first install) is tightened,
# whether or not its content differs — the mode is never preserved, only tightened
setup_node "$U_NEW" "$U_NEW" "$U_OLD"; chmod 644 "$TMPD/etc/reality.uuid"
run_fn
[ "$(stat_mode "$TMPD/etc/reality.uuid")" = 600 ] && pass "D6c: 0644 file with stale content ends 0600" || fail "D6c: 0644 preserved (mode $(stat_mode "$TMPD/etc/reality.uuid"))"
setup_node "$U_NEW" "$U_NEW" "$U_NEW"; chmod 644 "$TMPD/etc/reality.uuid"
run_fn
[ "$(stat_mode "$TMPD/etc/reality.uuid")" = 600 ] && pass "D6d: 0644 file with CORRECT content is still tightened to 0600" || fail "D6d: world-readable identity file left as is"
setup_node "$U_OLD" "$U_NEW" "$U_OLD"
run_fn
[ "$(tr -d '\n' < "$TMPD/etc/reality.uuid")" = "$U_OLD" ] && pass "D7: reality.uuid NOT touched while still drifted" || fail "D7: reality.uuid changed before the re-render converged"

# D8 — wiring: reconcile never runs ahead of the key-rotation block. It runs at each
# clean exit (keys fetch failed / no rotation) and at the very end of the script,
# i.e. only after the rotation block has finished or was not needed.
calls=$(grep -c '^ *_reconcile_served_uuid || true$' "$REFRESH")
[ "$calls" = 3 ] && pass "D8a: exactly three call sites (two early exits + end of script)" || fail "D8a: $calls call sites"
rot_line=$(grep -n 'log "rotation detected:' "$REFRESH" | cut -d: -f1)
first_call=$(grep -n '^ *_reconcile_served_uuid || true$' "$REFRESH" | cut -d: -f1 | sed -n 1p)
last_call=$(grep -n '^ *_reconcile_served_uuid || true$' "$REFRESH" | cut -d: -f1 | sed -n 3p)
orig_end=$(grep -n 'OK rotation applied' "$REFRESH" | cut -d: -f1)
if [ -n "$rot_line" ] && [ "$first_call" -lt "$rot_line" ] && [ "$last_call" -gt "$orig_end" ]; then
    pass "D8b: the two early-exit calls sit before the rotation block, the last one after its commit"
else
    fail "D8b: call placement wrong (first=$first_call rotation=$rot_line commit=$orig_end last=$last_call)"
fi
# every call that precedes the rotation block is immediately followed by an exit 0
for n in $(grep -n '^ *_reconcile_served_uuid || true$' "$REFRESH" | cut -d: -f1 | sed -n 1,2p); do
    next_line=$(sed -n "$((n+1))p" "$REFRESH")
    if [[ "$next_line" =~ ^\ *exit\ 0$ ]]; then pass "D8c: call at line $n is directly followed by exit 0"; else fail "D8c: call at line $n is not at an exit"; fi
done

echo "=== upgrade.sh: --render-only ==="
OUTCOME="$TMPD/outcome.sh"
awk '/^_assert_rendered_uuid_matches_node_config\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE" > "$OUTCOME"
BLOCK="$TMPD/block.sh"
awk '/^if \[\[ "\$MODE" == render_only \]\]; then/{f=1} f{print} /^fi$/ && f{exit}' "$UPGRADE" > "$BLOCK"
if [ -s "$OUTCOME" ] && [ -s "$BLOCK" ] && bash -n "$OUTCOME" && bash -n "$BLOCK"; then
    pass "U0: outcome check and mode block extracted"
else
    fail "U0: extract"; exit 1
fi

# $1=rendered uuid, $2=uuid in the LOCAL node-config (may be stale), $3=uuid the hub serves
# NOW ("" → fetch fails); env GATE_RC, DRY_RUN → prints the exit code
render_only() {
    mkdir -p "$TMPD/u"
    printf '{"outbounds":[{"settings":{"vnext":[{"users":[{"id":"%s"}]}]}}]}\n' "$1" > "$TMPD/u/xray-client.json"
    printf '{"reality_uuid":"%s"}\n' "$2" > "$TMPD/u/node-config.json"
    if [ -n "$3" ]; then printf '%s' "$3" > "$TMPD/u/served"; else rm -f "$TMPD/u/served"; fi
    (
        die() { printf 'die: %s\n' "$*" >&2; exit 9; }
        log() { :; }; warn() { printf 'warn: %s\n' "$*" >&2; }
        PREFIX_ETC="$TMPD/u"; NODE_CFG="$TMPD/u/node-config.json"; XRAY_CFG="$TMPD/u/xray-client.json"
        MODE=render_only; DRY_RUN="${DRY_RUN:-0}"
        _ensure_channel_render_lib() { :; }
        fetch_served_xray_uuid() { [ -f "$TMPD/u/served" ] && cat "$TMPD/u/served"; }
        _render_gate() { printf '%s %s\n' "$1" "${2:-}" >> "$TMPD/gate_called"; return "$GATE_RC"; }
        # shellcheck disable=SC1090
        source "$ROOT/channel-render-lib.sh" >/dev/null 2>&1
        # re-define after sourcing the lib (it also defines fetch_served_xray_uuid)
        fetch_served_xray_uuid() { [ -f "$TMPD/u/served" ] && cat "$TMPD/u/served"; }
        # shellcheck disable=SC1090
        source "$OUTCOME"
        # shellcheck disable=SC1090
        source "$BLOCK"
        exit 5   # the block did not exit
    ) 2>"$TMPD/u/err"
    echo $?
}
rm -f "$TMPD/gate_called"
[ "$(GATE_RC=0 render_only "$U_NEW" "$U_NEW" "$U_NEW")" = 0 ] && pass "U1: gate ok + served uuid applied → exit 0" || fail "U1: healthy render-only did not succeed"
grep -q '^render-only ch1$' "$TMPD/gate_called" && pass "U1b: ran under _render_gate with ch1 as the strict channel" || fail "U1b: _render_gate not used with ch1 strict"
[ "$(GATE_RC=1 render_only "$U_OLD" "$U_NEW" "$U_NEW")" = 9 ] && pass "U2: gate regression → die" || fail "U2: gate failure not fatal"
[ "$(GATE_RC=0 render_only "$U_OLD" "$U_NEW" "$U_NEW")" = 9 ] && pass "U3: gate ok but served uuid NOT applied → die (a soft-skipped render must not read as success)" || fail "U3: unapplied uuid accepted"
grep -q 'nothing was rendered' "$TMPD/u/err" && pass "U3b: the failure says nothing was rendered" || fail "U3b: misleading failure text"
# SEC-CR-007: the LOCAL node-config is stale and happens to equal the rendered uuid
# (refetch soft-failed) while the hub serves a different one. Comparing with the
# local file would pass vacuously.
[ "$(GATE_RC=0 render_only "$U_OLD" "$U_OLD" "$U_NEW")" = 9 ] && pass "U3c: stale local node-config == rendered, hub serves another → die" || fail "U3c: verified against a stale local node-config"
rm -f "$TMPD/gate_called"
[ "$(GATE_RC=0 render_only "$U_OLD" "$U_NEW" "")" = 9 ] && [ ! -f "$TMPD/gate_called" ] \
    && pass "U3d: cannot fetch the served uuid → die before touching anything" || fail "U3d: proceeded without a verifiable target"
rm -f "$TMPD/gate_called"
if [ "$(DRY_RUN=1 GATE_RC=0 render_only "$U_OLD" "$U_NEW" "$U_NEW")" = 0 ] && [ ! -f "$TMPD/gate_called" ]; then
    pass "U4: --dry-run touches nothing"
else
    fail "U4: dry-run ran the gate"
fi
grep -q -e '--render-only)        MODE=render_only' "$UPGRADE" && pass "U5: flag parsed" || fail "U5: --render-only not parsed"

echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
