#!/bin/bash
# tests/test_publicip_dns_precedence.sh
#
# Regression guard for the coturn/SFU external-ip bug (live incident,
# 2026-07-17): hydrate.sh's step-1 PUBLIC_IP autodetect (curl ifconfig.me /
# api.ipify.org) returns the host's OUTBOUND egress IP. On a multi-homed
# host (e.g. an Oracle Cloud instance whose NAT-gateway EGRESS IP differs
# from its reserved INBOUND public IP) that value has no inbound path —
# using it verbatim for coturn's external-ip / the SFU's SFU_PUBLIC_IP makes
# every WebRTC relay candidate unreachable, so ICE connectivity checks stall
# (~6s) and calls never connect. Confirmed live: egress=132.145.192.254 (no
# inbound path) vs. the real reachable IP 129.159.103.86 (the TURNS DNS
# A-record); relay RTT dropped 6000ms→67ms once corrected.
#
# Fix: hydrate.sh's resolve_external_ip() and upgrade.sh's resolve_public_ip()
# resolve the authoritative external IP with explicit precedence:
#   1. OXPULSE_PUBLIC_IP env override (operator escape hatch)
#   2. DNS A-record of TURNS_SUBDOMAIN.PARTNER_DOMAIN — the authoritative
#      INBOUND address (exactly what clients connect to for TURNS:443)
#   3. curl ifconfig.me / api.ipify.org egress autodetect (pre-existing
#      fallback, unchanged)
#
# Test strategy: extract each function via awk (same pattern as
# tests/test_upgrade_syncs_healthcheck.sh Section B) into a sourceable
# preamble with a minimal log()/warn()/die() stub, PATH-stub dig/getent/curl,
# and execute the REAL function — not a re-implementation — asserting the
# resolved PUBLIC_IP / PUBLIC_IP_SOURCE for each precedence tier. hydrate.sh
# itself cannot be run end-to-end in CI (hardcoded /etc, /var/lib paths
# requiring root — see tests/test_hydrate_x_installer_version_header.sh),
# so function-extraction is the only way to falsify this behaviourally
# rather than just structurally.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HYDRATE="$REPO_ROOT/hydrate.sh"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$HYDRATE" ]] || { echo "FAIL: hydrate.sh not found at $HYDRATE"; exit 1; }
[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Section A — structural
# ===========================================================================
echo "=== Section A: structural ==="

bash -n "$HYDRATE" && pass "A1: hydrate.sh syntax clean" || { fail "A1: hydrate.sh syntax error"; exit 1; }
bash -n "$UPGRADE" && pass "A2: upgrade.sh syntax clean" || { fail "A2: upgrade.sh syntax error"; exit 1; }

grep -q '^resolve_external_ip() {' "$HYDRATE" \
    && pass "A3: resolve_external_ip() defined in hydrate.sh" \
    || { fail "A3: resolve_external_ip() not found in hydrate.sh"; exit 1; }
grep -q '^resolve_public_ip() {' "$UPGRADE" \
    && pass "A4: resolve_public_ip() defined in upgrade.sh" \
    || { fail "A4: resolve_public_ip() not found in upgrade.sh"; exit 1; }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ── extraction preambles ────────────────────────────────────────────────
HYDRATE_PREAMBLE="$TMPD/hydrate_fn.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^resolve_external_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE"
} > "$HYDRATE_PREAMBLE"
bash -n "$HYDRATE_PREAMBLE" || { fail "A5: extracted resolve_external_ip has syntax errors"; exit 1; }
pass "A5: extracted resolve_external_ip parses cleanly"

UPGRADE_PREAMBLE="$TMPD/upgrade_fn.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^resolve_public_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$UPGRADE_PREAMBLE"
bash -n "$UPGRADE_PREAMBLE" || { fail "A6: extracted resolve_public_ip has syntax errors"; exit 1; }
pass "A6: extracted resolve_public_ip parses cleanly"

# ── PATH stubs ───────────────────────────────────────────────────────────
BIN="$TMPD/bin"
mkdir -p "$BIN"

# dig stub: DIG_STUB_RESULT set → emit it as the A-record; unset/empty →
# emit nothing (mirrors a real NXDOMAIN / no-record dig +short).
cat > "$BIN/dig" <<'EOF'
#!/bin/bash
[[ -n "${DIG_STUB_RESULT:-}" ]] && printf '%s\n' "$DIG_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/dig"

