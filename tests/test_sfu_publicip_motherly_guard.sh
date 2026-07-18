#!/bin/bash
# tests/test_sfu_publicip_motherly_guard.sh
#
# T1 + T2 regression guard for the SFU_PUBLIC_IP / coturn external-ip
# authoritative-IP resolution.
#
# T1 — SFU_PUBLIC_IP must follow the SAME 3-tier authoritative IP as coturn's
# external-ip. SFU_PUBLIC_IP is rendered into docker-compose.yml from the
# {{PUBLIC_IP}} placeholder (docker-compose.yml.tpl), and {{PUBLIC_IP}} is the
# PUBLIC_IP global that hydrate.sh's resolve_external_ip() resolves with
# precedence: OXPULSE_PUBLIC_IP override → TURNS DNS A-record → egress
# autodetect. On a multi-homed OCI edge (live incident 2026-07-17) the egress
# IP (132.145.192.254) has no inbound path; the TURNS DNS A-record
# (129.159.103.86) is the reachable one. If SFU_PUBLIC_IP were derived from a
# DIFFERENT source than coturn's external-ip, the SFU would advertise the dead
# egress IP in WebRTC host candidates and group-call media would stall. This
# test asserts (structurally) that docker-compose.yml.tpl renders SFU_PUBLIC_IP
# from {{PUBLIC_IP}} — the SAME var resolve_external_ip sets — and
# (functionally) that resolve_external_ip's PUBLIC_IP output is the DNS
# A-record, so coturn external-ip AND SFU_PUBLIC_IP both equal it.
#
# T2 — motherly/central IP guard. An edge must NEVER advertise the central
# backend's IP as its own public IP. Live bug: the RU edge's egress route
# traversed the AWG mesh tunnel to motherly, so curl ifconfig.me returned the
# central IP (192.9.243.148) — rendering that as coturn external-ip /
# SFU_PUBLIC_IP points clients at the hub, not the edge. The guard derives the
# motherly IP from OXPULSE_MOTHERLY_IP env (operator escape hatch) or by
# resolving BACKEND_URL's host A-record, and rejects any tier that would yield
# it, falling through to the next tier with a loud warning. Applies to BOTH
# the external-ip and SFU_PUBLIC_IP resolution (they share PUBLIC_IP).
#
# Test strategy: extract resolve_external_ip via awk (same pattern as
# tests/test_publicip_dns_precedence.sh) into a sourceable preamble with a
# minimal log()/warn()/die() stub, PATH-stub dig/getent/curl, and execute the
# REAL function — not a re-implementation. hydrate.sh itself cannot be run
# end-to-end in CI (hardcoded /etc, /var/lib paths requiring root).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HYDRATE="$REPO_ROOT/hydrate.sh"
COMPOSE_TPL="$REPO_ROOT/docker-compose.yml.tpl"

