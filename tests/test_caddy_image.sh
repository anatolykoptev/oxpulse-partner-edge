#!/bin/bash
# Verifies the partner-edge Caddy image has caddy-l4 plugin linked.
# Run: bash test_caddy_image.sh [<image-tag>]
# Default tag: oxpulse-partner-edge-caddy:test (local build)
set -euo pipefail
IMAGE="${1:-oxpulse-partner-edge-caddy:test}"

if ! docker info >/dev/null 2>&1; then
  echo "FAIL: docker daemon unreachable" >&2
  exit 2
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "FAIL: image $IMAGE not found — build it first with 'docker build -t $IMAGE -f deploy/partner-edge/images/Dockerfile.caddy deploy/partner-edge/images/'"
  exit 1
fi

# The caddy binary should list 'layer4' in its module listing.
# Match start-of-line 'layer4' followed by EOL or whitespace — avoids
# false-negative if caddy list-modules appends '@module-version' or
# provenance suffixes in future releases.
modules=$(docker run --rm "$IMAGE" caddy list-modules 2>&1)
if ! echo "$modules" | grep -qE '^layer4( |$)'; then
  echo "FAIL: caddy-l4 module not found. caddy list-modules output:"
  echo "$modules" | grep -E 'layer|l4' || true
  exit 1
fi

# Also verify version matches pin (safety against accidental rollback)
version=$(docker run --rm "$IMAGE" caddy version 2>&1)
if ! echo "$version" | grep -qE 'v2\.11\.[0-9]+'; then
  echo "FAIL: caddy version is not 2.11.x: $version"
  exit 1
fi

echo "PASS: caddy-l4 module present, caddy version $version"
