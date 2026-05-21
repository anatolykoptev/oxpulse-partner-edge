# oxpulse-partner-edge

[![CI](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml/badge.svg)](https://github.com/anatolykoptev/oxpulse-partner-edge/actions/workflows/ci.yml)
[![Latest release](https://img.shields.io/github/v/release/anatolykoptev/oxpulse-partner-edge?label=release)](https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest)
[![License: AGPL-3.0 OR Commercial](https://img.shields.io/badge/license-AGPL--3.0%20OR%20Commercial-blue.svg)](LICENSE)

Production-ready co-brand mirror node for the OxPulse network. One command installs TLS termination, an encrypted bypass tunnel, an obfuscated fallback channel, TURN/STUN relay, a WebRTC SFU, and an AmneziaWG mesh link to the central node — on any VPS.

## Why

OxPulse is encrypted real-time communication built to work under network-level filtering. The partner-edge bundle in this repository is the open-source component that operators self-host to extend the OxPulse mesh. Every byte that passes through a partner-edge node is end-to-end encrypted between participants — operators see only ciphertext and minimal forwarding metadata. Run by individual sysadmins, civic-tech communities, and university labs in jurisdictions that respect privacy.

## What's inside

| Component | Purpose | Network mode |
|-----------|---------|--------------|
| **caddy** | TLS (ACME/Let's Encrypt), SNI mux, reverse proxy for `/api/*` + `/ws/*` + `/sfu/ws/*` | bridge (`:80`, `:443`) |
| **xray-client** | Encrypted outbound tunnel — VLESS + Reality + XHTTP + ML-KEM-768 PQ | bridge (internal `:3080`) |
| **hysteria2** | Anti-censorship fallback channel — `lb_policy first` failover from Reality | bridge (`:18443`) |
| **coturn** | TURN/STUN relay — UDP 3478, TURNS on `:5349` via Caddy SNI mux | host |
| **sfu** | WebRTC Selective Forwarding Unit — Rust binary (`crates/sfu/`) | host |
| **amneziawg-go** | Userspace AmneziaWG (WireGuard obfuscation fork) mesh link to motherly | host iface `awg0` |

Optional channel (enable with `--naive-server=<host>`):

| Component | Purpose |
|-----------|---------|
| **naive** | NaïveProxy HTTPS-cloaked SOCKS5 fallback (CH5) |

## Requirements

- Debian 12 / Ubuntu 22.04+ / AlmaLinux 9 / Rocky 9 / CentOS Stream 9 with `systemd`
- **Dedicated host** (no control panel, no other workloads — see [`docs/HOSTING_REQUIREMENTS.md`](docs/HOSTING_REQUIREMENTS.md))
- **2 vCPU, 4 GiB RAM, 40 GiB SSD** (1 GiB minimum is no longer sufficient — SFU peaks at 600–900 MiB under 100-participant load; 2 GiB hosts OOM mid-call)
- Public IPv4; DNS A record for your domain
- Either `ufw` (Debian-family) or `firewalld` (RHEL-family) — installer configures the whitelist automatically; missing → installer warns + skips and you must apply manually

### Ports the installer opens

| Port | Proto | Public | Scope |
|------|-------|--------|-------|
| `22` | tcp | yes | SSH |
| `80`, `443` | tcp | yes | Caddy HTTP + HTTPS |
| `443` | udp | yes | Caddy QUIC (h3) |
| `3478`, `5349` | tcp + udp | yes | Coturn STUN / TURN / TURN-TLS |
| `7878` | udp | yes | SFU media (WebRTC RTP) |
| `18443` | tcp + udp | yes | Hysteria2 fallback channel |
| *partner-specific* | udp | yes | AmneziaWG mesh inbound (port allocated by motherly per partner, e.g. `43994`) |
| `9317` | tcp | **mesh-only** (`10.9.0.0/24`) | SFU Prometheus `/metrics` |
| `8912` | tcp | **mesh-only** (`10.9.0.0/24`) | SFU relay API |
| `8920` | tcp | loopback / bridge | SFU client WebSocket (Caddy reverse-proxies to it) |

See [`lib/install-firewall.sh`](lib/install-firewall.sh) for the exact rules. SFU privileged sockets (`9317`, `8912`, `8920`) are NOT publicly reachable post-install.

## Install

```bash
curl -fsSL \
  https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-edge-installer.sh \
  | sudo bash -s -- \
      --domain=call.your-domain.example \
      --partner-id=your-partner-id \
      --token=ptkn_<registration-token>
```

The installer is idempotent — re-running on an already-installed host is safe (validates the existing install, refreshes templates, no side-effects).

<details>
<summary>All installer flags</summary>

| Flag | Required | Description |
|------|----------|-------------|
| `--domain=<fqdn>` | ✓ | Partner edge domain (must already resolve to this server) |
| `--partner-id=<id>` | ✓ | Short identifier matching your backend config |
| `--token=<ptkn_...>` | ✓* | Single-use registration token from the backend |
| `--manual-config=<path>` | ✓* | Local JSON config file (alternative to `--token`) |
| `--image-version=<tag>` | | Pin containers to a specific image tag (default: `stable`) |
| `--dry-run` | | Render configs and print plan — no docker/systemd changes |
| `--bake` | | Bake phase for snapshot workflows: install packages + images, no secrets, no start |
| `--naive-server=<host>` | | Enable naive proxy bypass channel (CH5). Omitting this flag skips the channel cleanly. Test-fixture hosts (`localhost`, `*.example.com`, `*.example.net`, `*.example.org`, `*.test`) are auto-rejected with a warning. |

\* Either `--token` or `--manual-config` is required.
</details>

## Day-2 operations

### Upgrade

```bash
sudo oxpulse-partner-edge-upgrade                  # pull :stable images
sudo oxpulse-partner-edge-upgrade v0.12.52         # pin to a specific tag
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
journalctl -u oxpulse-partner-edge-refresh -f         # daily refresh runs
journalctl -u oxpulse-partner-edge-sni-rotate -f      # daily SNI rotation
journalctl -u oxpulse-channels-health-report -f       # 60s channel health
```

## Automatic maintenance

Once installed, four systemd timers run without intervention:

| Timer | Schedule | Purpose |
|-------|----------|---------|
| `oxpulse-partner-edge-refresh.timer` | Daily (4h jitter, `Persistent=true`) | Fetches updated credentials from the backend; refreshes `sfu-keys.env` (Ed25519 JWT verify key); re-renders tunnel config if the operator has rotated keys or changed channel settings |
| `oxpulse-partner-edge-sni-rotate.timer` | Daily (04:00–06:00 UTC, randomised) | Rotates the tunnel's server-name indicator from a pool provided by the backend; reduces long-lived traffic correlation |
| `oxpulse-partner-cert-watch.path` | On cert change | Signals coturn to reload when Caddy renews the TURNS TLS certificate |
| `oxpulse-channels-health-report.timer` | Every 60s | Probes local channel listeners (Reality / Hysteria2 / Naive) and reports RTT + handshake status to the central server via `POST /api/partner/channel-health` |

Check timer status:
```bash
systemctl list-timers 'oxpulse-partner-*'
```

If any timer reports `inactive (dead)` despite being `enabled`, check `systemctl status <timer>` and `journalctl -u <timer>` — a hard `Requires=` on a missing unit can leave a timer dead silently (closed in #234, but worth verifying on legacy installs).

## AmneziaWG mesh

Partner-edges form a layer-3 mesh with the central node via [AmneziaWG](https://github.com/amnezia-vpn/amneziawg-go), an obfuscated WireGuard fork that defeats DPI fingerprinting. The installer brings up `awg0` on the partner using parameters returned by the central's `/api/partner/register`.

**Critical invariant:** the obfuscation parameters (`Jc/Jmin/Jmax/S1/S2/S4/H1..H4/I1..I5`) MUST match byte-for-byte across every peer in the mesh. A single-byte drift makes the data plane silently drop decrypted packets while WireGuard handshake keeps succeeding — see [`docs/AWG_PARAM_INVARIANT.md`](docs/AWG_PARAM_INVARIANT.md) for the failure mode and the diagnostic procedure.

The mesh carries inter-partner control plane (SFU `/metrics` scraping, relay-API, OTLP traces). It does **not** carry user media — SRTP frames are end-to-end encrypted client-to-client independently.

## State and secrets

| Path | Contents |
|------|---------|
| `/etc/oxpulse-partner-edge/` | Rendered configs (docker-compose, Caddyfile, tunnel JSON, coturn) |
| `/etc/oxpulse-partner-edge/reality.priv` | x25519 private key (mode 0600, never leaves this host) |
| `/etc/oxpulse-partner-edge/reality.pub` | x25519 public key (mode 0644, sent to backend on register) |
| `/etc/oxpulse-partner-edge/reality.uuid` | Per-edge VLESS UUID (mode 0644, sent to backend on register) |
| `/etc/amnezia/amneziawg/awg0.conf` | AmneziaWG `[Interface]` + central peer (mode 0600, contains x25519 private key) |
| `/var/lib/oxpulse-partner-edge/install.env` | Installed partner ID, domain, image version |
| `/var/lib/oxpulse-partner-edge/node-config.json` | Full node config from registration (credentials, channel list, mesh params) |
| `/var/lib/oxpulse-partner-edge/keys-version` | Last-seen Reality key rotation version hash |
| `/var/lib/oxpulse-partner-edge/channels-version` | Last-seen channel config version hash |
| `/var/lib/oxpulse-partner-edge/sfu-keys.env` | Ed25519 public key for SFU relay JWT verification (refreshed daily) |
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
   The xray-config-watch path-unit reloads xray-reality on motherly to apply the updated client list.
   Existing sessions on this edge will reconnect.

## SFU environment variables

Configured via `SFU_*` entries in `/etc/oxpulse-partner-edge/sfu-extra.env` (persisted across upgrades) or the docker-compose env block.

| Variable | Default | Description |
|----------|---------|-------------|
| `SFU_UDP_PORT` | `7878` | WebRTC media port (DTLS/SRTP/STUN) — public |
| `SFU_METRICS_PORT` | `9317` | Prometheus `/metrics` endpoint |
| `SFU_RELAY_API_PORT` | `8912` | Cascade relay API (`POST /relay/connect`) |
| `SFU_CLIENT_WS_PORT` | `8920` | Client-facing WebSocket (`/sfu/ws/{room_id}`, fronted by Caddy) |
| `SFU_BIND_ADDRESS` | `0.0.0.0` | Default bind for all sockets — UDP media MUST stay 0.0.0.0 for ICE |
| `SFU_METRICS_BIND` | (= `SFU_BIND_ADDRESS`) | Override bind for `/metrics` — partner-edge sets this to the AWG mesh IP so `:9317` is mesh-only |
| `SFU_RELAY_API_BIND` | (= `SFU_BIND_ADDRESS`) | Override bind for relay API — partner-edge sets this to the AWG mesh IP |
| `SFU_CLIENT_WS_BIND` | (= `SFU_BIND_ADDRESS`) | Override bind for client WS (reserved; Caddy proxies via host bridge today) |
| `SFU_EDGE_ID` | (set by installer) | Per-edge label baked into every Prometheus series |
| `SFU_PUBLIC_IP` | (set by installer) | Public IPv4 advertised in WebRTC ICE host candidates |
| `SIGNALING_SFU_SECRET` | (set by installer) | HS256 shared secret for browser room-JWT verification |
| `SFU_SIGNING_PUBLIC_KEY` | (auto-fetched, refreshed daily) | Ed25519 public key for relay JWT verification |
| `STR0M_STATS_INTERVAL_SECS` | `2` | str0m PeerStats/MediaStats event cadence (0 disables) |
| `SFU_SOLO_KICK_AFTER_SECS` | `120` | How long a 1-participant room persists before the lone peer is disconnected (0 disables) |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | (set if mesh enabled) | OTLP traces export — typically `http://10.9.0.2:4317` over awg0 |
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
  oxpulse-partner-cert-watch.path \
  oxpulse-channels-health-report.timer
sudo docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml down -v
sudo awg-quick down awg0 2>/dev/null || true
sudo rm -rf \
  /etc/oxpulse-partner-edge \
  /var/lib/oxpulse-partner-edge \
  /etc/amnezia/amneziawg/awg0.conf \
  /etc/systemd/system/oxpulse-partner-edge* \
  /etc/systemd/system/oxpulse-partner-cert-watch* \
  /usr/local/sbin/oxpulse-partner-edge-* \
  /usr/local/sbin/oxpulse-channels-health-report \
  /usr/local/sbin/channel-render-lib.sh
sudo systemctl daemon-reload
```

## Security

- **Dedicated host required.** See [`docs/HOSTING_REQUIREMENTS.md`](docs/HOSTING_REQUIREMENTS.md). Partner-edge carries cryptographic key material (AmneziaWG private key, Reality private key, signing keys); a shared host with a control panel (ISPmanager, cPanel, Plesk) exposes these via panel cron jobs and webhooks.
- **Host firewall whitelist enforced at install time.** [`lib/install-firewall.sh`](lib/install-firewall.sh) applies a least-privilege rule set via `ufw` (Debian/Ubuntu) or `firewalld` (RHEL/CentOS). SFU privileged sockets (`:9317`, `:8912`) are mesh-only (`10.9.0.0/24`); `:8920` is loopback/bridge only.
- **Application-layer mesh-only bind.** Beyond the firewall, the SFU binary now scopes `/metrics` and relay-API sockets to the AWG mesh IP via `SFU_METRICS_BIND` / `SFU_RELAY_API_BIND` (defence-in-depth, ships with v0.13+).
- Each partner node receives independent credentials — a single compromised node cannot affect others.
- Coturn blocks SSRF into RFC 1918 / CGNAT / link-local ranges via `denied-peer-ip`.
- The SFU verifies relay JWTs against an Ed25519 public key fetched from the backend (no shared secret needed; refreshed daily).
- Tunnel credentials and coturn secrets are stored `0600`; never appear in container environment or logs.
- AmneziaWG obfuscation parameters MUST match across the mesh — see [`docs/AWG_PARAM_INVARIANT.md`](docs/AWG_PARAM_INVARIANT.md).

## Changelog

See [CHANGELOG.md](CHANGELOG.md).

## Documentation

- [Hosting requirements](docs/HOSTING_REQUIREMENTS.md) — read before installing
- [AWG param invariant](docs/AWG_PARAM_INVARIANT.md) — the mesh data-plane constraint
- [Roadmap](docs/ROADMAP.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Threat model](docs/THREAT-MODEL.md)
- [Follow-ups](docs/FOLLOWUPS.md) — open issues / deferred TODOs from PR reviews
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

## opec — tenant control plane

`opec` is included as a compiled binary starting from the release where this crate is introduced.

```bash
# Build locally:
cargo build --release -p opec
./target/release/opec --help
```

See [`crates/opec/README.md`](crates/opec/README.md) and [`docs/runbooks/opec-tenant.md`](docs/runbooks/opec-tenant.md).
