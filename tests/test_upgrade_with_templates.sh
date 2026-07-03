#!/bin/bash
# tests/test_upgrade_with_templates.sh
# Tests the --with-templates surface of upgrade.sh that is NOT the Caddyfile render
# itself (flag wiring, template rollback). The Caddyfile render authority is
# reconcile_caddy_surface (opec render caddy) — covered by tests/test_caddyfile_golden.sh,
# tests/test_render_completeness.sh, tests/test_reconcile_caddy_disk_drift.sh and
# tests/test_confd_survives_upgrade.sh. The old re_render_caddy shell renderer this file
# used to exercise was deleted in the Phase 5 strangler completion (0 production callers).
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"

[[ -f "$UPGRADE" ]] || { echo "FAIL: upgrade.sh not found at $UPGRADE"; exit 1; }

TMPDIR_ROOT=$(mktemp -d)
cleanup() { rm -rf "$TMPDIR_ROOT"; }
trap cleanup EXIT

# ---- sandbox dirs ----
T_ETC="$TMPDIR_ROOT/etc"
T_LIB="$TMPDIR_ROOT/lib"
mkdir -p "$T_ETC" "$T_LIB"

# Fake healthcheck that always succeeds.
FAKE_HC="$TMPDIR_ROOT/fake-healthcheck"
printf '#!/bin/bash\nexit 0\n' > "$FAKE_HC"
chmod 0755 "$FAKE_HC"

# ---- Test 1: syntax check ----
echo "==> Test 1: upgrade.sh syntax"
bash -n "$UPGRADE" || { echo "FAIL: upgrade.sh has syntax errors"; exit 1; }
echo "OK: syntax clean"

# ---- Test 2: --with-templates appears in usage block ----
echo "==> Test 2: --with-templates in usage/flag list"
grep -q '\-\-with-templates' "$UPGRADE" \
    || { echo "FAIL: --with-templates not in upgrade.sh"; exit 1; }
grep -q 'MODE=with_templates' "$UPGRADE" \
    || { echo "FAIL: MODE=with_templates not in upgrade.sh"; exit 1; }
echo "OK: --with-templates flag wired"

# ---- Test 3: rollback restores .prev files ----
echo "==> Test 3: do_rollback_templates restores .prev files"

OLD_CADDY="# old caddyfile backup"
OLD_STATE="PARTNER_ID=prev-state"
OLD_COMPOSE="# old compose backup"

echo "$OLD_CADDY"  > "$T_LIB/Caddyfile.prev"
echo "$OLD_STATE"  > "$T_LIB/install.env.prev"
echo "$OLD_COMPOSE" > "$T_LIB/docker-compose.yml.prev"
printf '#!/bin/bash\n# old healthcheck\n' > "$T_LIB/healthcheck.prev"

# Overwrite live files with "new" content.
echo "# new caddyfile" > "$T_ETC/Caddyfile"

bash -c '
    set -euo pipefail
    log()  { printf "==> %s\n" "$*" >&2; }
    warn() { printf "!! %s\n" "$*" >&2; }
    die()  { printf "ERR %s\n" "$*" >&2; exit 1; }

    PREV_CADDYFILE="'"$T_LIB"'/Caddyfile.prev"
    PREV_HEALTHCHECK="'"$T_LIB"'/healthcheck.prev"
    PREV_STATE_FILE="'"$T_LIB"'/install.env.prev"
    PREV_COMPOSE_FILE="'"$T_LIB"'/docker-compose.yml.prev"
    PREFIX_ETC="'"$T_ETC"'"
    STATE_FILE="'"$T_LIB"'/install.env"
    COMPOSE_FILE="'"$T_ETC"'/docker-compose.yml"
    HEALTHCHECK="'"$FAKE_HC"'"

    eval "$(awk "/^do_rollback_templates\(\)/,/^\}$/" "'"$UPGRADE"'")"
    do_rollback_templates
' 2>&1 || { echo "FAIL: do_rollback_templates returned non-zero"; exit 1; }

RESTORED=$(cat "$T_ETC/Caddyfile")
[[ "$RESTORED" == "$OLD_CADDY" ]] \
    || { echo "FAIL: Caddyfile not restored (got: $RESTORED)"; exit 1; }

echo "OK: do_rollback_templates restores .prev files"

# ---- Test 4: existing tests still pass ----
echo "==> Test 4: test_upgrade_die_on_empty_sfu_secret.sh"
REPO_ROOT="$REPO_ROOT" bash "$REPO_ROOT/tests/test_upgrade_die_on_empty_sfu_secret.sh" \
    || { echo "FAIL: existing sfu_secret test regressed"; exit 1; }
echo "OK: existing sfu_secret test still passes"

echo ""
echo "PASS: all test_upgrade_with_templates tests passed"
