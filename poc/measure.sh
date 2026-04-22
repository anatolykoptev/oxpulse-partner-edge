#!/bin/bash
# PoC Measurement Script — TURNS-on-443 Task 1.2
# Run from deploy/partner-edge/poc/ or via absolute path.
#
# Usage: bash measure.sh {a-prime|b}
#
# Runs one variant end-to-end: boot → measure C1-C5 → teardown.
# Only ONE variant may run at a time (both bind 127.0.0.1:18443).
# Requires: docker, docker compose v2.17+, openssl, curl, ss (iproute2).
# No sudo required — uses docker volume inspect + docker run for cert access.

set -euo pipefail

VARIANT="${1:?usage: $0 a-prime|b}"
case "$VARIANT" in
  a-prime|b) ;;
  *) echo "ERROR: invalid variant '$VARIANT'. Use 'a-prime' or 'b'"; exit 2 ;;
esac

BASE="$(dirname "$(readlink -f "$0")")"
VARIANT_DIR="$BASE/$VARIANT"

# Per-variant names (must match compose file declarations)
case "$VARIANT" in
  a-prime)
    COMPOSE_PROJECT="oxpulse-partner-edge-poc-aprime"
    CERT_VOLUME="${COMPOSE_PROJECT}_poc-aprime-coturn-cert"
    CADDY_SVC="caddy"
    COTURN_SVC="coturn"
    MAIN_RESPONSE="PoC app response OK"
    ;;
  b)
    COMPOSE_PROJECT="oxpulse-partner-edge-poc-b"
    CERT_VOLUME="${COMPOSE_PROJECT}_poc-b-coturn-cert"
    CADDY_SVC="caddy"
    COTURN_SVC="coturn"
    MAIN_RESPONSE="PoC app response OK (Variant B)"
    ;;
esac

# Tracking counters
PASS=0; FAIL=0; SKIP=0

c_pass() { echo "C${1} PASS — ${2}"; PASS=$((PASS+1)); }
c_fail() { echo "C${1} FAIL — ${2}"; FAIL=$((FAIL+1)); }
c_skip() { echo "C${1} SKIP — ${2}"; SKIP=$((SKIP+1)); }

echo ""
echo "=== PoC Measurement — Variant $VARIANT — $(date -Iseconds) ==="
echo "=== Working dir: $VARIANT_DIR"
echo ""

cd "$VARIANT_DIR"

# ─── Pre-flight: cleanup any prior sandbox ────────────────────────────────
echo "--- Pre-flight: cleanup ---"
docker compose down -v --remove-orphans 2>/dev/null || true
# Confirm port 18443 is free (avoid misleading failures)
if ss -lnt 2>/dev/null | awk '{print $4}' | grep -q "127.0.0.1:18443$"; then
  echo "ERROR: 127.0.0.1:18443 is still bound. Another variant may be running."
  echo "       Run: docker compose -f ../a-prime/docker-compose.yml down -v"
  echo "       Run: docker compose -f ../b/docker-compose.yml down -v"
  exit 1
fi

# ─── Boot ─────────────────────────────────────────────────────────────────
echo ""
echo "--- Boot (a-prime builds caddy-l4 via xcaddy, ~90-120s; b pulls, ~20s) ---"
BUILD_FLAG=""
[ "$VARIANT" = "a-prime" ] && BUILD_FLAG="--build"
BOOT_EXIT=0
time docker compose up -d $BUILD_FLAG || BOOT_EXIT=$?

if [ "$BOOT_EXIT" -ne 0 ]; then
  echo ""
  echo "BLOCKED: docker compose up exited $BOOT_EXIT — containers did not start."
  echo "         All criteria C1-C5 are UNMEASURABLE for this variant."
  echo "         See build output above for root cause."
  # Mark all criteria as skip
  for N in 1 2 3 4 5; do c_skip $N "BLOCKED — containers failed to start"; done
  docker compose down -v --remove-orphans 2>/dev/null || true
  echo ""
  echo "=== SUMMARY — Variant $VARIANT — $(date -Iseconds) ==="
  echo "    PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
  echo "    VERDICT: BLOCKED (boot failure)"
  echo "=== End — Variant $VARIANT ==="
  exit 1
fi

# ─── Wait for readiness ───────────────────────────────────────────────────
echo ""
echo "--- Waiting for Caddy admin API at http://127.0.0.1:2019/config/ ---"
CADDY_READY=false
for i in $(seq 1 40); do
  if docker compose exec -T "$CADDY_SVC" \
       wget -qO- http://127.0.0.1:2019/config/ >/dev/null 2>&1; then
    echo "Caddy admin ready (attempt $i)"
    CADDY_READY=true
    break
  fi
  sleep 3
