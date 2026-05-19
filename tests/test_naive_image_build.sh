#!/usr/bin/env bash
# Phase 5.10 Task 8 — verify Dockerfile.naive builds + binary works.
# Skips actual build if docker unavailable (CI/sandbox); falls back to
# syntax check via grep'd structural validation.
set -euo pipefail

cd "$(dirname "$0")/.."

# Quick structural check (always runs)
[[ -f Dockerfile.naive ]] || { echo "FAIL: Dockerfile.naive missing"; exit 1; }
grep -qE '^FROM ' Dockerfile.naive || { echo "FAIL: no FROM directive"; exit 1; }
grep -qE 'naiveproxy|naive' Dockerfile.naive || { echo "FAIL: no naive reference"; exit 1; }
grep -qE 'EXPOSE|CMD|ENTRYPOINT' Dockerfile.naive || { echo "FAIL: no runtime directive"; exit 1; }

# If docker available + DOCKER_BUILD=1 env set, actually build
if [[ "${DOCKER_BUILD:-0}" == "1" ]] && command -v docker >/dev/null 2>&1; then
    docker build -f Dockerfile.naive -t partner-edge-naive:test --no-cache . \
        >/tmp/naive-build.log 2>&1 \
        || { echo "FAIL: docker build failed"; tail -20 /tmp/naive-build.log; exit 1; }

    size=$(docker image inspect partner-edge-naive:test --format '{{.Size}}')
    [[ "$size" -lt 80000000 ]] \
        || { echo "FAIL: image too large ($size bytes — expect <80MB)"; exit 1; }

    docker run --rm partner-edge-naive:test --version 2>&1 | grep -qE 'naive|^v?[0-9]+' \
        || { echo "FAIL: naive binary missing or wrong"; exit 1; }
    echo "OK: naive image builds + binary works"
else
    echo "OK (structural only — set DOCKER_BUILD=1 for full build test)"
fi

# release.yml validation
python3 -c "
import yaml, sys
with open('.github/workflows/release.yml') as f:
    doc = yaml.safe_load(f)
jobs = doc.get('jobs', {})
if 'build-and-push-naive' not in jobs:
    print('FAIL: build-and-push-naive job missing from release.yml')
    sys.exit(1)
if 'merge-manifests-naive' not in jobs:
    print('FAIL: merge-manifests-naive job missing from release.yml')
    sys.exit(1)
print('OK: release.yml has naive build+merge jobs')
"
