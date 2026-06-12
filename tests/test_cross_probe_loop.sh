#!/usr/bin/env bash
# tests/test_cross_probe_loop.sh — behavioral tests for the P3b edge cross-probe
# loop in oxpulse-channels-health-report.sh (mesh producer half-2).
#
# Plain bash (no bats), same ok/fail pattern as the rest of the repo.
#
# Coverage:
#   1  roster parse — valid public peer → probed, CrossProbeReportRequest emitted
#      with the EXACT bare field names + probe_mode:"peer".
#   2  SSRF dial-time recheck — internal hosts (127.0.0.1 literal, 10.0.0.5
#      literal, a hostname resolving to 169.254.169.254) are REJECTED before any
#      dial; a public host is ALLOWED.
#   3  empty roster ([]) → loop self-skips cleanly (no dial, no POST, state=disabled).
#   4  absent roster file → loop self-skips cleanly.
#   5  no cross-probe token → loop self-skips (fail-closed, pre-P3a central).
#   6  secret-not-on-argv — the base TURN secret never reaches the HMAC binary's
#      argv during a peer probe (mirrors the ch4 SEC-CR-001 leak test).
#   7  budget cap — roster larger than OXPULSE_PEER_PROBE_MAX dials at most cap.
#   8  untrusted host is NOT shell-interpolated into the dial (a host with shell
#      metacharacters resolves-internal → rejected, no command injection).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-channels-health-report.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: reporter script not found at $SCRIPT"; exit 1; }

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

# ---------- helper: stub bin dir ----------
# Symlinks the real coreutils the script needs, plus default stubs.
make_bin() {
    local dir="$1"
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test awk sort dirname \
                realpath timeout mktemp rm python3; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        [[ -n "$loc" ]] && ln -sf "$loc" "$dir/$cmd"
    done
    printf '#!/bin/sh\nexit 0\n' > "$dir/ping"; chmod +x "$dir/ping"
    printf '#!/bin/sh\nexit 0\n' > "$dir/nc";   chmod +x "$dir/nc"
    if command -v jq >/dev/null 2>&1; then ln -sf "$(command -v jq)" "$dir/jq"; fi
    # curl: no-op 200 stub (real curl via symlink can hit perms).
    printf '#!/bin/sh\nprintf "200"\nexit 0\n' > "$dir/curl"; chmod +x "$dir/curl"
    printf '#!/bin/sh\nexit 0\n' > "$dir/systemctl"; chmod +x "$dir/systemctl"
}

# ---------- helper: node-config with a single coturn channel ----------
write_node_config() {
    printf '{"node_id":"prober-node","channels":[{"id":"ch4"}]}\n' > "$1/node-config.json"
}

echo "test_cross_probe_loop.sh"
echo

# ── Test 1: valid public peer → CrossProbeReportRequest emitted ───────────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT
make_bin "$T1"; mkdir -p "$T1/etc" "$T1/var"
write_node_config "$T1/etc"
printf '[{"node_id":"peer-pub","turns_host":"api-abc.example.com","turns_port":443}]\n' \
    > "$T1/var/peer-roster.json"

# getent stub: public host resolves to a TEST-NET-3 (public-class) address.
cat > "$T1/getent" <<'STUB'
#!/bin/sh
[ "$2" = "api-abc.example.com" ] && { echo "203.0.113.55 STREAM api-abc.example.com"; exit 0; }
exit 2
STUB
chmod +x "$T1/getent"

# docker stub: serve secret + accept the TURNS dial (exit 0 = handshake_ok).
cat > "$T1/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "t1-secret"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then echo "allocate success: relay address 203.0.113.55:49152"; exit 0; fi
exit 1
STUB
chmod +x "$T1/docker"

set +e
OUT1=$(PATH="$T1:/usr/bin:/bin" \
    _NODE_CONFIG="$T1/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T1/var" _PEER_ROSTER_FILE="$T1/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t1" OXPULSE_SERVICE_TOKEN="stkn_t1" \
    OXPULSE_TURN_SECRET="t1-secret" OXPULSE_GETENT_BIN="$T1/getent" \
    bash "$SCRIPT" --dry-run 2>/dev/null)
