#!/usr/bin/env bash
# migrate-turns-subdomain.sh — one-shot recovery for edges whose Caddyfile +
# coturn.conf were rendered with the legacy `TURNS_SUBDOMAIN=turns` default
# instead of the server-generated `api-<6-hex>` value.
#
# ROOT CAUSE (2026-05-27 edge-c/edge-b incident):
#   install.sh pre-v0.12.48 wrote the POST *request* body to --out-json instead
#   of the response body (opec regression fixed in PR #215, commit 634874f).
#   As a result `json_get turns_subdomain "$tmp_cfg"` returned empty; the
#   TURNS_SUBDOMAIN env stayed at the arg-parser default "turns"; Caddyfile and
#   coturn.conf were rendered with `turns.<domain>` as the TLS SNI match.
#
#   Meanwhile, oxpulse-chat always generates `api-<6-hex>` as `turns_subdomain`
#   and stores it in partner_nodes. Clients receive `turns:api-<hex>.<domain>:443`
#   in TURN credentials, but the caddy-l4 SNI matcher only knows `turns.<domain>`:
#   the TLS ClientHello passes through to the HTTP app (no l4 match), Caddy
#   returns a TLS InternalError alert, and TURNS-443 stays permanently dead for
#   RU clients relying on the TCP-443 relay path.
#
# WHAT THIS SCRIPT DOES:
#   1. Reads DOMAIN from $STATE_FILE (install.env).
#   2. Fetches the canonical `turns_subdomain` from the oxpulse-chat API
#      (GET /api/partner/node-config or POST /api/partner/register re-hydrate).
#      Falls back to OXPULSE_TURNS_SUBDOMAIN env when API is unreachable.
#   3. Writes the correct value to $STATE_FILE (TURNS_SUBDOMAIN=api-<hex>).
#   4. Re-renders Caddyfile and coturn.conf.
#   5. Applies ACME cert via Caddy (issues cert for `api-<hex>.<domain>`).
#   6. Restarts coturn to reload the new cert path.
#   7. Prints a DNS verification reminder.
#
# USAGE:
#   sudo bash migrate-turns-subdomain.sh [--dry-run] [--subdomain=api-<hex>]
#
#   --dry-run         : print what would change, make no modifications.
#   --subdomain=VAL   : skip API lookup, use VAL directly (for manual fix).
#   --backend-api=URL : override backend URL (default: from install.env).
#   --service-token=T : raw service token for /api/partner/node-config auth.
#
# AFTER RUNNING:
#   1. Add DNS A-record: api-<hex>.<domain> → <PUBLIC_IP>
#   2. Wait for Caddy to issue ACME cert (~30–60s)
#   3. Run: oxpulse-partner-edge-healthcheck
#   4. Verify TURNS-443 in healthcheck output (check 9)
#
# MANUAL RECOVERY (if this script is unavailable):
#   a. Query the correct subdomain:
#      curl -s https://api.oxpulse.chat/api/partner/node-config \
#        -H "Authorization: Bearer $(cat /etc/oxpulse-partner-edge/token)" \
#        | jq -r .turns_subdomain
#   b. Edit /var/lib/oxpulse-partner-edge/install.env:
#      TURNS_SUBDOMAIN=api-<hex>
#   c. Re-render Caddyfile:
#      sudo upgrade.sh --with-templates --dry-run   # preview
#      sudo upgrade.sh --with-templates             # apply
#   d. Add DNS A-record for api-<hex>.<domain> → <PUBLIC_IP>
#   e. Wait for Caddy ACME + restart coturn:
#      docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml restart coturn
set -euo pipefail

PREFIX_ETC="${OXPULSE_PREFIX_ETC:-/etc/oxpulse-partner-edge}"
PREFIX_LIB="${OXPULSE_PREFIX_LIB:-/var/lib/oxpulse-partner-edge}"
STATE_FILE="$PREFIX_LIB/install.env"
NODE_CONFIG_FILE="$PREFIX_ETC/node-config.json"
CADDYFILE="$PREFIX_ETC/Caddyfile"
COTURN_CONF="$PREFIX_ETC/coturn.conf"
COMPOSE_FILE="$PREFIX_ETC/docker-compose.yml"

