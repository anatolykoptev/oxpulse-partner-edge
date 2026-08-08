#!/usr/bin/env bash
# tests/test_compose_profile_converges_on_upgrade.sh
#
# COMPOSE_PROFILES was written only by install.sh. A profile-gated service added
# to docker-compose.yml.tpl therefore reached a fresh install and NO existing
# node — shipped, CI-green, and wired on nothing.
#
# Measured 2026-08-08 while trying to roll the metrics collector (#570):
#
#   rvpn        .env = COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml
#   ruoxp       .env ABSENT
#   zvonilka    .env ABSENT
#   cheburator  .env ABSENT
#   pillow      .env ABSENT
#
# Not one node had COMPOSE_PROFILES at all. rvpn's line is the second hazard:
# install.sh wrote the profile file with `>`, which would have truncated the
# COMPOSE_FILE entry that decides which compose files load.
#
# So this guards two things that are easy to get wrong and silent when wrong:
# the merge must never destroy neighbouring keys, and the upgrade path must
# actually call it.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/lib/compose-lib.sh"
UPGRADE="$REPO_ROOT/upgrade.sh"
fails=0
_fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
_ok()   { echo "  ok: $*"; }

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# shellcheck source=lib/compose-lib.sh
source "$LIB"

if ! command -v compose_env_ensure_profile >/dev/null 2>&1; then
    _fail "S0: compose_env_ensure_profile not defined after sourcing $LIB"
    echo "RESULT: $fails failure(s)"; exit 1
fi
_ok "S0: function defined"

# ---------------------------------------------------------------------------
# S1. Missing .env — create it with just the profile.
# ---------------------------------------------------------------------------
f="$TMPD/a.env"
out=$(compose_env_ensure_profile metrics "$f")
if [[ "$out" == "metrics" ]] && [[ "$(cat "$f")" == "COMPOSE_PROFILES=metrics" ]]; then
    _ok "S1: absent .env created with the profile"
else
    _fail "S1: got out='$out' file='$(cat "$f" 2>/dev/null)'"
fi

# ---------------------------------------------------------------------------
# S2. THE ONE THAT MATTERS — a neighbouring key must survive.
#
# This is rvpn's real .env. Truncating it drops the line that decides which
# compose files load at all, which no test would notice and the node would
# only reveal on its next restart.
# ---------------------------------------------------------------------------
f="$TMPD/b.env"
printf 'COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml\n' > "$f"
compose_env_ensure_profile metrics "$f" >/dev/null
if ! grep -q '^COMPOSE_FILE=docker-compose.yml:docker-compose.override.yml$' "$f"; then
    _fail "S2: DESTROYED a neighbouring key — COMPOSE_FILE is gone. File now: $(cat "$f")"
elif ! grep -q '^COMPOSE_PROFILES=metrics$' "$f"; then
    _fail "S2: profile not added. File: $(cat "$f")"
else
    _ok "S2: neighbouring COMPOSE_FILE preserved and profile added"
fi

# ---------------------------------------------------------------------------
# S3. Existing profiles are merged, not replaced.
# ---------------------------------------------------------------------------
f="$TMPD/c.env"
printf 'COMPOSE_PROFILES=ch3,ch5\n' > "$f"
out=$(compose_env_ensure_profile metrics "$f")
if [[ "$out" == "ch3,ch5,metrics" ]] && grep -q '^COMPOSE_PROFILES=ch3,ch5,metrics$' "$f"; then
    _ok "S3: merged into an existing set ($out)"
else
    _fail "S3: got '$out', file '$(cat "$f")'"
fi

# ---------------------------------------------------------------------------
# S4. Idempotent — a second call must not duplicate. The ch3 path once shipped
# "ch3,ch3", which is why this is checked rather than assumed.
# ---------------------------------------------------------------------------
compose_env_ensure_profile metrics "$f" >/dev/null
compose_env_ensure_profile metrics "$f" >/dev/null
# Count OCCURRENCES, not matching lines. `grep -c` counts lines, and every
# duplicate lands on the same COMPOSE_PROFILES line — so `grep -c` returns 1
# whether the value is "metrics" or "metrics,metrics,metrics". The first
# version of this check used it and a mutant that disabled the membership
# test survived, which is the whole reason the matrix is run.
value=$(awk -F= '/^COMPOSE_PROFILES=/{ print $2; exit }' "$f")
n=$(awk -v v="$value" 'BEGIN{ n=split(v, a, ","); c=0; for(i=1;i<=n;i++) if(a[i]=="metrics") c++; print c }')
lines=$(grep -c '^COMPOSE_PROFILES=' "$f")
if [[ "$value" == "ch3,ch5,metrics" ]] && (( n == 1 )) && (( lines == 1 )); then
    _ok "S4: repeat calls are a no-op (value='$value', one 'metrics' entry)"
else
    _fail "S4: duplicated or reordered — value='$value' metrics_count=$n profile_lines=$lines"
fi

# ---------------------------------------------------------------------------
# S5. Substring safety: a profile whose name contains another's must not
# suppress it.
# ---------------------------------------------------------------------------
f="$TMPD/d.env"
printf 'COMPOSE_PROFILES=metrics-extra\n' > "$f"
out=$(compose_env_ensure_profile metrics "$f")
if [[ "$out" == "metrics-extra,metrics" ]]; then
    _ok "S5: 'metrics' added despite 'metrics-extra' already present"
else
    _fail "S5: substring match suppressed the add — got '$out'"
fi

# ---------------------------------------------------------------------------
# S6. Always returns 0. Every caller runs under `set -e`; a non-zero return on
# the already-present path would abort an upgrade on its most common branch.
# ---------------------------------------------------------------------------
f="$TMPD/e.env"
printf 'COMPOSE_PROFILES=metrics\n' > "$f"
compose_env_ensure_profile metrics "$f" >/dev/null; rc_present=$?
compose_env_ensure_profile metrics "$TMPD/new.env" >/dev/null; rc_new=$?
if (( rc_present == 0 && rc_new == 0 )); then
    _ok "S6: returns 0 on both the already-present and the fresh path"
else
    _fail "S6: rc_present=$rc_present rc_new=$rc_new — a set -e caller would abort"
fi

# ---------------------------------------------------------------------------
# S7. WIRING — the upgrade path must call it, gated on the mesh address.
# Everything above tests a function nothing has to invoke.
# ---------------------------------------------------------------------------
call_line=$(awk '/compose_env_ensure_profile "metrics"/ && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$UPGRADE")
gate_line=$(awk '/_wt_mesh_ip=/ && $0 !~ /^[[:space:]]*#/ { print NR; exit }' "$UPGRADE")
if [[ -z "$call_line" ]]; then
    _fail "S7: upgrade.sh never calls compose_env_ensure_profile — the collector would reach no existing node"
elif [[ -z "$gate_line" ]]; then
    _fail "S7: upgrade.sh calls it without deriving a mesh address — an empty bind publishes host inventory"
elif (( gate_line > call_line )); then
    _fail "S7: the mesh-address gate (line $gate_line) comes AFTER the call (line $call_line)"
else
    _ok "S7: upgrade.sh derives the mesh address at line $gate_line, then converges at line $call_line"
fi

echo
if (( fails == 0 )); then echo "RESULT: all checks passed"; exit 0; fi
echo "RESULT: $fails failure(s)"; exit 1
