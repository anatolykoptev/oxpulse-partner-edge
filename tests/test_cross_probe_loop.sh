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

# ── Test 9: SEC-CR-301 extended SSRF classifier ───────────────────────────────
# Each new internal/ambiguous IP-literal class must be REJECTED before any dial:
#   CGNAT 100.64/10, 0.0.0.0/8, IPv4-mapped/compat IPv6, bracketed IPv6,
#   non-dotted-decimal IPv4 (hex / octal / decimal). A clean public dotted-quad
#   literal must still be ALLOWED (the dial happens). Mirrors T2's -S dial filter.
T9=$(mktemp -d)
trap 'rm -rf "$T9"' EXIT
make_bin "$T9"; mkdir -p "$T9/etc" "$T9/var"
write_node_config "$T9/etc"
cat > "$T9/var/peer-roster.json" <<'JSON'
[
  {"node_id":"cgnat","turns_host":"100.64.1.1","turns_port":443},
  {"node_id":"zeronet","turns_host":"0.1.2.3","turns_port":443},
  {"node_id":"v4mapped","turns_host":"::ffff:127.0.0.1","turns_port":443},
  {"node_id":"v4compat","turns_host":"::127.0.0.1","turns_port":443},
  {"node_id":"bracketed","turns_host":"[::1]","turns_port":443},
  {"node_id":"hexlit","turns_host":"0x7f000001","turns_port":443},
  {"node_id":"octlit","turns_host":"0177.0.0.1","turns_port":443},
  {"node_id":"declit","turns_host":"2130706433","turns_port":443},
  {"node_id":"mapped-cgnat","turns_host":"::ffff:100.64.0.9","turns_port":443},
  {"node_id":"mapped-hex","turns_host":"::ffff:7f00:1","turns_port":443},
  {"node_id":"mapped-hex-upper","turns_host":"::FFFF:7F00:1","turns_port":443},
  {"node_id":"compat-hex","turns_host":"::7f00:1","turns_port":443},
  {"node_id":"nat64-hex","turns_host":"64:ff9b::7f00:1","turns_port":443},
  {"node_id":"nat64-dotted","turns_host":"64:ff9b::127.0.0.1","turns_port":443},
  {"node_id":"pub","turns_host":"203.0.113.77","turns_port":443},
  {"node_id":"pub-mapped","turns_host":"::ffff:8.8.8.8","turns_port":443},
  {"node_id":"pub-v6","turns_host":"2606:4700:4700::1111","turns_port":443}
]
JSON
# getent: only used for hostname forms; all entries here are IP literals classified
# without resolution, so getent should NOT even be consulted for them. Provide a
# fail-closed stub anyway.
cat > "$T9/getent" <<'STUB'
#!/bin/sh
exit 2
STUB
chmod +x "$T9/getent"
DIAL9="$T9/dial.log"
cat > "$T9/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    [[ "\$*" == *" -S "* ]] && printf '%s\n' "\$*" >> "$DIAL9"
    echo "allocate success"
    exit 0
