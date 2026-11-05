#!/usr/bin/env bash
# tests/test_relay_probe_uclient.sh — relay_probe_allocate picks the turnutils_uclient
# shipped next to the running turnserver, not whatever is first on PATH.
#
# Why: a distro 4.6.1 client against an upgraded 4.18 turnserver fails
# `channel bind: error 400` (exit 255), so a working relay reported
# handshake_ok=false. The PATH stub below reproduces that failure.
#
# Mutation that must turn this RED (the call site, not the helper):
#   * relay/relay-probe-lib.sh relay_probe_allocate(): replace
#     `"$(relay_probe_uclient)"` with `"${TURN_UCLIENT:-turnutils_uclient}"`
#     -> "shipped client wins over PATH", "fallback ..." stays green, and the
#     PATH stub's 255 turns "shipped client wins over PATH" + "PATH client is
#     not invoked when a shipped one exists" RED.
set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="${RELAY_PROBE_LIB:-$REPO_ROOT/relay/relay-probe-lib.sh}"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
command -v python3 >/dev/null || { echo "SKIP: python3 not available"; exit 0; }
T="$(mktemp -d)"; trap 'rm -rf -- "${T:?}"' EXIT

mkdir -p "$T/bin" "$T/lib/releases/1.0.0" "$T/etc"
echo "test-secret" > "$T/etc/node-secret"
# PATH client = the distro 4.6.1 one: fails against a 4.18 server.
cat > "$T/bin/turnutils_uclient" <<STUB
#!/bin/bash
echo path >> "$T/calls"
echo "channel bind: error 400" >&2
exit 255
STUB
# shipped client = the one released with the running turnserver.
cat > "$T/lib/releases/1.0.0/turnutils_uclient" <<STUB
#!/bin/bash
echo shipped >> "$T/calls"
exit 0
STUB
# an explicit override
cat > "$T/override" <<STUB
#!/bin/bash
echo override >> "$T/calls"
exit 0
STUB
chmod +x "$T/bin/turnutils_uclient" "$T/lib/releases/1.0.0/turnutils_uclient" "$T/override"

# probe <env...>: run relay_probe_allocate in a clean subshell; prints "rc calls".
probe() {
	: > "$T/calls"
	local rc
	env -i PATH="$T/bin:/usr/bin:/bin" HOME="$T" "$@" bash -c '
		warn() { :; }
		_PREFIX_ETC="$1"; EXTERNAL_IP=192.0.2.1; RELAY_HOSTNAME=relay.example
		. "$2"
		relay_probe_allocate' _ "$T/etc" "$LIB" >/dev/null 2>&1
	rc=$?
	echo "$rc $(tr '\n' ',' < "$T/calls")"
}
ln -sfn releases/1.0.0 "$T/lib/current"

r="$(probe RELAY_LIB_DIR="$T/lib")"
[[ "$r" == "0 shipped," ]] && pass "shipped client wins over PATH" || fail "shipped client wins over PATH (got: $r)"
[[ "$r" != *path* ]] && pass "PATH client is not invoked when a shipped one exists" || fail "PATH client is not invoked when a shipped one exists (got: $r)"

# upgrader rollback: current re-pointed at another release -> that release's client.
mkdir -p "$T/lib/releases/0.0.0"
printf '#!/bin/bash\necho previous >> "%s/calls"\nexit 0\n' "$T" > "$T/lib/releases/0.0.0/turnutils_uclient"
chmod +x "$T/lib/releases/0.0.0/turnutils_uclient"
ln -sfn releases/0.0.0 "$T/lib/current"
r="$(probe RELAY_LIB_DIR="$T/lib")"
[[ "$r" == "0 previous," ]] && pass "follows current after a rollback" || fail "follows current after a rollback (got: $r)"

# no shipped client (current missing, or not executable) -> PATH.
rm -f "$T/lib/current"
r="$(probe RELAY_LIB_DIR="$T/lib")"
[[ "$r" == "1 path," ]] && pass "fallback: no current client -> PATH client" || fail "fallback: no current client -> PATH client (got: $r)"
ln -sfn releases/1.0.0 "$T/lib/current"; chmod -x "$T/lib/releases/1.0.0/turnutils_uclient"
r="$(probe RELAY_LIB_DIR="$T/lib")"
[[ "$r" == "1 path," ]] && pass "fallback: non-executable current client -> PATH client" || fail "fallback: non-executable current client -> PATH client (got: $r)"
chmod +x "$T/lib/releases/1.0.0/turnutils_uclient"

# TURN_UCLIENT overrides both.
r="$(probe RELAY_LIB_DIR="$T/lib" TURN_UCLIENT="$T/override")"
[[ "$r" == "0 override," ]] && pass "TURN_UCLIENT overrides shipped and PATH" || fail "TURN_UCLIENT overrides shipped and PATH (got: $r)"
rm -f "$T/lib/current"
r="$(probe RELAY_LIB_DIR="$T/lib" TURN_UCLIENT="$T/override")"
[[ "$r" == "0 override," ]] && pass "TURN_UCLIENT overrides PATH when nothing is shipped" || fail "TURN_UCLIENT overrides PATH when nothing is shipped (got: $r)"

echo "---- $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
