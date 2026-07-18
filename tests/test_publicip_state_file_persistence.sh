#!/bin/bash
# tests/test_publicip_state_file_persistence.sh
#
# Regression guard for the reconcile-revert path of the PUBLIC_IP DNS-resolution
# fix (#451/#453). hydrate.sh's resolve_external_ip() corrects the in-memory
# PUBLIC_IP from the egress autodetect IP to the TURNS DNS A-record, but
# install.sh has already persisted the raw egress IP to $PREFIX_LIB/install.env.
# If hydrate.sh does not write the resolved value back, reconcile.sh's tier-2
# STATE_FILE resolution reads the egress IP on the next converge and re-renders
# coturn's external-ip / SFU_PUBLIC_IP to the unreachable egress IP — reverting
# the incident fix.
#
# Asserts:
#   A1-A2: hydrate.sh defines _persist_state_ip and calls it for PUBLIC_IP
#           and PRIVATE_IP after resolve_external_ip.
#   B1-B3: after resolve_external_ip + _persist_state_ip, the STATE_FILE contains
#           exactly one PUBLIC_IP= line whose value is the DNS IP (not egress),
#           and exactly one PRIVATE_IP= line with the resolved private IP.
#   C1-C3: reconcile.sh's _setup_coturn_render_env tier-2 PUBLIC_IP resolution,
#           fed the persisted STATE_FILE, yields the DNS IP and private IP.
#
# Uses the same awk-extract + PATH-stub pattern as test_publicip_dns_precedence.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
HYDRATE="$REPO_ROOT/hydrate.sh"
RECONCILE="$REPO_ROOT/lib/reconcile.sh"

[[ -f "$HYDRATE" ]] || { echo "FAIL: hydrate.sh not found at $HYDRATE"; exit 1; }
[[ -f "$RECONCILE" ]] || { echo "FAIL: reconcile.sh not found at $RECONCILE"; exit 1; }

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

TMPD=$(mktemp -d)
trap 'rm -rf "$TMPD"' EXIT

EGRESS="132.145.192.254"
DNS_IP="129.159.103.86"
PRIVATE_IP="10.0.0.5"
TURNS="turns"
DOMAIN="example.com"

# ===========================================================================
# Section A — structural
# ===========================================================================
echo "=== Section A: structural ==="

bash -n "$HYDRATE" && pass "A0: hydrate.sh syntax clean" || { fail "A0: hydrate.sh syntax error"; exit 1; }

grep -qE '^_persist_state_ip\(\)' "$HYDRATE" \
    && pass "A1: _persist_state_ip() defined in hydrate.sh" \
    || { fail "A1: _persist_state_ip() not defined in hydrate.sh"; exit 1; }

grep -qE '_persist_state_ip[[:space:]]+"?PUBLIC_IP' "$HYDRATE" \
    && pass "A2: PUBLIC_IP persisted by hydrate.sh" \
    || { fail "A2: PUBLIC_IP not persisted in hydrate.sh"; exit 1; }

grep -qE '_persist_state_ip[[:space:]]+"?PRIVATE_IP' "$HYDRATE" \
    && pass "A3: PRIVATE_IP persisted by hydrate.sh" \
    || { fail "A3: PRIVATE_IP not persisted in hydrate.sh"; exit 1; }

# Extract the hydrate helper + resolver into a sourceable preamble with stubs.
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
bash -n "$HYDRATE_PREAMBLE" && pass "A4: extracted hydrate functions parse cleanly" \
    || { fail "A4: extracted hydrate functions have syntax errors"; exit 1; }

# PATH stubs for dig/getent/curl.
BIN="$TMPD/bin"
mkdir -p "$BIN"

cat > "$BIN/dig" <<'EOF'
#!/bin/bash
[[ -n "${DIG_STUB_RESULT:-}" ]] && printf '%s\n' "$DIG_STUB_RESULT"
exit 0
EOF
chmod +x "$BIN/dig"

cat > "$BIN/getent" <<'EOF'
#!/bin/bash
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
# Section B — functional: resolved IPs persisted to STATE_FILE
# ===========================================================================
echo ""
echo "=== Section B: resolved PUBLIC_IP/PRIVATE_IP persisted to STATE_FILE ==="

STATE_FILE="$TMPD/install.env"
mkdir -p "$(dirname "$STATE_FILE")"
# Simulate the STATE_FILE written by install.sh with the raw egress IP.
printf 'PUBLIC_IP=%s\n' "$EGRESS" > "$STATE_FILE"
printf 'PRIVATE_IP=%s\n' "$PRIVATE_IP" >> "$STATE_FILE"

RUN="$TMPD/run_hydrate.sh"
cat > "$RUN" <<EOF
export STATE_FILE="$STATE_FILE"
export PREFIX_LIB="$TMPD/lib"
export PRIVATE_IP="$PRIVATE_IP"
source "$HYDRATE_PREAMBLE"
resolve_external_ip "$EGRESS" "$TURNS" "$DOMAIN"
_persist_state_ip "PUBLIC_IP" "\$PUBLIC_IP"
_persist_state_ip "PRIVATE_IP" "\$PRIVATE_IP"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PRIVATE_IP=\$PRIVATE_IP"
echo "EXTERNAL_IP_LINE=\$EXTERNAL_IP_LINE"
EOF
chmod +x "$RUN"