fi
exit 1
STUB
chmod +x "$T9/docker"
set +e
ERR9=$(PATH="$T9:/usr/bin:/bin" \
    _NODE_CONFIG="$T9/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T9/var" _PEER_ROSTER_FILE="$T9/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t9" OXPULSE_SERVICE_TOKEN="stkn_t9" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T9/getent" \
    OXPULSE_PEER_PROBE_MAX=20 OXPULSE_PEER_PROBE_REJECT_HEADROOM=20 \
    bash "$SCRIPT" --dry-run 2>&1 >/dev/null)
set -e
# None of the 14 internal/ambiguous literals may appear in the dial log. The
# SEC-CR-306 family — hex-compressed / uppercase / IPv4-compat / NAT64 v4-mapped
# IPv6 (::ffff:7f00:1, ::FFFF:7F00:1, ::7f00:1, 64:ff9b::7f00:1, 64:ff9b::…) —
# bypassed the OLD string-shape classifier (it only matched a dotted ".*.*.*.*"
# tail) and connected to the embedded internal v4. They MUST now reject pre-dial.
LEAKED9=""
# NOTE: each token must be a substring UNIQUE to an internal roster host — do not
# add a token (e.g. bare "::1") that is also a substring of a PUBLIC dial target
# ("2606:4700:4700::1111" contains "::1"), or the -Fq match false-positives. We
# grep the bracketed loopback "[::1]" / its roster host instead where needed.
for bad in "100.64.1.1" "0.1.2.3" "::ffff:127.0.0.1" "::127.0.0.1" \
           "0x7f000001" "0177.0.0.1" "2130706433" "100.64.0.9" \
           "::ffff:7f00:1" "::FFFF:7F00:1" "::7f00:1" \
           "64:ff9b::7f00:1" "64:ff9b::127.0.0.1"; do
    grep -Fq "$bad" "$DIAL9" 2>/dev/null && LEAKED9="$LEAKED9 $bad"
done
if [[ -z "$LEAKED9" ]]; then
    ok "test9: all SEC-CR-301/306 classes REJECTED pre-dial (CGNAT/0.0.0.0/mapped/compat/bracket/hex/oct/dec/NAT64)"
else
    fail "test9: SSRF LEAK — dialed:$LEAKED9; dial log: $(cat "$DIAL9" 2>/dev/null)"
fi
# At least 14 REJECTs logged (one per internal literal in the roster).
if [[ $(printf '%s\n' "$ERR9" | grep -c 'REJECT') -ge 14 ]]; then
    ok "test9: 14 internal/ambiguous literals each logged a REJECT (incl. hex/NAT64 SEC-CR-306)"
else
    fail "test9: expected >=14 REJECT logs; got $(printf '%s\n' "$ERR9" | grep -c 'REJECT')"
fi
# The clean public dotted-quad literal WAS dialed (no false-positive over-block).
if grep -Fq "203.0.113.77" "$DIAL9" 2>/dev/null; then
    ok "test9: clean public dotted-quad literal ALLOWED (no over-block)"
else
    fail "test9: public literal 203.0.113.77 not dialed; dial log: $(cat "$DIAL9" 2>/dev/null)"
fi
# A public IPv4-MAPPED v6 (::ffff:8.8.8.8) and a real public v6 MUST still be
# allowed — the byte-level guard rejects only EMBEDDED-INTERNAL v4 and internal
# v6, never a public mapped/native address (regression-guard against over-block).
if grep -Fq "::ffff:8.8.8.8" "$DIAL9" 2>/dev/null; then
    ok "test9: public IPv4-mapped v6 (::ffff:8.8.8.8) ALLOWED (no over-block)"
else
    fail "test9: public mapped ::ffff:8.8.8.8 not dialed; dial log: $(cat "$DIAL9" 2>/dev/null)"
fi
if grep -Fq "2606:4700:4700::1111" "$DIAL9" 2>/dev/null; then
    ok "test9: public native v6 (2606:4700:4700::1111) ALLOWED (no over-block)"
else
    fail "test9: public v6 2606:4700:4700::1111 not dialed; dial log: $(cat "$DIAL9" 2>/dev/null)"
fi
trap - EXIT; rm -rf "$T9"

# ── Test 10: MINOR 5 rotation fairness — tail covered across cycles ───────────
# A 4-peer roster with cap=2 dials peers [0,1] cycle 1, then [2,3] cycle 2 (the
# persisted offset advances). Over two cycles every peer is dialed exactly once.
T10=$(mktemp -d)
trap 'rm -rf "$T10"' EXIT
make_bin "$T10"; mkdir -p "$T10/etc" "$T10/var"
write_node_config "$T10/etc"
cat > "$T10/var/peer-roster.json" <<'JSON'
[
  {"node_id":"r1","turns_host":"r1.example.com","turns_port":443},
  {"node_id":"r2","turns_host":"r2.example.com","turns_port":443},
  {"node_id":"r3","turns_host":"r3.example.com","turns_port":443},
  {"node_id":"r4","turns_host":"r4.example.com","turns_port":443}
]
JSON
cat > "$T10/getent" <<'STUB'
#!/bin/sh
case "$2" in r[1-4].example.com) echo "203.0.113.${2#r}0 STREAM"; exit 0 ;; esac
exit 2
STUB
chmod +x "$T10/getent"
DIAL10="$T10/dial.log"
cat > "$T10/docker" <<STUB
#!/bin/bash
if [[ "\$*" == *"sed"* && "\$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "\$*" == *"turnutils_uclient"* ]]; then
    # record the dialed hostname (last positional) for -S peer dials only
    [[ "\$*" == *" -S "* ]] && { for a in \$*; do last="\$a"; done; printf '%s\n' "\$last" >> "$DIAL10"; }
    echo "allocate success"; exit 0
fi
exit 1
STUB
chmod +x "$T10/docker"
run_cycle10() {
    set +e
    PATH="$T10:/usr/bin:/bin" \
        _NODE_CONFIG="$T10/etc/node-config.json" _TOKEN_LIB=/nonexistent \
        STATE_DIR="$T10/var" _PEER_ROSTER_FILE="$T10/var/peer-roster.json" \
        OXPULSE_CROSS_PROBE_TOKEN="xprb_t10" OXPULSE_SERVICE_TOKEN="stkn_t10" \
        OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T10/getent" \
        OXPULSE_PEER_PROBE_MAX=2 \
        bash "$SCRIPT" --dry-run >/dev/null 2>&1
    set -e
}
run_cycle10   # cycle 1 — offset 0 → dials r1,r2; persists next offset 2
run_cycle10   # cycle 2 — offset 2 → dials r3,r4; persists next offset 0
UNIQ10=$(sort -u "$DIAL10" 2>/dev/null | grep -c 'example.com' || echo 0)
if [[ "$UNIQ10" -eq 4 ]]; then
    ok "test10: rotation fair — all 4 peers dialed across 2 cycles (no permanent tail truncation)"
else
    fail "test10: expected 4 distinct peers over 2 cycles; got $UNIQ10 ($(sort -u "$DIAL10" 2>/dev/null | tr '\n' ' '))"
fi
# The persisted marker must record the offset + a non-empty dropped set in cycle 1
# state has rolled to cycle 2's terminal; just assert the OFFSET key exists.
if grep -q '^PEER_PROBE_OFFSET=' "$T10/var/peer-probe-mode.env" 2>/dev/null; then
    ok "test10: peer-probe-mode.env persists PEER_PROBE_OFFSET (rotation state)"
else
    fail "test10: expected PEER_PROBE_OFFSET in marker; state: $(cat "$T10/var/peer-probe-mode.env" 2>/dev/null)"
fi
trap - EXIT; rm -rf "$T10"

# ── Test 11: MINOR 6 persistent-4xx marker bit ────────────────────────────────
# A peer POST that returns 4xx (revoked token / roster membership) must set
# PEER_PROBE_POST_4XX=1 in the marker so the otherwise-swallowed 4xx is observable.
T11=$(mktemp -d)
trap 'rm -rf "$T11"' EXIT
make_bin "$T11"; mkdir -p "$T11/etc" "$T11/var"
write_node_config "$T11/etc"
printf '[{"node_id":"peer-pub","turns_host":"good.example.com","turns_port":443}]\n' \
    > "$T11/var/peer-roster.json"
cat > "$T11/getent" <<'STUB'
#!/bin/sh
[ "$2" = "good.example.com" ] && { echo "198.51.100.9 STREAM"; exit 0; }
exit 2
STUB
chmod +x "$T11/getent"
cat > "$T11/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then echo "allocate success"; exit 0; fi
exit 1
STUB
chmod +x "$T11/docker"
# curl stub returns 403 for the cross-probe POST so _post_cross_probe sees a 4xx.
# NOT --dry-run (dry-run skips the POST); use a real (stubbed) curl path.
cat > "$T11/curl" <<'STUB'
#!/bin/sh
printf '403'
exit 0
STUB
chmod +x "$T11/curl"
set +e
PATH="$T11:/usr/bin:/bin" \
    _NODE_CONFIG="$T11/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="$T11/var" _PEER_ROSTER_FILE="$T11/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t11" OXPULSE_SERVICE_TOKEN="stkn_t11" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="$T11/getent" \
    OXPULSE_BACKEND_API="https://api.test.invalid" \
    bash "$SCRIPT" >/dev/null 2>&1
set -e
if grep -q '^PEER_PROBE_POST_4XX=1$' "$T11/var/peer-probe-mode.env" 2>/dev/null; then
    ok "test11: persistent 4xx → PEER_PROBE_POST_4XX=1 in marker (revoked token observable)"
else
    fail "test11: expected PEER_PROBE_POST_4XX=1; state: $(cat "$T11/var/peer-probe-mode.env" 2>/dev/null)"
fi
trap - EXIT; rm -rf "$T11"

# ── Test 12: MAJOR 1 marker truthfulness under SIGTERM ────────────────────────
# A SIGTERM mid-loop must leave PEER_PROBE_MODE=interrupted (NOT a stale "peer").
# node-config has NO channels → main() goes STRAIGHT to _run_peer_probe_loop (no
# 10s self-probe to wait through). The peer dial blocks (docker stub sleeps), so
# the loop is parked at the dial with the 'started' marker already on disk when
# we SIGTERM. The signal trap must downgrade the marker to 'interrupted' (and
# never leave the terminal 'peer').
T12=$(mktemp -d)
trap 'rm -rf "$T12"' EXIT
make_bin "$T12"; mkdir -p "$T12/etc" "$T12/var"
# No channels → skip the self-probe loop entirely; go straight to the peer loop.
printf '{"node_id":"prober-node","channels":[]}\n' > "$T12/etc/node-config.json"
printf '[{"node_id":"slow","turns_host":"slow.example.com","turns_port":443}]\n' \
    > "$T12/var/peer-roster.json"
cat > "$T12/getent" <<'STUB'
#!/bin/sh
[ "$2" = "slow.example.com" ] && { echo "198.51.100.50 STREAM"; exit 0; }
exit 2
STUB
chmod +x "$T12/getent"
# docker stub: the turnutils dial sleeps so the loop is parked when we kill.
cat > "$T12/docker" <<'STUB'
#!/bin/bash
if [[ "$*" == *"sed"* && "$*" == *"static-auth-secret"* ]]; then echo "s"; exit 0; fi
if [[ "$*" == *"turnutils_uclient"* ]]; then sleep 30; echo "allocate success"; exit 0; fi
exit 1
STUB
chmod +x "$T12/docker"
set +e
# Run the script in its OWN process group (setsid) so we can SIGTERM the whole
# group — mirroring systemd, which signals the entire service cgroup (the bash
# script AND its blocking docker/sleep children). Signalling only the bash PID
# would leave the trap DEFERRED behind the foreground child until it exits.
setsid bash -c '
    PATH="'"$T12"':/usr/bin:/bin" \
    _NODE_CONFIG="'"$T12"'/etc/node-config.json" _TOKEN_LIB=/nonexistent \
    STATE_DIR="'"$T12"'/var" _PEER_ROSTER_FILE="'"$T12"'/var/peer-roster.json" \
    OXPULSE_CROSS_PROBE_TOKEN="xprb_t12" OXPULSE_SERVICE_TOKEN="stkn_t12" \
    OXPULSE_TURN_SECRET="s" OXPULSE_GETENT_BIN="'"$T12"'/getent" \
    OXPULSE_PEER_PROBE_TIMEOUT=30 \
    exec bash "'"$SCRIPT"'" --dry-run
' >/dev/null 2>&1 &
SCRIPT_PID=$!
# Poll until the 'started' marker shows the loop is parked (or give up after 5s).
_waited=0
while [[ ! -r "$T12/var/peer-probe-mode.env" ]] && [[ "$_waited" -lt 50 ]]; do
    sleep 0.1
    _waited=$((_waited + 1))
done
# Confirm the marker reached 'started' before we kill (the loop is parked at the
# blocking dial), then SIGTERM the whole process group (negative PID = the group
# led by SCRIPT_PID via setsid).
MODE12_PRE=$(sed -n 's/^PEER_PROBE_MODE=//p' "$T12/var/peer-probe-mode.env" 2>/dev/null | head -1 || true)
kill -TERM -- "-$SCRIPT_PID" 2>/dev/null || kill -TERM "$SCRIPT_PID" 2>/dev/null
wait "$SCRIPT_PID" 2>/dev/null
# Read the marker WITHOUT set -e (sed on a missing file returns 2 under pipefail).
MODE12=$(sed -n 's/^PEER_PROBE_MODE=//p' "$T12/var/peer-probe-mode.env" 2>/dev/null | head -1 || true)
set -e
if [[ "$MODE12_PRE" == "started" ]]; then
    ok "test12: 'started' marker present before SIGTERM (loop parked at dial)"
else
    fail "test12: expected 'started' pre-kill marker; got '$MODE12_PRE'"
fi
if [[ "$MODE12" == "interrupted" ]]; then
    # The SIGTERM trap MUST fire and downgrade the marker. The env reliably
    # produces 'interrupted'; we require it EXACTLY (no 'started' fallback) so a
    # future regression where the trap stops firing is caught, not masked.
    ok "test12: SIGTERM mid-loop → marker downgraded to 'interrupted' (no stale 'peer')"
else
    fail "test12: SIGTERM left marker MODE='$MODE12' (expected 'interrupted' — trap must fire)"
fi
trap - EXIT; rm -rf "$T12"

echo
echo "Cross-probe loop: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
