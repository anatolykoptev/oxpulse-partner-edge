#!/usr/bin/env bash
# tests/test_render_gate.sh — the post-upgrade refetch + re-render must run
# under a health gate, and its rollback must be render-scoped (#514).
#
# re_render_xray does not merely write a file: it rewrites xray-client.json and
# restarts the tunnel. It used to run AFTER the main settle gate, AFTER
# `rm -f "$_baseline_snapshot"` had discarded the rollback baseline, and AFTER
# "upgraded successfully" had been logged — so the change most likely to break
# traffic sat outside the gate that exists to catch exactly that.
#
# Two oracles, deliberately:
#   - ORDERING is a static property of upgrade.sh, so T5/T6/T7 assert on the
#     source. An executed test cannot distinguish "logged success after the
#     gate" from "logged success before it" without replaying a whole upgrade.
#   - BEHAVIOUR (does the gate fail, is the config restored, is the rollback
#     render-scoped) is executed against the real _render_gate, T1-T4.
#
# Plain bash, no bats (repo convention).
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
CRL="$REPO_ROOT/channel-render-lib.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: $UPGRADE not found"; exit 1; }
[[ -f "$CRL" ]] || { echo "FAIL: $CRL not found"; exit 1; }
PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_render_gate.sh"
echo

TC=$(mktemp -d)
trap 'rm -rf "$TC"' EXIT

_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }

PRE="$TC/preamble.sh"
{
    echo 'log(){  printf "LOG: %s\n"  "$*" >> "'"$TC"'/logs"; }'
    echo 'warn(){ printf "WARN: %s\n" "$*" >> "'"$TC"'/warns"; }'
    # The render is what this gate brackets; drive its effect from a file so a
    # test can make the render benign or harmful without touching the gate.
    echo 'refetch_node_config(){ printf "refetch\n" >> "'"$TC"'/calls"; }'
    echo 're_render_xray(){ printf "render\n" >> "'"$TC"'/calls"; printf "RENDERED\n" > "$XRAY_CFG"; cat "'"$TC"'/hc_after_render" > "'"$TC"'/hc_post"; }'
    echo 'health_snapshot(){ cat "'"$TC"'/hc_pre" > "$2"; }'
    echo '_settle_serveability_snapshot(){ : > "$1"; }'
    _extract_fn settle_healthcheck_with_retry
    _extract_fn _settle_docker_health_watch
    _extract_fn _render_gate
} > "$PRE"

if bash -n "$PRE" 2>/dev/null; then
    ok "T0: _render_gate extracts and parses alongside the settle gate"
else
    bad "T0: preamble parse failed"
fi

# docker stub — records every invocation so a test can prove what the rollback
# did NOT do, and reports no containers so the late-wedge watch exits early.
mkdir -p "$TC/bin"
cat > "$TC/bin/docker" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TC/docker_calls"
exit 0
STUB
chmod +x "$TC/bin/docker"
export PATH="$TC/bin:$PATH"

cat > "$TC/hc" <<'HCSTUB'
#!/bin/sh
[ "$1" = "--snapshot" ] && { cat "$HC_POST"; exit 0; }
exit 1
HCSTUB
chmod +x "$TC/hc"

_reset() {
    : > "$TC/logs"; : > "$TC/warns"; : > "$TC/calls"; : > "$TC/docker_calls"
    printf 'PRE-RENDER-CONFIG\n' > "$TC/xray-client.json"
}

# _run POST_STATE -> echoes rc of _render_gate
# hc_pre is always all-GREEN; POST_STATE is what the render leaves behind.
_run() {
    printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_pre"
    printf 'check_01=GREEN\ncheck_02=GREEN\n' > "$TC/hc_post"
    printf '%s' "$1" > "$TC/hc_after_render"
    bash -c "source '$PRE'
        export HEALTHCHECK='$TC/hc'
        export HC_POST='$TC/hc_post'
        export PREFIX_ETC='$TC'
        export DOCKER_BIN=docker
        export XRAY_CFG='$TC/xray-client.json'
        export OXPULSE_UPGRADE_HEALTH_TIMEOUT=3
        export OXPULSE_UPGRADE_SETTLE_RECHECK_SECS=0
        _render_gate probe; echo rc=\$?" 2>/dev/null | sed -n 's/^rc=//p'
}