# getent stub: mimics `getent ahostsv4 <host>` column shape.
cat > "$BIN/getent" <<'EOF'
#!/bin/bash
[[ -n "${GETENT_STUB_RESULT:-}" ]] && printf '%s STREAM stub-host\n' "$GETENT_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/getent"

# curl stub: CURL_STUB_RESULT is the egress-autodetect fallback value.
cat > "$BIN/curl" <<'EOF'
#!/bin/bash
[[ -n "${CURL_STUB_RESULT:-}" ]] && printf '%s' "$CURL_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/curl"

# Isolated PATH with only the stubs above (plus grep/head/awk from the real
# system, needed by the DNS-tier branches once dig/getent DO resolve).
STUBPATH="$BIN:$PATH"

# Empty PATH (no dig, no getent, no curl at all) for the "both tools absent"
# degrade-gracefully case. Resolve bash's OWN absolute path first — an
# empty PATH would otherwise also make the outer `bash -c` invocation
# itself fail to find `bash` ("command not found"), which is not what this
# case is testing.
EMPTY_BIN="$TMPD/empty-bin"
mkdir -p "$EMPTY_BIN"
BASH_BIN="$(command -v bash)"

# ===========================================================================
# Section B — functional: hydrate.sh resolve_external_ip precedence
# ===========================================================================
echo ""
echo "=== Section B: hydrate.sh resolve_external_ip precedence ==="

_run_hydrate() {
    # $1=egress_ip $2=turns_subdomain $3=partner_domain $4=private_ip
    # Pre-set the global PUBLIC_IP to the egress value, exactly as hydrate.sh's
    # caller does, so the harness reproduces the production short-circuit.
    bash -c "source '$HYDRATE_PREAMBLE'; PUBLIC_IP=\"$1\"; PRIVATE_IP='$4'; resolve_external_ip '$1' '$2' '$3'; \
        echo \"PUBLIC_IP=\$PUBLIC_IP\"; echo \"PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE\"; \
        echo \"EXTERNAL_IP_LINE=\$EXTERNAL_IP_LINE\"; echo \"ALLOWED_PEER_IP_LINE=\$ALLOWED_PEER_IP_LINE\"" 2>&1
}

# B1: this IS the live bug, falsified. Without the fix, PUBLIC_IP stays the
# egress IP (132.145.192.254-style) even though the TURNS DNS A-record
# (129.159.103.86) is the reachable one — revert resolve_external_ip to
# "PUBLIC_IP=$egress_ip; return" and this test goes RED.
B1_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="129.159.103.86" \
    _run_hydrate "132.145.192.254" "turns" "example.com" "") && B1_RC=0 || B1_RC=$?
[[ "$B1_RC" -eq 0 ]] || fail "B1: resolve_external_ip died unexpectedly: $B1_OUT"
echo "$B1_OUT" | grep -qF 'PUBLIC_IP=129.159.103.86' \
    && pass "B1: DNS A-record (129.159.103.86) wins over egress autodetect (132.145.192.254)" \
    || fail "B1: expected DNS IP 129.159.103.86, got: $B1_OUT"
echo "$B1_OUT" | grep -qF 'PUBLIC_IP_SOURCE=dns' \
    && pass "B1b: source labeled dns" || fail "B1b: source not labeled dns: $B1_OUT"

# B2: OXPULSE_PUBLIC_IP override wins over BOTH DNS and autodetect.
B2_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="129.159.103.86" OXPULSE_PUBLIC_IP="203.0.113.9" \
    _run_hydrate "132.145.192.254" "turns" "example.com" "") && B2_RC=0 || B2_RC=$?
[[ "$B2_RC" -eq 0 ]] || fail "B2: resolve_external_ip died unexpectedly: $B2_OUT"
echo "$B2_OUT" | grep -qF 'PUBLIC_IP=203.0.113.9' \
    && pass "B2: OXPULSE_PUBLIC_IP override (203.0.113.9) wins over DNS" \
    || fail "B2: expected override 203.0.113.9, got: $B2_OUT"
echo "$B2_OUT" | grep -qF 'PUBLIC_IP_SOURCE=override' \
    && pass "B2b: source labeled override" || fail "B2b: source not labeled override: $B2_OUT"

# B3: no DNS A-record (dig present, empty result) → falls through to the
# step-1 egress autodetect value passed in as $1 (unchanged fallback).
B3_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="" \
    _run_hydrate "132.145.192.254" "turns" "example.com" "") && B3_RC=0 || B3_RC=$?
