# OxPulse Partner Edge Bundle

One-command installer for a production-grade **co-brand mirror node** that
participates in the OxPulse network. Tested on Debian 12, Ubuntu
22.04 / 24.04, AlmaLinux 9, Rocky Linux 9.

The bundle runs four containers on the partner's VPS:

- **Caddy** — TLS termination (ACME via Let's Encrypt), SPA CDN, reverse
  proxy of `/api/*` + `/ws/*` through the tunnel.
- **xray-client** — VLESS + Reality + XHTTP tunnel to the main backend.
  Exposes only `:3080` inside the docker network.
- **coturn** — TURN/STUN relay with HMAC auth (`:3478/udp+tcp`,
  `:5349/tcp` for TURNS). Runs in host network mode.
- **sfu** — str0m-based Selective Forwarding Unit for encrypted group calls.
  Terminates WebRTC on `:3478/udp` and exposes Prometheus metrics on
  `:9317/tcp`.

## Prerequisites

- Debian 12+, Ubuntu 22.04+, AlmaLinux 9+, or Rocky 9+ (`systemd` + `bash`)
- 1 vCPU, 1 GB RAM, 20 GB disk minimum
- Public IPv4 reachable from the internet
- A DNS A record for your partner domain pointing at the VPS's public IP
- Ports open: **80, 443/tcp+udp, 3478/tcp+udp, 3479/udp, 5349/tcp,
  8912/tcp (relay API), 9317/tcp (SFU metrics), 49152–65535/udp**

## Firewall

`install.sh` does **not** manage your host firewall.

```bash
# ufw example
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 3478/tcp
ufw allow 3478/udp       # TURN/STUN + WebRTC media
ufw allow 5349/tcp       # TURNS
ufw allow 8912/tcp       # Relay API
ufw allow 9317/tcp       # SFU Prometheus metrics
ufw allow 49152:65535/udp  # TURN relay ports
```

## Quickstart

```bash
curl -fsSL https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-edge-installer.sh \
  -o install.sh
sudo bash install.sh \
  --domain=call.your-domain.example \
  --partner-id=your-partner-id \
  --token=ptkn_<registration-token>
```

### CLI flags

| Flag | Default | Notes |
|------|---------|-------|
| `--domain=<fqdn>` | required | Partner edge domain. Must resolve to this host. |
| `--partner-id=<id>` | required | Short identifier; must match backend config. |
| `--token=<ptkn_...>` | — | Registration token (calls `/api/partner/register`). |
| `--manual-config=<path>` | — | Alternative: read node config from a local JSON file. |
| `--image-version=<tag>` | `latest` | Pin images to a specific published tag. |
| `--dry-run` | off | Render templates + print plan, skip docker/systemd. |

## What the installer creates

| Path | Purpose |
|------|---------|
| `/etc/oxpulse-partner-edge/docker-compose.yml` | Rendered compose file |
| `/etc/oxpulse-partner-edge/Caddyfile` | Rendered Caddy config |
| `/etc/oxpulse-partner-edge/xray-client.json` | Rendered tunnel config |
| `/etc/oxpulse-partner-edge/coturn.conf` | TURN server config |
| `/var/lib/oxpulse-partner-edge/install.env` | Partner/version state |
| `/usr/local/sbin/oxpulse-partner-edge-healthcheck` | Verification tool |
| `/usr/local/sbin/oxpulse-partner-edge-upgrade` | Upgrade / rollback tool |
| `/etc/systemd/system/oxpulse-partner-edge.service` | Systemd unit |

## Verification

```bash
sudo oxpulse-partner-edge-healthcheck          # full external check
sudo oxpulse-partner-edge-healthcheck --local  # docker-network only (pre-DNS)
```

## SFU environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `SFU_UDP_PORT` | `3478` | WebRTC media multiplexed UDP port |
| `SFU_METRICS_PORT` | `9317` | HTTP `/metrics` Prometheus endpoint |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface for all sockets |
| `SFU_RELAY_API_PORT` | `8912` | HTTP relay API for cascade SFU connections |
| `RELAY_JWT_SECRET` | change-me | HMAC-SHA256 secret; must match `RELAY_JWT_SECRET` in oxpulse-chat. **Change before deployment.** |
| `RUST_LOG` | `info` | `tracing_subscriber` directive |

## Prometheus scrape config

```yaml
scrape_configs:
  - job_name: oxpulse-sfu
    scrape_interval: 30s
    static_configs:
      - targets: ['<edge-public-ip>:9317']
        labels:
          partner: 'your-partner-id'
```

## Upgrade / rollback

```bash
# Pull :latest and recreate:
sudo oxpulse-partner-edge-upgrade

# Pin to a specific tag:
sudo oxpulse-partner-edge-upgrade v0.8.0

# Explicit rollback:
sudo oxpulse-partner-edge-upgrade --rollback
```

## Snapshot-based scaling

For scaling to multiple edge nodes via VM snapshots:

1. **Bake** the master VM: `sudo bash install.sh --bake`
2. Take a snapshot of the powered-off VM.
3. Launch clones with `user_data` cloud-init providing per-clone `OXPULSE_PARTNER_DOMAIN` and `OXPULSE_REGISTRATION_TOKEN`.
4. On first boot, `oxpulse-partner-edge-hydrate.service` calls `/api/partner/register` and renders config automatically.

Each clone requires a unique single-use registration token. Request tokens from OxPulse ops.

## Troubleshooting

**Port already in use** — Stop nginx/apache before `install.sh`.

**Caddy can't get a TLS cert** — Verify DNS A record resolves to this host's public IP. Do not proxy through Cloudflare (use DNS-only mode).

**TURN doesn't work** — UDP 3478 + 49152-65535 are filtered by your cloud firewall.

**xray-client reconnects** — Reality credentials don't match the backend. Re-register.

## Security

- TURN shared secret is per-partner. Rotating it requires node redeployment.
- Coturn runs in host-network mode to advertise real public relay candidates. The `denied-peer-ip` list in `coturn.conf` blocks SSRF into RFC1918 ranges.
- The Caddy container mounts the Caddyfile read-only.
- Relay API (`SFU_RELAY_API_PORT`) should be accessible only from the OxPulse backend — restrict in your cloud security group.

## Uninstall

```bash
sudo systemctl disable --now oxpulse-partner-edge
sudo docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml down -v
sudo rm -rf /etc/oxpulse-partner-edge /var/lib/oxpulse-partner-edge \
            /etc/systemd/system/oxpulse-partner-edge.service \
            /usr/local/sbin/oxpulse-partner-edge-*
sudo systemctl daemon-reload
```

## Support

- GitHub issues: https://github.com/anatolykoptev/oxpulse-partner-edge/issues
- CHANGELOG: [CHANGELOG.md](CHANGELOG.md)
