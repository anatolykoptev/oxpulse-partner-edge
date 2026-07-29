#!/bin/bash
# Verifies the partner-edge Caddy image has caddy-l4 plugin linked.
# Run: bash test_caddy_image.sh [<image-tag>]
# Default tag: partner-edge-caddy:test (local build)
set -euo pipefail
IMAGE="${1:-partner-edge-caddy:test}"

# The image is a locally-built artifact (caddy + caddy-l4 plugin), not present
# in the generic unit sweep / a fresh CI checkout. Self-skip (no-op) when the
# daemon is unreachable or the image is absent — matching the other docker
# tests — and run the real module/version assertions only when it IS built.
if ! docker info >/dev/null 2>&1; then
  echo "SKIP: docker daemon unreachable" >&2
  exit 0
fi

if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "SKIP: image $IMAGE not built locally — build with 'docker build -t $IMAGE -f images/Dockerfile.caddy images/'" >&2
  exit 0
fi

# The caddy binary should list 'layer4' in its module listing.
# Match start-of-line 'layer4' followed by EOL or whitespace — avoids
# false-negative if caddy list-modules appends '@module-version' or
# provenance suffixes in future releases.
modules=$(docker run --rm "$IMAGE" caddy list-modules 2>&1)
if ! echo "$modules" | grep -E '^layer4( |$)' >/dev/null; then
  echo "FAIL: caddy-l4 module not found. caddy list-modules output:"
  echo "$modules" | grep -E 'layer|l4' || true
  exit 1
fi

# Also verify version matches pin (safety against accidental rollback)
version=$(docker run --rm "$IMAGE" caddy version 2>&1)
if ! echo "$version" | grep -E 'v2\.11\.[0-9]+' >/dev/null; then
  echo "FAIL: caddy version is not 2.11.x: $version"
  exit 1
fi

echo "PASS: caddy-l4 module present, caddy version $version"
