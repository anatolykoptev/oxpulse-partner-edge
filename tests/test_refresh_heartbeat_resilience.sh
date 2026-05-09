#!/bin/bash
# Behavioral regression tests for oxpulse-partner-edge-refresh.sh preflight checks.
#
# Incident 2026-05-09 root cause: cheburator1 had jq absent from systemd unit
# PATH. set -euo pipefail exits before the heartbeat POST, leaving last_seen_at
# stale for 1 week.
#
# Tests verify the script fails fast with a clear message when required tools
# are missing, using stub binaries rather than grepping source text.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/oxpulse-partner-edge-refresh.sh"

[[ -f "$SCRIPT" ]] || { echo "FAIL: refresh script not found at $SCRIPT"; exit 1; }

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Helper: create a stub bin dir containing only the listed tools (from system),
# plus any extra stubs. Tools NOT listed are absent → command -v returns nonzero.
# We avoid including /usr/bin or /bin in PATH so only our stubs are visible.
make_bin() {
    local dir="$1"; shift
    # Provide essential POSIX utilities the script needs (date, printf, cat, etc.)
    # by symlinking them. These are always available in /bin or /usr/bin.
    for cmd in bash sh date printf cat tee cp mv mkdir chmod install sleep \
                sed grep head tail wc stat cut tr expr test; do
        local loc
        loc=$(command -v "$cmd" 2>/dev/null || true)
        if [[ -n "$loc" ]]; then ln -sf "$loc" "$dir/$cmd"; fi
    done
    # Also provide systemctl and other system tools as no-ops so script
    # doesn't abort on them before reaching what we're testing.
    cat > "$dir/systemctl" <<'STUB'
#!/bin/sh
exit 0
STUB
    chmod +x "$dir/systemctl"
    # Caller adds specific tool stubs after this call.
}

# ── Test 1: jq missing → nonzero exit + "jq required" ───────────────────────
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

make_bin "$T1"
# curl stub present (passes curl preflight), jq absent
cat > "$T1/curl" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T1/curl"
# jq intentionally absent from T1

set +e
PATH="$T1" LOG_FILE="$T1/refresh.log" bash "$SCRIPT" >"$T1/out_jq.txt" 2>&1
jq_exit=$?
set -e

[[ $jq_exit -ne 0 ]] \
    || fail "test1: script must exit nonzero when jq is missing (got exit 0)"
grep -qi "jq required" "$T1/out_jq.txt" \
    || fail "test1: output must contain 'jq required' when jq missing; got: $(cat "$T1/out_jq.txt")"
pass "test1: jq missing → exit $jq_exit, output contains 'jq required'"

trap - EXIT
rm -rf "$T1"

# ── Test 2: curl missing → nonzero exit + "curl required" ────────────────────
T2=$(mktemp -d)
trap 'rm -rf "$T2"' EXIT

make_bin "$T2"
# jq stub present (passes jq preflight), curl absent
if command -v jq >/dev/null 2>&1; then
    ln -sf "$(command -v jq)" "$T2/jq"
else
    cat > "$T2/jq" <<'EOF'
#!/bin/sh
# Minimal stub: passes command -v check; actual jq calls not reached before curl check
echo "stub"
EOF
    chmod +x "$T2/jq"
fi
# curl intentionally absent from T2

set +e
PATH="$T2" LOG_FILE="$T2/refresh.log" bash "$SCRIPT" >"$T2/out_curl.txt" 2>&1
curl_exit=$?
set -e

[[ $curl_exit -ne 0 ]] \
    || fail "test2: script must exit nonzero when curl is missing (got exit 0)"
grep -qi "curl required" "$T2/out_curl.txt" \
    || fail "test2: output must contain 'curl required' when curl missing; got: $(cat "$T2/out_curl.txt")"
pass "test2: curl missing → exit $curl_exit, output contains 'curl required'"

trap - EXIT
rm -rf "$T2"

# ── Test 3: dnf-only host → die message suggests "dnf install -y jq" ─────────
T3=$(mktemp -d)
trap 'rm -rf "$T3"' EXIT

make_bin "$T3"
# provide dnf stub, no apt-get, no curl (jq check fires first)
cat > "$T3/dnf" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T3/dnf"
# jq and curl intentionally absent so jq preflight fires

set +e
PATH="$T3" LOG_FILE="$T3/refresh.log" bash "$SCRIPT" >"$T3/out_dnf.txt" 2>&1
dnf_exit=$?
set -e

[[ $dnf_exit -ne 0 ]] \
    || fail "test3: script must exit nonzero when jq is missing"
grep -q "dnf install -y jq" "$T3/out_dnf.txt" \
    || fail "test3: die message must contain 'dnf install -y jq' when dnf is the only PM; got: $(cat "$T3/out_dnf.txt")"
grep -v "apt-get" "$T3/out_dnf.txt" >/dev/null \
    || fail "test3: die message must NOT contain 'apt-get' on dnf-only host; got: $(cat "$T3/out_dnf.txt")"
pass "test3: dnf-only host → die message contains 'dnf install -y jq'"

trap - EXIT
rm -rf "$T3"

# ── Test 4: apt-get-only host → die message suggests "apt-get install -y jq" ─
T4=$(mktemp -d)
trap 'rm -rf "$T4"' EXIT

make_bin "$T4"
# provide apt-get stub, no dnf, no curl (jq check fires first)
cat > "$T4/apt-get" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T4/apt-get"
# jq and curl intentionally absent so jq preflight fires

set +e
PATH="$T4" LOG_FILE="$T4/refresh.log" bash "$SCRIPT" >"$T4/out_apt.txt" 2>&1
apt_exit=$?
set -e

[[ $apt_exit -ne 0 ]] \
    || fail "test4: script must exit nonzero when jq is missing"
grep -q "apt-get install -y jq" "$T4/out_apt.txt" \
    || fail "test4: die message must contain 'apt-get install -y jq' when apt-get is the only PM; got: $(cat "$T4/out_apt.txt")"
pass "test4: apt-get-only host → die message contains 'apt-get install -y jq'"

trap - EXIT
rm -rf "$T4"

# ── Syntax check ──────────────────────────────────────────────────────────────
bash -n "$SCRIPT" \
    || fail "refresh script has syntax errors"
pass "syntax check clean"

echo ""
echo "All tests passed."
