# Partner-edge hosting requirements

This document spells out the hosting expectations for running a production
partner-edge node. The 2026-05-21 audit found two host-configuration gaps
that are best addressed at the operator level (the installer cannot fix
them at install time): the host must be **dedicated** (no other workloads)
and must have **enough RAM** to handle the steady-state SFU load.

## TL;DR

| Requirement | Minimum | Recommended |
|---|---|---|
| RAM           | **2 GiB**       | **4 GiB**            |
| vCPUs         | 1               | **2**                |
| Disk          | 20 GiB          | **40 GiB SSD**       |
| Bandwidth     | 1 TB/month      | unmetered            |
| Public IPv4   | 1 (static)      | 1 static + 1 reserve |
| Dedicated host | — | **MUST be dedicated**  |
| Hosting panel | — | **MUST NOT be installed (ISPmanager, cPanel, Plesk, etc.)** |

## Why dedicated host

Partner-edges carry cryptographic key material:

- **AmneziaWG private key** (`/etc/amnezia/amneziawg/awg0.conf`) —
  whoever reads this file can decrypt the partner's mesh traffic.
- **Reality UUID + private key fragment** (`/etc/oxpulse-partner-edge/node-config.json`).
- **Ed25519 signing public key** (`sfu-keys.env`) — less sensitive (public
  key, not signing key), but its corruption breaks JWT verification and
  silently drops 1:1 calls.

A host shared with other workloads — especially ones with their own
control panels (ISPmanager, cPanel, Plesk) — gives those panels root via
their cron jobs and webhooks. The 2026-05-21 audit found ISPmanager
cron tasks running every 5 minutes on one of the live partners; any
compromise of that panel exposes our keys.

**Rule:** the partner-edge host must run only the partner-edge stack
(docker, the partner-edge containers, fail2ban, ufw/firewalld). Nothing
else. No website, no mail server, no other VPN.

## RAM sizing

**Empirical baseline (2026-05-22, zvonilka partner-edge under light load):**

| Component | RSS |
|---|---|
| oxpulse-partner-caddy     | 27 MiB |
| oxpulse-partner-xray      | 23 MiB |
| oxpulse-partner-hysteria2 | 22 MiB |
| oxpulse-partner-coturn    | 9 MiB |
| oxpulse-partner-sfu       | 4 MiB (idle) |
| dockerd                   | 58 MiB |
| journald                  | 127 MiB |
| **Stack overhead**        | **~270 MiB** |

Total RAM at idle / light traffic: ~700 MiB used out of 1.8 GiB on
zvonilka. **2 GiB is sufficient for 1:1 calls and small rooms (the
current production workload across all 4 partners as of 2026-05-22).**

**4 GiB is the comfortable choice** for:

- larger rooms (more participants -> more str0m RTP buffers + decoder state)
- bursty hysteria2 / Reality channels
- co-resident logs that accumulate between log rotations
- headroom for the SFU under load spikes without paging

The exact SFU memory growth per participant is **not yet measured
in-house** -- see followup P in `FOLLOWUPS.md` for the planned
capacity benchmark. Until that publishes, we recommend 4 GiB for any
partner expecting > 20 concurrent participants per room, and document
2 GiB as the verified-working minimum for the current fleet's workload.

## Why ufw / firewalld must be active

PR #231 (host firewall hardening, merged 2026-05-21) made the installer
configure a host firewall whitelist by default. Before that, all three
production partners shipped with `:9317/tcp` (SFU `/metrics`),
`:8912/tcp` (SFU relay API), and `:8920/tcp` (SFU client WS) publicly
reachable from the open internet — they exposed room state and the
internal control plane.

The installer now applies a least-privilege whitelist (see
`lib/firewall-lib.sh`); this requires **either** `ufw` (Debian /
Ubuntu) **or** `firewalld` (RHEL / CentOS / Rocky / Alma). On other
distros the installer warns and skips — the operator must apply the
whitelist manually. Allowed ports:

- Public TCP: `22, 80, 443, 18443, 3478, 5349`
- Public UDP: `443, 18443, 3478, 5349, 7878, <AWG_PORT>`
- Mesh-only (10.9.0.0/24): `9317/tcp, 8912/tcp`

If you disable the firewall after install, re-expose this surface to
the internet — even for a few minutes — and you leak the partner's
real-time room statistics.

## Bandwidth note

A single 1:1 call at ~500 kbps consumes ~225 MiB per hour per direction
through the partner. A 50-call hour saturates ~22 Mbps. Cloud bandwidth
caps below 1 TB/month bite at modest weekly active users.

## See also

- `docs/AWG_PARAM_INVARIANT.md` — AmneziaWG obfuscation parameter constraint.
- `docs/THREAT-MODEL.md` — adversary model the host requirements are derived from.
- `lib/firewall-lib.sh` — installer-time enforcement of the whitelist above.
- `lib/install-preflight.sh` — installer-time RAM/swap warning (`_preflight_low_memory_swap`) + ghost-container cleanup pass.