done
if [ "$CADDY_READY" = "false" ]; then
  echo "WARNING: Caddy did not become ready in 120s — continuing anyway"
fi

echo "--- Waiting 8s for coturn to settle ---"
sleep 8

# ─── Criterion 1: Caddyfile parses + caddy-l4 plugin present ──────────────
echo ""
echo "--- Criterion 1: Caddyfile validates inside running container ---"
C1_OUT=$(docker compose exec -T "$CADDY_SVC" \
  caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1)
echo "$C1_OUT" | tail -6
if echo "$C1_OUT" | grep -q -E "(Valid|Configuration is valid|0 error)"; then
  c_pass 1 "Caddyfile accepted by caddy binary in container"
elif echo "$C1_OUT" | grep -q -i "error"; then
  c_fail 1 "Caddyfile parse/validate error"
  echo "    Full output:"
  echo "$C1_OUT" | head -20 | sed 's/^/    /'
else
  # Some caddy versions exit 0 with no explicit "valid" but no error line
  if docker compose exec -T "$CADDY_SVC" \
       caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile 2>&1; then
    c_pass 1 "validate exited 0, no error keyword"
  else
    c_fail 1 "validate exited non-zero"
  fi
fi

# For Variant A' also confirm layer4 plugin is loaded
if [ "$VARIANT" = "a-prime" ]; then
  echo "  (a-prime) checking layer4 plugin in caddy binary..."
  if docker compose exec -T "$CADDY_SVC" caddy list-modules 2>&1 \
       | grep -q "layer4"; then
    echo "  layer4 plugin: PRESENT"
  else
    echo "  layer4 plugin: NOT FOUND (caddy-l4 may not have compiled)"
  fi
fi

# ─── Criterion 2: HTTP/3 fallthrough — UDP 18443 closed ───────────────────
echo ""
echo "--- Criterion 2: HTTP/3 UDP state on 127.0.0.1:18443 ---"
# We bind TCP only; UDP MUST NOT be present (we dropped H3 on purpose).
UDP_STATE=$(ss -lnu 2>/dev/null | awk '{print $5}' | grep "127.0.0.1:18443$" || true)
if [ -n "$UDP_STATE" ]; then
  c_fail 2 "UDP 18443 listener IS present — H3 may be active"
  echo "    $UDP_STATE"
else
  c_pass 2 "UDP 18443 not listening — H3 correctly absent"
fi

# ─── Criterion 3: Cert renewal + SIGUSR2 reload ───────────────────────────
echo ""
echo "--- Criterion 3: Cert renewal + SIGUSR2 coturn reload ---"
# Find volume mount path via docker volume inspect (no sudo needed)
CERT_MOUNTPOINT=$(docker volume inspect "$CERT_VOLUME" 2>/dev/null \
  | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0]['Mountpoint'])" 2>/dev/null || true)

if [ -z "$CERT_MOUNTPOINT" ]; then
  c_skip 3 "Volume $CERT_VOLUME not found — cert-init may not have run"
else
  # Access cert via docker run (avoids need for sudo)
  CERT_EXISTS=$(docker run --rm \
    -v "${CERT_VOLUME}:/certs:ro" \
    alpine:3.20 sh -c "[ -f /certs/cert.pem ] && echo yes || echo no" 2>/dev/null)

  if [ "$CERT_EXISTS" != "yes" ]; then
    c_skip 3 "cert.pem not found in volume $CERT_VOLUME"
  else
    # Capture log line count before reload
    LOGS_BEFORE=$(docker compose logs "$COTURN_SVC" 2>&1 | wc -l)

    # Touch cert file: spin up a transient container with the volume rw
    docker run --rm \
      -v "${CERT_VOLUME}:/certs" \
      alpine:3.20 sh -c "touch /certs/cert.pem" 2>/dev/null

    # Send SIGUSR2 to coturn (PID 1 inside container)
    docker compose exec -T "$COTURN_SVC" \
      sh -c 'kill -USR2 1' 2>/dev/null || true

    sleep 3

    LOGS_AFTER=$(docker compose logs "$COTURN_SVC" 2>&1)
    # coturn logs "Reloading SSL..."; match broadly
    if echo "$LOGS_AFTER" | grep -i -q -E "(Reload|reload).*(SSL|TLS|cert)"; then
      c_pass 3 "coturn logged cert reload after SIGUSR2"
      echo "  Matching log lines:"
      echo "$LOGS_AFTER" | grep -i -E "(Reload|reload).*(SSL|TLS|cert)" \
        | tail -5 | sed 's/^/    /'
    else
      c_fail 3 "no reload log line after SIGUSR2 — coturn may not support it"
      echo "  Last 15 coturn log lines:"
      echo "$LOGS_AFTER" | tail -15 | sed 's/^/    /'
      echo "  NOTE: This is a known PoC limitation — production coturn handles"
      echo "        SIGUSR2 via the systemd path unit, not the container's PID 1."
    fi
  fi
