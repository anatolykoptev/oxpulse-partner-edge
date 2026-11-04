#!/usr/bin/env bash
# tests/test_coturn_conf_rollback.sh — coturn.conf is rolled back with the image.
#
# reconcile_all renders the NEW coturn.conf BEFORE the image pull / compose up. A
# --with-templates upgrade whose pull, recreate or settle gate then fails rolls the
# image back to the previous coturn; if the conf is not rolled back too, the old
# binary reads the new conf (4.6.x without no-dtls / no-cli / no-tlsv1* = DTLS,
# CLI, TLS 1.0/1.1 silently on). Same for `upgrade.sh --rollback`.
#
#   R1  recreate-failure scenario: snapshot -> reconcile overwrites -> rollback
#       restores coturn.conf byte-identical (and mode). Real functions, extracted.
#   R2  no conf at snapshot time -> a stale .prev is dropped, not resurrected.
#   R3  ordering: the snapshot is taken before reconcile_all in the
#       --with-templates block, and every failure branch rolls back via
#       do_rollback_templates (which owns the conf restore).
#   R4  `upgrade.sh --rollback` end to end in a sandbox restores coturn.conf.
set -euo pipefail
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
UPGRADE="$REPO_ROOT/upgrade.sh"
[[ -f "$UPGRADE" ]] || { echo "FAIL: $UPGRADE not found"; exit 1; }
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
TC=$(mktemp -d); trap 'rm -rf "$TC"' EXIT
_extract_fn() { awk -v fn="$1" '$0 ~ "^"fn"\\(\\) \\{"{f=1} f{print} /^\}$/ && f{exit}' "$UPGRADE"; }
echo "=== coturn.conf rollback ==="

# ---- R1: with-templates, recreate fails -> conf byte-identical to pre-upgrade ----
ETC="$TC/r1/etc"; LIB="$TC/r1/lib"; mkdir -p "$ETC" "$LIB"
printf 'listening-port=3478\nno-dtls\nno-cli\nstatic-auth-secret=old\n' > "$ETC/coturn.conf"
chmod 0600 "$ETC/coturn.conf"
cp -a "$ETC/coturn.conf" "$TC/r1/pre-upgrade.conf"
printf 'old compose\n' > "$ETC/docker-compose.yml"; printf 'IMAGE_VERSION=old\n' > "$LIB/install.env"
# shellcheck disable=SC2016
bash -c '
set -euo pipefail
log(){ :; }; warn(){ echo "WARN: $*" >&2; }; die(){ echo "DIE: $*" >&2; exit 1; }
PREFIX_ETC="'"$ETC"'"; PREFIX_LIB="'"$LIB"'"
PREV_CADDYFILE="$PREFIX_LIB/Caddyfile.prev"; PREV_HEALTHCHECK="$PREFIX_LIB/healthcheck.prev"
PREV_STATE_FILE="$PREFIX_LIB/install.env.prev"; PREV_COMPOSE_FILE="$PREFIX_LIB/docker-compose.yml.prev"
PREV_COTURN_CONF="$PREFIX_LIB/coturn.conf.prev"
STATE_FILE="$PREFIX_LIB/install.env"; COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"; HEALTHCHECK=/bin/true
DOCKER_BIN=true
list_partner_edge_services(){ :; }; ghcr_login_from_file(){ :; }
'"$(_extract_fn snapshot_coturn_conf)"'
'"$(_extract_fn restore_coturn_conf)"'
'"$(_extract_fn do_rollback_templates)"'
# Step 1 of the with-templates path: back up everything before any mutation.
cp -a "$COMPOSE_FILE" "$PREV_COMPOSE_FILE"; cp -a "$STATE_FILE" "$PREV_STATE_FILE"
snapshot_coturn_conf
# reconcile_all renders the NEW conf (4.18 shape: legacy lines gone, new deny added) ...
printf "listening-port=3478\ndenied-peer-ip=64:ff9b::-64:ff9b::ffff:ffff\nstatic-auth-secret=new\n" > "$PREFIX_ETC/coturn.conf.tmp"
mv "$PREFIX_ETC/coturn.conf.tmp" "$PREFIX_ETC/coturn.conf"; chmod 0644 "$PREFIX_ETC/coturn.conf"
# ... then compose up fails -> the failure branch calls do_rollback_templates.
do_rollback_templates
' >"$TC/r1/out" 2>&1 || { echo "  (harness output: $(cat "$TC/r1/out"))"; }
if cmp -s "$ETC/coturn.conf" "$TC/r1/pre-upgrade.conf"; then
    pass "R1: recreate-failure rollback restores coturn.conf byte-identical"