set -e

# The cross-probe report line must be present and valid against the exact schema.
REPORT1=$(printf '%s\n' "$OUT1" | jq -c 'select(.probe_mode=="peer")' 2>/dev/null | head -1)
if [[ -n "$REPORT1" ]]; then
    ok "test1: cross-probe report emitted for the public peer"
else
    fail "test1: no probe_mode=peer report; output: $OUT1"
fi
# Field-by-field shape (bare names, types).
if printf '%s' "$REPORT1" | jq -e '
        .prober_node_id=="prober-node"
        and .target_node_id=="peer-pub"
        and .channel_name=="coturn"
        and .probe_mode=="peer"
        and (.handshake_ok==true)
        and (.rtt_ms|type=="number")
        and (.probed_at|test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    ' >/dev/null 2>&1; then
    ok "test1: report body has exact field names + types (probed_at ISO8601 UTC)"
else
    fail "test1: report body schema mismatch: $REPORT1"
fi

trap - EXIT; rm -rf "$T1"

# ── Test 2: SSRF dial-time recheck rejects internal, allows public ────────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT
make_bin "$T2"; mkdir -p "$T2/etc" "$T2/var"
write_node_config "$T2/etc"
# Four peers: loopback literal, RFC-1918 literal, a hostname that resolves to
# cloud-metadata 169.254.169.254, and one genuinely public host.
cat > "$T2/var/peer-roster.json" <<'JSON'
[
  {"node_id":"peer-loop","turns_host":"127.0.0.1","turns_port":443},
  {"node_id":"peer-1918","turns_host":"10.0.0.5","turns_port":443},
  {"node_id":"peer-rebind","turns_host":"rebind.evil.example","turns_port":443},
  {"node_id":"peer-ok","turns_host":"good.example.com","turns_port":443}
]
JSON

# getent: the rebind host resolves to link-local metadata; good host is public.
cat > "$T2/getent" <<'STUB'
#!/bin/sh
case "$2" in
  rebind.evil.example) echo "169.254.169.254 STREAM rebind.evil.example"; exit 0 ;;
  good.example.com)    echo "198.51.100.9 STREAM good.example.com";        exit 0 ;;
esac
exit 2
STUB
chmod +x "$T2/getent"

DIAL_LOG="$T2/dial.log"
# Record ONLY peer-probe (TLS, -S) dials — the ch4 self-probe (plain turn:3478,
# 127.0.0.1 fallback) shares the turnutils_uclient stub but is NOT a peer probe;
# logging it would conflate the self-probe loopback target with an SSRF leak.
cat > "$T2/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then echo "t2-secret"; exit 0; fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    [[ "\$*" == *" -S "* ]] && printf '%s\n' "\$*" >> "$DIAL_LOG"
    echo "allocate success"
    exit 0
fi
exit 1
STUB
chmod +x "$T2/docker"