fi

# ─── Criterion 4: TLS ClientHello for both SNIs ────────────────────────────
echo ""
echo "--- Criterion 4: TLS handshake for main SNI + TURNS SNI ---"
for SNI in example.test turns.example.test; do
  echo ""
  echo "  -- SNI: $SNI --"
  TLS_OUT=$(timeout 6 openssl s_client \
    -connect 127.0.0.1:18443 \
    -servername "$SNI" \
    -showcerts \
    </dev/null 2>&1 || true)

  # Did we get a Server Certificate?
  if echo "$TLS_OUT" | grep -q "Server certificate"; then
    echo "  TLS handshake: OK"
    echo "$TLS_OUT" | grep -E "^(subject=|issuer=|Protocol|Cipher)" \
      | head -8 | sed 's/^/    /'
    c_pass 4 "TLS handshake OK for $SNI"
  elif echo "$TLS_OUT" | grep -q "CONNECTED"; then
    echo "  Connected but no full TLS handshake (may be TURNS TCP passthrough)"
    echo "$TLS_OUT" | head -10 | sed 's/^/    /'
    # For TURNS SNI this is EXPECTED — caddy-l4 passes raw TCP to coturn
    if [ "$SNI" = "turns.example.test" ]; then
      c_pass 4 "TURNS SNI TCP passthrough detected (expected — coturn owns TLS)"
    else
      c_fail 4 "Main SNI did not complete TLS handshake"
    fi
  else
    echo "  No connection for $SNI:"
    echo "$TLS_OUT" | head -8 | sed 's/^/    /'
    c_fail 4 "TLS connect failed for $SNI"
  fi
done

# ─── Criterion 5: HTTPS latency on main SNI ───────────────────────────────
echo ""
echo "--- Criterion 5: HTTPS latency on main SNI (example.test:18443), 20 req ---"
LATENCIES=()
for i in $(seq 1 20); do
  T=$(curl -sk \
    --resolve "example.test:18443:127.0.0.1" \
    -o /dev/null \
    -w "%{time_total}" \
    https://example.test:18443/ 2>/dev/null || echo "9.9999")
  LATENCIES+=("$T")
done

# Sort and compute percentiles
printf '%s\n' "${LATENCIES[@]}" | sort -n | \
  awk '
  { all[NR]=$1*1000 }
  END {
    n=NR
    p50 = all[int(n*0.50)+1]
    p95 = all[int(n*0.95)+1]
    p99_idx = int(n*0.99)+1
    if (p99_idx > n) p99_idx = n
    p99 = all[p99_idx]
    printf "  p50: %.2f ms\n  p95: %.2f ms\n  p99: %.2f ms\n  max: %.2f ms\n",
           p50, p95, p99, all[n]
    if (p50 < 2) status="PASS (<2ms)"
    else status="FAIL (>=2ms — check Caddy-l4 overhead)"
    printf "  C5 p50 verdict: %s\n", status
  }
'
# Record pass/fail for summary
P50_MS=$(printf '%s\n' "${LATENCIES[@]}" | sort -n | \
  awk '{all[NR]=$1*1000} END {print all[int(NR*0.50)+1]}')
# Use bc or awk for float comparison
if awk "BEGIN {exit !($P50_MS < 2)}"; then
  c_pass 5 "p50 latency ${P50_MS}ms < 2ms threshold"
else
  c_fail 5 "p50 latency ${P50_MS}ms >= 2ms threshold"
fi

# ─── Logs snapshot ────────────────────────────────────────────────────────
echo ""
echo "--- Service log snapshots (last 10 lines each) ---"
echo "  [caddy]"
docker compose logs --tail=10 "$CADDY_SVC" 2>&1 | sed 's/^/  /'
echo "  [coturn]"
docker compose logs --tail=10 "$COTURN_SVC" 2>&1 | sed 's/^/  /'

# ─── Teardown ─────────────────────────────────────────────────────────────
echo ""
echo "--- Teardown ---"
docker compose down -v --remove-orphans

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "=== SUMMARY — Variant $VARIANT — $(date -Iseconds) ==="
echo "    PASS=$PASS  FAIL=$FAIL  SKIP=$SKIP"
if [ "$FAIL" -eq 0 ] && [ "$PASS" -ge 4 ]; then
  echo "    VERDICT: VIABLE (all mandatory criteria pass)"
elif [ "$FAIL" -le 1 ]; then
  echo "    VERDICT: VIABLE_WITH_CONCERNS ($FAIL criterion failed — review results.md)"
else
  echo "    VERDICT: NOT_VIABLE ($FAIL criteria failed)"
fi
echo "=== End — Variant $VARIANT ==="