[[ -f "$HYDRATE" ]] || { echo "FAIL: hydrate.sh not found at $HYDRATE"; exit 1; }
[[ -f "$COMPOSE_TPL" ]] || { echo "FAIL: docker-compose.yml.tpl not found at $COMPOSE_TPL"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

# ===========================================================================
# Section A — structural
# ===========================================================================
echo "=== Section A: structural ==="

bash -n "$HYDRATE" && pass "A1: hydrate.sh syntax clean" || { fail "A1: hydrate.sh syntax error"; exit 1; }

# A2: resolve_external_ip carries the motherly-IP guard. RED before the guard
# is added (grep finds no "motherly" reference inside the function body).
_hydrate_fn_body=$(awk '/^resolve_external_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE")
echo "$_hydrate_fn_body" | grep -qi 'motherly' \
    && pass "A2: resolve_external_ip has motherly-IP guard" \
    || fail "A2: resolve_external_ip missing motherly-IP guard (T2 not implemented)"

# A3: T1 structural — SFU_PUBLIC_IP is rendered from {{PUBLIC_IP}}, the SAME
# var resolve_external_ip sets. A regression that derives SFU_PUBLIC_IP from a
# different var (e.g. a raw egress-only var) would break the equality invariant
# between coturn external-ip and SFU_PUBLIC_IP on a multi-homed edge.
grep -qF 'SFU_PUBLIC_IP: "{{PUBLIC_IP}}"' "$COMPOSE_TPL" \
    && pass "A3: docker-compose.yml.tpl renders SFU_PUBLIC_IP from {{PUBLIC_IP}} (T1: shares resolver source)" \
    || fail "A3: SFU_PUBLIC_IP not bound to {{PUBLIC_IP}} in docker-compose.yml.tpl — coturn external-ip and SFU_PUBLIC_IP would diverge"

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

# ── extraction preamble ─────────────────────────────────────────────────
HYDRATE_PREAMBLE="$TMPD/hydrate_fn.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^resolve_external_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$HYDRATE"
} > "$HYDRATE_PREAMBLE"
bash -n "$HYDRATE_PREAMBLE" && pass "A4: extracted resolve_external_ip parses cleanly" \
    || { fail "A4: extracted resolve_external_ip has syntax errors"; exit 1; }

# ── PATH stubs ───────────────────────────────────────────────────────────
BIN="$TMPD/bin"
mkdir -p "$BIN"

# dig stub: per-host lookup via DIG_STUB_<host-with-dots-as-underscores>, with
# DIG_STUB_RESULT as a catch-all fallback. This lets the test return DIFFERENT
# A-records for the TURNS subdomain vs the BACKEND_URL host in the same run
# (needed so the motherly-IP derivation from BACKEND_URL can be exercised
# independently of the TURNS DNS tier). The query hostname is the first non
# '+flag' arg that is not a record type (dig is invoked as
# `dig +short +time=3 +tries=1 <host> A` — the LAST arg is the record type `A`,
# NOT the host, so ${@: -1} would wrongly pick `A`).
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

# getent stub: mimics `getent ahostsv4 <host>` column shape.
cat > "$BIN/getent" <<'EOF'
#!/bin/bash
_query="${@: -1}"
_env="GETENT_STUB_$(printf '%s' "$_query" | tr -cd 'A-Za-z0-9._' | tr '.' '_')"
[[ -n "${!_env:-}" ]] && { printf '%s STREAM stub-host\n' "${!_env}"; exit 0; }
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

STUBPATH="$BIN:$PATH"

_run_hydrate() {
    # $1=egress_ip $2=turns_subdomain $3=partner_domain $4=private_ip
    bash -c "source '$HYDRATE_PREAMBLE'; PRIVATE_IP='$4'; resolve_external_ip '$1' '$2' '$3'; \
        echo \"PUBLIC_IP=\$PUBLIC_IP\"; echo \"PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE\"; \
        echo \"EXTERNAL_IP_LINE=\$EXTERNAL_IP_LINE\"; echo \"ALLOWED_PEER_IP_LINE=\$ALLOWED_PEER_IP_LINE\"" 2>&1
}

MOTHERLY="192.9.243.148"
EDGE_DNS="129.159.103.86"
EGRESS="132.145.192.254"

# ===========================================================================
# Section B — T1 functional: SFU_PUBLIC_IP follows the resolver
# ===========================================================================
echo ""
echo "=== Section B: T1 — SFU_PUBLIC_IP follows resolve_external_ip ==="

# B1: resolve_external_ip resolves PUBLIC_IP to the TURNS DNS A-record. Since
# docker-compose.yml.tpl renders SFU_PUBLIC_IP from {{PUBLIC_IP}} (A3) and
# coturn's EXTERNAL_IP_LINE is derived from the same PUBLIC_IP, BOTH equal the
# DNS A-record on a multi-homed edge. Revert resolve_external_ip to
# "PUBLIC_IP=$egress_ip" and PUBLIC_IP becomes 132.145.192.254 → this assert
# REDS (the value that flows to both coturn external-ip and SFU_PUBLIC_IP
# would be the dead egress IP).
B1_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" \
    _run_hydrate "$EGRESS" "turns" "example.com" "") && B1_RC=0 || B1_RC=$?
[[ "$B1_RC" -eq 0 ]] || fail "B1: resolve_external_ip died unexpectedly: $B1_OUT"
echo "$B1_OUT" | grep -qF "PUBLIC_IP=$EDGE_DNS" \
    && pass "B1: PUBLIC_IP resolves to TURNS DNS A-record ($EDGE_DNS) — flows to both coturn external-ip and SFU_PUBLIC_IP" \
    || fail "B1: expected PUBLIC_IP=$EDGE_DNS (DNS A-record), got: $B1_OUT"
echo "$B1_OUT" | grep -qF "EXTERNAL_IP_LINE=$EDGE_DNS" \
    && pass "B2: EXTERNAL_IP_LINE (coturn external-ip) equals the resolved DNS IP" \
    || fail "B2: EXTERNAL_IP_LINE not equal to resolved DNS IP, got: $B1_OUT"
# B3: structural restatement of the SFU_PUBLIC_IP==PUBLIC_IP invariant — the
# template placeholder IS {{PUBLIC_IP}}, so SFU_PUBLIC_IP == PUBLIC_IP ==
# EXTERNAL_IP_LINE's public component by construction. Combined with B1/B2,
# this closes T1's AC (coturn external-ip AND SFU_PUBLIC_IP both equal the DNS
# A-record on a multi-homed edge).
grep -qF 'SFU_PUBLIC_IP: "{{PUBLIC_IP}}"' "$COMPOSE_TPL" \
    && pass "B3: SFU_PUBLIC_IP bound to {{PUBLIC_IP}} → equals PUBLIC_IP (== DNS A-record from B1)" \
    || fail "B3: SFU_PUBLIC_IP not bound to {{PUBLIC_IP}}"

# ===========================================================================
# Section C — T2: motherly guard rejects OXPULSE_PUBLIC_IP override tier
# ===========================================================================
echo ""
echo "=== Section C: T2 — motherly guard rejects override tier, falls through ==="

# C1: OXPULSE_PUBLIC_IP == motherly → rejected, falls through to DNS tier
# (non-motherly) → PUBLIC_IP = DNS IP. Warn emitted. Revert the guard and
# PUBLIC_IP stays = motherly (override wins) → this assert REDS.
C1_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    OXPULSE_PUBLIC_IP="$MOTHERLY" DIG_STUB_RESULT="$EDGE_DNS" \
    _run_hydrate "$EGRESS" "turns" "example.com" "") && C1_RC=0 || C1_RC=$?