else
    fail "R1: recreate-failure rollback left a different coturn.conf: $(tr '\n' '|' < "$ETC/coturn.conf")"
fi
if [[ "$(stat -c %a "$ETC/coturn.conf")" == "600" ]]; then
    pass "R1b: restored coturn.conf keeps its pre-upgrade mode (0600)"
else
    fail "R1b: restored coturn.conf mode is $(stat -c %a "$ETC/coturn.conf"), expected 600"
fi

# ---- R2: no conf to snapshot -> stale .prev is removed ----
ETC2="$TC/r2/etc"; LIB2="$TC/r2/lib"; mkdir -p "$ETC2" "$LIB2"
printf 'STALE from an older upgrade\n' > "$LIB2/coturn.conf.prev"
# shellcheck disable=SC2016
bash -c '
set -euo pipefail
PREFIX_ETC="'"$ETC2"'"; PREV_COTURN_CONF="'"$LIB2"'/coturn.conf.prev"
'"$(_extract_fn snapshot_coturn_conf)"'
snapshot_coturn_conf
'
if [[ ! -e "$LIB2/coturn.conf.prev" ]]; then
    pass "R2: no coturn.conf at snapshot time drops a stale coturn.conf.prev"
else
    fail "R2: stale coturn.conf.prev survived a snapshot with no conf"
fi

# ---- R3: ordering in the --with-templates block ----
_wt_start=$(awk '/^if \[\[ "\$MODE" == with_templates \]\]/ {print NR; exit}' "$UPGRADE")
_snap_line=$(awk "NR>$_wt_start && /^[[:space:]]*snapshot_coturn_conf[[:space:]]*\$/ {print NR; exit}" "$UPGRADE")
_rec_line=$(awk "NR>$_wt_start && /^[[:space:]]*reconcile_all / && !/^[[:space:]]*#/ {print NR; exit}" "$UPGRADE")
if [[ -n "$_snap_line" && -n "$_rec_line" && "$_snap_line" -lt "$_rec_line" ]]; then
    pass "R3: snapshot_coturn_conf (line $_snap_line) runs before reconcile_all (line $_rec_line)"
else
    fail "R3: snapshot_coturn_conf (${_snap_line:-missing}) is not before reconcile_all (${_rec_line:-missing})"
fi
_rb_calls=$(awk "NR>$_wt_start && /^[[:space:]]*do_rollback_templates[[:space:]]*\$/" "$UPGRADE" | wc -l)
if [[ "$_rb_calls" -ge 4 ]]; then
    pass "R3b: all $_rb_calls with-templates failure branches (pull / resolve / compose up / settle) roll back via do_rollback_templates"
else
    fail "R3b: expected >=4 do_rollback_templates calls in the with-templates block, found $_rb_calls"
fi

