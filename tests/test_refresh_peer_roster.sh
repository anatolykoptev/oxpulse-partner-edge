#!/bin/bash
# tests/test_refresh_peer_roster.sh — daily peer-roster refresh leg in
# oxpulse-partner-edge-refresh.sh (lib/xprb-refresh-lib.sh: refresh_peer_roster).
#
# Root cause 2026-10-11: peer-roster.json was written once, at register time,
# and never refreshed. pillow's copy dated from Jun 16 and still listed a peer
# revoked weeks earlier (403 on every peer-probe cycle); edges registered later
# never appeared in older edges' rosters. The central's GET
# /api/partner/node-config now carries a freshly built `peer_roster`.
#
# Cases:
#   1 field present (new roster)  -> file REPLACED, mode 0644, no tmp left over
#   2 field absent (older central)-> file UNTOUCHED
#   3 field present but malformed -> file UNTOUCHED + failure counter
#   4 HTTP 500 from node-config   -> file UNTOUCHED + failure counter
#   5 empty array                 -> file replaced with [] (a real "no peers")
#   6 no roster file yet          -> created
#   7 bearer never on curl argv   -> CWE-214 guard shared with the token leg
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"
[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }
command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test touch \
                dirname mktemp basename sha256sum sync rm ls; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    printf '#!/bin/sh\nexit 0\n' > "$dir/systemctl"; chmod +x "$dir/systemctl"
    ln -sf "$(command -v jq)" "$dir/jq"
}

KEYS_BODY='{"version":"v1","sfu_signing_public_key":"","channels_version":"c1","reality_public_key":"pk","reality_encryption":"enc","reality_server_names":[]}'
OLD_ROSTER='[{"node_id":"ruoxp-revoked0001","turns_host":"api-aaa.revoked.example","turns_port":443}]'

# write_curl_stub dir nodecfg_body nodecfg_code argv_log
write_curl_stub() {
    local dir="$1" body="$2" code="$3" argv_log="${4:-/dev/null}"
    printf '%s' "$body" > "$dir/nodecfg.body"
    cat > "$dir/curl" <<CURLSTUB
#!/bin/bash
for arg in "\$@"; do
    if [[ "\$arg" == *partner/heartbeat* ]]; then echo '{"ok":true}'; echo 200; exit 0; fi
    if [[ "\$arg" == *partner/cross-probe-token* ]]; then
        echo '{"cross_probe_token":"xprb_unused"}'; echo 200; exit 0
    fi
    if [[ "\$arg" == *partner/node-config* ]]; then
        printf '%s\n' "\$@" > "$argv_log"
        printf 'call\n' >> "$dir/nc.calls"
        cat "$dir/nodecfg.body"; echo; echo '$code'; exit 0
    fi
done
echo '$KEYS_BODY'
exit 0
CURLSTUB
    chmod +x "$dir/curl"
}

# setup dir [roster_json]: fresh prefix tree; roster file only when given.
setup() {
    local dir="$1" roster="${2:-}"
    make_bin "$dir"
    mkdir -p "$dir/etc" "$dir/var" "$dir/textfile"
    printf '{"node_id":"test-node-roster"}\n' > "$dir/etc/node-config.json"
    echo v1 > "$dir/var/keys-version"; echo c1 > "$dir/var/channels-version"
    # Fresh token file -> the (unrelated) token re-mint leg is age-gated off.
    printf 'xprb_fresh' > "$dir/etc/cross-probe-token"
    if [[ -n "$roster" ]]; then printf '%s\n' "$roster" > "$dir/var/peer-roster.json"; chmod 0644 "$dir/var/peer-roster.json"; fi
}

run_refresh() {
    local dir="$1"
    env ${EXTRA_ENV:-} PATH="$dir" LOG_FILE="$dir/refresh.log" \
        PARTNER_EDGE_PREFIX_ETC="$dir/etc" PARTNER_EDGE_PREFIX_LIB="$dir/var" \
        PARTNER_EDGE_TEXTFILE_DIR="$dir/textfile" OXPULSE_BACKEND_URL="${STUB_URL:-https://stub.invalid}" \
        OXPULSE_SERVICE_TOKEN="stkn_roster_test" \
        bash "$SCRIPT" >"$dir/out.txt" 2>&1
}

mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
NEW_ROSTER='[{"node_id":"ruoxp-new000000001","turns_host":"api-bbb.fresh.example","turns_port":443},{"node_id":"ruoxp-new000000002","turns_host":"api-ccc.fresh.example","turns_port":443}]'

# ── 1: present -> replaced ───────────────────────────────────────────────────
T=$D/t1; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" "{\"node_id\":\"test-node-roster\",\"peer_roster\":$NEW_ROSTER}" 200
run_refresh "$T" || fail "t1: refresh exited nonzero: $(cat "$T/out.txt")"
[[ "$(jq -c . "$T/var/peer-roster.json")" == "$(jq -c . <<<"$NEW_ROSTER")" ]] \
    || fail "t1: roster not replaced; got: $(cat "$T/var/peer-roster.json") out: $(cat "$T/out.txt")"
[[ "$(mode_of "$T/var/peer-roster.json")" == "644" ]] || fail "t1: mode must stay 0644, got $(mode_of "$T/var/peer-roster.json")"
compgen -G "$T/var/peer-roster.json.*" >/dev/null && fail "t1: temp file left behind"
pass "t1: present peer_roster replaces the file (0644, atomic)"

# ── 2: absent -> untouched ───────────────────────────────────────────────────
T=$D/t2; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" '{"node_id":"test-node-roster","channels":[]}' 200
run_refresh "$T" || fail "t2: refresh exited nonzero"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t2: roster changed although the field was absent"
pass "t2: absent peer_roster leaves the file untouched"

# ── 3: malformed -> untouched ────────────────────────────────────────────────
T=$D/t3; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" '{"node_id":"x","peer_roster":"not-an-array"}' 200
run_refresh "$T" || fail "t3: refresh exited nonzero"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t3: malformed peer_roster must not touch the file"
grep -q 'reason="malformed_response"' "$T/textfile/partner_edge.prom" || fail "t3: failure counter missing"
write_curl_stub "$T" '{"node_id":"x","peer_roster":[{"node_id":"a"}]}' 200   # element missing turns_host
run_refresh "$T" || fail "t3b: refresh exited nonzero"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t3b: incomplete entry must reject the whole roster"
pass "t3: malformed peer_roster rejected whole"

# ── 4: HTTP 500 -> untouched ─────────────────────────────────────────────────
T=$D/t4; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 401   # 4xx: not retried, body ignored
run_refresh "$T" || fail "t4: refresh exited nonzero"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t4: non-200 must not touch the file"
grep -q 'reason="http_401"' "$T/textfile/partner_edge.prom" || fail "t4: failure counter missing"
pass "t4: non-200 leaves the file untouched"

# ── 5: empty array -> replaced ───────────────────────────────────────────────
T=$D/t5; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" '{"node_id":"x","peer_roster":[]}' 200
run_refresh "$T" || fail "t5: refresh exited nonzero"
[[ "$(jq -c . "$T/var/peer-roster.json")" == "[]" ]] || fail "t5: empty roster must replace the file"
pass "t5: empty array is a real answer and replaces the file"

# ── 6: no file yet -> created ────────────────────────────────────────────────
T=$D/t6; mkdir -p "$T"; setup "$T"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200
run_refresh "$T" || fail "t6: refresh exited nonzero"
[[ "$(jq 'length' "$T/var/peer-roster.json")" == "2" ]] || fail "t6: roster file not created"
pass "t6: missing roster file is created"

# ── 7: bearer not on argv ────────────────────────────────────────────────────
T=$D/t7; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200 "$T/argv.log"
run_refresh "$T" || fail "t7: refresh exited nonzero"
[[ -s "$T/argv.log" ]] || fail "t7: node-config was never fetched"
grep -q 'stkn_roster_test' "$T/argv.log" && fail "t7: service token leaked onto curl argv (CWE-214)"
pass "t7: bearer stays off argv"

# ── 8: truncated JSON is malformed, NOT "older central" ─────────────────────
T=$D/t8; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" '{"node_id":"x","peer_roster":[{"node_id":"a","turns_ho' 200
run_refresh "$T" || fail "t8: refresh exited nonzero"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t8: truncated body must not touch the file"
grep -q 'reason="malformed_response"' "$T/textfile/partner_edge.prom" || fail "t8: malformed counter missing"
grep -q 'peer_roster_field_absent_total' "$T/textfile/partner_edge.prom" && fail "t8: truncated JSON must not count as field-absent"
pass "t8: truncated JSON counted malformed_response, file kept"

# ── 9: field absent is counted; success gauge on a real refresh ──────────────
T=$D/t9; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" '{"node_id":"x","channels":[]}' 200
run_refresh "$T" || fail "t9: refresh exited nonzero"
grep -q 'partner_edge_peer_roster_field_absent_total' "$T/textfile/partner_edge.prom" || fail "t9: field-absent counter missing"
[[ -e "$T/textfile/partner_edge_peer_roster_refresh_success_timestamp.prom" ]] && fail "t9: success gauge must not be set when nothing was applied"
T=$D/t9b; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200
run_refresh "$T" || fail "t9b: refresh exited nonzero"
grep -Eq '^partner_edge_peer_roster_refresh_success_timestamp [0-9]{10}' "$T/textfile/partner_edge_peer_roster_refresh_success_timestamp.prom" \
    || fail "t9b: success timestamp gauge missing: $(cat "$T"/textfile/*timestamp.prom 2>&1)"
pass "t9: field-absent counted; success timestamp gauge set only on success"

# ── 10: deadline budget — ONE attempt, no 5xx retry loop ─────────────────────
# TimeoutStartSec=120; the token leg already has a ~52s retry budget, so the
# roster fetch must not add another. Restoring 3 attempts makes this RED.
T=$D/t10; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" '{"error":"overloaded"}' 503
run_refresh "$T" || fail "t10: refresh exited nonzero"
[[ "$(wc -l < "$T/nc.calls")" -eq 1 ]] || fail "t10: roster fetch must make exactly 1 attempt on 5xx, made $(wc -l < "$T/nc.calls")"
pass "t10: single attempt on 5xx"

line_of() { local n; n=$(grep -n -m1 "$1" "$2" || true); printf '%s' "${n%%:*}"; }
# ── 11: runs after the critical path ─────────────────────────────────────────
T=$D/t11; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200
run_refresh "$T" || fail "t11: refresh exited nonzero"
hb=$(line_of 'heartbeat ok' "$T/out.txt")
tok=$(line_of 'cross-probe token' "$T/out.txt")
ch=$(line_of 'no rotation' "$T/out.txt")
ro=$(line_of 'peer roster' "$T/out.txt")
[[ -n "$hb" && -n "$tok" && -n "$ch" && -n "$ro" ]] || fail "t11: missing log markers: $(cat "$T/out.txt")"
[[ "$ro" -gt "$ch" && "$ro" -gt "$hb" && "$ro" -gt "$tok" ]] || fail "t11: roster must run after heartbeat/token/channel steps (hb=$hb tok=$tok ch=$ch ro=$ro)"
pass "t11: roster refresh runs last"

# ── 12: deadline guard skips the fetch entirely ──────────────────────────────
T=$D/t12; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200
EXTRA_ENV="ROSTER_START_DEADLINE_SECS=-1" run_refresh "$T" || fail "t12: refresh exited nonzero"
[[ ! -e "$T/nc.calls" ]] || fail "t12: node-config must not be fetched past the deadline guard"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t12: file must be untouched"
grep -q 'reason="deadline_skipped"' "$T/textfile/partner_edge.prom" || fail "t12: deadline_skipped counter missing"
pass "t12: deadline guard skips the roster fetch"

# ── 13: bearer only over https ───────────────────────────────────────────────
T=$D/t13; mkdir -p "$T"; setup "$T" "$OLD_ROSTER"; cp "$T/var/peer-roster.json" "$T/before"
write_curl_stub "$T" "{\"peer_roster\":$NEW_ROSTER}" 200
STUB_URL="http://stub.invalid" run_refresh "$T" || fail "t13: refresh exited nonzero"
[[ ! -e "$T/nc.calls" ]] || fail "t13: token must not be sent over http"
cmp -s "$T/before" "$T/var/peer-roster.json" || fail "t13: file must be untouched"
grep -q 'reason="fetch_failed"' "$T/textfile/partner_edge.prom" || fail "t13: counted failure missing"
pass "t13: non-https BACKEND_URL refused and counted"

echo "PASS: test_refresh_peer_roster"
