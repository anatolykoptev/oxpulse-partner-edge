#!/usr/bin/env bash
# tests/test_compose_healthcheck_interpolation.sh
#
# Guards the SFU healthcheck in docker-compose.yml.tpl against docker compose's
# YAML-time `$VAR` interpolation.
#
# The defect this exists for (measured on a live edge 2026-08-07):
# the template read `[ -z \"$SIGNALING_SFU_SECRET\" ] || nc -z ...`. compose
# interpolates `$VAR` in the YAML BEFORE the container sees it, against its OWN
# environment — where the secrets are absent (they live in the service's
# `environment:` block). So compose baked in `[ -z "" ]`, which is TRUE, the
# `||` short-circuited, and NEITHER `nc -z` port probe ever ran. The container
# stayed green on /metrics alone — exactly the pre-fix state the 2026-05-06
# post-mortem describes and that this healthcheck was written to end.
#
# `docker inspect .Config.Healthcheck` is the only place that was visible; the
# YAML still read `$VAR`. So the assertion here is on the RENDERED-BY-COMPOSE
# form, not on the source text alone.
#
# WHY THIS FILE AND NOT tests/test_install_render_identical.sh: that test calls
# render_template on `tests/fixtures/install-render/compose.tpl` — a FIXTURE
# COPY. It validates render_template's substitution mechanics against a frozen
# pair and never reads the shipped docker-compose.yml.tpl, so a defect in the
# shipped template is invisible to it. This test reads the shipped file.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
TPL="docker-compose.yml.tpl"
fails=0
ok()   { printf '  ok   %s\n' "$1"; }
bad()  { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "=== SFU healthcheck vs docker compose interpolation ==="

# ---------------------------------------------------------------- S1 floor
# Anti-vacuous: every later assertion is on this one line. If the healthcheck
# is renamed or moved, they would all pass by matching nothing.
HC=$(awk '/^ *test: \["CMD-SHELL"/ && /SIGNALING_SFU_SECRET/ {print; exit}' "$TPL")
if [[ -n "$HC" ]]; then
    ok "S1 located the SFU healthcheck CMD-SHELL line in $TPL"
else
    bad "S1 no SFU healthcheck line found in $TPL — every assertion below would be vacuous"
    echo "FAILED=$((fails))"
    exit 1
fi

# ------------------------------------------------- S2 container-side vars
# These four are measured present INSIDE the running container, and main.rs
# gates the listeners on them. They must survive compose untouched, so they
# must be written `$$`.
for v in SIGNALING_SFU_SECRET RELAY_JWT_SECRET; do
    if [[ "$HC" == *"\$\$$v"* ]]; then
        ok "S2 \$\$$v escaped — compose emits a literal \$, container expands it"
    else
        bad "S2 $v is not \$\$-escaped — compose will substitute empty and the || short-circuits, disabling the probe it guards"
    fi
done
for v in SFU_CLIENT_WS_PORT SFU_RELAY_API_PORT; do
    if [[ "$HC" == *"\$\${$v"* ]]; then
        ok "S3 \$\${$v} escaped — the container's own override wins"
    else
        bad "S3 $v is not \$\$-escaped — compose bakes the default and a node overriding the port is probed on the wrong one"
    fi
done

# ------------------------------------------------------ S4 the asymmetry
# SFU_METRICS_BIND / SFU_RELAY_API_BIND are measured ABSENT from the container
# environment. They resolve ONLY via compose interpolation. Escaping them would
# expand to empty, point wget at http://:PORT, and turn a passing probe into a
# fleet-wide unhealthy. The asymmetry is deliberate — assert it so a later
# "make it consistent" edit is caught here rather than in production.
for v in SFU_METRICS_BIND SFU_RELAY_API_BIND; do
    if [[ "$HC" == *"\$\${$v}"* || "$HC" == *"\$\$$v"* ]]; then
        bad "S4 $v IS \$\$-escaped — it is absent from the container env, so this expands to empty and the probe targets http://:PORT (fleet-wide unhealthy)"
    else
        ok "S4 $v left unescaped — resolved by compose, which is the only thing that can resolve it"
    fi
done

# ------------------------------------------- S5 simulate compose, the real gate
# The assertions above are on spelling. This one reproduces the FAILURE: apply
# compose's interpolation rules and assert the guard is not left comparing the
# empty string.
#
# The environment modelled is the one MEASURED on a live edge, not an empty one:
# compose resolves the two BIND vars (they are in the .env beside the compose
# file — which is why the metrics probe works at all) and does NOT resolve the
# secrets or the ports (those live only in the service's `environment:` block).
# An all-empty environment would be a different, easier question.
#
#   $$X   -> $X   (escape consumed; the CONTAINER expands it later)
#   $X    -> compose env value, or "" when unset
#   ${X}  -> same, honouring ${X:-default}
#
# Single pass, left to right. Doing it as sequential regex passes is wrong: the
# `$X` produced by unescaping `$$X` is then eaten by the later `$X -> ""` pass.
simulated=$(COMPOSE_HC="$HC" python3 -c '
import os, re, sys

hc = os.environ["COMPOSE_HC"]
# Measured: compose CAN resolve these; it CANNOT resolve the secrets or ports.
compose_env = {"SFU_METRICS_BIND": "10.9.0.6", "SFU_RELAY_API_BIND": "10.9.0.6"}

TOKEN = re.compile(r"\$\$\{[^}]*\}|\$\$[A-Za-z_]\w*|\$\{([A-Za-z_]\w*)(?::-([^}]*))?\}|\$([A-Za-z_]\w*)")

def sub(m):
    if m.group(0).startswith("$$"):
        return m.group(0)[1:]          # escape consumed, container expands later
    name = m.group(1) or m.group(3)
    default = m.group(2)
    return compose_env.get(name, default if default is not None else "")

sys.stdout.write(TOKEN.sub(sub, hc))
')

if [[ "$simulated" == *'[ -z \"\" ]'* || "$simulated" == *'[ -z "" ]'* ]]; then
    bad "S5 after compose interpolation the guard reads [ -z \"\" ] — TRUE, so || short-circuits and no nc -z probe runs. This is the live defect."
else
    ok "S5 after compose interpolation the secret guards still reference a variable, so the nc -z probes remain reachable"
fi

# The metrics probe must still have a host after interpolation — the flip side
# of S4. An empty bind here means wget targets http://:PORT and the whole
# healthcheck fails closed.
if [[ "$simulated" == *"http://:"* ]]; then
    bad "S5b after compose interpolation the metrics URL has an empty host (http://:PORT) — probe fails closed, container marked unhealthy"
else
    ok "S5b metrics URL keeps a host after compose interpolation"
fi

echo "FAILED=$fails"
[[ "$fails" -eq 0 ]]
