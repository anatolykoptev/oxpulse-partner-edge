#!/usr/bin/env bash
# tests/test_metrics_exporter_binds_mesh_only.sh
#
# Guards the node-exporter service added for #411 against the one way it can
# do harm.
#
# The exporter renders its listen address from {{AWG_HOST_IP}}. If that value
# is ever empty, "--web.listen-address={{AWG_HOST_IP}}:9100" becomes
# "--web.listen-address=:9100", which binds EVERY interface and publishes host
# inventory — kernel version, filesystems, uptime, process counts — from a
# relay whose entire purpose is to be unremarkable to a censor. The same class
# was found live on 2026-05-21: SFU_METRICS_BIND was leaking on the public NIC
# across all three partners then in production.
#
# So the gate is not "does the service exist" but "can it ever bind wide". Two
# independent defences, and this file tests both:
#   1. the template interpolates the mesh placeholder, never a wildcard;
#   2. install.sh only adds the `metrics` profile when AWG_HOST_IP is non-empty,
#      so an empty value means the service never starts at all.
#
# Defence 2 is tested by EXECUTING the gate, not by reading it — a grep would
# pass against a gate whose branches were swapped.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TPL="$REPO_ROOT/docker-compose.yml.tpl"
INSTALL="$REPO_ROOT/install.sh"
fails=0

_fail() { echo "FAIL: $*" >&2; fails=$((fails + 1)); }
_ok()   { echo "  ok: $*"; }

# ---------------------------------------------------------------------------
# S1. Anti-vacuous floor.
# Every later assertion greps inside the node-exporter block. If the block is
# renamed or removed, those greps find nothing and would report success. Prove
# the block is here and substantial before trusting anything below it.
# ---------------------------------------------------------------------------
block=$(awk '
    /^  node-exporter:/ { inblk = 1 }
    inblk && /^  [a-z]/ && !/^  node-exporter:/ { exit }
    inblk { print }
' "$TPL")

if [[ -z "$block" ]]; then
    _fail "S1: no 'node-exporter:' service in $TPL — every assertion below would be vacuous"
    echo "RESULT: $fails failure(s)"; exit 1
fi

flag_count=$(printf '%s\n' "$block" | grep -cE '^\s+- "--')
if (( flag_count < 3 )); then
    _fail "S1: node-exporter block has $flag_count command flags, expected >= 3 (rootfs, listen-address, textfile)"
else
    _ok "S1: node-exporter block present with $flag_count command flags"
fi

# ---------------------------------------------------------------------------
# S2. The listen address must interpolate the mesh placeholder.
# ---------------------------------------------------------------------------
listen=$(printf '%s\n' "$block" | grep -oE '\-\-web\.listen-address=[^"]*' || true)
if [[ -z "$listen" ]]; then
    _fail "S2: no --web.listen-address flag in the node-exporter block"
elif [[ "$listen" != *'{{AWG_HOST_IP}}'* ]]; then
    _fail "S2: listen address does not interpolate {{AWG_HOST_IP}} (got: $listen)"
else
    _ok "S2: listen address interpolates the mesh placeholder ($listen)"
fi

# ---------------------------------------------------------------------------
# S3. No wildcard bind, in any spelling.
# ---------------------------------------------------------------------------
for bad in '0.0.0.0' '[::]' '*:9100'; do
    if printf '%s\n' "$block" | grep -qF -- "--web.listen-address=$bad"; then
        _fail "S3: node-exporter binds the wildcard address '$bad'"
    fi
done
[[ $fails -eq 0 ]] && _ok "S3: no wildcard bind in any spelling"

# ---------------------------------------------------------------------------
# S4. The textfile collector must be enabled.
# Without it the exporter serves host metrics and none of the partner_edge_*
# series the host scripts write — which is the state measured fleet-wide on
# 2026-08-08 and the whole reason #411 exists.
# ---------------------------------------------------------------------------
if printf '%s\n' "$block" | grep -q -- '--collector.textfile.directory='; then
    _ok "S4: textfile collector enabled"
else
    _fail "S4: no --collector.textfile.directory — partner_edge_* series would not be served"
fi

# ---------------------------------------------------------------------------
# S5. Render simulation: a populated mesh IP produces a mesh-scoped address.
# ---------------------------------------------------------------------------
rendered=$(printf '%s\n' "$listen" | sed 's/{{AWG_HOST_IP}}/10.9.0.7/')
if [[ "$rendered" == "--web.listen-address=10.9.0.7:9100" ]]; then
    _ok "S5: renders to a mesh-scoped address ($rendered)"
else
    _fail "S5: unexpected render with AWG_HOST_IP=10.9.0.7 (got: $rendered)"
fi

# ---------------------------------------------------------------------------
# S6. THE ONE THAT MATTERS — execute install.sh's profile gate, both arms.
#
# An empty AWG_HOST_IP renders "--web.listen-address=:9100". Nothing in the
# template can prevent that; the only thing standing between an empty value
# and a fleet-wide metrics leak is install.sh refusing to activate the
# profile. So run that gate for real rather than reading it.
# ---------------------------------------------------------------------------
gate=$(awk '
    /^if \[\[ -n "\$\{AWG_HOST_IP:-\}" \]\]; then/ { inblk = 1 }
    inblk { print }
    inblk && /^fi$/ { exit }
' "$INSTALL")

if [[ -z "$gate" ]]; then
    _fail "S6: could not locate the AWG_HOST_IP profile gate in install.sh"
else
    _run_gate() { # _run_gate <awg_host_ip_value> -> prints resulting profiles
        (
            set +u
            AWG_HOST_IP="$1"
            COMPOSE_PROFILES_EXTRA=""
            log()  { :; }
            warn() { :; }
            eval "$gate"
            printf '%s' "$COMPOSE_PROFILES_EXTRA"
        )
    }

    with_ip=$(_run_gate "10.9.0.7")
    if [[ "$with_ip" == *metrics* ]]; then
        _ok "S6a: mesh address present -> profile enabled (profiles='$with_ip')"
    else
        _fail "S6a: mesh address present but 'metrics' profile NOT enabled (profiles='$with_ip')"
    fi

    without_ip=$(_run_gate "")
    if [[ "$without_ip" == *metrics* ]]; then
        _fail "S6b: FAIL-OPEN — empty AWG_HOST_IP still enabled the metrics profile (profiles='$without_ip'). The exporter would bind every interface on a censorship-facing relay."
    else
        _ok "S6b: empty mesh address -> profile withheld (profiles='$without_ip')"
    fi
fi

echo
if (( fails == 0 )); then
    echo "RESULT: all checks passed"
    exit 0
fi
echo "RESULT: $fails failure(s)"
exit 1