DRY_RUN=0
FORCE_SUBDOMAIN=""
BACKEND_API_OVERRIDE=""
SERVICE_TOKEN_OVERRIDE=""

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

for arg in "$@"; do
    case $arg in
        --dry-run)           DRY_RUN=1 ;;
        --subdomain=*)       FORCE_SUBDOMAIN="${arg#--subdomain=}" ;;
        --backend-api=*)     BACKEND_API_OVERRIDE="${arg#--backend-api=}" ;;
        --service-token=*)   SERVICE_TOKEN_OVERRIDE="${arg#--service-token=}" ;;
        -h|--help)
            sed -n '/^#/!q;s/^# \{0,2\}//p' "$0"
            exit 0 ;;
        *) die "unknown argument: $arg" ;;
    esac
done

[[ $DRY_RUN -eq 1 ]] && log "[DRY-RUN] no changes will be made"

# ── 1. Load install state ─────────────────────────────────────────────────────
[[ -f "$STATE_FILE" ]] || die "state file not found: $STATE_FILE — only run on a fully-installed edge"
set -a
# shellcheck disable=SC1090
. "$STATE_FILE"
set +a

PARTNER_DOMAIN="${PARTNER_DOMAIN:-}"
CURRENT_TURNS_SUBDOMAIN="${TURNS_SUBDOMAIN:-}"
BACKEND_API="${BACKEND_API_OVERRIDE:-${BACKEND_API:-https://api.oxpulse.chat}}"
BACKEND_API="${BACKEND_API%/}"

[[ -n "$PARTNER_DOMAIN" ]] || die "PARTNER_DOMAIN missing from $STATE_FILE"
log "partner_domain=$PARTNER_DOMAIN  current_turns_subdomain=${CURRENT_TURNS_SUBDOMAIN:-<unset>}"

# ── 2. Determine correct subdomain ───────────────────────────────────────────
if [[ -n "$FORCE_SUBDOMAIN" ]]; then
    CORRECT_SUBDOMAIN="$FORCE_SUBDOMAIN"
    log "using operator-supplied subdomain: $CORRECT_SUBDOMAIN"
elif [[ -n "${OXPULSE_TURNS_SUBDOMAIN:-}" ]]; then
    CORRECT_SUBDOMAIN="$OXPULSE_TURNS_SUBDOMAIN"
    log "using env OXPULSE_TURNS_SUBDOMAIN: $CORRECT_SUBDOMAIN"
else
    # Prefer node-config.json on disk (written at install / upgrade time).
    if [[ -f "$NODE_CONFIG_FILE" ]]; then
        _nc_subdomain=$(python3 -c \
            "import json,sys; d=json.load(open('$NODE_CONFIG_FILE')); print(d.get('turns_subdomain',''))" \
            2>/dev/null || true)
        if [[ -n "$_nc_subdomain" && "$_nc_subdomain" != "turns" ]]; then
            CORRECT_SUBDOMAIN="$_nc_subdomain"
            log "found turns_subdomain in node-config.json: $CORRECT_SUBDOMAIN"
        fi
    fi

    # Fall back to API call.
    if [[ -z "${CORRECT_SUBDOMAIN:-}" ]]; then
        SERVICE_TOKEN="${SERVICE_TOKEN_OVERRIDE:-}"
        if [[ -z "$SERVICE_TOKEN" ]]; then
            _token_file="$PREFIX_ETC/token"
            [[ -r "$_token_file" ]] && SERVICE_TOKEN=$(cat "$_token_file")
        fi

        if [[ -n "$SERVICE_TOKEN" ]]; then
            log "querying $BACKEND_API/api/partner/node-config ..."
            _nc_resp=$(curl -fsSL --max-time 15 \
                -H "Authorization: Bearer $SERVICE_TOKEN" \
                "$BACKEND_API/api/partner/node-config" 2>/dev/null || true)
            if [[ -n "$_nc_resp" ]]; then
                _api_subdomain=$(printf '%s' "$_nc_resp" \
                    | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('turns_subdomain',''))" \
                    2>/dev/null || true)
                if [[ -n "$_api_subdomain" && "$_api_subdomain" != "turns" ]]; then
                    CORRECT_SUBDOMAIN="$_api_subdomain"
                    log "turns_subdomain from API: $CORRECT_SUBDOMAIN"
                fi
            fi
        fi

        [[ -n "${CORRECT_SUBDOMAIN:-}" ]] || \
            die "could not determine correct turns_subdomain. \
Supply it explicitly: --subdomain=api-<hex>, or set OXPULSE_TURNS_SUBDOMAIN."
    fi