[[ "$B3_RC" -eq 0 ]] || fail "B3: resolve_external_ip died unexpectedly: $B3_OUT"
echo "$B3_OUT" | grep -qF 'PUBLIC_IP=132.145.192.254' \
    && pass "B3: no DNS record → falls through to egress autodetect" \
    || fail "B3: expected fallback 132.145.192.254, got: $B3_OUT"
echo "$B3_OUT" | grep -qF 'PUBLIC_IP_SOURCE=autodetect' \
    && pass "B3b: source labeled autodetect" || fail "B3b: source not labeled autodetect: $B3_OUT"

# B4: dig AND getent both absent from PATH → degrades gracefully to
# autodetect (no crash / die). hydrate.sh does NOT hard-require dig, unlike
# upgrade.sh — this is the explicit graceful-degrade requirement.
B4_OUT=$(PATH="$EMPTY_BIN" \
    "$BASH_BIN" -c "source '$HYDRATE_PREAMBLE'; PUBLIC_IP='132.145.192.254'; PRIVATE_IP=''; resolve_external_ip '132.145.192.254' 'turns' 'example.com'; \
        echo \"PUBLIC_IP=\$PUBLIC_IP\"; echo \"PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE\"" 2>&1) && B4_RC=0 || B4_RC=$?
[[ "$B4_RC" -eq 0 ]] \
    && pass "B4: dig+getent both absent → resolve_external_ip does not die (RC=0)" \
    || fail "B4: resolve_external_ip died with dig+getent absent (RC=$B4_RC): $B4_OUT"
echo "$B4_OUT" | grep -qF 'PUBLIC_IP=132.145.192.254' \
    && pass "B4b: degrades to egress autodetect value" \
    || fail "B4b: expected egress fallback, got: $B4_OUT"
echo "$B4_OUT" | grep -qF 'PUBLIC_IP_SOURCE=autodetect' \
    && pass "B4c: source labeled autodetect" || fail "B4c: $B4_OUT"

# B5: EXTERNAL_IP_LINE / ALLOWED_PEER_IP_LINE are RECOMPUTED from the final
# resolved PUBLIC_IP (not stale from the egress value) — this is the actual
# value that lands in coturn.conf's external-ip and docker-compose.yml's
# SFU_PUBLIC_IP; a regression that keeps the OCI-hairpin lines pinned to the
# egress IP would reintroduce the exact incident even if PUBLIC_IP itself
# were fixed.
B5_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="129.159.103.86" \
    _run_hydrate "132.145.192.254" "turns" "example.com" "10.0.0.5") && B5_RC=0 || B5_RC=$?
[[ "$B5_RC" -eq 0 ]] || fail "B5: resolve_external_ip died unexpectedly: $B5_OUT"
echo "$B5_OUT" | grep -qF 'EXTERNAL_IP_LINE=129.159.103.86/10.0.0.5' \
    && pass "B5: EXTERNAL_IP_LINE recomputed from resolved DNS IP + PRIVATE_IP" \
    || fail "B5: EXTERNAL_IP_LINE not recomputed correctly, got: $B5_OUT"
echo "$B5_OUT" | grep -qF 'ALLOWED_PEER_IP_LINE=allowed-peer-ip=10.0.0.5' \
    && pass "B5b: ALLOWED_PEER_IP_LINE recomputed" \
    || fail "B5b: ALLOWED_PEER_IP_LINE not recomputed, got: $B5_OUT"

# ===========================================================================
# Section C — functional: upgrade.sh resolve_public_ip precedence
# ===========================================================================
echo ""
echo "=== Section C: upgrade.sh resolve_public_ip precedence ==="

_run_upgrade() {
    # upgrade.sh sources STATE_FILE before calling resolve_public_ip, so the
    # global PUBLIC_IP is pre-set to a stale egress value in production.
    bash -c "source '$UPGRADE_PREAMBLE'; PUBLIC_IP='132.145.192.254'; resolve_public_ip '$1' '$2'; \
        echo \"PUBLIC_IP=\$PUBLIC_IP\"; echo \"PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE\"; echo \"DIG_IPS=\$DIG_IPS\"" 2>&1
}

# C1: DNS tier wins over curl autodetect.
C1_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="129.159.103.86" CURL_STUB_RESULT="132.145.192.254" \
    _run_upgrade "turns" "example.com") && C1_RC=0 || C1_RC=$?