# ── T1 — a render that regresses health FAILS the gate ──────────────────────
# This is #514: before this gate existed the upgrade had already logged success.
_reset
rc=$(_run 'check_01=GREEN
check_02=RED
')
[[ "$rc" != "0" ]] && ok "T1: a render that regresses a check fails the gate (rc=$rc)" \
                   || bad "T1: the gate passed over a render that broke a green check — this is #514 (rc=$rc)"

# ── T2 — a clean render passes, and its output is KEPT ──────────────────────
_reset
rc=$(_run 'check_01=GREEN
check_02=GREEN
')
if [[ "$rc" == "0" ]]; then
    ok "T2: a clean render passes the gate"
else
    bad "T2: a clean render was wrongly rolled back (rc=$rc)"
fi
if [[ "$(cat "$TC/xray-client.json")" == "RENDERED" ]]; then
    ok "T2b: a passing render's config is left in place, not reverted"
else
    bad "T2b: a passing render's output was discarded"
fi

# ── T3 — on regression the PRE-RENDER config is restored ───────────────────
_reset
rc=$(_run 'check_01=GREEN
check_02=RED
')
if [[ "$(cat "$TC/xray-client.json")" == "PRE-RENDER-CONFIG" ]]; then
    ok "T3: the pre-render xray-client.json is restored on regression"
else
    bad "T3: config after rollback is '$(cat "$TC/xray-client.json")' — the broken render is still installed"
fi

# ── T4 — the rollback is RENDER-SCOPED: images/compose are NOT reverted ────
# Images and compose passed their own gate; reverting them because a render
# regressed would undo a change that is not the one that broke.
if grep -qE 'compose (pull|up)' "$TC/docker_calls" 2>/dev/null; then
    _offending=$(sed -n '/compose \(pull\|up\)/{s/.*\(compose [a-z]*\).*/\1/p;q;}' "$TC/docker_calls")
    bad "T4: the render rollback ran '${_offending}' — it reverted images/compose, not just the render"
else
    ok "T4: the render rollback touched no image or compose state (render-scoped)"
fi
if grep -q 'compose restart xray-client' "$TC/docker_calls" 2>/dev/null; then
    ok "T4b: the restored config is applied by restarting xray-client"
else
    bad "T4b: config restored but xray-client never restarted — the rollback is not in effect"
fi

# ── T5 — ORDERING (static): the gate precedes the success claim ────────────
# The defect this issue names is an ORDER, which is a property of the source.
# sed reports the first match's line number and quits — no pipe into a
# truncating reader, which the repo's pipefail guard rejects.
_plain_gate_line=$(sed -n '/_render_gate "plain-upgrade-render"/{=;q;}' "$UPGRADE")
_plain_succ_line=$(sed -n '/log "upgraded to \$TARGET successfully"/{=;q;}' "$UPGRADE")
if [[ -n "$_plain_gate_line" && -n "$_plain_succ_line" && "$_plain_gate_line" -lt "$_plain_succ_line" ]]; then
    ok "T5: plain path gates the render (line $_plain_gate_line) BEFORE claiming success (line $_plain_succ_line)"
else
    bad "T5: plain path claims success at line ${_plain_succ_line:-?} before/without the render gate at line ${_plain_gate_line:-none}"
fi

# ── T6 — the --with-templates path is gated too ────────────────────────────
# The issue named one path; both have the defect, so both need the gate.
_wt_gate_line=$(sed -n '/_render_gate "with-templates-upgrade-render"/{=;q;}' "$UPGRADE")
_wt_succ_line=$(sed -n '/log "--with-templates upgrade to \$TARGET complete"/{=;q;}' "$UPGRADE")
if [[ -n "$_wt_gate_line" && -n "$_wt_succ_line" && "$_wt_gate_line" -lt "$_wt_succ_line" ]]; then
    ok "T6: --with-templates path gates the render before claiming completion"
else
    bad "T6: --with-templates path is ungated (gate=${_wt_gate_line:-none} claim=${_wt_succ_line:-?})"
fi

# ── T7 — no NEW ungated re_render_xray call appears ────────────────────────
# Exactly one bare call may live outside _render_gate: the --templates-only
# mode (upgrade.sh:970). That mode has no health gate at all and re-rendering
# is its entire purpose, so gating it is a behaviour change #514 does not ask
# for — filed as a follow-up rather than changed here. This pins the count so a
# NEW ungated call site fails instead of quietly reopening the hole.
_outside=$(awk '/^_render_gate\(\) \{/{ing=1} ing&&/^\}$/{ing=0;next} !ing && /^[[:space:]]*re_render_xray[[:space:]]*$/{n++} END{print n+0}' "$UPGRADE")
if [[ "$_outside" -eq 1 ]]; then
    ok "T7: the only ungated re_render_xray is the known --templates-only one"
elif [[ "$_outside" -eq 0 ]]; then
    bad "T7: expected the --templates-only call to remain; found 0 — update this baseline deliberately"
else
    bad "T7: $_outside ungated re_render_xray calls (baseline 1) — a new render runs outside the gate"
fi

# ── T8 — the restart is no longer asserted when it did not happen ──────────
# Static: channel-render-lib.sh used to swallow the restart result with
# `2>/dev/null || true` and log "xray-client restarted" on the next line
# unconditionally, so a restart that never happened was reported as one that did.
if grep -q 'docker compose restart xray-client 2>/dev/null || true' "$CRL"; then
    bad "T8: the restart result is still swallowed while the next line asserts it happened"
elif grep -q 'xray-client restart FAILED' "$CRL"; then
    ok "T8: a failed xray-client restart is reported as a failure, not logged as success"
else
    bad "T8: no failure branch for the xray-client restart"
fi

echo
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
