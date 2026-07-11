#!/usr/bin/env bash
# tests/test_peer_ip_guard_lib.sh — direct-source unit tests for
# lib/peer-ip-guard-lib.sh (SSRF / internal-IP classification guard).
#
# P1 of the 2026-07-08 health-report-lib-extraction plan
# (the operator's internal health-report-lib extraction plan (2026-07-08)):
# extract _ip_is_internal / _host_is_internal / _ipv4_literal_is_suspect /
# _ipv6_embedded_v4 out of oxpulse-channels-health-report.sh (was lines 610-784)
# into their own lib. This file ports EVERY SEC-CR assertion the inline
# functions carried, so the extraction is provably behavior-preserving.
#
# Threat classes pinned here (see lib header for the SEC-CR-NNN citations):
#   SEC-CR-301  non-canonical IPv4 literal encodings (hex/octal/decimal/short)
#   SEC-CR-306  byte-level embedded-v4 in IPv6 (mapped/NAT64/compat), ANY
#               textual encoding (dotted AND hex-compressed) — a 2026-06-12
#               crypto-security review (306-88340f3) found the hex-compressed
#               forms (::ffff:7f00:1 etc.) slipped past an earlier dotted-only
#               matcher; this suite pins that regression closed.
#   SEC-CR-322-02  vetted dial-IP echo (DNS-rebind TOCTOU defence-in-depth)
#
# Plain bash, no bats (repo convention — see tests/test_settle_dual_pin_consistency.sh).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LIB="$REPO_ROOT/lib/peer-ip-guard-lib.sh"

[[ -f "$LIB" ]] || { echo "FAIL: lib/peer-ip-guard-lib.sh not found at $LIB"; exit 1; }

# shellcheck disable=SC1090
source "$LIB"

PASS=0
FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*" >&2; FAIL=$((FAIL + 1)); }

echo "test_peer_ip_guard_lib.sh"
echo

# ── 0. Provides: every function the header advertises actually loaded ──────
for fn in _ip_is_internal _host_is_internal _ipv4_literal_is_suspect _ipv6_embedded_v4; do
    if declare -F "$fn" >/dev/null 2>&1; then
        ok "P0: $fn is defined after sourcing the lib"
    else
        bad "P0: $fn NOT defined — extraction dropped it"
    fi
done

# ── helper: assert a classifier's return code for one input ────────────────
# $1 label  $2 function  $3 arg  $4 expected rc (0=internal/reject, 1=public/allow)
assert_rc() {
    local label="$1" fn="$2" arg="$3" expected="$4"
    local rc
    # NOTE: must call under an if/&&-guard, not a bare "cmd; rc=$?" — under
    # set -e, a bare simple command that returns nonzero aborts the script
    # BEFORE "rc=$?" runs (this bit even inside _ip_is_internal's own
    # internal `_embedded_v4=$(...)` assignment when the guard is missing).
    if "$fn" "$arg" >/dev/null 2>&1; then rc=0; else rc=$?; fi
    if [[ "$rc" == "$expected" ]]; then
        ok "$label: $fn '$arg' -> rc=$rc (expected $expected)"
    else
        bad "$label: $fn '$arg' -> rc=$rc (expected $expected)"
    fi
}

# ── 1. _ip_is_internal — literal IPv4/IPv6 range classification ────────────
assert_rc "T1"  _ip_is_internal "::1"                    0   # IPv6 loopback
assert_rc "T2"  _ip_is_internal "0.0.0.0"                 0   # "this network" / unspecified
assert_rc "T3"  _ip_is_internal "127.0.0.1"               0   # IPv4 loopback
assert_rc "T4"  _ip_is_internal "10.0.0.5"                0   # RFC-1918
assert_rc "T5"  _ip_is_internal "192.168.1.1"             0   # RFC-1918
assert_rc "T6"  _ip_is_internal "169.254.169.254"         0   # link-local / cloud metadata
assert_rc "T7"  _ip_is_internal "172.16.0.1"              0   # RFC-1918 172.16/12
assert_rc "T8"  _ip_is_internal "100.64.0.1"              0   # CGNAT 100.64.0.0/10
assert_rc "T9"  _ip_is_internal "fe80::1"                 0   # IPv6 link-local
assert_rc "T10" _ip_is_internal "fc00::1"                 0   # IPv6 ULA
assert_rc "T11" _ip_is_internal "8.8.8.8"                 1   # public v4
assert_rc "T12" _ip_is_internal "2001:db8::1"             1   # public pure v6 (python3 present)

# ── 2. SEC-CR-306 — embedded-v4 in IPv6, byte-level, ANY textual encoding ──
# IPv4-mapped ::ffff:0:0/96 — dotted AND hex-compressed AND uppercase.
assert_rc "T13 (SEC-CR-306 mapped/dotted)"        _ip_is_internal "::ffff:127.0.0.1" 0
assert_rc "T14 (SEC-CR-306 mapped/hex-compressed)" _ip_is_internal "::ffff:7f00:1"    0
assert_rc "T15 (SEC-CR-306 mapped/hex-uppercase)"  _ip_is_internal "::FFFF:7F00:1"    0
# NAT64 well-known 64:ff9b::/96 — dotted AND hex-compressed.
assert_rc "T16 (SEC-CR-306 NAT64/dotted)"          _ip_is_internal "64:ff9b::127.0.0.1" 0
assert_rc "T17 (SEC-CR-306 NAT64/hex-compressed)"  _ip_is_internal "64:ff9b::7f00:1"    0
# IPv4-compatible (deprecated, all-zero prefix) embedding an RFC-1918 address.
assert_rc "T18 (SEC-CR-306 compat/embeds-1918)"    _ip_is_internal "::10.0.0.1"         0
# A public v4 embedded via the mapped prefix must still be classified PUBLIC
# (the extractor must not reject on prefix match alone — only on the embedded
# value being internal).
assert_rc "T19 (SEC-CR-306 mapped/public embedded)" _ip_is_internal "::ffff:8.8.8.8"    1