set +e
ERR2=$(PATH="$T2:/usr/bin:/bin" \
    _NODE_CONFIG="$T2/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T2/var" _PEER_ROSTER_FILE="$T2/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t2" OXPULSE_SERVICE_TOKEN="stkn_t2" \
    OXPULSE_TURN_SECRET="t2-secret" OXPULSE_GETENT_BIN="$T2/getent" \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e

# The three internal hosts must NEVER appear in the dial log (rejected pre-dial).
LEAKED=""
for bad in 127.0.0.1 10.0.0.5 rebind.evil.example; do
    grep -q "$bad" "$DIAL_LOG" 2>/dev/null && LEAKED="$LEAKED $bad"
done
if [[ -z "$LEAKED" ]]; then
    ok "test2: internal/rebind hosts REJECTED before dial (no SSRF dial)"
else
    fail "test2: SSRF LEAK — internal host(s) dialed:$LEAKED; dial log: $(cat "$DIAL_LOG" 2>/dev/null)"
fi
# All three must have produced a REJECT warning.
if [[ $(printf '%s\n' "$ERR2" | grep -c 'REJECT') -ge 3 ]]; then
    ok "test2: all three internal hosts logged a REJECT"
else
    fail "test2: expected >=3 REJECT logs; got: $(printf '%s\n' "$ERR2" | grep REJECT)"
fi
# The public host MUST have been dialed.
if grep -q 'good.example.com' "$DIAL_LOG" 2>/dev/null; then
    ok "test2: the public host WAS dialed (allow path works)"
else
    fail "test2: public host not dialed; dial log: $(cat "$DIAL_LOG" 2>/dev/null)"
fi
# rejected count in the state marker should be 3.
if grep -q '^PEER_PROBE_REJECTED=3$' "$T2/var/peer-probe-mode.env" 2>/dev/null; then
    ok "test2: peer-probe-mode.env records REJECTED=3"
else
    fail "test2: expected PEER_PROBE_REJECTED=3; state: $(cat "$T2/var/peer-probe-mode.env" 2>/dev/null)"
fi

trap - EXIT; rm -rf "$T2"

# ── Test 3: empty roster ([]) → self-skip ─────────────────────────────────────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT
make_bin "$T3"; mkdir -p "$T3/etc" "$T3/var"
write_node_config "$T3/etc"
printf '[]\n' > "$T3/var/peer-roster.json"
cat > "$T3/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then echo "DIALED" >&2; exit 0; fi
exit 1
STUB
chmod +x "$T3/docker"
set +e
ERR3=$(PATH="$T3:/usr/bin:/bin" \
    _NODE_CONFIG="$T3/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T3/var" _PEER_ROSTER_FILE="$T3/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t3" OXPULSE_SERVICE_TOKEN="stkn_t3" \
    OXPULSE_TURN_SECRET="s" \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e
if ! printf '%s' "$ERR3" | grep -q 'DIALED'; then
    ok "test3: empty roster → no dial"
else
    fail "test3: empty roster still dialed a peer"
fi
if grep -q '^PEER_PROBE_MODE=disabled$' "$T3/var/peer-probe-mode.env" 2>/dev/null; then
    ok "test3: empty roster → state=disabled"
else
    fail "test3: expected PEER_PROBE_MODE=disabled; state: $(cat "$T3/var/peer-probe-mode.env" 2>/dev/null)"
fi
trap - EXIT; rm -rf "$T3"

# ── Test 4: absent roster file → self-skip ────────────────────────────────────
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT
make_bin "$T4"; mkdir -p "$T4/etc" "$T4/var"
write_node_config "$T4/etc"
cat > "$T4/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
exit 1
STUB
chmod +x "$T4/docker"
set +e
RC4=0
PATH="$T4:/usr/bin:/bin" \
    _NODE_CONFIG="$T4/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T4/var" _PEER_ROSTER_FILE="$T4/var/does-not-exist.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t4" OXPULSE_SERVICE_TOKEN="stkn_t4" \
    OXPULSE_TURN_SECRET="s" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1 || RC4=$?
set -e
if [[ "$RC4" -eq 0 ]]; then
    ok "test4: absent roster file → clean exit 0 (graceful skip)"
else
    fail "test4: absent roster file caused non-zero exit $RC4"
fi
trap - EXIT; rm -rf "$T4"

# ── Test 5: no cross-probe token → self-skip (fail-closed) ────────────────────
T5=$(mktemp -d)
trap 'rm -rf "$T5"' EXIT
make_bin "$T5"; mkdir -p "$T5/etc" "$T5/var"
write_node_config "$T5/etc"
printf '[{"node_id":"peer-pub","turns_host":"good.example.com","turns_port":443}]\n' \
    > "$T5/var/peer-roster.json"
cat > "$T5/getent" <<'STUB'
#!/bin/sh
[ "$2" = "good.example.com" ] && { echo "198.51.100.9 STREAM"; exit 0; }
exit 2
STUB
chmod +x "$T5/getent"
cat > "$T5/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then echo "DIALED" >&2; exit 0; fi
exit 1
STUB
chmod +x "$T5/docker"
# _CROSS_PROBE_TOKEN_FILE points at a non-existent file AND no env token.
set +e
ERR5=$(PATH="$T5:/usr/bin:/bin" \
    _NODE_CONFIG="$T5/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T5/var" _PEER_ROSTER_FILE="$T5/var/peer-roster.json" \
    _CROSS_PROBE_TOKEN_FILE="$T5/etc/no-token" OXPULSE_SERVICE_TOKEN="stkn_t5" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T5/getent" \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e
if ! printf '%s' "$ERR5" | grep -q 'DIALED'; then
    ok "test5: no cross-probe token → no dial (fail-closed)"
else
    fail "test5: probed despite missing cross-probe token"
fi
if printf '%s' "$ERR5" | grep -qi 'no cross-probe token'; then
    ok "test5: skip is logged (graceful degrade)"
else
    fail "test5: expected a 'no cross-probe token' skip log; got: $ERR5"
fi
trap - EXIT; rm -rf "$T5"

# ── Test 6: secret-not-on-argv during a peer probe (SEC-CR-001) ───────────────
T6=$(mktemp -d)
trap 'rm -rf "$T6"' EXIT
make_bin "$T6"; mkdir -p "$T6/etc" "$T6/var"
write_node_config "$T6/etc"
printf '[{"node_id":"peer-pub","turns_host":"good.example.com","turns_port":443}]\n' \
    > "$T6/var/peer-roster.json"
cat > "$T6/getent" <<'STUB'
#!/bin/sh
[ "$2" = "good.example.com" ] && { echo "198.51.100.9 STREAM"; exit 0; }
exit 2
STUB
chmod +x "$T6/getent"

LEAK_MARKER="XPRBSECRETLEAK_d41d8cd98f00b204e9800998"
ARGV_LOG="$T6/hmac_argv.log"
REAL_PYTHON3=$(command -v python3)

cat > "$T6/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then echo "$LEAK_MARKER"; exit 0; fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then echo "allocate success"; exit 0; fi
exit 1
STUB
chmod +x "$T6/docker"

# HMAC stub: record argv, delegate to real python3 (valid cred still produced).
cat > "$T6/hmac_stub" <<STUB
#!/bin/bash
printf '%s\n' "\$*" >> "$ARGV_LOG"
exec "$REAL_PYTHON3" "\$@"
STUB
chmod +x "$T6/hmac_stub"

set +e
PATH="$T6:/usr/bin:/bin" \
    _NODE_CONFIG="$T6/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T6/var" _PEER_ROSTER_FILE="$T6/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t6" OXPULSE_SERVICE_TOKEN="stkn_t6" \
    OXPULSE_TURN_SECRET="$LEAK_MARKER" OXPULSE_GETENT_BIN="$T6/getent" \
    OXPULSE_HMAC_BIN="$T6/hmac_stub" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e

if [[ -s "$ARGV_LOG" ]]; then
    ok "test6: HMAC binary invoked during peer probe (real mint path)"
else
    fail "test6: HMAC argv log empty — peer-probe mint path did not run"
fi
if grep -q "$LEAK_MARKER" "$ARGV_LOG" 2>/dev/null; then
    fail "test6: SECRET LEAK — base TURN secret found on HMAC argv: $(cat "$ARGV_LOG")"
else
    ok "test6: base TURN secret NOT on HMAC argv during peer probe (no /proc/cmdline leak)"
fi
if grep -qE ':[0-9]*healthprobe|[0-9]+:healthprobe' "$ARGV_LOG" 2>/dev/null; then
    ok "test6: HMAC input uses canonical <ts>:healthprobe username"
else
    fail "test6: expected <ts>:healthprobe on HMAC argv; got: $(cat "$ARGV_LOG")"
fi
trap - EXIT; rm -rf "$T6"

# ── Test 7: budget cap — at most OXPULSE_PEER_PROBE_MAX dials per cycle ────────
T7=$(mktemp -d)
trap 'rm -rf "$T7"' EXIT
make_bin "$T7"; mkdir -p "$T7/etc" "$T7/var"
write_node_config "$T7/etc"
# 5 public peers; cap to 2.
cat > "$T7/var/peer-roster.json" <<'JSON'
[
  {"node_id":"p1","turns_host":"h1.example.com","turns_port":443},
  {"node_id":"p2","turns_host":"h2.example.com","turns_port":443},
  {"node_id":"p3","turns_host":"h3.example.com","turns_port":443},
  {"node_id":"p4","turns_host":"h4.example.com","turns_port":443},
  {"node_id":"p5","turns_host":"h5.example.com","turns_port":443}
]
JSON
cat > "$T7/getent" <<'STUB'
#!/bin/sh
# all h*.example.com resolve to distinct public addresses
case "$2" in h[1-5].example.com) echo "203.0.113.${2#h}0 STREAM"; exit 0 ;; esac
exit 2
STUB
chmod +x "$T7/getent"
DIAL7="$T7/dial.log"
# Count ONLY peer-probe (TLS, -S) dials — the ch4 self-probe shares the
# turnutils_uclient stub but dials plain turn:3478 (no -S) and is NOT bounded by
# the peer-probe cap; counting it would over-report by 1 (mirrors test2's -S
# filter rationale).
cat > "$T7/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    [[ "\$*" == *" -S "* ]] && printf 'd\n' >> "$DIAL7"
    echo "allocate success"
    exit 0
fi
exit 1
STUB
chmod +x "$T7/docker"
set +e
PATH="$T7:/usr/bin:/bin" \
    _NODE_CONFIG="$T7/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T7/var" _PEER_ROSTER_FILE="$T7/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t7" OXPULSE_SERVICE_TOKEN="stkn_t7" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T7/getent" \
    OXPULSE_PEER_PROBE_MAX=2 \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e
DIALS=$(wc -l < "$DIAL7" 2>/dev/null || echo 0)
if [[ "$DIALS" -eq 2 ]]; then
    ok "test7: budget cap honoured — exactly 2 dials for a 5-peer roster (cap=2)"
else
    fail "test7: expected 2 dials under cap=2; got $DIALS"
fi
trap - EXIT; rm -rf "$T7"

# ── Test 8: untrusted host with shell metacharacters is not executed ──────────
# A roster host containing shell metacharacters must NOT be interpreted by the
# shell. It resolves-internal (getent returns nothing → fail-closed reject), so
# the marker file the injection would create must NOT appear.
T8=$(mktemp -d)
trap 'rm -rf "$T8"' EXIT
make_bin "$T8"; mkdir -p "$T8/etc" "$T8/var"
write_node_config "$T8/etc"
INJECT_MARKER="$T8/INJECTED"
# turns_host carries a command-substitution payload that would touch the marker
# IF the value were ever evaluated by a shell.
printf '[{"node_id":"evil","turns_host":"$(touch %s)","turns_port":443}]\n' \
    "$INJECT_MARKER" > "$T8/var/peer-roster.json"
cat > "$T8/getent" <<'STUB'
#!/bin/sh
exit 2
STUB
chmod +x "$T8/getent"
cat > "$T8/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then exit 0; fi
exit 1
STUB
chmod +x "$T8/docker"
set +e
PATH="$T8:/usr/bin:/bin" \
    _NODE_CONFIG="$T8/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T8/var" _PEER_ROSTER_FILE="$T8/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t8" OXPULSE_SERVICE_TOKEN="stkn_t8" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T8/getent" \
    bash "$SCRIPT" --dry-run >/dev/null 2>&1
set -e
if [[ ! -e "$INJECT_MARKER" ]]; then
    ok "test8: shell-metachar host NOT evaluated (no command injection)"
else
    fail "test8: COMMAND INJECTION — marker file created from a roster host value"
fi
trap - EXIT; rm -rf "$T8"

echo
echo "Cross-probe loop: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
