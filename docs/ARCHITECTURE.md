# Architecture

This document describes the public architecture of the `oxpulse-partner-edge`
bundle — the open-source component that partners self-host to extend the
OxPulse mesh. It covers the component layout, cryptographic boundary,
trust model, and anti-filtering layer. Internal control-plane logic and
web-client internals are out of scope; they live in separate private
repositories.

Intended audience: partners evaluating deployment, grant reviewers,
independent auditors, and contributors.

Cross-references: [THREAT-MODEL.md](THREAT-MODEL.md),
[SECURITY.md](../SECURITY.md), [DECISION.md](../DECISION.md).

## High-level diagram

```
                ┌──────────────────────────┐
                │   Browser (SvelteKit)    │
                │   E2E encryption layer   │
                └────────────┬─────────────┘
                             │ TLS 1.3
                             │ (SRTP / WebRTC inside)
                             ▼
                ┌──────────────────────────┐
                │     Caddy (SNI mux)      │
                │  ACME / Let's Encrypt    │
                │  :80, :443               │
                └─┬────────┬───────┬───────┘
                  │        │       │
        ┌─────────▼──┐  ┌──▼────┐ ┌▼──────────┐
        │ str0m SFU  │  │coturn │ │xray-client│
        │ (SRTP fwd) │  │TURN/  │ │(VLESS+    │
        │ :8912      │  │STUN   │ │ Reality+  │
        │            │  │:3478, │ │ XHTTP)    │
        │            │  │TURNS  │ │ outbound  │
        │            │  │via mux│ │           │
        └────────────┘  └───────┘ └─────┬─────┘
                                        │
                                        ▼
                          ┌─────────────────────────┐
                          │  OxPulse control plane  │
                          │  (proprietary, not in   │
                          │   this repo)            │
                          └─────────────────────────┘
```

## Cryptographic boundary

```
   ┌───────────────────────────────────────┐
   │ User device (browser)                 │
   │                                       │
   │   plaintext ──► encrypt ──► SRTP/SFrame
   │                                       │
   └────────────────┬──────────────────────┘
                    │   only ciphertext crosses this line
   ─ ─ ─ ─ ─ ─ ─ ─ ┼ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─ ─
                    │
   ┌────────────────▼──────────────────────┐
   │ Partner-edge node (this repo)         │
   │                                       │
   │   forward SRTP frames; never decrypt  │
   │   forward TURN; never inspect         │
   │   forward XHTTP; never decrypt        │
   │                                       │
   └───────────────────────────────────────┘
```

The partner-edge node holds no key material capable of decrypting media
or messages. SFrame keys are negotiated end-to-end among the up-to-six
participants and never transit through any forwarder.

## Component breakdown

### Caddy

TLS termination and SNI multiplexing on ports 80 and 443. Caddy handles
ACME certificate issuance via Let's Encrypt, reverse-proxies `/api/*` and
`/ws/*` to the control plane, and multiplexes TURNS traffic to coturn on
the same `:443` port using SNI-based routing (the Variant A' architecture
described in `DECISION.md`). Caddy sees TLS handshake metadata (SNI,
client IP) but does not see application-layer plaintext — WebRTC media
is encrypted end-to-end inside the TLS tunnel.

Configuration: `Caddyfile.tpl`.

### xray-client

Outbound encrypted tunnel using VLESS + Reality + XHTTP transport with
ML-KEM-768 post-quantum encryption. This container establishes the
obfuscated connection between the partner-edge node and the OxPulse
control plane, making the tunnel traffic indistinguishable from standard
HTTPS to network-level observers. xray-client handles only ciphertext;
it cannot decrypt the inner WebRTC or signaling payloads.

Configuration: `xray-client.json.tpl`.

### coturn

TURN/STUN relay for WebRTC connectivity. Listens on UDP 3478 for
standard STUN/TURN and shares port 443 with Caddy for TURNS (TLS-wrapped
TURN) via SNI multiplexing. coturn relays encrypted SRTP packets between
participants — it sees packet headers (source/destination, timestamps)
but never decrypts media content. SSRF is mitigated by blocking relay
to RFC 1918, CGNAT, and link-local address ranges via `denied-peer-ip`.

