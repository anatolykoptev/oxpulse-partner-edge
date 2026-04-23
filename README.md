# oxpulse-partner-edge

[![CI](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/anatolykoptev/oxpulse-partner-edge?label=release)](https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest)
[![License: MIT OR Apache-2.0](https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg)](LICENSE)

Production-ready co-brand mirror node for the OxPulse network. One command installs TLS termination, a VLESS+Reality bypass tunnel, TURN/STUN relay, and an encrypted-group-call SFU on any VPS.

## What's inside

| Container | Purpose |
|-----------|---------|
| **caddy** | TLS (ACME/Let's Encrypt), SNI mux, reverse proxy for `/api/*` + `/ws/*` |
| **xray-client** | VLESS + Reality + XHTTP outbound tunnel (bypasses DPI/censorship) |
| **coturn** | TURN/STUN relay — UDP 3478, TURNS on 443 via Caddy SNI mux |
| **sfu** | WebRTC Selective Forwarding Unit for encrypted group calls |

## Requirements

- Debian 12 / Ubuntu 22.04+ / AlmaLinux 9 / Rocky 9 with `systemd`
- 1 vCPU, 1 GB RAM, 20 GB disk
- Public IPv4; DNS A record for your domain
- Open ports: `80, 443, 3478/tcp+udp, 5349/tcp, 8912/tcp, 9317/tcp, 49152–65535/udp`

## Install

```bash
curl -fsSL \
  https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-edge-installer.sh \
  | sudo bash -s -- \
      --domain=call.your-domain.example \
      --partner-id=your-partner-id \
      --token=ptkn_<registration-token>
```

<details>
<summary>All installer flags</summary>

| Flag | Required | Description |
|------|----------|-------------|
| `--domain=<fqdn>` | ✓ | Partner edge domain (must already resolve) |
| `--partner-id=<id>` | ✓ | Short identifier matching backend config |
| `--token=<ptkn_...>` | ✓* | Single-use registration token |
| `--manual-config=<path>` | ✓* | Local JSON config (alternative to `--token`) |
| `--image-version=<tag>` | | Pin to a specific image tag |
| `--dry-run` | | Preview only — no docker/systemd changes |

\* Either `--token` or `--manual-config` is required.
</details>

## SFU configuration

The `sfu` container is configured via environment variables in
`/etc/oxpulse-partner-edge/docker-compose.yml`.

| Variable | Default | Description |
|----------|---------|-------------|
| `SFU_UDP_PORT` | `3478` | WebRTC media port (DTLS/SRTP/STUN) |
| `SFU_METRICS_PORT` | `9317` | Prometheus `/metrics` endpoint |
| `SFU_RELAY_API_PORT` | `8912` | Cascade relay API (`POST /relay/connect`) |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface |
| `RELAY_JWT_SECRET` | — | HMAC-SHA256 secret shared with oxpulse-chat. **Required for cascade relay.** |
| `RUST_LOG` | `info` | Log filter |

## Verify

```bash
sudo oxpulse-partner-edge-healthcheck         # full 12-point check
sudo oxpulse-partner-edge-healthcheck --local # pre-DNS (docker-network only)
```

## Upgrade / rollback

```bash
sudo oxpulse-partner-edge-upgrade             # pull :latest
sudo oxpulse-partner-edge-upgrade v0.8.0      # pin to version
sudo oxpulse-partner-edge-upgrade --rollback  # revert to previous
```

## Snapshot scaling (multiple nodes)

1. Provision a master VM and run `sudo bash install.sh --bake`
2. Snapshot the VM (before first boot hydration)
3. Launch clones with `user_data` providing `OXPULSE_PARTNER_DOMAIN` and `OXPULSE_REGISTRATION_TOKEN`
4. On first boot, `oxpulse-partner-edge-hydrate.service` registers the node and starts all services automatically

## Uninstall

```bash
sudo systemctl disable --now oxpulse-partner-edge
sudo docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml down -v
sudo rm -rf /etc/oxpulse-partner-edge /var/lib/oxpulse-partner-edge \
            /etc/systemd/system/oxpulse-partner-edge.service \
            /usr/local/sbin/oxpulse-partner-edge-*
sudo systemctl daemon-reload
```

## Security

- Coturn runs in host-network mode and blocks SSRF into RFC1918/CGNAT/link-local ranges via `denied-peer-ip`.
- Restrict `SFU_RELAY_API_PORT` (8912) to the OxPulse backend IP in your cloud firewall.
- Each partner node has independent TURN credentials — one node compromise does not affect others.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## License

MIT OR Apache-2.0