[[ "$C1_RC" -eq 0 ]] || fail "C1: resolve_external_ip died unexpectedly: $C1_OUT"
echo "$C1_OUT" | grep -qF "PUBLIC_IP=$EDGE_DNS" \
    && pass "C1: override==motherly rejected → fell through to DNS ($EDGE_DNS)" \
    || fail "C1: expected fall-through to DNS $EDGE_DNS, got: $C1_OUT"
echo "$C1_OUT" | grep -qi 'motherly' \
    && pass "C2: loud warning emitted for motherly override rejection" \
    || fail "C2: no motherly warning in output: $C1_OUT"
echo "$C1_OUT" | grep -qF 'PUBLIC_IP_SOURCE=dns' \
    && pass "C3: source labeled dns after override rejection" \
    || fail "C3: source not labeled dns: $C1_OUT"

# ===========================================================================
# Section D — T2: motherly guard rejects DNS tier, falls through to egress
# ===========================================================================
echo ""
echo "=== Section D: T2 — motherly guard rejects DNS tier, falls through ==="

# D1: DNS A-record == motherly → rejected, falls through to egress (non-motherly)
# → PUBLIC_IP = egress. Warn emitted.
D1_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    DIG_STUB_RESULT="$MOTHERLY" \
    _run_hydrate "$EGRESS" "turns" "example.com" "") && D1_RC=0 || D1_RC=$?
[[ "$D1_RC" -eq 0 ]] || fail "D1: resolve_external_ip died unexpectedly: $D1_OUT"
echo "$D1_OUT" | grep -qF "PUBLIC_IP=$EGRESS" \
    && pass "D1: DNS==motherly rejected → fell through to egress ($EGRESS)" \
    || fail "D1: expected fall-through to egress $EGRESS, got: $D1_OUT"
echo "$D1_OUT" | grep -qi 'motherly' \
    && pass "D2: loud warning emitted for motherly DNS rejection" \
    || fail "D2: no motherly warning in output: $D1_OUT"
echo "$D1_OUT" | grep -qF 'PUBLIC_IP_SOURCE=autodetect' \
    && pass "D3: source labeled autodetect after DNS rejection" \
    || fail "D3: source not labeled autodetect: $D1_OUT"