Configuration: `coturn.conf.tpl`.

### str0m SFU

Rust-based WebRTC Selective Forwarding Unit built on the str0m library.
Handles group calls for 3–6 participants by forwarding SRTP packets
without decrypting them. The SFU verifies relay authorization via
Ed25519-signed JWTs (public key fetched from the control plane) but
never possesses media decryption keys. Listens on port 8912 for the
cascade relay API.

Configuration: environment variables in `sfu-extra.env`; see the SFU
environment variables table in `README.md`.

## Trust boundaries

| Partner trusts | Source |
|---|---|
| Cryptographic primitives (X25519, AES-128-GCM, ML-KEM-768, SRTP) | Standard cryptographic literature; primitives chosen for known security properties |
| Their own VPS hardware and OS | Their procurement |
| OxPulse control plane to register / disconnect honestly | Operator transparency report (`TRANSPARENCY.md`); partner can withdraw at any time |
| The open code in this repository | Direct audit of AGPL-3.0 source |

## Independent verification checklist

A partner can confirm the following by reading the source and running
standard network analysis tools:

1. **No plaintext payload exits the partner-edge container.** All media
   is SRTP-encrypted before reaching the node; the SFU forwards frames
   without decryption.

2. **No telemetry phones home beyond the documented control-plane
   heartbeat.** The only outbound connections are the xray tunnel and
   the periodic heartbeat to the control plane, both documented in
   `docker-compose.yml.tpl`.

3. **No covert RPC channel.** Every outbound connection is enumerable
   in the Docker Compose template and the Caddy/xray configuration
   files. There are no undocumented callbacks.

4. **Exact metadata exposed at the edge:** room IDs, partner IDs,
   timestamps, byte counters, ICE candidate addresses. This metadata
   is necessary for call routing and is documented here for
   transparency.

## Anti-filtering layer

The partner-edge bundle includes multiple layers designed to resist
network-level filtering:

- **VLESS + Reality + XHTTP transport** — the xray-client tunnel
  presents as standard TLS to external observers. Configuration in
  `xray-client.json.tpl`.

- **5-way SNI rotation** — the tunnel rotates its server name indicator
  across a pool of domains, reducing long-lived traffic correlation.
  Implemented in `oxpulse-partner-edge-sni-rotate.sh`, scheduled via
  systemd timer.

- **Deterministic per-node SNI selection** — each node selects its SNI
  deterministically via `sha256(node_id)`, diversifying the (IP, SNI)
  tuple across the mesh to prevent bulk fingerprinting.

- **Cover page + active-probing defense** — a static cover page is
  served to direct HTTP visitors, and the `@probe` Caddy matcher
  defends against active-probing attempts. Source: `cover/` directory
  and `Caddyfile.tpl`.

- **ML-KEM-768 post-quantum encryption** — the xray 26.x tunnel layer
  uses ML-KEM-768 to provide forward secrecy against future quantum
  decryption.

- **AmneziaWG mesh interconnect** — partner-to-partner traffic uses
  AmneziaWG for mesh connectivity, provisioned during `install.sh`.

Architectural rationale for the TURNS-on-:443 via SNI mux design
(Variant A') is documented in `DECISION.md`.

## Operational model

1. Partner runs the one-command installer published as a release asset
   (`partner-edge-installer.sh` — the contents are `install.sh`).
2. The installer registers the node with the OxPulse control plane via
   `POST /api/partner/register` using the provided bootstrap token.
3. The control plane assigns an initial trust score and includes the
   node in the active mesh rotation.
4. A periodic heartbeat reports node health and receives configuration
   updates (SNI domain rotation, AmneziaWG mesh member list).
5. The partner can withdraw at any time by uninstalling. The control
   plane removes the node from active rotation immediately.