# ── 3. _ipv6_embedded_v4 — the byte-level extractor's own tri-state contract ─
if out=$(_ipv6_embedded_v4 "::ffff:127.0.0.1" 2>/dev/null); then rc=0; else rc=$?; fi
[[ "$rc" == 0 && "$out" == "127.0.0.1" ]] \
    && ok "T20: _ipv6_embedded_v4 mapped-loopback -> rc=0 prints 127.0.0.1" \
    || bad "T20: _ipv6_embedded_v4 mapped-loopback -> rc=$rc out='$out' (expected rc=0 '127.0.0.1')"

if _ipv6_embedded_v4 "2001:db8::1" >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ "$rc" == 1 ]] \
    && ok "T21: _ipv6_embedded_v4 pure-v6 (no embedded v4) -> rc=1" \
    || bad "T21: _ipv6_embedded_v4 pure-v6 -> rc=$rc (expected 1)"

if _ipv6_embedded_v4 "not-an-ip" >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ "$rc" == 2 ]] \
    && ok "T22: _ipv6_embedded_v4 unparseable literal -> rc=2 (ambiguous, caller fails closed)" \
    || bad "T22: _ipv6_embedded_v4 unparseable -> rc=$rc (expected 2)"

# ── 4. _ipv4_literal_is_suspect — SEC-CR-301 non-canonical encoding gate ───
assert_rc "T23 (SEC-CR-301 canonical clean)"   _ipv4_literal_is_suspect "127.0.0.1"   1
assert_rc "T24 (SEC-CR-301 canonical public)"  _ipv4_literal_is_suspect "8.8.8.8"     1
assert_rc "T25 (SEC-CR-301 octal loopback)"    _ipv4_literal_is_suspect "0177.0.0.1"  0
assert_rc "T26 (SEC-CR-301 short-form)"        _ipv4_literal_is_suspect "127.1"       0
assert_rc "T27 (SEC-CR-301 decimal loopback)"  _ipv4_literal_is_suspect "2130706433"  0

# ── 5. _host_is_internal — the top-level dial-time gate every caller uses ──
# Non-canonical numeric encodings must reject WITHOUT ever reaching a resolver.
assert_rc "T28 (SEC-CR-301 hex loopback via host gate)"     _host_is_internal "0x7f000001"  0
assert_rc "T29 (SEC-CR-301 octal loopback via host gate)"   _host_is_internal "0177.0.0.1"  0
assert_rc "T30 (SEC-CR-301 decimal loopback via host gate)" _host_is_internal "2130706433"  0
assert_rc "T31 (SEC-CR-301 short-form via host gate)"       _host_is_internal "127.1"       0
assert_rc "T32 (IPv6 literal via host gate)"                _host_is_internal "::1"         0
assert_rc "T33 (SEC-CR-306 mapped literal via host gate)"   _host_is_internal "::ffff:127.0.0.1" 0

# SEC-CR-322-02: a public host's vetted dial IP is echoed on stdout (pins the
# dial to the exact address the guard vetted, closing resolve-then-dial TOCTOU).
if out=$(_host_is_internal "8.8.8.8" 2>/dev/null); then rc=0; else rc=$?; fi
[[ "$rc" == 1 && "$out" == "8.8.8.8" ]] \
    && ok "T34 (SEC-CR-322-02): _host_is_internal public literal echoes vetted IP" \
    || bad "T34 (SEC-CR-322-02): rc=$rc out='$out' (expected rc=1 out=8.8.8.8)"

# Empty host must fail closed (reject), never crash under set -u callers.
assert_rc "T35 (empty host fails closed)" _host_is_internal "" 0

# ── 6. python3-missing fail-closed default (MUST reject, never allow) ──────
# _ipv6_embedded_v4 shells to python3 for byte-level classification; the guard
# must NEVER silently allow a v6-shaped literal it cannot vet because the
# interpreter isn't there.
OXPULSE_PY_BIN="/nonexistent/python3-not-installed"

if _ipv6_embedded_v4 "::1" >/dev/null 2>&1; then rc=0; else rc=$?; fi
[[ "$rc" != 0 ]] \
    && ok "T36: _ipv6_embedded_v4 with python3 missing never returns rc=0 (never claims a confident embedded-v4 read); got rc=$rc" \
    || bad "T36: _ipv6_embedded_v4 with python3 missing returned rc=0 — false confident read"

assert_rc "T37 (python3 missing, known-loopback still rejects)"        _ip_is_internal "::1"        0
assert_rc "T38 (python3 missing, a PUBLIC pure-v6 fails closed too)"   _ip_is_internal "2001:db8::1" 0
assert_rc "T39 (python3 missing, propagates through _host_is_internal)" _host_is_internal "::1"      0

unset OXPULSE_PY_BIN

echo
echo "── peer-ip-guard-lib fitness: $PASS passed, $FAIL failed ──"
[[ "$FAIL" -eq 0 ]] || exit 1
