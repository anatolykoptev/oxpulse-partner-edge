# Multi-Channel Deployment Runbook

> **Status:** stable (v0.12.46+) — replaces ad-hoc deployment guidance pre-Phase 5.8.
> Sister docs: [`../THREAT-MODEL.md`](../THREAT-MODEL.md),
> [`channels-health.md`](channels-health.md),
> [`m4a5-deploy.md`](m4a5-deploy.md).

## What "production-ready" means

After `install.sh` completes on a fresh edge:

- All channels listed in `channels-status.env` with state `active` have a running container.
- Channels not provisioned (no credentials in node-config OR env) show `skipped`.
- Caddy `/metrics` endpoint exposes `caddy_reverse_proxy_upstreams_healthy{upstream=...}`.
- Telegram channel receives alerts within 90s of upstream transition.
- `systemctl is-active oxpulse-partner-edge.service` returns `active`.

## Provisioning workflow

### Fresh partner edge install

```bash
# 1. Operator copies install.sh to partner VPS (root user)
curl -fsSL https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download/<TAG>/partner-edge-installer.sh \
    -o /root/install.sh
chmod +x /root/install.sh

# 2. Run installer with registration token
sudo /root/install.sh \
    --partner-id=PARTNER_SHORT_ID \
    --domain=partner.example.com \
    --token=ptkn_xxxxxxxx

# 3. Wait for "Step 10/10 done" message
# 4. Verify with healthcheck
/usr/local/sbin/oxpulse-partner-edge-healthcheck
```

### Provisioning naive (UC5) channel

Naive (UC5) requires backend-issued credentials. Pass via env:

```bash
NAIVE_SERVER=naive.upstream.example.com \
NAIVE_SOCKS_PORT=1080 \
NAIVE_USERNAME=USER \
NAIVE_PASSWORD=PASS \
    sudo /root/install.sh --partner-id=... --domain=... --token=...
```

Naive container deploys; Caddy upstream pool includes `127.0.0.1:NAIVE_SOCKS_PORT` as tertiary fallback.

### Re-installation on existing edge (preserve identity)

```bash
# 1. Uninstall (keeps reality + awg keys in backup)
sudo /root/uninstall.sh --yes --keep-backups
# Backup landed in /root/oxpulse-backup-<epoch>/

# 2. Restore identity files BEFORE re-install
BACKUP=$(ls -td /root/oxpulse-backup-* | head -1)
mkdir -p /etc/oxpulse-partner-edge && chmod 700 /etc/oxpulse-partner-edge
for k in reality.priv reality.pub reality.uuid awg-private.key awg-public.key token node-config.json; do
    cp -p $BACKUP/$k /etc/oxpulse-partner-edge/
done

# 3. Re-run installer with --manual-config (reuses node-config from backup)
sudo /root/install.sh \
    --partner-id=$PARTNER_ID --domain=$PARTNER_DOMAIN --tunnel=$TUNNEL \
    --manual-config=/etc/oxpulse-partner-edge/node-config.json
```

## Verifying multi-channel deployment

```bash
# Per-channel state
ssh edge "cat /var/lib/oxpulse-partner-edge/channels-status.env"

# Expected output (full multi-channel — xray + awg + naive provisioned):
# xray=active
# hysteria2=active   (or skipped if no creds)
# naive=active        (or skipped if no NAIVE_SERVER env)
# awg=active

# Caddy live metrics
ssh edge "docker exec oxpulse-partner-caddy curl -s --resolve localhost:2019:127.0.0.1 \
    http://localhost:2019/metrics | grep caddy_reverse_proxy_upstreams_healthy"

# Expected: one line per upstream in pool:
# caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} 1
# caddy_reverse_proxy_upstreams_healthy{upstream="host.docker.internal:18443"} 0|1
# caddy_reverse_proxy_upstreams_healthy{upstream="127.0.0.1:1080"} 0|1

# HTTP endpoints
curl -sk https://partner.example.com/api/health   # -> 200
curl -sk https://partner.example.com/             # -> 200 (SPA)
```

## Alert taxonomy

Telegram alerts delivered via `lib/telegram-alert-lib.sh` (rate-limited, flock-guarded).
Webhook → API fallback chain. State dir: `/var/lib/oxpulse-partner-edge/telegram/`.

| Alert | Severity | Source | Operator action |
|---|---|---|---|
| `TRANSITION upstream=X healthy -> unhealthy` | warn | `oxpulse-channels-health-report.sh` every 60s | Check container logs; verify backend reachable |
| `TRANSITION upstream=X unhealthy -> healthy` | info | same | Recovery confirmed, no action |
| `CRITICAL: all upstreams unhealthy on <edge>` | critical | future Phase 5.8.x watchdog | On-call: SSH edge, check `docker ps`, network, backend |

