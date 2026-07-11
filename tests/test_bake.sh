#!/bin/bash
# Structural checks: the installer parses --bake, gates node registration
# (secrets) behind BAKE_MODE, and pre-pulls images UNCONDITIONALLY so a bake
# host caches images into the snapshot.
#
# Installer modularization moved arg parsing to lib/install-args.sh and systemd
# unit wiring to lib/install-systemd.sh; the BAKE_MODE gate + image pre-pull
# remain in install.sh. Assert each against the file that now owns it.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-/home/user/src/oxpulse-partner-edge}"
INSTALL="$REPO_ROOT/install.sh"
ARGS_LIB="$REPO_ROOT/lib/install-args.sh"
SYSTEMD_LIB="$REPO_ROOT/lib/install-systemd.sh"

# 1. BAKE_MODE variable exists and defaults to 0 (arg-parsing lib).
grep -qE '^[[:space:]]*BAKE_MODE=0\b' "$ARGS_LIB" \
    || { echo "FAIL: BAKE_MODE=0 default not found in lib/install-args.sh"; exit 1; }

# 2. --bake flag is parsed (sets BAKE_MODE=1).
grep -qE -- '--bake\)' "$ARGS_LIB" \
    || { echo "FAIL: --bake case not parsed in lib/install-args.sh"; exit 1; }

# 3. The BAKE_MODE=0 gate exists in install.sh — the secrets/registration path
#    lives inside it and is skipped in bake mode.
gate_line=$(grep -nE '^if \[ "\$BAKE_MODE" = "0" \]' "$INSTALL" | head -1 | cut -d: -f1)
[ -n "$gate_line" ] \
    || { echo "FAIL: 'if [ \"\$BAKE_MODE\" = \"0\" ]' gate not found in install.sh"; exit 1; }

# 4. Image pre-pull (docker pull) is NOT gated behind BAKE_MODE=0 — it must run
#    BEFORE the gate so bake mode caches images into the snapshot.
pull_line=$(grep -nE '^[[:space:]]*docker pull ' "$INSTALL" | head -1 | cut -d: -f1)
[ -n "$pull_line" ] \
    || { echo "FAIL: no 'docker pull' found in install.sh"; exit 1; }
[ "$pull_line" -lt "$gate_line" ] \
    || { echo "FAIL: docker pull is inside/after the BAKE_MODE=0 gate — bake cannot cache images"; exit 1; }

# 5. Node registration (POST /api/partner/register) runs INSIDE the BAKE_MODE=0
#    gate so a bake host never registers (it has no secrets yet).
reg_line=$(grep -n '/api/partner/register' "$INSTALL" \
    | awk -F: -v g="$gate_line" '$1 > g {print $1; exit}')
[ -n "$reg_line" ] \
    || { echo "FAIL: node registration (/api/partner/register) not found inside the BAKE_MODE=0 gate"; exit 1; }

# 6. install.sh still parses cleanly.
bash -n "$INSTALL" || { echo "FAIL: bash -n failed on install.sh"; exit 1; }

# 7. Installer installs the hydrate unit file (systemd lib).
grep -q 'oxpulse-partner-edge-hydrate.service' "$SYSTEMD_LIB" \
    || { echo "FAIL: lib/install-systemd.sh does not install hydrate unit"; exit 1; }

# 8. Installer installs the hydrate script to /usr/local/sbin (PREFIX_SBIN or literal).
grep -qE '(PREFIX_SBIN|/usr/local/sbin)/oxpulse-partner-edge-hydrate' "$SYSTEMD_LIB" \
    || { echo "FAIL: lib/install-systemd.sh does not install hydrate script"; exit 1; }

# 9. Installer enables the hydrate unit in bake mode WITHOUT --now (must not start
#    on the bake host — secrets aren't present yet).
grep -qE 'systemctl enable oxpulse-partner-edge-hydrate\.service' "$SYSTEMD_LIB" \
    || { echo "FAIL: lib/install-systemd.sh does not enable hydrate.service in bake mode"; exit 1; }
if grep -E 'systemctl enable.*--now.*oxpulse-partner-edge-hydrate' "$SYSTEMD_LIB"; then
    echo "FAIL: hydrate.service is enabled with --now (must not start during bake)"
    exit 1
fi

# 10. systemd lib still parses cleanly.
bash -n "$SYSTEMD_LIB" || { echo "FAIL: bash -n failed on lib/install-systemd.sh"; exit 1; }

echo "PASS: installer --bake structure present"