B_OUT=$(export PATH="$STUBPATH" DIG_STUB_RESULT="$DNS_IP"; bash "$RUN") && B_RC=0 || B_RC=$?
[[ "$B_RC" -eq 0 ]] || fail "B0: resolve/persist died unexpectedly (RC=$B_RC): $B_OUT"

echo "$B_OUT" | grep -qF "PUBLIC_IP=$DNS_IP" \
    && pass "B1: resolve_external_ip yields DNS IP ($DNS_IP)" \
    || fail "B1: expected PUBLIC_IP=$DNS_IP, got: $B_OUT"

public_ip_val=$(grep '^PUBLIC_IP=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 | head -1 || true)
public_ip_count=$(grep -c '^PUBLIC_IP=' "$STATE_FILE" 2>/dev/null || true)
private_ip_val=$(grep '^PRIVATE_IP=' "$STATE_FILE" 2>/dev/null | cut -d= -f2 | head -1 || true)
private_ip_count=$(grep -c '^PRIVATE_IP=' "$STATE_FILE" 2>/dev/null || true)

[[ "$public_ip_val" == "$DNS_IP" ]] \
    && pass "B2: STATE_FILE PUBLIC_IP line is the DNS IP ($DNS_IP), not egress" \
    || fail "B2: expected STATE_FILE PUBLIC_IP=$DNS_IP, got '$public_ip_val'"

[[ "$public_ip_count" -eq 1 ]] \
    && pass "B3: exactly one PUBLIC_IP= line in STATE_FILE (idempotent)" \
    || fail "B3: expected exactly one PUBLIC_IP= line, found $public_ip_count"

[[ "$private_ip_val" == "$PRIVATE_IP" ]] \
    && pass "B4: STATE_FILE PRIVATE_IP line preserved ($PRIVATE_IP)" \
    || fail "B4: expected STATE_FILE PRIVATE_IP=$PRIVATE_IP, got '$private_ip_val'"

[[ "$private_ip_count" -eq 1 ]] \
    && pass "B5: exactly one PRIVATE_IP= line in STATE_FILE (idempotent)" \
    || fail "B5: expected exactly one PRIVATE_IP= line, found $private_ip_count"

# ===========================================================================
# Section C — functional: reconcile tier-2 reads the persisted DNS IP
# ===========================================================================
echo ""
echo "=== Section C: reconcile tier-2 resolution from persisted STATE_FILE ==="

RECONCILE_PREAMBLE="$TMPD/reconcile_fn.sh"
{
    cat <<'HELPERS'
log()  { :; }
warn() { :; }
die()  { printf 'ERR %s\n' "$*" >&2; exit 1; }
HELPERS
    awk '/^_setup_coturn_render_env\(\)/{f=1} f{print} /^}$/ && f{exit}' "$RECONCILE"
} > "$RECONCILE_PREAMBLE"
bash -n "$RECONCILE_PREAMBLE" && pass "C0: extracted reconcile function parses cleanly" \
    || { fail "C0: extracted reconcile function has syntax errors"; exit 1; }

R2="$TMPD/run_reconcile.sh"
cat > "$R2" <<EOF
export TURN_SECRET="test-secret"
export PARTNER_DOMAIN="$DOMAIN"
export TURNS_SUBDOMAIN="$TURNS"
export STATE_FILE="$STATE_FILE"
export COMPOSE_FILE="$TMPD/etc/docker-compose.yml"
export PREFIX_ETC="$TMPD/etc"
source "$RECONCILE_PREAMBLE"
PUBLIC_IP=""
PRIVATE_IP=""
_setup_coturn_render_env "$TMPD/etc"
echo "PUBLIC_IP=\$PUBLIC_IP"
echo "PRIVATE_IP=\$PRIVATE_IP"
EOF
chmod +x "$R2"

C_OUT=$(bash "$R2") && C_RC=0 || C_RC=$?
[[ "$C_RC" -eq 0 ]] || fail "C1: _setup_coturn_render_env died unexpectedly (RC=$C_RC): $C_OUT"

recon_public=$(echo "$C_OUT" | grep '^PUBLIC_IP=' | cut -d= -f2 | head -1 || true)
recon_private=$(echo "$C_OUT" | grep '^PRIVATE_IP=' | cut -d= -f2 | head -1 || true)

[[ "$recon_public" == "$DNS_IP" ]] \
    && pass "C2: reconcile tier-2 PUBLIC_IP resolution yields DNS IP ($DNS_IP)" \
    || fail "C2: expected reconcile PUBLIC_IP=$DNS_IP, got '$recon_public'"

[[ "$recon_private" == "$PRIVATE_IP" ]] \
    && pass "C3: reconcile tier-2 PRIVATE_IP resolution yields persisted private IP" \
    || fail "C3: expected reconcile PRIVATE_IP=$PRIVATE_IP, got '$recon_private'"

# ===========================================================================
echo ""
echo "$PASS passed, $FAIL failed"
if [[ "$FAIL" -eq 0 ]]; then
    echo "PASS: test_publicip_state_file_persistence — all checks passed"
    exit 0
else
    echo "FAIL: test_publicip_state_file_persistence — $FAIL check(s) failed"
    exit 1
fi
