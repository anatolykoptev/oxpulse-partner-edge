#!/bin/bash
# tests/test_publicip_register_tier.sh
#
# T3b regression guard: the central's POST /api/partner/register response now
# carries a server-side-resolved `public_ip` field (the edge's authoritative
# inbound IP, as seen from outside the NAT). hydrate.sh must consume it as a
# NEW precedence tier in resolve_external_ip — ABOVE the DNS-derive and egress
# autodetect tiers (the central is more authoritative than the edge's own
# DNS-derive/egress) but BELOW the operator's explicit OXPULSE_PUBLIC_IP
# override (operator escape hatch always wins).
#
# Final precedence (most-authoritative first):
#   1. OXPULSE_PUBLIC_IP env override (operator escape hatch — unchanged)
#   2. REGISTER_PUBLIC_IP  (central-authoritative public_ip from register
#      response — NEW tier T3b; motherly-self guard applies)
#   3. DNS A-record of TURNS_SUBDOMAIN.PARTNER_DOMAIN (unchanged)
#   4. Egress autodetect (curl ifconfig.me / api.ipify.org — unchanged)
#
# Asserts:
#   A: structural — public_ip parsed from register response; REGISTER_PUBLIC_IP
#      tier present in resolve_external_ip with motherly guard.
#   B: non-empty REGISTER_PUBLIC_IP (!= motherly) is used verbatim for BOTH
#      coturn external-ip (EXTERNAL_IP_LINE) and SFU_PUBLIC_IP (PUBLIC_IP), is
#      persisted to STATE_FILE, AND DNS-derive/egress are NOT consulted (stubbed
#      to return DIFFERENT values — if consulted, the assert fails).
#   C: empty REGISTER_PUBLIC_IP → existing DNS-derive behavior unchanged.
#   D: REGISTER_PUBLIC_IP == motherly → rejected by guard, falls through to DNS.
#   E: OXPULSE_PUBLIC_IP override still wins over REGISTER_PUBLIC_IP (operator
#      escape hatch stays top).
#
# RED-on-revert: stash the tier-2 REGISTER_PUBLIC_IP addition → section B
# asserts MUST fail (PUBLIC_IP would be the DNS stub value, not the register
# value; persistence would write the wrong IP).
#
# Uses the same awk-extract + PATH-stub dig/getent/curl pattern as
# tests/test_publicip_dns_precedence.sh and tests/test_publicip_state_file_persistence.sh.
# Pre-sets the caller's globals (PUBLIC_IP=egress, PRIVATE_IP) exactly as the
# #453 harness fix does — a test that extracts the function into a fresh
# subshell without the caller's pre-set globals is SYNTHETIC GREEN.
#
# PRIVACY: all IPs are RFC-5737 TEST-NET placeholders (203.0.113.x / 198.51.100.x)
# and the domain is example.com — no real infra IPs, per the fleet-scrub gate.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HYDRATE="$REPO_ROOT/hydrate.sh"