# ===========================================================================
# Section E — T2: all tiers motherly → die (refuse to advertise central IP)
# ===========================================================================
echo ""
echo "=== Section E: T2 — all tiers motherly → die ==="

# E1: override==motherly, DNS==motherly, egress==motherly → no valid non-motherly
# IP → die. Revert the guard and PUBLIC_IP would silently become motherly →
# this assert REDS (RC=0 instead of nonzero).
E1_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    OXPULSE_PUBLIC_IP="$MOTHERLY" DIG_STUB_RESULT="$MOTHERLY" \
    _run_hydrate "$MOTHERLY" "turns" "example.com" "") && E1_RC=0 || E1_RC=$?
[[ "$E1_RC" -ne 0 ]] \
    && pass "E1: all tiers motherly → resolve_external_ip dies (RC=$E1_RC)" \
    || fail "E1: expected die with all tiers motherly, got RC=0: $E1_OUT"
echo "$E1_OUT" | grep -qi 'motherly' \
    && pass "E2: die message references motherly IP" \
    || fail "E2: die message does not reference motherly: $E1_OUT"

# ===========================================================================
# Section F — T2: motherly IP derived from BACKEND_URL host A-record
# ===========================================================================
echo ""
echo "=== Section F: T2 — motherly IP derived from BACKEND_URL host ==="

# F1: OXPULSE_MOTHERLY_IP unset; BACKEND_URL host (motherly.example.com) resolves
# to the motherly IP via dig. The override tier == that derived motherly IP →
# rejected → falls through to DNS (non-motherly). Proves the BACKEND_URL
# derivation path produces a working guard without OXPULSE_MOTHERLY_IP.
# Per-host dig stub: turns.example.com → EDGE_DNS, motherly.example.com → MOTHERLY.
F1_OUT=$(PATH="$STUBPATH" \
    BACKEND_URL="https://motherly.example.com" \
    OXPULSE_PUBLIC_IP="$MOTHERLY" \
    DIG_STUB_turns_example_com="$EDGE_DNS" \
    DIG_STUB_motherly_example_com="$MOTHERLY" \
    _run_hydrate "$EGRESS" "turns" "example.com" "") && F1_RC=0 || F1_RC=$?
[[ "$F1_RC" -eq 0 ]] || fail "F1: resolve_external_ip died unexpectedly: $F1_OUT"
echo "$F1_OUT" | grep -qF "PUBLIC_IP=$EDGE_DNS" \
    && pass "F1: motherly IP derived from BACKEND_URL host → override rejected → fell through to DNS ($EDGE_DNS)" \
    || fail "F1: expected fall-through to DNS $EDGE_DNS, got: $F1_OUT"
echo "$F1_OUT" | grep -qi 'motherly' \
    && pass "F2: loud warning emitted for BACKEND_URL-derived motherly rejection" \
    || fail "F2: no motherly warning in output: $F1_OUT"

# ===========================================================================
# Section G — T2: upgrade.sh resolve_public_ip motherly guard (mirror)
# ===========================================================================
echo ""
echo "=== Section G: T2 — upgrade.sh resolve_public_ip motherly guard ==="

UPGRADE="$REPO_ROOT/upgrade.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }
bash -n "$UPGRADE" && pass "G0: upgrade.sh syntax clean" || { fail "G0: upgrade.sh syntax error"; exit 1; }

UPGRADE_PREAMBLE="$TMPD/upgrade_fn.sh"
{
    cat <<'HELPERS'
log()  { printf '==> %s\n' "$*" >&2; }
warn() { printf '!! %s\n'  "$*" >&2; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^resolve_public_ip\(\)/{f=1} f{print} /^}$/ && f{exit}' "$UPGRADE"
} > "$UPGRADE_PREAMBLE"
bash -n "$UPGRADE_PREAMBLE" && pass "G1: extracted resolve_public_ip parses cleanly" \
    || { fail "G1: extracted resolve_public_ip has syntax errors"; exit 1; }

_run_upgrade() {
    bash -c "source '$UPGRADE_PREAMBLE'; resolve_public_ip '$1' '$2'; \
        echo \"PUBLIC_IP=\$PUBLIC_IP\"; echo \"PUBLIC_IP_SOURCE=\$PUBLIC_IP_SOURCE\"; echo \"DIG_IPS=\$DIG_IPS\"" 2>&1
}

