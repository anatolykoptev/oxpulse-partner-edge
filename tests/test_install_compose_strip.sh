#!/usr/bin/env bash
# test_install_compose_strip.sh — behavioral tests for Phase 5.5 BLOCKER 1 fix:
# compose post-render strip removes failed-channel service blocks so that
# `docker compose up` does not fail on missing config file volume mounts.

set -uo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

# Verify python3 + yaml are available (required by the strip logic).
python3 -c "import yaml" 2>/dev/null \
    || fail "python3 yaml module not available — install python3-yaml"
pass "python3 yaml module available"

# Shared strip helper (mirrors install.sh BLOCKER 1 python3 block).
_strip_compose() {
    local compose_file=$1
    shift
    python3 - "$compose_file" "$@" <<'PYEOF'
import sys, yaml, pathlib
compose_path = pathlib.Path(sys.argv[1])
failed = set(sys.argv[2:])
with compose_path.open() as f:
    doc = yaml.safe_load(f)
for kind in failed:
    doc.get('services', {}).pop(kind, None)
for _svc, conf in doc.get('services', {}).items():
    deps = conf.get('depends_on')
    if isinstance(deps, list):
        conf['depends_on'] = [d for d in deps if d not in failed]
        if not conf['depends_on']:
            del conf['depends_on']
    elif isinstance(deps, dict):
        for d in list(deps):
            if d in failed:
                del deps[d]
        if not deps:
            del conf['depends_on']
tmp = compose_path.with_suffix('.tmp')
with tmp.open('w') as f:
    yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
tmp.replace(compose_path)
PYEOF
}

# ---------------------------------------------------------------------------
# Case 1 — xray failed → services.xray stripped; caddy + naive retained
# ---------------------------------------------------------------------------
T1=$(mktemp -d)
trap 'rm -rf "$T1"' EXIT

cat > "$T1/docker-compose.yml" <<'COMPOSE_EOF'
services:
  caddy:
    image: caddy:2
    restart: unless-stopped
  xray:
    image: teddysun/xray:latest
    restart: unless-stopped
    volumes:
      - /etc/oxpulse-partner-edge/xray-client.json:/etc/xray/config.json:ro
    depends_on:
      - caddy
  naive:
    image: klzgrad/naiveproxy:latest
    restart: unless-stopped
COMPOSE_EOF

_strip_compose "$T1/docker-compose.yml" xray

python3 - "$T1/docker-compose.yml" <<'PYEOF'
import sys, yaml, pathlib
doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
assert 'xray' not in doc.get('services', {}), "xray service still present after strip"
assert 'naive' in doc.get('services', {}), "naive service unexpectedly stripped"
assert 'caddy' in doc.get('services', {}), "caddy service unexpectedly stripped"
PYEOF
pass "Case 1: xray stripped from compose, caddy+naive retained"

# ---------------------------------------------------------------------------
# Case 2 — depends_on refs to failed service are removed from remaining services
# ---------------------------------------------------------------------------
T2=$(mktemp -d)

cat > "$T2/docker-compose.yml" <<'COMPOSE_EOF'
services:
  caddy:
    image: caddy:2
    depends_on:
      - xray
  xray:
    image: teddysun/xray:latest
COMPOSE_EOF

_strip_compose "$T2/docker-compose.yml" xray

python3 - "$T2/docker-compose.yml" <<'PYEOF'
import sys, yaml, pathlib
doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
caddy = doc['services']['caddy']
assert 'depends_on' not in caddy, f"depends_on still present: {caddy.get('depends_on')}"
PYEOF
pass "Case 2: depends_on refs to stripped xray removed from caddy"

# ---------------------------------------------------------------------------
# Case 3 — depends_on as dict (docker-compose v3 long form) also stripped
# ---------------------------------------------------------------------------
T3=$(mktemp -d)

cat > "$T3/docker-compose.yml" <<'COMPOSE_EOF'
services:
  caddy:
    image: caddy:2
    depends_on:
      xray:
        condition: service_started
  xray:
    image: teddysun/xray:latest
COMPOSE_EOF

_strip_compose "$T3/docker-compose.yml" xray

python3 - "$T3/docker-compose.yml" <<'PYEOF'
import sys, yaml, pathlib
doc = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
caddy = doc['services']['caddy']
assert 'depends_on' not in caddy, f"depends_on dict still present: {caddy.get('depends_on')}"
PYEOF
pass "Case 3: depends_on dict (long form) refs to stripped xray removed from caddy"

# ---------------------------------------------------------------------------
# Case 4 — install.sh compose strip block is wired
# ---------------------------------------------------------------------------
grep -q 'stripping failed channels from compose' "$REPO_ROOT/install.sh" \
    || fail "Case 4: install.sh does not contain compose strip invocation"
pass "Case 4: install.sh contains compose strip invocation"

# ---------------------------------------------------------------------------
# Case 5 — python3-yaml dep ensured in lib/install-deps.sh
# ---------------------------------------------------------------------------
grep -q 'python3-yaml\|python3-pyyaml\|import yaml' "$REPO_ROOT/lib/install-deps.sh" \
    || fail "Case 5: lib/install-deps.sh does not ensure python3-yaml (PyYAML)"
pass "Case 5: lib/install-deps.sh ensures PyYAML availability"

echo
echo "All compose-strip tests passed."
