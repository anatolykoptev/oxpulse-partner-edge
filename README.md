# oxpulse-partner-edge

[![CI](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/anatolykoptev/oxpulse-partner-edge?label=release)](https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest)
[![License: AGPL-3.0 OR Commercial](https://img.shields.io/badge/license-AGPL--3.0%20OR%20Commercial-blue.svg)](LICENSE)

Production-ready co-brand mirror node for the OxPulse network. One command installs TLS termination, an encrypted bypass tunnel, TURN/STUN relay, and a WebRTC SFU on any VPS.

## Why

OxPulse is encrypted real-time communication built to work under network-level filtering. The partner-edge bundle in this repository is the open-source component that operators self-host to extend the OxPulse mesh. Every byte that passes through a partner-edge node is end-to-end encrypted between participants — operators see only ciphertext and minimal forwarding metadata. Run by individual sysadmins, civic-tech communities, and university labs in jurisdictions that respect privacy.

## What's inside

| Container | Purpose |
|-----------|---------|
| **caddy** | TLS (ACME/Let's Encrypt), SNI mux, reverse proxy for `/api/*` + `/ws/*` |
| **xray-client** | Encrypted outbound tunnel with traffic obfuscation (VLESS + Reality + XHTTP) |
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
| `--domain=<fqdn>` | ✓ | Partner edge domain (must already resolve to this server) |
| `--partner-id=<id>` | ✓ | Short identifier matching your backend config |
| `--token=<ptkn_...>` | ✓* | Single-use registration token from the backend |
| `--manual-config=<path>` | ✓* | Local JSON config file (alternative to `--token`) |
| `--image-version=<tag>` | | Pin containers to a specific image tag (default: `latest`) |
| `--dry-run` | | Render configs and print plan — no docker/systemd changes |
| `--bake` | | Bake phase for snapshot workflows: install packages + images, no secrets, no start |

\* Either `--token` or `--manual-config` is required.
</details>

## Day-2 operations

### Upgrade

```bash
sudo oxpulse-partner-edge-upgrade                  # pull :latest images
sudo oxpulse-partner-edge-upgrade v0.9.0           # pin to a specific tag
sudo oxpulse-partner-edge-upgrade --check          # report whether an upgrade is available
sudo oxpulse-partner-edge-upgrade --rollback       # revert to previous image tag
sudo oxpulse-partner-edge-upgrade --templates-only # refresh tunnel config from upstream template only, no image pull
```

`--templates-only` is useful for applying operator-side configuration changes (cipher updates, transport parameters, SNI pool expansions) to all nodes without a full image upgrade.

### Health check

```bash
sudo oxpulse-partner-edge-healthcheck          # full 12-point check (requires DNS)
sudo oxpulse-partner-edge-healthcheck --local  # pre-DNS check (docker-network only)
```

### Logs

```bash
docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml logs -f
```

## Automatic maintenance

Once installed, three systemd timers run without intervention:

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `oxpulse-partner-edge-refresh.timer` | Daily | Fetches updated credentials from the backend; re-renders tunnel config if the operator has rotated keys or changed channel settings |
| `oxpulse-partner-edge-sni-rotate.timer` | Daily (04:00–06:00 UTC, randomised) | Rotates the tunnel's server-name indicator from a pool provided by the backend; reduces long-lived traffic correlation |
| `oxpulse-partner-cert-watch.path` | On cert change | Signals coturn to reload when Caddy renews the TURNS TLS certificate |

Check timer status:
```bash
systemctl list-timers 'oxpulse-partner-*'
```

## State and secrets

| Path | Contents |
|------|---------|
| `/etc/oxpulse-partner-edge/` | Rendered configs (docker-compose, Caddyfile, tunnel JSON, coturn) |
| `/etc/oxpulse-partner-edge/reality.priv` | x25519 private key (mode 0600, never leaves this host) |
| `/etc/oxpulse-partner-edge/reality.pub` | x25519 public key (mode 0644, sent to backend on register) |
| `/etc/oxpulse-partner-edge/reality.uuid` | Per-edge VLESS UUID (mode 0644, sent to backend on register) |
| `/var/lib/oxpulse-partner-edge/install.env` | Installed partner ID, domain, image version |
| `/var/lib/oxpulse-partner-edge/node-config.json` | Full node config from registration (credentials, channel list) |
| `/var/lib/oxpulse-partner-edge/keys-version` | Last-seen key rotation version hash |
| `/var/lib/oxpulse-partner-edge/channels-version` | Last-seen channel config version hash |
| `/var/lib/oxpulse-partner-edge/sfu-keys.env` | Ed25519 public key for SFU relay JWT verification |
| `/var/log/oxpulse-partner-edge-*.log` | Per-component maintenance logs |

### Reality keypair

The x25519 keypair and VLESS UUID are generated once at first install using `partner-cli keygen` and
persisted under `/etc/oxpulse-partner-edge/`. Reinstalling reuses the existing files — the edge
keeps its registered identity across upgrades.

**Prerequisite:** `partner-cli` must be on PATH before running `install.sh`. Install it from the
oxpulse-chat release bundle or build from source:
```bash
cargo build -p partner-cli --release
sudo install -m 0755 target/release/partner-cli /usr/local/bin/
```

**Rotation procedure:**

1. Delete `/etc/oxpulse-partner-edge/install.env` — otherwise `install.sh` detects an existing
   install at the top-level guard and short-circuits before reaching the keygen block.
2. Delete the three Reality files:
   ```bash
   sudo rm /etc/oxpulse-partner-edge/reality.{priv,pub,uuid}
   ```
3. Re-run `install.sh` — `partner-cli keygen` is invoked, new keys and UUID are written, and
   `POST /api/partner/register` ships the new `reality_public_key`. The backend upserts
   `partner_nodes.reality_pubkey` via `ON CONFLICT DO UPDATE` (idempotent — no 409 risk).
   The path-watcher SIGHUPs xray-reality to apply the updated client list (slice 2c).
   Existing sessions on this edge will reconnect.

Note: `PARTNER_REALITY_UUID` env var (in `.env`) remains valid for legacy edges that have not
re-run `install.sh` since M6. New installs populate `partner_nodes.reality_uuid` directly from
the register payload and do not rely on the fleet-wide env UUID.

## SFU environment variables

Configured via `SFU_*` entries in `/etc/oxpulse-partner-edge/sfu-extra.env` (persisted across upgrades).

| Variable | Default | Description |
|----------|---------|-------------|
| `SFU_UDP_PORT` | `7878` | WebRTC media port (DTLS/SRTP/STUN) |
| `SFU_METRICS_PORT` | `8878` | Prometheus `/metrics` endpoint |
| `SFU_RELAY_API_PORT` | `8912` | Cascade relay API (`POST /relay/connect`) |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Bind interface |
| `SFU_SIGNING_PUBLIC_KEY` | (auto-fetched) | Ed25519 public key for relay JWT verification |
| `RUST_LOG` | `info` | Log filter |

## Snapshot scaling (multiple nodes from one image)

1. Provision a master VM, run `sudo bash install.sh --bake`
2. Snapshot the VM before its first hydration boot
3. On each clone, supply `OXPULSE_PARTNER_DOMAIN` and `OXPULSE_REGISTRATION_TOKEN` via `user_data` or `/etc/oxpulse-partner-edge/hydrate.env`
4. `oxpulse-partner-edge-hydrate.service` registers the clone and starts all services on first boot automatically

## Uninstall

```bash
sudo systemctl disable --now \
  oxpulse-partner-edge \
  oxpulse-partner-edge-refresh.timer \
  oxpulse-partner-edge-sni-rotate.timer \
  oxpulse-partner-cert-watch.path
sudo docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml down -v
sudo rm -rf \
  /etc/oxpulse-partner-edge \
  /var/lib/oxpulse-partner-edge \
  /etc/systemd/system/oxpulse-partner-edge* \
  /etc/systemd/system/oxpulse-partner-cert-watch* \
  /usr/local/sbin/oxpulse-partner-edge-* \
  /usr/local/sbin/channel-render-lib.sh
sudo systemctl daemon-reload
```

## Security

- Each partner node receives independent credentials — a single compromised node cannot affect others.
- Coturn blocks SSRF into RFC 1918 / CGNAT / link-local ranges via `denied-peer-ip`.
- Restrict `SFU_RELAY_API_PORT` (8912) to the OxPulse backend IP in your cloud firewall.
- The SFU verifies relay JWTs against an Ed25519 public key fetched from the backend (no shared secret needed).
- Tunnel credentials and coturn secrets are stored `0600`; never appear in container environment or logs.

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Documentation

- [Roadmap](docs/ROADMAP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Threat model](docs/THREAT-MODEL.md)
- [Security policy](SECURITY.md)
- [Transparency report](TRANSPARENCY.md)
- [Contributing guide](CONTRIBUTING.md)
- [Code of conduct](CODE_OF_CONDUCT.md)
- [Contributor License Agreement](CLA.md)
- [Commercial license](LICENSE-COMMERCIAL.md)
- [Architecture decisions](DECISION.md)

## License

`oxpulse-partner-edge` is dual-licensed:

- **AGPL-3.0** — the default. See [`LICENSE`](LICENSE). Suitable for community deployments, self-hosters, partners running unmodified or AGPL-compatible modified versions.
- **Commercial license** — for organizations that cannot accept AGPL § 13 (network use as SaaS) or want to ship proprietary modifications. See [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md).

Contributions to this repo require signing the [Contributor License Agreement](CLA.md) — necessary for the dual-licensing model. See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the contribution flow.