# ---- R4: `upgrade.sh --rollback`, end to end in a sandbox ----
D="$TC/r4"; mkdir -p "$D"/{etc,var,sbin,bin,libdir,systemd,share}
printf '# stub\nre_render_xray() { return 0; }\n' > "$D/sbin/channel-render-lib.sh"
printf '# stub\nghcr_configure_token() { return 0; }\nghcr_login_from_file() { return 0; }\nghcr_pull_diagnose() { return 0; }\n' > "$D/sbin/ghcr-auth-lib.sh"
printf '#!/bin/bash\nexit 0\n' > "$D/sbin/healthcheck"; chmod 0755 "$D/sbin/healthcheck"
_compose() { printf 'services:\n  sfu:\n    image: ghcr.io/anatolykoptev/partner-edge-sfu:%s\n    environment:\n      SIGNALING_SFU_SECRET: "x"\n' "$1"; }
printf 'IMAGE_VERSION=v1\nSIGNALING_SFU_SECRET=x\n' > "$D/var/install.env"
printf 'IMAGE_VERSION=v0\nSIGNALING_SFU_SECRET=x\n' > "$D/var/install.env.prev"
_compose v1 > "$D/etc/docker-compose.yml"; _compose v0 > "$D/var/docker-compose.yml.prev"
printf 'OLD-CONF\n' > "$D/var/coturn.conf.prev"; printf 'NEW-CONF\n' > "$D/etc/coturn.conf"
cat > "$D/docker" <<'F'
#!/bin/bash
[[ "$*" == *"config --services"* ]] && { echo sfu; exit 0; }
[[ "$*" == *"compose config"* ]] && { cat "$COMPOSE_FILE_PATH"; exit 0; }
exit 0
F
chmod +x "$D/docker"
R4_OUT=$(OXPULSE_PREFIX_ETC="$D/etc" OXPULSE_PREFIX_LIB="$D/var" OXPULSE_PREFIX_SBIN="$D/sbin" \
    OXPULSE_PREFIX_BIN="$D/bin" OXPULSE_PREFIX_LIBDIR="$D/libdir" OXPULSE_PREFIX_SHARE="$D/share" \
    OXPULSE_SYSTEMD_DIR="$D/systemd" OXPULSE_HEALTHCHECK="$D/sbin/healthcheck" OXPULSE_SKIP_ROOT_CHECK=1 \
    DOCKER_BIN="$D/docker" COMPOSE_FILE_PATH="$D/etc/docker-compose.yml" SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW=file:///dev/null bash "$UPGRADE" --rollback 2>&1) && R4_RC=0 || R4_RC=$?
if [[ "$R4_RC" -eq 0 && "$(cat "$D/etc/coturn.conf")" == "OLD-CONF" ]]; then
    pass "R4: upgrade.sh --rollback restores coturn.conf from coturn.conf.prev"
else
    fail "R4: --rollback rc=$R4_RC, coturn.conf='$(cat "$D/etc/coturn.conf")' (expected OLD-CONF); output tail: $(printf '%s' "$R4_OUT" | tail -4)"
fi
# A rollback with ONLY a conf snapshot must still be recognised as something to roll back.
rm -f "$D/var/install.env.prev" "$D/var/docker-compose.yml.prev"
printf 'NEW-CONF\n' > "$D/etc/coturn.conf"
R4B_OUT=$(OXPULSE_PREFIX_ETC="$D/etc" OXPULSE_PREFIX_LIB="$D/var" OXPULSE_PREFIX_SBIN="$D/sbin" \
    OXPULSE_PREFIX_BIN="$D/bin" OXPULSE_PREFIX_LIBDIR="$D/libdir" OXPULSE_PREFIX_SHARE="$D/share" \
    OXPULSE_SYSTEMD_DIR="$D/systemd" OXPULSE_HEALTHCHECK="$D/sbin/healthcheck" OXPULSE_SKIP_ROOT_CHECK=1 \
    DOCKER_BIN="$D/docker" COMPOSE_FILE_PATH="$D/etc/docker-compose.yml" SYSTEMCTL_BIN=true \
    OXPULSE_REPO_RAW=file:///dev/null bash "$UPGRADE" --rollback 2>&1) && R4B_RC=0 || R4B_RC=$?
if [[ "$R4B_OUT" != *"nothing to roll back to"* && "$(cat "$D/etc/coturn.conf")" == "OLD-CONF" ]]; then
    pass "R4b: a coturn.conf.prev alone counts as a template snapshot to roll back"
else
    fail "R4b: conf-only snapshot ignored by --rollback (rc=$R4B_RC): $(printf '%s' "$R4B_OUT" | tail -3)"
fi

echo ""
echo "=== coturn.conf rollback: $PASS passed, $FAIL failed ==="
[[ $FAIL -eq 0 ]]
