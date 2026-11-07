#!/usr/bin/env bash
# tests/test_render_only_ch1_gate.sh — a --render-only that leaves ch1 rejected must
# roll back even when every other signal is green (SERVING_PARTIAL).
#
# The review finding: settle_healthcheck_with_retry deliberately tolerates a
# per-channel regression while another channel still serves (the right call for an
# image upgrade). --render-only changes the credential ch1 authenticates with; "hub
# rejects the new uuid, AWG/naive still fine" is a failed rotation, not a degraded
# upgrade. The REAL _render_gate and the REAL settle gate run here; only the
# renderer, docker and the probes are stubbed.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_render_only_ch1_gate.sh"

TC=$(mktemp -d)
[[ -n "$TC" && -d "$TC" ]] || { echo "mktemp failed"; exit 1; }
trap 'rm -r "${TC:?}"' EXIT

_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }

PRE="$TC/preamble.sh"
{
    echo 'log(){  :; }'
    echo 'warn(){ printf "WARN: %s\n" "$*" >> "'"$TC"'/warns"; }'
    echo 'refetch_node_config(){ :; }'
    # the render: swaps the xray config and flips the probe phase to "post"
    echo 're_render_xray(){ printf "RENDERED\n" > "$XRAY_CFG"; printf post > "'"$TC"'/phase"; cat "'"$TC"'/hc_after" > "'"$TC"'/hc_post"; }'
    echo 'health_snapshot(){ cat "'"$TC"'/hc_pre" > "$2"; }'
    echo '_settle_serveability_snapshot(){ cat "'"$TC"'/serve_$(cat "'"$TC"'/phase")" > "$1"; }'
    echo '_settle_docker_baseline_capture(){ : > "$1"; }'
    _extract_fn settle_healthcheck_with_retry
    _extract_fn _settle_docker_health_watch
    _extract_fn _settle_serveability_adjudicate
    _extract_fn _settle_serveability_alert
    _extract_fn _assert_node_cfg_renderable
    _extract_fn _render_gate_channel_recovers
    _extract_fn _render_gate
} > "$PRE"
bash -n "$PRE" && ok "T0: real gate functions extract and parse" || { bad "T0: parse"; exit 1; }

mkdir -p "$TC/bin"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/docker_calls"\nexit 0\n' "$TC" > "$TC/bin/docker"
chmod +x "$TC/bin/docker"
export PATH="$TC/bin:$PATH"
cat > "$TC/hc" <<'HC'
#!/bin/sh
[ "$1" = "--snapshot" ] && { cat "$HC_POST"; exit 0; }
exit 1
HC
chmod +x "$TC/hc"

# _run STRICT HC_AFTER SERVE_PRE SERVE_POST -> prints rc and the config left behind
_run() {
    : > "$TC/warns"; : > "$TC/docker_calls"
    printf 'PRE-RENDER-CONFIG\n' > "$TC/xray-client.json"
    printf '{"node_id":"n","reality_uuid":"u","reality_public_key":"p","backend_endpoint":"h:1"}\n' > "$TC/node-config.json"
    printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_pre"
    printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_post"
    printf '%s' "$2" > "$TC/hc_after"
    printf '%s' "$3" > "$TC/serve_pre"
    printf '%s' "$4" > "$TC/serve_post"
    printf pre > "$TC/phase"
    local rc
    bash -c "source '$PRE'
        export HEALTHCHECK='$TC/hc' HC_POST='$TC/hc_post' PREFIX_ETC='$TC' DOCKER_BIN=docker
        export XRAY_CFG='$TC/xray-client.json' NODE_CFG='$TC/node-config.json'
        export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3 OXPULSE_UPGRADE_SETTLE_RECHECK_SECS=0
        _render_gate probe $1; echo rc=\$?" 2>/dev/null | sed -n 's/^rc=//p' > "$TC/rc"
    rc=$(cat "$TC/rc")
    echo "$rc"
}
GREEN=$'check_01=GREEN\ncheck_02=GREEN\n'
REDCH=$'check_01=GREEN\ncheck_02=RED\n'
BOTH_OK=$'ch1=OK\nch2=OK\n'
CH1_DOWN=$'ch1=DOWN\nch2=OK\n'
CH1_BASE_DOWN=$'ch1=DOWN\nch2=OK\n'

# G1 — every health signal green, ch1 rejected, AWG still OK: the bug. Strict gate must fail.
rc=$(_run ch1 "$GREEN" "$BOTH_OK" "$CH1_DOWN")
[[ "$rc" != 0 ]] && ok "G1: ch1 DOWN with all other signals green fails the strict gate (rc=$rc)" \
                 || bad "G1: a rejected uuid was committed — every other signal was green (rc=$rc)"
[[ "$(cat "$TC/xray-client.json")" == "PRE-RENDER-CONFIG" ]] && ok "G1b: pre-render xray-client.json restored" \
                 || bad "G1b: the rejected config is still installed"
grep -q 'restart' "$TC/docker_calls" && ok "G1c: tunnel restarted onto the restored config" || bad "G1c: no restart after restore"

# G2 — same, but the settle gate itself sees a regression and adjudicates SERVING_PARTIAL
rc=$(_run ch1 "$REDCH" "$BOTH_OK" "$CH1_DOWN")
[[ "$rc" != 0 ]] && ok "G2: SERVING_PARTIAL (ch1 regressed, ch2 serves) fails the strict gate" \
                 || bad "G2: SERVING_PARTIAL committed a rejected uuid (rc=$rc)"

# G3 — control: without the strict channel the gate keeps its upgrade behaviour (tolerates partial)
rc=$(_run "" "$REDCH" "$BOTH_OK" "$CH1_DOWN")
[[ "$rc" == 0 ]] && ok "G3: no strict channel => upgrade semantics unchanged (SERVING_PARTIAL tolerated)" \
                 || bad "G3: the strict channel leaked into the plain gate (rc=$rc)"

# G4 — ch1 serves after the render: passes and the new config is kept
rc=$(_run ch1 "$GREEN" "$BOTH_OK" "$BOTH_OK")
[[ "$rc" == 0 && "$(cat "$TC/xray-client.json")" == "RENDERED" ]] && ok "G4: ch1 serving after the render passes, config kept" \
                 || bad "G4: healthy render rejected (rc=$rc)"

# G5 — ch1 was not serving before: nothing to defend, the strict check does not invent a failure
rc=$(_run ch1 "$GREEN" "$CH1_BASE_DOWN" "$CH1_DOWN")
[[ "$rc" == 0 ]] && ok "G5: ch1 already DOWN before the render is not blamed on it" || bad "G5: blamed the render for a pre-existing outage (rc=$rc)"

echo "--- $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