See also: [`channels-health.md`](channels-health.md) for full metric exposition spec.

### Rate limiting

- Default `OXPULSE_TG_MIN_INTERVAL=600` (10 min). Override via env.
- `force` second arg to `tg_alert()` bypasses rate-limit (used for CRITICAL).
- Flock ensures concurrent invocations are serialized; one writer wins.

### Circuit breaker (future Phase 5.8.x)

Not yet implemented. Tracking in plan: separate watchdog timer caps repeated alerts on
cascading failure. Reference impl: `piter-server/deploy/piter/vpn-watchdog.sh`.
State file (when implemented): `/var/lib/oxpulse-partner-edge/circuit-breaker.state`.

## Channel deployment matrix

| Channel | Compose service | Required for install OK? | Provisioning |
|---|---|---|---|
| xray (CH1) | `oxpulse-partner-xray` | Always rendered + required | vless-reality params from node-config |
| AWG mesh (CH2) | host kmod/userspace | Always required for control plane | AWG keys from `opec secrets awg-keygen` |
| hysteria2 (CH3) | `oxpulse-partner-hy2` | Optional — skipped if no `HYSTERIA2_*` env | Env: `HYSTERIA2_SERVER`, `HYSTERIA2_PORT`, `HYSTERIA2_AUTH`, `HYSTERIA2_OBFS` |
| naive (UC5) | `oxpulse-partner-naive` | Optional — skipped if no `NAIVE_SERVER` env | Env: `NAIVE_SERVER`, `NAIVE_SOCKS_PORT`, `NAIVE_USERNAME`, `NAIVE_PASSWORD` |

## Recovery procedures

### `channels-status.env` reports `xray=failed_at_render`

```bash
# 1. Check rendered xray-client.json validity
docker logs oxpulse-partner-xray --tail 20

# 2. Common cause: backend reality 0rtt session cache mismatch (drift between
#    backend XRAY_REALITY_DECRYPTION env and edge's stored encryption blob).
#    Refresh node-config from backend:
systemctl start oxpulse-partner-edge-refresh.service
journalctl -u oxpulse-partner-edge-refresh.service -n 20

# 3. If all channels down — restore identity from backup and re-install (see above)
```

### `naive=active` but container restart-loops

```bash
docker logs oxpulse-partner-naive --tail 30
# Common: bad NAIVE_SERVER URL or wrong NAIVE_PASSWORD.
# Re-run install with corrected env vars.
```

### Caddy `/metrics` 404

```bash
# Verify Caddyfile rendered with metrics directive
ssh edge "grep -A2 'servers {' /etc/oxpulse-partner-edge/Caddyfile | head -5"
# Should show: servers { ... metrics ... }
# If not — re-render: refresh.timer fires daily, or manually:
systemctl start oxpulse-partner-edge-refresh.service
```

## Operator override flags

| Env var | Default | Purpose |
|---|---|---|
| `OXPULSE_TG_WEBHOOK` | `http://10.9.0.2:8765/webhook/monitor/healthcheck` | Dozor webhook (mesh-routed) |
| `OXPULSE_TG_MIN_INTERVAL` | 600 | Rate-limit window (seconds) |
| `OXPULSE_TG_CHAT` | (none) | Telegram chat ID for direct API fallback |
| `TG_TOKEN` | (none) | Bot token for direct API fallback |
| `NAIVE_SOCKS_PORT` | 1080 | Naive SOCKS5 listener port |
| `OXPULSE_NO_INTEGRITY` | unset | Skip tier-4 SHA256 checksum (NOT recommended) |
| `OXPULSE_CLEAN_SBIN` | unset | Auto-remove zombie scripts in PREFIX_SBIN |

## Known limitations (v0.12.46)

- **Backend reality 0rtt session cache** — separate concern (oxpulse-chat repo). When
  backend restarts, ML-KEM 0rtt blob in edge's stored encryption may expire/mismatch.
  Symptom: xray container healthy but caddy `/api/health` falls back to hy2 fallback.
  Mitigation: `systemctl start oxpulse-partner-edge-refresh.service` to refetch a fresh blob.
- **Circuit breaker** — not implemented. If all channels go down simultaneously, alerts fire
  indefinitely (rate-limited but no auto-park). Phase 5.8.x roadmap.
- **UC2 AmneziaWG-direct user channel** — not exposed. AWG today = control plane only.
  Native mobile app requires an architectural decision (see `ARCHITECTURE.md` §Channel Layers).
