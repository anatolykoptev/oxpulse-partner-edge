#!/usr/bin/env bash
# tests/test_prerender_before_recreate.sh — a plain upgrade from an on-disk
# `randomized` xray-client.json must render the chrome config BEFORE the compose
# up that recreates xray.
#
# Why it matters (silent otherwise): the recreate reads the config already on
# disk. _render_gate renders only AFTER the main settle gate, so an edge on the
# old `randomized` config was recreated on it; ~50% of those processes wedge
# against REALITY >= 2026-09-08. Check 7 now sees the wedge, so the main gate
# rolled the upgrade back (single-homed) or alerted (multi-homed) on a coin flip.
#
# Oracle: the REAL plain-path block of upgrade.sh (from `declare -A
# _after_digests` through the recreate failure branch) is extracted and executed
# with recreate_changed_services stubbed to record which fingerprint the config
# on disk carries AT THE MOMENT of the recreate. Moving the render after the
# recreate leaves `randomized` there -> RED.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: $UPGRADE not found"; exit 1; }
PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }
echo "test_prerender_before_recreate.sh"

TC=$(mktemp -d); trap 'rm -rf "$TC"' EXIT
_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }
# plain path: after-digests block up to the end of the recreate-failure branch
_plain_block() {
	awk '/^declare -A _after_digests$/{f=1} f{print} /recreate_changed_services _before_digests/{s=1} /^fi$/ && f && s{exit}' "$UPGRADE"
}

{
	echo 'log(){ :; }; warn(){ printf "WARN %s\n" "$*" >> "'"$TC"'/warns"; }; die(){ echo "DIE $*" >&2; exit 9; }'
	echo '_ensure_channel_render_lib(){ :; }'
	echo 'refetch_node_config(){ :; }'
	# the renderer (reused, not reimplemented): writes the CURRENT template's config
	echo 're_render_xray(){ printf "%s\n" "$RENDER_OUTPUT" > "$XRAY_CFG"; echo render >> "'"$TC"'/order"; }'
	echo 'resolve_pulled_digests(){ return 0; }'
	echo 'recreate_changed_services(){ echo "recreate fp=$(grep -o "\"fingerprint\": *\"[a-z]*\"" "$XRAY_CFG" | head -1)" >> "'"$TC"'/order"; return "${RECREATE_RC:-0}"; }'
	_extract_fn _prerender_xray_before_up
	echo 'declare -A _before_digests=() _edge_svcs=()'
	_plain_block
} > "$TC/plain.sh"
bash -n "$TC/plain.sh" || { echo "FAIL: extraction does not parse"; exit 1; }
grep -q "_prerender_xray_before_up" "$TC/plain.sh" || { echo "FAIL: plain block does not call _prerender_xray_before_up"; exit 1; }

run_plain() {   # on-disk-fingerprint
	: > "$TC/order"; : > "$TC/warns"
	printf '{"streamSettings":{"realitySettings":{"fingerprint": "%s"}}}\n' "$1" > "$TC/xray-client.json"
	RENDER_OUTPUT='{"streamSettings":{"realitySettings":{"fingerprint": "chrome"}}}' \
		XRAY_CFG="$TC/xray-client.json" PREFIX_ETC="$TC" bash "$TC/plain.sh"
}

run_plain randomized
if [[ "$(head -1 "$TC/order")" == render && "$(sed -n 2p "$TC/order")" == 'recreate fp="fingerprint": "chrome"' ]]; then
	ok "T1: randomized on disk -> render runs first, xray is recreated on the chrome config"
else
	bad "T1: wrong order/config at recreate: $(tr '\n' '|' < "$TC/order")"
fi

run_plain chrome
if [[ "$(cat "$TC/order")" == 'recreate fp="fingerprint": "chrome"' ]]; then
	ok "T2: chrome already on disk -> no extra render before the recreate"
else
	bad "T2: unexpected pre-render on a converged config: $(tr '\n' '|' < "$TC/order")"
fi

# T3 — a failing render must not abort the upgrade (soft), only warn
: > "$TC/order"
sed 's/^re_render_xray().*/re_render_xray(){ return 1; }/' "$TC/plain.sh" > "$TC/plain-fail.sh"
printf '{"streamSettings":{"realitySettings":{"fingerprint": "randomized"}}}\n' > "$TC/xray-client.json"
if XRAY_CFG="$TC/xray-client.json" PREFIX_ETC="$TC" bash "$TC/plain-fail.sh" && grep -q "WARN pre-recreate xray render failed" "$TC/warns" \
   && grep -q '^recreate' "$TC/order"; then
	ok "T3: a failed pre-render warns and the upgrade proceeds to the recreate"
else
	bad "T3: failed pre-render aborted or was silent"
fi

# T4 — the same guard on the --with-templates path (static ordering: same helper
#      call immediately before its recreate)
for pair in "_wt_before_digests _wt_after_digests" "_before_digests _after_digests"; do
	call=$(grep -n "recreate_changed_services $pair" "$UPGRADE" | head -1 | cut -d: -f1)
	prev=$(sed -n "$((call - 1))p" "$UPGRADE" | tr -d '\t ')
	if [[ "$prev" == "_prerender_xray_before_up" ]]; then
		ok "T4: render precedes recreate_changed_services $pair"
	else
		bad "T4: line before recreate_changed_services $pair is '$prev', not _prerender_xray_before_up"
	fi
done

echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