[[ -f "$HYDRATE" ]] || { echo "FAIL: hydrate.sh not found at $HYDRATE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# RFC-5737 TEST-NET placeholders — no real infra IPs.
REGISTER_IP="203.0.113.9"     # central-authoritative register public_ip
MOTHERLY="198.51.100.1"       # central/hub IP (must never be advertised as edge)
EDGE_DNS="203.0.113.50"       # TURNS DNS A-record (different from register)
EGRESS="198.51.100.50"        # egress autodetect fallback
PRIVATE_IP="10.0.0.5"
TURNS="turns"
DOMAIN="example.com"

# ===========================================================================
# Section A — structural
# ===========================================================================
echo "=== Section A: structural ==="

bash -n "$HYDRATE" && pass "A1: hydrate.sh syntax clean" || { fail "A1: hydrate.sh syntax error"; exit 1; }

# A2: public_ip is parsed from the register response alongside the other fields.
# Mirror how turns_subdomain/service_token are read via jq_get.
grep -qE 'jq_get[[:space:]]+public_ip' "$HYDRATE" \
    && pass "A2: public_ip parsed from register response via jq_get" \
    || fail "A2: public_ip not parsed from register response (expected jq_get public_ip)"

# A3: REGISTER_PUBLIC_IP tier present inside resolve_external_ip. RED before the
# tier is added (grep finds no REGISTER_PUBLIC_IP reference inside the function
# body).
_hydrate_fn_body=$(awk '/^resolve_external_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE")
echo "$_hydrate_fn_body" | grep -F 'REGISTER_PUBLIC_IP' >/dev/null \
    && pass "A3: resolve_external_ip consumes REGISTER_PUBLIC_IP tier" \
    || fail "A3: resolve_external_ip does not reference REGISTER_PUBLIC_IP (T3b tier not implemented)"

# A4: the register tier applies the motherly-self guard (defense-in-depth:
# never advertise the hub as the edge's own IP even if the central mistakenly
# returned it).
echo "$_hydrate_fn_body" | grep -A2 'REGISTER_PUBLIC_IP' | grep -i 'motherly' >/dev/null \
    && pass "A4: REGISTER_PUBLIC_IP tier has motherly-self guard" \
    || fail "A4: REGISTER_PUBLIC_IP tier missing motherly-self guard"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ── extraction preamble ─────────────────────────────────────────────────
# Extract _persist_state_ip AND resolve_external_ip so the persistence assert
# (section B) can run the real persist path, mirroring
# test_publicip_state_file_persistence.sh.
HYDRATE_PREAMBLE="$TMPD/hydrate_fn.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^_persist_state_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE"
    awk '/^resolve_external_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE"
} > "$HYDRATE_PREAMBLE"
bash -n "$HYDRATE_PREAMBLE" && pass "A5: extracted hydrate functions parse cleanly" \
    || { fail "A5: extracted hydrate functions have syntax errors"; exit 1; }

# ── PATH stubs ───────────────────────────────────────────────────────────
BIN="$TMPD/bin"
mkdir -p "$BIN"

# dig stub: per-host via DIG_STUB_<host-with-dots-as-underscores>, fallback
# DIG_STUB_RESULT. Lets us return DIFFERENT A-records for the TURNS subdomain
# vs the BACKEND_URL host (so the motherly-IP derivation from BACKEND_URL can
# be exercised independently of the TURNS DNS tier).
cat > "$BIN/dig" <<'EOF'
#!/bin/bash
_query=""
for a in "$@"; do
    case "$a" in
        +*) continue ;;
        A|AAAA|MX|NS|TXT|CNAME|SRV|PTR|SOA|CAA) break ;;
        *) _query="$a"; break ;;
    esac
done
_env="DIG_STUB_$(printf '%s' "$_query" | tr -cd 'A-Za-z0-9._' | tr '.' '_')"
[[ -n "${!_env:-}" ]] && { printf '%s\n' "${!_env}"; exit 0; }
[[ -n "${DIG_STUB_RESULT:-}" ]] && printf '%s\n' "$DIG_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/dig"

cat > "$BIN/getent" <<'EOF'
#!/bin/bash
_query="${@: -1}"
_env="GETENT_STUB_$(printf '%s' "$_query" | tr -cd 'A-Za-z0-9._' | tr '.' '_')"
[[ -n "${!_env:-}" ]] && { printf '%s STREAM stub-host\n' "${!_env}"; exit 0; }
[[ -n "${GETENT_STUB_RESULT:-}" ]] && printf '%s STREAM stub-host\n' "$GETENT_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/getent"

cat > "$BIN/curl" <<'EOF'
#!/bin/bash
[[ -n "${CURL_STUB_RESULT:-}" ]] && printf '%s' "$CURL_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/curl"

STUBPATH="$BIN:$PATH"

# ===========================================================================
# Section B — non-empty REGISTER_PUBLIC_IP wins, DNS/egress NOT consulted
# ===========================================================================
echo ""
echo "=== Section B: REGISTER_PUBLIC_IP used verbatim, DNS/egress skipped ==="

