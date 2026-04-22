#!/bin/bash
# Test: partner-edge Caddy does NOT leak Via or Alt-Svc headers
set -eu
DOMAIN="${1:?partner domain required}"
resp=$(curl -sI "https://${DOMAIN}/" --max-time 10)

if echo "$resp" | grep -qi '^via:'; then
  echo "FAIL: Via header leaked" >&2
  echo "$resp" | grep -i '^via:' >&2
  exit 1
fi

if echo "$resp" | grep -qi '^alt-svc:'; then
  echo "FAIL: Alt-Svc header leaked" >&2
  echo "$resp" | grep -i '^alt-svc:' >&2
  exit 1
fi

echo "PASS: no Via or Alt-Svc in response headers"

# Also verify no UDP 443 listener (HTTP/3 dropped under ТСПУ hardening)

# Skip UDP check if nmap isn't installed or we lack privileges — better to
# SKIP than falsely PASS. nmap -sU requires root / CAP_NET_RAW.
if ! command -v nmap >/dev/null 2>&1; then
  echo "SKIP: nmap not installed — UDP 443 probe requires nmap" >&2
  exit 0
fi
if [ "$(id -u)" != "0" ] && ! nmap --help 2>&1 | grep -q "unprivileged"; then
  echo "SKIP: UDP 443 probe needs root (nmap -sU)" >&2
  exit 0
fi

if timeout 5 nmap -sU -p 443 "${DOMAIN}" 2>/dev/null | grep -q '443/udp\s*open'; then
  echo "FAIL: UDP 443 listener detected (HTTP/3)" >&2
  exit 1
fi
echo "PASS: UDP 443 closed"