fi

# ── 3. Validate shape ─────────────────────────────────────────────────────────
if [[ ! "$CORRECT_SUBDOMAIN" =~ ^api-[0-9a-f]{6,}$ ]]; then
    warn "turns_subdomain '$CORRECT_SUBDOMAIN' does not match expected api-<hex> pattern"
    warn "Proceed only if you are certain this is correct."
fi

if [[ "$CORRECT_SUBDOMAIN" == "${CURRENT_TURNS_SUBDOMAIN:-}" ]]; then
    log "TURNS_SUBDOMAIN already correct ($CORRECT_SUBDOMAIN) — nothing to do"
    exit 0
fi

log "migration: '$CURRENT_TURNS_SUBDOMAIN' → '$CORRECT_SUBDOMAIN'"

# ── 4. Update install.env ─────────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 ]]; then
    # Atomic update via sed — preserve all other lines.
    if grep -q '^TURNS_SUBDOMAIN=' "$STATE_FILE"; then
        _tmp=$(mktemp)
        sed "s|^TURNS_SUBDOMAIN=.*|TURNS_SUBDOMAIN=$CORRECT_SUBDOMAIN|" "$STATE_FILE" > "$_tmp"
        chmod 0600 "$_tmp"
        mv "$_tmp" "$STATE_FILE"
    else
        printf 'TURNS_SUBDOMAIN=%s\n' "$CORRECT_SUBDOMAIN" >> "$STATE_FILE"
        chmod 0600 "$STATE_FILE"
    fi
    log "updated $STATE_FILE: TURNS_SUBDOMAIN=$CORRECT_SUBDOMAIN"
else
    log "[dry-run] would update $STATE_FILE: TURNS_SUBDOMAIN=$CORRECT_SUBDOMAIN"
fi

# ── 5. Re-render Caddyfile ────────────────────────────────────────────────────
_esc() { printf '%s' "$1" | sed -e 's/[\\&|]/\\&/g'; }