[[ "$C1_RC" -eq 0 ]] || fail "C1: resolve_public_ip died unexpectedly: $C1_OUT"
echo "$C1_OUT" | grep -qF 'PUBLIC_IP=129.159.103.86' \
    && pass "C1: DNS A-record wins over curl autodetect" \
    || fail "C1: expected DNS IP, got: $C1_OUT"
echo "$C1_OUT" | grep -qF 'PUBLIC_IP_SOURCE=dns' && pass "C1b: source labeled dns" || fail "C1b: $C1_OUT"
echo "$C1_OUT" | grep -qF 'DIG_IPS=129.159.103.86' \
    && pass "C1c: DIG_IPS populated for the caller's DNS-preflight guard" || fail "C1c: $C1_OUT"

# C2: OXPULSE_PUBLIC_IP override wins over DNS.
C2_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="129.159.103.86" OXPULSE_PUBLIC_IP="203.0.113.9" \
    _run_upgrade "turns" "example.com") && C2_RC=0 || C2_RC=$?
[[ "$C2_RC" -eq 0 ]] || fail "C2: resolve_public_ip died unexpectedly: $C2_OUT"
echo "$C2_OUT" | grep -qF 'PUBLIC_IP=203.0.113.9' \
    && pass "C2: OXPULSE_PUBLIC_IP override wins over DNS" \
    || fail "C2: got: $C2_OUT"
echo "$C2_OUT" | grep -qF 'DIG_IPS=129.159.103.86' \
    && pass "C2b: DIG_IPS still populated (guard still runs against override)" || fail "C2b: $C2_OUT"

# C3: no DNS record → falls through to curl autodetect.
C3_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="" CURL_STUB_RESULT="132.145.192.254" \
    _run_upgrade "turns" "example.com") && C3_RC=0 || C3_RC=$?
[[ "$C3_RC" -eq 0 ]] || fail "C3: resolve_public_ip died unexpectedly: $C3_OUT"
echo "$C3_OUT" | grep -qF 'PUBLIC_IP=132.145.192.254' \
    && pass "C3: no DNS record → falls through to curl autodetect" \
    || fail "C3: got: $C3_OUT"
echo "$C3_OUT" | grep -qF 'PUBLIC_IP_SOURCE=autodetect' \
    && pass "C3b: source labeled autodetect" || fail "C3b: $C3_OUT"

# C4: no DNS record AND curl fails too → die (unchanged pre-existing
# behaviour: could-not-determine-public-IP must still be fatal).
C4_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="" CURL_STUB_RESULT="" \
    _run_upgrade "turns" "example.com") && C4_RC=0 || C4_RC=$?
[[ "$C4_RC" -ne 0 ]] \
    && pass "C4: no DNS record + curl failure → resolve_public_ip dies (fatal, as before)" \
    || fail "C4: resolve_public_ip should have died with no DNS + no curl result, RC=$C4_RC: $C4_OUT"
echo "$C4_OUT" | grep -qF 'could not determine public IP' \
    && pass "C4b: die message unchanged in spirit" || fail "C4b: $C4_OUT"

# C5: maybe_v01_to_v02_preflight delegates to resolve_public_ip and reuses
# its DIG_IPS in the existing guard — no direct 'dig +short' call remains
# in the caller (would mean a second, redundant DNS lookup).
preflight_block=$(awk '/^maybe_v01_to_v02_preflight\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE")
dig_calls=$(echo "$preflight_block" | grep -c 'dig +short' || true)
[[ "$dig_calls" -eq 0 ]] \
    && pass "C5: maybe_v01_to_v02_preflight issues no direct dig call (delegates to resolve_public_ip)" \
    || fail "C5: maybe_v01_to_v02_preflight still calls dig directly ($dig_calls occurrence(s))"
echo "$preflight_block" | grep -qF 'resolve_public_ip "$TURNS_SUBDOMAIN" "$PARTNER_DOMAIN"' \
    && pass "C6: maybe_v01_to_v02_preflight calls resolve_public_ip" \
    || fail "C6: resolve_public_ip not called from maybe_v01_to_v02_preflight"
echo "$preflight_block" | grep -qF 'grep -Fxq "$PUBLIC_IP" <<< "$DIG_IPS"' \
    && pass "C7: existing DNS-preflight guard preserved — still guards override/autodetect paths (not deleted, per spec)" \
    || fail "C7: DNS-preflight guard removed from maybe_v01_to_v02_preflight"

# ===========================================================================
echo ""
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: test_publicip_dns_precedence — all checks passed"
    exit 0
else
    echo "FAIL: test_publicip_dns_precedence — $FAIL check(s) failed"
    exit 1
fi
