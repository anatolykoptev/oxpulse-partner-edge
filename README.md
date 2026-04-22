# OxPulse Partner Edge Bundle

One-command installer for a production-grade **co-brand mirror node** that
participates in the oxpulse.chat network. Tested on Debian 12, Ubuntu
22.04 / 24.04, AlmaLinux 9, Rocky Linux 9.

The bundle runs four containers on the partner's VPS:

- **Caddy** — TLS termination (ACME via Let's Encrypt), SPA CDN, reverse
  proxy of `/api/*` + `/ws/*` through the tunnel.
- **xray-client** — VLESS + Reality + XHTTP tunnel to the main backend
  (`<backend>:5349` — operator-side xray-reality). Exposes only `:3080` inside the docker network.
- **coturn** — TURN/STUN relay with HMAC auth (`:3478/udp+tcp`,
  `:5349/tcp` for TURNS). Runs in host network mode.
- **sfu** (M2.1+) — str0m-based selective forwarding unit for group calls.
  Terminates WebRTC on `:7878/udp` and exposes Prometheus metrics on
  `:9317/tcp`. Host-networked so DTLS/SRTP sees the partner's real public
  IP with no NAT translation (see architecture decision D8:
  `docs/superpowers/decisions/2026-04-21-group-calls-architecture.md`).

Relationship to [`deploy/turn-node/`](../turn-node): that package is a
bare TURN relay only. `partner-edge` is the full app-mirror bundle.

## Prerequisites

- Debian 12+, Ubuntu 22.04+, AlmaLinux 9+, or Rocky 9+ (`systemd` + `bash`)
- 1 vCPU, 1 GB RAM, 20 GB disk (minimum — SFU adds ~100 MB RSS)
- Public IPv4 reachable from the internet
- A DNS A record for your partner domain pointing at the VPS's public IP
- Ports free: **80, 443/tcp+udp, 3478/tcp+udp, 3479/udp, 5349/tcp,
  7878/udp (SFU media), 9317/tcp (SFU metrics), 49152-65535/udp**

## Firewall

`install.sh` does **not** manage your host firewall — that is left to the
operator so it integrates cleanly with existing `ufw`/`firewalld`/cloud
security-group policies.

Open these ports **before** running `install.sh` (default port values shown;
adjust if you override `SFU_UDP_PORT` / `SFU_METRICS_PORT` during install):

```bash
# ufw example
ufw allow 80/tcp
ufw allow 443/tcp
ufw allow 443/udp        # QUIC (Caddy future)
ufw allow 3478/tcp
ufw allow 3478/udp       # TURN/STUN
ufw allow 5349/tcp       # TURNS
ufw allow 7878/udp       # SFU media (SFU_UDP_PORT, default 7878)
ufw allow 9317/tcp       # SFU Prometheus metrics (SFU_METRICS_PORT, default 9317)
ufw allow 49152:65535/udp  # TURN relay ports

# firewall-cmd example (RHEL/AlmaLinux/Rocky)
firewall-cmd --permanent --add-port=80/tcp
firewall-cmd --permanent --add-port=443/tcp
firewall-cmd --permanent --add-port=3478/tcp
firewall-cmd --permanent --add-port=3478/udp
firewall-cmd --permanent --add-port=5349/tcp
firewall-cmd --permanent --add-port=7878/udp   # SFU_UDP_PORT
firewall-cmd --permanent --add-port=9317/tcp   # SFU_METRICS_PORT
firewall-cmd --permanent --add-port=49152-65535/udp
firewall-cmd --reload
```

**SFU port overrides:** if you passed a custom `SFU_UDP_PORT` or
`SFU_METRICS_PORT` during install (interactive prompt or env override),
replace `7878` and `9317` with those values in the firewall rules above.

## Quickstart

```bash
# On a freshly provisioned VM, as root:
curl -fsSL https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-edge-installer.sh \
  -o install.sh
sudo bash install.sh \
  --domain=call.rvpn.online \
  --partner-id=rvpn \
  --manual-config=./node-config.json
```

The installer runs 10 steps (preflight → docker → IP detect → fetch config
→ render templates → pull → start → healthcheck → systemd → report) and
prints a banner on success.

### CLI flags

| Flag                      | Default       | Notes |
|---------------------------|---------------|-------|
| `--domain=<fqdn>`         | required      | Partner edge domain. Must already resolve. |
| `--partner-id=<id>`       | required      | Short tag; must match backend `config/partners/<id>.json`. |
| `--token=<ptkn_...>`      | —             | Registration token (calls `/api/partner/register`). |
| `--manual-config=<path>`  | —             | Alternative: read node config from a local JSON file. |
| `--tunnel=vless\|wg\|https` | `vless`     | Backend tunnel kind (only `vless` implemented in v0.1.0). |
| `--image-version=<tag>`   | `latest`      | Pin images to a specific published tag. |
| `--dry-run`               | off           | Render templates + print plan, skip docker/systemd. |

### Manual config fallback (v0.1.0)

The `/api/partner/register` endpoint is **not yet implemented** (Task 4 of
the partner-mirror plan). Until it lands, the partner operator receives a
small JSON file from OxPulse ops out-of-band and passes it to
`--manual-config`.

```json
{
  "node_id": "rvpn-call1",
  "backend_endpoint": "<operator-backend>:5349",
  "turn_secret": "<shared-hmac-secret>",
  "reality_uuid": "<uuid-v4>",
  "reality_public_key": "<base64-reality-pubkey>",
  "reality_short_id": "<8-hex-chars>",
  "reality_server_name": "www.samsung.com"
}
```

Keep this file `chmod 0600` — it contains the fleet-wide TURN secret.

## What the installer lays down

| Path                                             | Purpose                      |
|--------------------------------------------------|------------------------------|
| `/etc/oxpulse-partner-edge/docker-compose.yml`   | Rendered compose file        |
| `/etc/oxpulse-partner-edge/Caddyfile`            | Rendered Caddy config        |
| `/etc/oxpulse-partner-edge/xray-client.json`     | Rendered xray-client config  |
| `/etc/oxpulse-partner-edge/coturn.conf`          | Rendered turnserver.conf     |
| `/var/lib/oxpulse-partner-edge/install.env`      | Partner/version state        |
| `/usr/local/sbin/oxpulse-partner-edge-healthcheck` | 8-point verification        |
| `/usr/local/sbin/oxpulse-partner-edge-upgrade`   | Upgrade / rollback tool      |
| `/etc/systemd/system/oxpulse-partner-edge.service` | Systemd unit               |

## Verification

```bash
sudo oxpulse-partner-edge-healthcheck          # full external check
sudo oxpulse-partner-edge-healthcheck --local  # docker-network only (pre-DNS)
```

The 12-point healthcheck covers:

1. All four containers running (caddy, xray, coturn, sfu)
2. `/api/health` returns 2xx
3. `/api/branding` reports the expected `partner_id` (needs Task 3 backend)
4. TCP :443 listening
5. UDP :3478 listening
6. TCP :5349 listening
7. xray-client has an ESTABLISHED outbound to the backend
8. Coturn process loaded the rendered shared secret
9. TURNS :443 TLS handshake (SNI-muxed via caddy-l4)
10. SPA HTML served on `GET /`
11. SFU `:7878/udp` listening (M2.1)
12. SFU `/metrics` on `:9317` returns 200 (M1.5 endpoint)

**Expected-fail until backend lands:** checks 2 and 3 return FAIL until
`/api/branding` and the host-based branding resolver (Task 3) are deployed.
Use `--local` during that window.

### SFU environment variables

The `sfu` container reads its runtime config from env; defaults are baked
into `docker-compose.yml.tpl` and the Dockerfile. Override by editing the
rendered `/etc/oxpulse-partner-edge/docker-compose.yml` + recreating:

| Env                 | Default   | Purpose |
|---------------------|-----------|---------|
| `SFU_UDP_PORT`      | `7878`    | WebRTC media port (DTLS/SRTP over UDP). |
| `SFU_METRICS_PORT`  | `9317`    | Prometheus `/metrics` HTTP endpoint.   |
| `SFU_BIND_ADDRESS`  | `0.0.0.0` | Bind address for both sockets.          |
| `RUST_LOG`          | `info`    | `tracing_subscriber` filter directive. |

Scrape `http://<public-ip>:9317/metrics` from your Prometheus. Metric
names are prefixed `sfu_*` (e.g. `sfu_active_clients`,
`sfu_dominant_speaker_changes_total`).

### Prometheus scrape config (M6.1)

Add to your `prometheus.yml`:

```yaml
scrape_configs:
  - job_name: oxpulse-sfu
    scrape_interval: 30s
    static_configs:
      - targets: ['<edge-public-ip>:9317']
        labels:
          partner: '<your-partner-id>'
```

Every metric carries an `edge_id` const label set from the `SFU_EDGE_ID`
environment variable in `docker-compose.yml` (default `"local"`; set it to
e.g. `"ed-moscow-1"` during deploy).

Typical PromQL queries (M6.1 additions marked):

| Query | Description |
|-------|-------------|
| `rate(sfu_forwarded_packets_total[1m])` | Forwarded packet rate by media kind |
| `sfu_active_participants` | Current connected clients |
| `rate(sfu_layer_transitions_total[1m])` | Simulcast layer-switch rate per subscriber |
| `histogram_quantile(0.95, rate(sfu_dominant_speaker_hysteresis_ms_bucket[5m]))` | P95 dominant-speaker hysteresis (ms) |
| `sfu_e2e_handshake_failures_total` | E2E key-exchange failures (always 0 from SFU; M6.3 emits from client) |

## Upgrade / rollback

```bash
# Pull :latest and recreate (auto-rolls back on healthcheck failure):
sudo oxpulse-partner-edge-upgrade

# Pin to a specific tag:
sudo oxpulse-partner-edge-upgrade v0.2.0

# See whether an upgrade is pending without applying:
sudo oxpulse-partner-edge-upgrade --check

# Explicit rollback to the previous compose file:
sudo oxpulse-partner-edge-upgrade --rollback
```

The upgrade tool keeps the previous `docker-compose.yml` at
`/var/lib/oxpulse-partner-edge/docker-compose.yml.prev`, so rollback works
even if the new images are removed from GHCR.

## Troubleshooting

**Port already in use at install time**
  Some other service (nginx, apache) is on 80/443. Stop it or uninstall
  before running `install.sh`.

**Caddy can't get a TLS cert**
  Verify DNS A record for your domain resolves to this host's public IP.
  Caddy logs: `docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml logs caddy`.
  If you fronted the domain with Cloudflare, set DNS-only (grey cloud) —
  Caddy needs direct HTTP-01 to the edge.

**xray-client keeps reconnecting**
  Reality credentials don't match the backend. Check `reality_public_key`
  and `reality_short_id` in your manual-config JSON against what OxPulse ops
  provisioned for your partner-id.

**TURN doesn't work, signaling does**
  UDP 3478 + 49152-65535 are blocked upstream. The VPS provider's firewall,
  or a local `ufw`/`firewalld`, is filtering them. TURNS on :5349 works as
  a TCP fallback from restrictive client networks.

**Installer says "backend_endpoint missing"**
  Your manual-config JSON is missing a required field. Diff against the
  schema above.

## How branding is applied

The partner-edge bundle is **brand-agnostic**. All branding lives on the
backend at `config/partners/<partner_id>.json` and is injected into the
SvelteKit SPA at response time.

Request flow:

```
browser → https://call.rvpn.online/          (Caddy)
      → xray-client:3080                     (VLESS+Reality to backend)
      → <backend>:5349                       (xray-reality)
      → oxpulse-chat:8907                    (Rust/Axum)
```

Caddy adds `X-Forwarded-Host: call.rvpn.online` so the backend's branding
resolver picks the right config. This means a single installer binary
handles any partner — no image rebuild per partner.

## Uninstall

```bash
sudo systemctl disable --now oxpulse-partner-edge
sudo docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml down -v
sudo rm -rf /etc/oxpulse-partner-edge /var/lib/oxpulse-partner-edge \
            /etc/systemd/system/oxpulse-partner-edge.service \
            /usr/local/sbin/oxpulse-partner-edge-*
sudo systemctl daemon-reload
```

## Snapshot-based scaling (slepok workflow)

For partners scaling to N edge nodes via VM snapshots ("slepoks" — clones
of a baked master image).

### 1. Bake phase (run once on the master VM)

Provision a fresh VM, install Docker, then run:

```bash
sudo bash install.sh --bake
```

`--bake` installs packages, pulls Docker images, and installs + enables the
`oxpulse-partner-edge-hydrate.service` systemd unit — but does **not** write
any secrets or start any containers. The VM is now a clean golden image.

**Critical:** take the snapshot AFTER `--bake` completes but BEFORE hydration
runs. If hydrate.sh has run (i.e., the sentinel
`/var/lib/oxpulse-partner-edge/hydrated` exists), the snapshot will contain
master-VM credentials and every clone will come up with the same
`node_id`/`turn_secret`. Power off or halt the VM before snapshotting to be
safe.

### 2. Create the snapshot

Use your cloud provider's snapshot facility on the baked VM:

- **Hetzner Cloud**: Actions → Create snapshot in the server detail page, or
  `hcloud server create-image --type snapshot`
- **AWS EC2**: Actions → Image and templates → Create image
- **DigitalOcean**: Power off → Snapshots tab → Take snapshot

The snapshot name should encode the oxpulse version tag for traceability.

### 3. Provision clones with cloud-init

Each clone needs its own `OXPULSE_PARTNER_DOMAIN` and
`OXPULSE_REGISTRATION_TOKEN` (one token per clone — see Token provisioning
below). Copy `cloud-init.example.yaml`, fill in the per-clone values, and
pass the result as `user_data` when launching from the snapshot.

Before launching each clone, create a DNS A record:

```
callN.YOURPARTNER.example.com  →  <clone public IP>
```

hydrate.sh verifies DNS resolves to the clone's public IP before proceeding.
Let's Encrypt HTTP-01 also requires the record to exist before cert issuance.

### 4. First-boot flow

On first boot, systemd reaches `multi-user.target` and fires
`oxpulse-partner-edge-hydrate.service` (or cloud-init's explicit `systemctl
start` shortens the latency). hydrate.sh:

1. Loads `/etc/oxpulse-partner-edge/hydrate.env`
2. Detects the VM's public IP
3. Calls `/api/partner/register` with the registration token
4. Receives `node_id`, `turn_secret`, Reality credentials, and `turns_subdomain`
5. Renders config templates and writes them to `/etc/oxpulse-partner-edge/`
6. Verifies DNS (`turns-XXX.callN.YOURPARTNER.example.com` → public IP)
7. Starts containers via `docker compose up -d`
8. Waits up to 120 s for Caddy to obtain the TLS cert
9. Enables `oxpulse-partner-edge.service` and the cert-watch path unit
10. Writes the sentinel `/var/lib/oxpulse-partner-edge/hydrated`

### 5. Re-seeding (token rotation / manual recovery)

To re-hydrate a clone (e.g., after rotating the registration token):

1. Update `/etc/oxpulse-partner-edge/hydrate.env` with the new token.
2. Run:

```bash
sudo /usr/local/sbin/hydrate.sh --reseed
```

`--reseed` stops containers, removes the sentinel, and runs the full
hydration sequence again. The idempotency check will catch token changes even
without `--reseed` (config hash mismatch triggers automatic re-hydration on
the next service start).

### 6. Troubleshooting

**"already hydrated" but you need to re-hydrate**
  The sentinel exists and the config hash matches. Use `--reseed` as above,
  or manually `rm /var/lib/oxpulse-partner-edge/hydrated` and restart the
  service.

**DNS mismatch error**
  hydrate.sh resolved `turns-XXX.callN.YOURPARTNER.example.com` to an address
  that does not match the VM's public IP. Fix the A record and re-run
  `hydrate.sh` (or `--reseed`). TTL-cached records may take a few minutes to
  propagate.

**ACME timeout (Caddy did not obtain TLS cert within 120s)**
  Check that port 80 is open in the cloud provider's firewall and in any local
  `ufw`/`firewalld` rules — Let's Encrypt HTTP-01 needs inbound TCP :80.
  Also verify you have not exceeded Let's Encrypt rate limits (5 duplicate
  certs per 7 days for the same FQDN). Caddy logs:
  `docker compose -f /etc/oxpulse-partner-edge/docker-compose.yml logs caddy`

**Service fails to start after hydration**
  Check `journalctl -u oxpulse-partner-edge-hydrate.service` and
  `journalctl -u oxpulse-partner-edge.service` for errors.

### Token provisioning

Each clone requires a unique bootstrap token (`ptkn_...`). Obtain N tokens
from the OxPulse backend before launching clones:

```
POST /admin/partner/tokens/issue
```

TODO: link to token-issuance endpoint docs (not yet published).

Tokens are single-use: once a clone has successfully registered and the
backend has recorded its `node_id`, the token is invalidated.

## Support

- GitHub issues: https://github.com/anatolykoptev/oxpulse-partner-edge/issues
- Operator runbook: [`docs/partners/onboarding.md`](../../docs/partners/onboarding.md)
- Design spec: `docs/superpowers/specs/2026-04-17-oxpulse-partner-mirror-design.md`

## Security notes

- The TURN shared secret is fleet-wide — rotating it requires coordinated
  redeploy of all nodes. Ask ops for the current value out-of-band.
- Reality credentials are per-partner. Compromising one partner node does
  not expose the backend or other partners.
- The Caddy container has no write access to `/etc/caddy/Caddyfile` (it's
  mounted `ro`). Cert storage is in an isolated docker volume.
- Coturn runs in **host network mode** because TURN must see the real
  public IP to advertise relay candidates. The `denied-peer-ip` list in
  `coturn.conf` blocks SSRF into RFC1918 / CGNAT / link-local ranges.

---

## Reality keypair rotation impact (operator note, Apr 2026)

The operator backend (krolik) rotates Reality x25519 + ML-KEM-768 keys on
a quarterly schedule (1st of Q1/Q2/Q3/Q4) via `rotate-reality-keys.timer`.
After each rotation, **the keys baked into your partner-edge node config
become stale** — your `xray-client` will fail to handshake with the
backend.

You'll receive a Telegram notification from operator ops within minutes of
the rotation. To recover, re-run the installer in upgrade mode:

```bash
sudo bash /opt/oxpulse-chat/install.sh --upgrade --partner-id=<your-id>
```

This re-calls `/api/partner/register` (or fetches new manual config),
rewrites `node-config.json`, restarts `xray-client` and `coturn`, and
verifies handshake.

Alternative if you have a registration token stored:

```bash
TOKEN=$(cat /etc/oxpulse-edge/registration.token)
curl -X POST https://oxpulse.chat/api/partner/register \
    -H 'Content-Type: application/json' \
    -d "{\"partner_id\":\"<id>\",\"domain\":\"<fqdn>\",\"token\":\"$TOKEN\"}" \
  | jq > /etc/oxpulse-edge/node-config.json.new
sudo mv /etc/oxpulse-edge/node-config.json.new /etc/oxpulse-edge/node-config.json
sudo systemctl restart xray-client coturn
```

### Auto-refresh (shipped)

`install.sh` now installs `oxpulse-partner-edge-refresh.timer` (daily,
±4h jitter). The timer runs `/usr/local/sbin/oxpulse-partner-edge-refresh`
which:

1. `GET ${OXPULSE_BACKEND_URL}/api/partner/keys` — public endpoint, no
   auth, returns `{reality_public_key, reality_encryption,
   reality_server_names, version}`. Cheap (~200B response).
2. Compares returned `version` (sha256 of pubkey+encryption) with stored
   value at `/var/lib/oxpulse-partner-edge/keys-version`.
3. If different: backs up `node-config.json`, merges new reality fields,
   `systemctl reload oxpulse-partner-edge.service` (compose recreate).
   On verify failure → restores backup, re-reloads, exits non-zero.
4. Persists new version hash.

**Manual re-registration is no longer required after operator rotations**
— the next daily fire (within 24h ±4h) picks up the new keys
automatically. For immediate refresh after a notification:

```bash
sudo systemctl start oxpulse-partner-edge-refresh.service
journalctl -u oxpulse-partner-edge-refresh.service -n 30
```

### Detecting a stuck node

If your `xray-client` log shows TLS handshake reject from `<backend>:5349`
right after a rotation timestamp, you missed the re-registration window.
Run the upgrade command above.

### Rotation schedule

`OnCalendar=*-01,04,07,10-01 04:55 + 2h jitter` (krolik local time, PDT/PST).
Next rotation: see operator broadcast or `systemctl list-timers
rotate-reality-keys` on krolik.
