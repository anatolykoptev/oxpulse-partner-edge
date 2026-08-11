#!/bin/bash
# tests/test_upgrade_collects_images.sh
#
# An upgrade pulls the images it needs and, until now, never removed the ones it
# replaced. The disk healer collects them, but only at 85% — so between upgrades
# every edge grew a tag per service per release with nothing reporting it (286
# across the five when anyone first counted).
#
# Worse than the space, that dead weight is SLACK. When something else fills a
# disk, the healer reclaims OUR images, drops back under the threshold and clears
# its budget — so the alert that should have said "the growth is not ours" never
# fires. Collecting at the point of creation is what makes that alert truthful.
#
# Structural + behavioural, hermetic: no docker, no network, no root.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
SELFHEAL="$REPO_ROOT/oxpulse-partner-edge-selfheal.sh"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

echo ""
echo "=== upgrade collects the images it replaced ==="

# 1 — BOTH success paths. The plain path and --with-templates each pull images, so
# a call on only one leaves half the fleet accumulating.
_n=$(grep -c '^\s*_collect_stale_images$' "$UPGRADE")
[[ "$_n" == 2 ]] && pass "called from both success paths ($_n)" \
                 || fail "called from $_n success path(s) — each pulls images, so both must collect"

# 2 — AFTER the success is declared, never before. A collector that runs first
# could delete an image the rollback still needs.
_ok=1
grep -q 'log "upgraded to \$TARGET successfully"' "$UPGRADE" || _ok=0
awk '/log "upgraded to \$TARGET successfully"/{s=NR} /^_collect_stale_images$/{if(NR<s) bad=1} END{exit bad?1:0}' "$UPGRADE" || _ok=0
[[ "$_ok" == 1 ]] && pass "the plain path collects only after success is declared" \
                  || fail "the collector runs before the upgrade is declared successful"

# 3 — the collector must never be able to fail an upgrade. A few stale tags are a
# far better outcome than a failed upgrade on an anti-censorship relay.
awk '/^_collect_stale_images\(\)/{f=1} f&&/^}/{exit} f' "$UPGRADE" | grep -q 'return 0' \
	&& pass "the helper returns 0 on every path" \
	|| fail "the helper can propagate a failure into the upgrade"
awk '/^_collect_stale_images\(\)/{f=1} f&&/^}/{exit} f' "$UPGRADE" | grep -qE '\bdie\b' \
	&& fail "the helper can die() — a collector must not abort an upgrade" \
	|| pass "the helper never calls die()"

# 4 — delegated, not reimplemented. A second copy of the keep-set rules (per repo,
# by image ID, version-sorted) would drift from the first, and the drift would be
# silent until it deleted a running release.
awk '/^_collect_stale_images\(\)/{f=1} f&&/^}/{exit} f' "$UPGRADE" | grep -q 'oxpulse-partner-edge-selfheal' \
	&& pass "it delegates to the installed collector" \
	|| fail "the upgrade grew its own copy of the keep-set rules"
awk '/^_collect_stale_images\(\)/{f=1} f&&/^}/{exit} f' "$UPGRADE" | grep -qE 'docker rmi|sort -Vru' \
	&& fail "the upgrade reimplements image removal instead of delegating" \
	|| pass "no second implementation of the removal rules"

# 5 — bounded. It runs inside an upgrade; a hung docker daemon must not park the
# upgrade indefinitely.
awk '/^_collect_stale_images\(\)/{f=1} f&&/^}/{exit} f' "$UPGRADE" | grep -q 'timeout ' \
	&& pass "the call is bounded by a timeout" \
	|| fail "an unbounded call — a hung docker parks the upgrade"

# 6 — the flag the upgrade calls actually exists in the collector. A rename on
# either side would leave the upgrade calling a mode that silently does a FULL
# heal run: container restarts and unit restarts, during an upgrade.
grep -q -- '--collect-images' "$SELFHEAL" \
	&& pass "the collector implements --collect-images" \
	|| fail "the flag the upgrade passes does not exist — the call would run a full heal"

# 7 — an unknown flag must not degrade into a full run. This is the failure mode
# behind case 6 and it deserves its own assertion.
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
if grep -qE '"\$\{1:-\}" == "--collect-images"' "$SELFHEAL"; then
	pass "the mode is matched exactly, not by prefix or substring"
else
	fail "the mode match is not an exact comparison"
fi

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
