#!/usr/bin/env bash
# tests/test_hy2_secret_mode.sh — F3: hysteria2-client.yaml writer agreement.
#
# Context: /etc/oxpulse-partner-edge/hysteria2-client.yaml was mode 640 on one
# edge and 600 on others, with shape differences (quoted vs unquoted values),
# because two different renderers produced it. This test enforces the invariant
# the fix establishes: every writer agrees on the stricter mode (0600) and one
# renderer (re_render_hysteria2), so a re-render never loosens permissions on a
# file holding channel credentials.
#
# Falsification: reverting any writer's chmod 0600 -> 0640, or reverting
# hydrate.sh's re_render_hysteria2 -> render_template, turns this test RED.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
INSTALL="$REPO_ROOT/install.sh"
ENABLE_HY2="$REPO_ROOT/oxpulse-partner-edge-enable-hy2"
HYDRATE="$REPO_ROOT/hydrate.sh"

FAIL=0
pass() { echo "OK: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }

for f in "$INSTALL" "$ENABLE_HY2" "$HYDRATE"; do
    [[ -f "$f" ]] || { echo "FAIL: $f not found"; exit 1; }
done

# ── 1. install.sh sets chmod 0600 (not 0640) on hysteria2-client.yaml ──────
echo "==> 1: install.sh uses chmod 0600 for hysteria2-client.yaml"
if grep -qE 'chmod 0600.*hysteria2-client\.yaml' "$INSTALL"; then
    pass "install.sh chmod 0600 for hysteria2-client.yaml"
else
    fail "install.sh does not chmod 0600 hysteria2-client.yaml"
fi

# ── 2. enable-hy2 sets chmod 0600 (not 0640) on the hy2 yaml ───────────────
echo "==> 2: enable-hy2 uses chmod 0600 for the hy2 yaml"
if grep -qE 'chmod 0600.*\$_hy2_yaml' "$ENABLE_HY2"; then
    pass "enable-hy2 chmod 0600 for hy2 yaml"
else
    fail "enable-hy2 does not chmod 0600 the hy2 yaml"
fi

# ── 3. NO writer loosens to 0640 on hysteria2-client.yaml ──────────────────
# The invariant: a re-render never loosens permissions. 0640 anywhere is a
# regression — it widens read access beyond root on a secret-bearing file.
echo "==> 3: no writer uses chmod 0640 on hysteria2-client.yaml"
violators=""
for f in "$INSTALL" "$ENABLE_HY2" "$HYDRATE"; do
    if grep -qE 'chmod 0640.*hysteria2-client\.yaml|chmod 0640.*\$_hy2_yaml' "$f"; then
        violators="$violators $(basename "$f")"
    fi
done
if [[ -z "$violators" ]]; then
    pass "no 0640 chmod on hysteria2-client.yaml in any writer"
else
    fail "0640 chmod still present in:$violators"
fi

# ── 4. hydrate.sh converges on re_render_hysteria2 (not render_template) ────
# hydrate.sh used the generic render_template (python mustache, no mode, no
# sed-escaping of YAML metacharacters) while install.sh + enable-hy2 used the
# dedicated re_render_hysteria2 (sed, umask 077 -> 0600). A hy2 password
# containing " or \ renders differently between the two. Converge on one.
echo "==> 4: hydrate.sh uses re_render_hysteria2 for hy2 (not render_template)"
# Extract the hy2 render block to scope the grep — render_template is used
# legitimately elsewhere in hydrate.sh for chassis templates.
hy2_block=$(awk '
    /if \[\[ -n "\$\{HYSTERIA2_SERVER:-\}" \]\]; then/ { found=1 }
    found { print }
    found && /^fi$/ { found=0; exit }
' "$HYDRATE")
# Strip comment lines before checking for CALLS — the block's comments
# legitimately reference both renderers to document why one was replaced;
# only actual invocations are divergence regressions.
hy2_code=$(echo "$hy2_block" | grep -v '^[[:space:]]*#')
# NOTE: `| grep ... >/dev/null` (not `| grep -q`) — under `set -o pipefail`,
# `grep -q` exits early on first match and can propagate SIGPIPE (141) from
# the producer as the pipeline's status, turning a passing assertion flaky.
# `grep >/dev/null` drains stdin fully. Enforced by test_pipefail_early_exit_guard.sh.
if echo "$hy2_code" | grep 're_render_hysteria2' >/dev/null; then
    pass "hydrate.sh hy2 block calls re_render_hysteria2"
else
    fail "hydrate.sh hy2 block does not call re_render_hysteria2"
fi
if echo "$hy2_code" | grep 'render_template' >/dev/null; then
    fail "hydrate.sh hy2 block still calls render_template (renderer divergence)"
else
    pass "hydrate.sh hy2 block does not call render_template"
fi

# ── Result ──────────────────────────────────────────────────────────────────
if [[ $FAIL -ne 0 ]]; then
    echo "FAIL: hy2 secret-mode writer-agreement test -- one or more checks failed"
    exit 1
fi
echo "PASS: hy2 secret-mode writer-agreement -- all writers agree on 0600 + one renderer"