STATE_FILE="$TMPD/install.env"
mkdir -p "$(dirname "$STATE_FILE")"
printf 'PUBLIC_IP=%s\n' "$EGRESS" > "$STATE_FILE"
printf 'PRIVATE_IP=%s\n' "$PRIVATE_IP" >> "$STATE_FILE"

# Run the REAL resolve_external_ip + _persist_state_ip, pre-setting the
# caller's globals (PUBLIC_IP=egress, PRIVATE_IP) exactly as hydrate.sh's
# caller does. REGISTER_PUBLIC_IP is set as a global (mirroring how
# hydrate.sh sets it from jq_get before calling resolve_external_ip).
RUN_B="$TMPD/run_b.sh"
cat > "$RUN_B" <<EOF
export STATE_FILE="$STATE_FILE"
export PUBLIC_IP="$EGRESS"
export PRIVATE_IP="$PRIVATE_IP"
export REGISTER_PUBLIC_IP="$REGISTER_IP"
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
_persist_state_ip "PUBLIC_IP" "\$PUBLIC_IP"
_persist_state_ip "PRIVATE_IP" "\$PRIVATE_IP"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE"
echo "EXTERNAL_IP_LINE=\$EXTERNAL_IP_LINE"
echo "ALLOWED_PEER_IP_LINE=\$ALLOWED_PEER_IP_LINE"
EOF
chmod +x "$RUN_B"

# Stub DNS to return EDGE_DNS (different from REGISTER_IP) and curl to return
# EGRESS. If the register tier works, PUBLIC_IP == REGISTER_IP and the DNS/egress
# stubs are never consulted. If the tier is missing (RED), PUBLIC_IP falls through
# to DNS → PUBLIC_IP == EDGE_DNS → assert B1 fails.
B_OUT=$(PATH="$STUBPATH" \
    DIG_STUB_RESULT="$EDGE_DNS" CURL_STUB_RESULT="$EGRESS" \
    bash "$RUN_B" 2>&1) && B_RC=0 || B_RC=$?
[[ "$B_RC" -eq 0 ]] || fail "B0: resolve/persist died unexpectedly (RC=$B_RC): $B_OUT"

echo "$B_OUT" | grep -F "PUBLIC_IP=$REGISTER_IP" >/dev/null \
    && pass "B1: REGISTER_PUBLIC_IP ($REGISTER_IP) used verbatim — DNS/egress NOT consulted" \
    || fail "B1: expected PUBLIC_IP=$REGISTER_IP (register tier), got: $B_OUT"

echo "$B_OUT" | grep -F 'PUBLIC_IP_SOURCE=register' >/dev/null \
    && pass "B2: source labeled register (central-authoritative)" \
    || fail "B2: source not labeled register: $B_OUT"

# B3: EXTERNAL_IP_LINE (coturn external-ip) derived from the register IP —
# this is the value that lands in coturn.conf; SFU_PUBLIC_IP shares PUBLIC_IP
# via {{PUBLIC_IP}} in docker-compose.yml.tpl (see test_sfu_publicip_motherly_guard).
echo "$B_OUT" | grep -F "EXTERNAL_IP_LINE=$REGISTER_IP/$PRIVATE_IP" >/dev/null \
    && pass "B3: EXTERNAL_IP_LINE (coturn external-ip) derived from register IP" \
    || fail "B3: expected EXTERNAL_IP_LINE=$REGISTER_IP/$PRIVATE_IP, got: $B_OUT"

