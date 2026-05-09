#!/bin/bash
# M2.1: verify docker-compose.yml.tpl adds the sfu service, install.sh gates
# its UDP/TCP ports in the preflight, and the SFU Dockerfile exists.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TPL="$REPO_ROOT/docker-compose.yml.tpl"
INSTALL="$REPO_ROOT/install.sh"
DOCKERFILE="$REPO_ROOT/images/Dockerfile.sfu"

# 1. sfu service block exists with expected container name.
grep -qE '^[[:space:]]+sfu:' "$TPL" \
    || { echo "FAIL: sfu: service block missing from $TPL"; exit 1; }
grep -q 'container_name: oxpulse-partner-sfu' "$TPL" \
    || { echo "FAIL: sfu container_name != oxpulse-partner-sfu"; exit 1; }

# 2. sfu uses the GHCR image (matches coturn/caddy/xray convention).
grep -qE 'image:[[:space:]]+ghcr\.io/anatolykoptev/partner-edge-sfu:\{\{IMAGE_VERSION\}\}' "$TPL" \
    || { echo "FAIL: sfu image tag does not match GHCR pattern"; exit 1; }

# 3. sfu runs in host networking (co-located media port, like coturn).
awk '/^[[:space:]]+sfu:/,/^[[:space:]]*$/' "$TPL" | grep -q 'network_mode: host' \
    || { echo "FAIL: sfu must use network_mode: host"; exit 1; }

# 4. sfu exposes the documented env surface.
for v in SFU_UDP_PORT SFU_METRICS_PORT SFU_BIND_ADDRESS; do
    grep -q "$v" "$TPL" \
        || { echo "FAIL: sfu service missing env $v"; exit 1; }
done

# 4b. SFU_EDGE_ID must be present in the sfu service block specifically.
#     Regression: rvpn1 partner-edge emitted metrics with edge_id="local"
#     (SFU fallback default) causing label collision in the central Prom view.
#     The Caddy service had SFU_EDGE_ID but the SFU service block was missing
#     it entirely. Manual fix was wiped on every install.sh re-render.
#     Scoped to the sfu: block (awk range) — a grep over the full file would
#     pass if SFU_EDGE_ID appears only in a different service (e.g. caddy).
# NOTE: upgrade.sh reads the already-rendered docker-compose.yml (not the .tpl)
#     and only re-renders xray config via channel-render-lib.sh; it does not
#     re-template compose from docker-compose.yml.tpl. SFU_EDGE_ID correctness
#     in upgrade.sh is therefore guaranteed at install time by install.sh and
#     this check — no separate check 4c needed for upgrade.sh.
awk '/^[[:space:]]+sfu:/,/^[[:space:]]*$/' "$TPL" | grep -q 'SFU_EDGE_ID.*{{SFU_EDGE_ID}}' \
    || { echo "FAIL: SFU_EDGE_ID placeholder missing from sfu service block in docker-compose.yml.tpl"; exit 1; }
grep -q 'SFU_EDGE_ID' "$INSTALL" \
    || { echo "FAIL: SFU_EDGE_ID not derived/substituted in install.sh"; exit 1; }

# 5. Healthcheck hits /metrics (M1.5 endpoint).
grep -q '/metrics' "$TPL" \
    || { echo "FAIL: sfu healthcheck does not probe /metrics"; exit 1; }

# 6. install.sh preflight includes the new ports (parameterized via SFU_UDP_PORT / SFU_METRICS_PORT).
grep -qE 'check_port_free "\$SFU_UDP_PORT" u' "$INSTALL" \
    || { echo "FAIL: install.sh does not preflight \$SFU_UDP_PORT/udp"; exit 1; }
grep -qE 'for p in 80 443 3478 5349 "\$SFU_METRICS_PORT"' "$INSTALL" \
    || { echo "FAIL: install.sh does not include \$SFU_METRICS_PORT in preflight loop"; exit 1; }
# 6b. SFU_UDP_PORT / SFU_METRICS_PORT are declared and passed to the render() sed chain.
grep -qE 'SFU_UDP_PORT=.*7878' "$INSTALL" \
    || { echo "FAIL: install.sh does not declare SFU_UDP_PORT default 7878"; exit 1; }
grep -qE 'SFU_METRICS_PORT=.*9317' "$INSTALL" \
    || { echo "FAIL: install.sh does not declare SFU_METRICS_PORT default 9317"; exit 1; }
grep -q '{{SFU_UDP_PORT}}' "$TPL" \
    || { echo "FAIL: compose template does not use {{SFU_UDP_PORT}} placeholder"; exit 1; }
# 6c. depends_on: caddy present in sfu service block.
grep -q 'caddy' "$TPL" \
    || { echo "FAIL: sfu service missing depends_on: caddy"; exit 1; }

# 7. Dockerfile.sfu exists and targets oxpulse-sfu binary.
[ -f "$DOCKERFILE" ] \
    || { echo "FAIL: $DOCKERFILE missing"; exit 1; }
grep -q 'oxpulse-sfu' "$DOCKERFILE" \
    || { echo "FAIL: Dockerfile.sfu does not reference oxpulse-sfu binary"; exit 1; }
grep -q -- '--locked' "$DOCKERFILE" \
    || { echo "FAIL: Dockerfile.sfu does not use --locked"; exit 1; }
grep -q 'mount=type=cache' "$DOCKERFILE" \
    || { echo "FAIL: Dockerfile.sfu does not use BuildKit cache mounts"; exit 1; }

echo "PASS: sfu compose + install + Dockerfile wiring"
