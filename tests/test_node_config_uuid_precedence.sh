#!/usr/bin/env bash
# node_config_xray_uuid (jq) must pick the SAME uuid re_render_xray's python does.
#
# jq's `//` skips only null/false, so `.xray.uuid // .reality_uuid` returns an
# EMPTY-STRING channel uuid where the python renderer (`x.get('uuid','') or
# d.get('reality_uuid','')`) falls through to the flat field. If the two disagree,
# the reconcile compares against a uuid the renderer will never write: either a
# permanent false drift (a re-render every run) or a false "converged".
#
# The python below is the renderer's own expression; the test first pins that the
# renderer still contains it verbatim, so the oracle cannot drift from the code.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
LIB="$ROOT/channel-render-lib.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

grep -qF "print(x.get('uuid','') or d.get('reality_uuid',''))" "$LIB" \
    && grep -qF "x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}" "$LIB" \
    && pass "O0: the renderer still derives the uuid with the python this test uses as oracle" \
    || { fail "O0: renderer's uuid expression changed — update the oracle AND node_config_xray_uuid"; exit 1; }

TMPD=$(mktemp -d); [ -n "$TMPD" ] && [ -d "$TMPD" ] || exit 1
trap 'rm -r "${TMPD:?}"' EXIT

oracle() {
    python3 -c "
import json,sys; d=json.load(open(sys.argv[1]))
ch=d.get('channels',[])
x=ch[0].get('xray',{}) if ch and ch[0].get('protocol','')=='vless-reality' else {}
print(x.get('uuid','') or d.get('reality_uuid',''))" "$1"
}
mine() { ( source "$LIB" >/dev/null 2>&1; node_config_xray_uuid "$1" ); }

n=0
check() {  # $1=label $2=json
    n=$((n+1)); f="$TMPD/c$n.json"; printf '%s' "$2" > "$f"
    want=$(oracle "$f"); got=$(mine "$f")
    if [ "$want" = "$got" ]; then pass "O$n: $1 → '${got:0:8}'"; else fail "O$n: $1 — renderer picks '$want', node_config_xray_uuid says '$got'"; fi
}
V='"protocol":"vless-reality"'
check "channel uuid wins over flat"            "{\"reality_uuid\":\"flat\",\"channels\":[{$V,\"xray\":{\"uuid\":\"chan\"}}]}"
check "EMPTY channel uuid falls through"       "{\"reality_uuid\":\"flat\",\"channels\":[{$V,\"xray\":{\"uuid\":\"\"}}]}"
check "null channel uuid falls through"        "{\"reality_uuid\":\"flat\",\"channels\":[{$V,\"xray\":{\"uuid\":null}}]}"
check "missing channel uuid falls through"     "{\"reality_uuid\":\"flat\",\"channels\":[{$V,\"xray\":{}}]}"
check "no xray object falls through"           "{\"reality_uuid\":\"flat\",\"channels\":[{$V}]}"
check "non-vless channel[0] is ignored"        "{\"reality_uuid\":\"flat\",\"channels\":[{\"protocol\":\"naive\",\"xray\":{\"uuid\":\"chan\"}}]}"
check "vless channel is not first → ignored"   "{\"reality_uuid\":\"flat\",\"channels\":[{\"protocol\":\"naive\"},{$V,\"xray\":{\"uuid\":\"chan\"}}]}"
check "flat only"                              "{\"reality_uuid\":\"flat\"}"
check "channels empty list"                    "{\"reality_uuid\":\"flat\",\"channels\":[]}"
check "nothing at all"                         "{}"
check "empty channel uuid and empty flat"      "{\"reality_uuid\":\"\",\"channels\":[{$V,\"xray\":{\"uuid\":\"\"}}]}"

echo "--- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