# B4: persisted to STATE_FILE — the authoritative IP, not the egress IP.
# Reuses the SAME _persist_state_ip helper as #453 (no second persist path).
public_ip_val=$(grep '^PUBLIC_IP=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 | head -1 || true)
public_ip_count=$(grep -c '^PUBLIC_IP=' "$STATE_FILE" 2>/dev/null || true)
[[ "$public_ip_val" == "$REGISTER_IP" ]] \
    && pass "B4: STATE_FILE PUBLIC_IP persisted as register IP ($REGISTER_IP), not egress" \
    || fail "B4: expected STATE_FILE PUBLIC_IP=$REGISTER_IP, got '$public_ip_val'"
[[ "$public_ip_count" -eq 1 ]] \
    && pass "B5: exactly one PUBLIC_IP= line in STATE_FILE (idempotent, reuses #453 persist)" \
    || fail "B5: expected exactly one PUBLIC_IP= line, found $public_ip_count"

# ===========================================================================
# Section C — empty REGISTER_PUBLIC_IP → existing DNS-derive behavior unchanged
# ===========================================================================
echo ""
echo "=== Section C: empty REGISTER_PUBLIC_IP → DNS-derive unchanged ==="

STATE_FILE_C="$TMPD/install_c.env"
mkdir -p "$(dirname "$STATE_FILE_C")"
printf 'PUBLIC_IP=%s\n' "$EGRESS" > "$STATE_FILE_C"
printf 'PRIVATE_IP=%s\n' "$PRIVATE_IP" >> "$STATE_FILE_C"

RUN_C="$TMPD/run_c.sh"
cat > "$RUN_C" <<EOF
export STATE_FILE="$STATE_FILE_C"
export PUBLIC_IP="$EGRESS"
export PRIVATE_IP="$PRIVATE_IP"
export REGISTER_PUBLIC_IP=""
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE"
EOF
chmod +x "$RUN_C"

# REGISTER_PUBLIC_IP empty → falls through to DNS tier → PUBLIC_IP == EDGE_DNS.
# This mirrors the pre-T3b behavior (older central without public_ip field).
C_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" \
    bash "$RUN_C" 2>&1) && C_RC=0 || C_RC=$?
[[ "$C_RC" -eq 0 ]] || fail "C1: resolve died unexpectedly (RC=$C_RC): $C_OUT"
echo "$C_OUT" | grep -F "PUBLIC_IP=$EDGE_DNS" >/dev/null \
    && pass "C1: empty REGISTER_PUBLIC_IP → DNS-derive wins (unchanged behavior)" \
    || fail "C1: expected PUBLIC_IP=$EDGE_DNS (DNS fallback), got: $C_OUT"
echo "$C_OUT" | grep -F 'PUBLIC_IP_SOURCE=dns' >/dev/null \
    && pass "C2: source labeled dns (unchanged)" \
    || fail "C2: source not labeled dns: $C_OUT"

# ===========================================================================
# Section D — REGISTER_PUBLIC_IP == motherly → rejected, falls through to DNS
# ===========================================================================
echo ""
echo "=== Section D: REGISTER_PUBLIC_IP == motherly → rejected, falls through ==="

RUN_D="$TMPD/run_d.sh"
cat > "$RUN_D" <<EOF
export STATE_FILE="$TMPD/install_d.env"
export PUBLIC_IP="$EGRESS"
export PRIVATE_IP="$PRIVATE_IP"
export REGISTER_PUBLIC_IP="$MOTHERLY"
export OXPULSE_MOTHERLY_IP="$MOTHERLY"
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE"
EOF
chmod +x "$RUN_D"

# REGISTER_PUBLIC_IP == motherly → guard rejects → falls through to DNS (non-motherly).
# Revert the guard and PUBLIC_IP stays = motherly → assert D1 REDS.
D_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" \
    bash "$RUN_D" 2>&1) && D_RC=0 || D_RC=$?
[[ "$D_RC" -eq 0 ]] || fail "D1: resolve died unexpectedly (RC=$D_RC): $D_OUT"
echo "$D_OUT" | grep -F "PUBLIC_IP=$EDGE_DNS" >/dev/null \
    && pass "D1: register==motherly rejected → fell through to DNS ($EDGE_DNS)" \
    || fail "D1: expected fall-through to DNS $EDGE_DNS, got: $D_OUT"
echo "$D_OUT" | grep -i 'motherly' >/dev/null \
    && pass "D2: loud warning emitted for motherly register rejection" \
    || fail "D2: no motherly warning in output: $D_OUT"
echo "$D_OUT" | grep -F 'PUBLIC_IP_SOURCE=dns' >/dev/null \
    && pass "D3: source labeled dns after register rejection" \
    || fail "D3: source not labeled dns: $D_OUT"

# ===========================================================================
# Section E — OXPULSE_PUBLIC_IP override still wins over REGISTER_PUBLIC_IP
# ===========================================================================
echo ""
echo "=== Section E: OXPULSE_PUBLIC_IP override wins over REGISTER_PUBLIC_IP ==="

OVERRIDE="203.0.113.99"
RUN_E="$TMPD/run_e.sh"
cat > "$RUN_E" <<EOF
export STATE_FILE="$TMPD/install_e.env"
export PUBLIC_IP="$EGRESS"
export PRIVATE_IP="$PRIVATE_IP"
export REGISTER_PUBLIC_IP="$REGISTER_IP"
export OXPULSE_PUBLIC_IP="$OVERRIDE"
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE"
EOF
chmod +x "$RUN_E"

# Operator override must win over the central's register value (operator escape
# hatch stays top). Revert the precedence (put register above override) and
# PUBLIC_IP becomes REGISTER_IP → assert E1 REDS.
E_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" \
    bash "$RUN_E" 2>&1) && E_RC=0 || E_RC=$?
[[ "$E_RC" -eq 0 ]] || fail "E1: resolve died unexpectedly (RC=$E_RC): $E_OUT"
echo "$E_OUT" | grep -F "PUBLIC_IP=$OVERRIDE" >/dev/null \
    && pass "E1: OXPULSE_PUBLIC_IP override ($OVERRIDE) wins over REGISTER_PUBLIC_IP ($REGISTER_IP)" \
    || fail "E1: expected override $OVERRIDE, got: $E_OUT"
echo "$E_OUT" | grep -F 'PUBLIC_IP_SOURCE=override' >/dev/null \
    && pass "E2: source labeled override (operator escape hatch stays top)" \
    || fail "E2: source not labeled override: $E_OUT"

# ===========================================================================
# ===========================================================================
echo "=== Section F: malformed REGISTER_PUBLIC_IP → rejected, DNS-derive self-heals ==="

RUN_F="$TMPD/run_f.sh"
cat > "$RUN_F" <<EOF
export STATE_FILE="$TMPD/install_f.env"
export PUBLIC_IP="$EGRESS"
export PRIVATE_IP="$PRIVATE_IP"
export REGISTER_PUBLIC_IP="null"
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE"
EOF
chmod +x "$RUN_F"

# A malformed central value (here the jq-null string "null"; the same guard
# covers IPv6 / hostname / whitespace) must NOT ship verbatim into coturn +
# SFU — it fails IPv4 validation, warns, and falls through to the known-good
# DNS A-record. Without the tier-2/tier-1 IPv4 gate this ships "null" as the
# advertised IP and breaks all media on the edge (reviewer MEDIUM, PR #455).
F_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" \
    bash "$RUN_F" 2>&1) && F_RC=0 || F_RC=$?
[[ "$F_RC" -eq 0 ]] || fail "F1: resolve died unexpectedly (RC=$F_RC): $F_OUT"
echo "$F_OUT" | grep -F "PUBLIC_IP=$EDGE_DNS" >/dev/null \
    && pass "F1: malformed REGISTER_PUBLIC_IP rejected → DNS-derive self-heals ($EDGE_DNS)" \
    || fail "F1: expected PUBLIC_IP=$EDGE_DNS (DNS fallback), got: $F_OUT"
echo "$F_OUT" | grep -F 'PUBLIC_IP_SOURCE=dns' >/dev/null \
    && pass "F2: source labeled dns after malformed-register rejection" \
    || fail "F2: source not labeled dns: $F_OUT"
echo "$F_OUT" | grep -iF 'not a bare IPv4' >/dev/null \
    && pass "F3: loud warning emitted for malformed register rejection" \
    || fail "F3: no malformed-register warning: $F_OUT"

# ===========================================================================
echo ""
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: test_publicip_register_tier — all checks passed"
    exit 0
else
    echo "FAIL: test_publicip_register_tier — $FAIL check(s) failed"
    exit 1
fi