# G2: override==motherly → rejected, falls through to DNS (non-motherly).
# Revert the upgrade.sh guard and PUBLIC_IP stays = motherly → REDS.
G2_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    OXPULSE_PUBLIC_IP="$MOTHERLY" DIG_STUB_RESULT="$EDGE_DNS" CURL_STUB_RESULT="$EGRESS" \
    _run_upgrade "turns" "example.com") && G2_RC=0 || G2_RC=$?
[[ "$G2_RC" -eq 0 ]] || fail "G2: resolve_public_ip died unexpectedly: $G2_OUT"
echo "$G2_OUT" | grep -qF "PUBLIC_IP=$EDGE_DNS" \
    && pass "G2: upgrade override==motherly rejected → fell through to DNS ($EDGE_DNS)" \
    || fail "G2: expected fall-through to DNS $EDGE_DNS, got: $G2_OUT"
echo "$G2_OUT" | grep -qi 'motherly' \
    && pass "G3: upgrade loud warning emitted for motherly override rejection" \
    || fail "G3: no motherly warning in output: $G2_OUT"

# G4: DNS==motherly → rejected, falls through to egress autodetect.
G4_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    DIG_STUB_RESULT="$MOTHERLY" CURL_STUB_RESULT="$EGRESS" \
    _run_upgrade "turns" "example.com") && G4_RC=0 || G4_RC=$?
[[ "$G4_RC" -eq 0 ]] || fail "G4: resolve_public_ip died unexpectedly: $G4_OUT"
echo "$G4_OUT" | grep -qF "PUBLIC_IP=$EGRESS" \
    && pass "G4: upgrade DNS==motherly rejected → fell through to egress ($EGRESS)" \
    || fail "G4: expected fall-through to egress $EGRESS, got: $G4_OUT"
echo "$G4_OUT" | grep -qF 'PUBLIC_IP_SOURCE=autodetect' \
    && pass "G5: upgrade source labeled autodetect after DNS rejection" \
    || fail "G5: source not labeled autodetect: $G4_OUT"

# G6: all tiers motherly → die.
G6_OUT=$(PATH="$STUBPATH" OXPULSE_MOTHERLY_IP="$MOTHERLY" \
    OXPULSE_PUBLIC_IP="$MOTHERLY" DIG_STUB_RESULT="$MOTHERLY" CURL_STUB_RESULT="$MOTHERLY" \
    _run_upgrade "turns" "example.com") && G6_RC=0 || G6_RC=$?
[[ "$G6_RC" -ne 0 ]] \
    && pass "G6: upgrade all tiers motherly → resolve_public_ip dies (RC=$G6_RC)" \
    || fail "G6: expected die with all tiers motherly, got RC=0: $G6_OUT"

# G7: backward-compat — no motherly env, no BACKEND_URL → guard is a no-op,
# DNS tier wins (unchanged pre-existing behaviour, mirrors C1 of the
# precedence suite). Revert the guard and this still passes (it guards
# against a regression that would make the no-op path reject).
G7_OUT=$(PATH="$STUBPATH" DIG_STUB_RESULT="$EDGE_DNS" CURL_STUB_RESULT="$EGRESS" \
    _run_upgrade "turns" "example.com") && G7_RC=0 || G7_RC=$?
[[ "$G7_RC" -eq 0 ]] || fail "G7: resolve_public_ip died unexpectedly: $G7_OUT"
echo "$G7_OUT" | grep -qF "PUBLIC_IP=$EDGE_DNS" \
    && pass "G7: upgrade no-motherly guard no-op → DNS tier wins (backward compat)" \
    || fail "G7: expected DNS $EDGE_DNS, got: $G7_OUT"
echo "$G7_OUT" | grep -qF 'PUBLIC_IP_SOURCE=dns' && pass "G8: upgrade source labeled dns" || fail "G8: $G7_OUT"

# ===========================================================================
echo ""
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: test_sfu_publicip_motherly_guard — all checks passed"
    exit 0
else
    echo "FAIL: test_sfu_publicip_motherly_guard — $FAIL check(s) failed"
    exit 1
fi