if [[ -f "$CADDYFILE" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
        # Rewrite TURNS_SUBDOMAIN references in-place.
        # Caddyfile contains two patterns: SNI matcher and vhost block.
        # Both embed the old subdomain directly after rendering.
        _old_esc=$(_esc "$CURRENT_TURNS_SUBDOMAIN")
        _new_esc=$(_esc "$CORRECT_SUBDOMAIN")
        _tmp=$(mktemp)
        sed "s|${_old_esc}|${_new_esc}|g" "$CADDYFILE" > "$_tmp"
        mv "$_tmp" "$CADDYFILE"
        log "updated $CADDYFILE (replaced '$CURRENT_TURNS_SUBDOMAIN' → '$CORRECT_SUBDOMAIN')"
    else
        _count=$(grep -c "${CURRENT_TURNS_SUBDOMAIN:-NOOP}" "$CADDYFILE" 2>/dev/null || echo 0)
        log "[dry-run] would replace $CURRENT_TURNS_SUBDOMAIN in $CADDYFILE ($_count occurrences)"
    fi
else
    warn "Caddyfile not found at $CADDYFILE — skipping (SFU-only node?)"
fi

# ── 6. Re-render coturn.conf ─────────────────────────────────────────────────
if [[ -f "$COTURN_CONF" ]]; then
    if [[ $DRY_RUN -eq 0 ]]; then
        _old_esc=$(_esc "$CURRENT_TURNS_SUBDOMAIN")
        _new_esc=$(_esc "$CORRECT_SUBDOMAIN")
        _tmp=$(mktemp)
        sed "s|${_old_esc}|${_new_esc}|g" "$COTURN_CONF" > "$_tmp"
        mv "$_tmp" "$COTURN_CONF"
        log "updated $COTURN_CONF (replaced '$CURRENT_TURNS_SUBDOMAIN' → '$CORRECT_SUBDOMAIN')"
    else
        _count=$(grep -c "${CURRENT_TURNS_SUBDOMAIN:-NOOP}" "$COTURN_CONF" 2>/dev/null || echo 0)
        log "[dry-run] would replace $CURRENT_TURNS_SUBDOMAIN in $COTURN_CONF ($_count occurrences)"
    fi
else
    warn "coturn.conf not found at $COTURN_CONF — skipping"
fi

# ── 7. Reload Caddy + coturn ──────────────────────────────────────────────────
if [[ $DRY_RUN -eq 0 ]]; then
    log "reloading Caddy config ..."
    if docker compose -f "$COMPOSE_FILE" exec -T caddy caddy reload \
            --config /etc/caddy/Caddyfile 2>/dev/null; then
        log "Caddy reloaded (will begin ACME HTTP-01 for $CORRECT_SUBDOMAIN.$PARTNER_DOMAIN)"
    else
        warn "caddy reload failed — restarting caddy container instead"
        docker compose -f "$COMPOSE_FILE" restart caddy 2>/dev/null || \
            warn "caddy restart also failed; check: docker compose -f $COMPOSE_FILE logs caddy"
    fi

    log "restarting coturn to pick up new cert path ..."
    # coturn runs with network_mode:host; restart via compose.
    docker compose -f "$COMPOSE_FILE" restart coturn 2>/dev/null || \
        warn "coturn restart failed; check: docker compose -f $COMPOSE_FILE logs coturn"
else
    log "[dry-run] would reload caddy + restart coturn"
fi

# ── 8. Post-migration checklist ───────────────────────────────────────────────
printf '\n'
printf '\033[32m==>\033[0m Migration complete.\n'
printf '\n'
printf 'NEXT STEPS (required before TURNS-443 goes live):\n'
printf '  1. Add DNS A-record:\n'
printf '       %s.%s  →  %s\n' "$CORRECT_SUBDOMAIN" "$PARTNER_DOMAIN" "${PUBLIC_IP:-<PUBLIC_IP>}"
printf '     (Caddy ACME HTTP-01 will issue a cert once DNS propagates, ~30-90s)\n'
printf '\n'
printf '  2. Verify cert issued:\n'
printf '       docker compose -f %s logs caddy 2>&1 | grep -i "certificate\|acme\|obtained"\n' "$COMPOSE_FILE"
printf '\n'
printf '  3. Run healthcheck:\n'
printf '       /usr/local/sbin/oxpulse-partner-edge-healthcheck\n'
printf '     Look for: [OK] TURNS-443 TLS handshake\n'
printf '\n'
printf '  4. If healthcheck 9 (TURNS-443) still fails after DNS + ACME:\n'
printf '       openssl s_client -connect %s.%s:443 -servername %s.%s -alpn dot 2>&1 | head -5\n' \
    "$CORRECT_SUBDOMAIN" "$PARTNER_DOMAIN" "$CORRECT_SUBDOMAIN" "$PARTNER_DOMAIN"
printf '     Expected: CONNECTED + certificate subject matching the FQDN.\n'
