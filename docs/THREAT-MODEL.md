# Threat model

## Introduction

This document defines the threat model for the `oxpulse-partner-edge`
bundle — the open-source AGPL-3.0 component that partner operators
self-host to extend the OxPulse encrypted communication mesh.

It is intended for independent security auditors, partners evaluating
whether to deploy a node, and grant reviewers assessing the maturity of
the project's security posture. It should be read alongside
[ARCHITECTURE.md](ARCHITECTURE.md) for the system layout and
cryptographic boundary, [SECURITY.md](../SECURITY.md) for the
responsible-disclosure process, and [DECISION.md](../DECISION.md) for
architectural rationale.

This is a living document. It is reviewed quarterly and updated whenever
a cryptographic primitive changes, the architecture changes materially,
or a newly-disclosed adversary capability affects the model. Material
updates are noted in `CHANGELOG.md` and called out in the next
`TRANSPARENCY.md` update.

## Assets we protect

The following assets are within scope of the threat model:

- **Message content.** End-to-end encrypted among up to six
  participants per room. Neither the partner-edge node nor the OxPulse
  control plane possesses the keys to decrypt message content.

- **Real-time media streams.** Audio, video, and screen-share streams
  are SRTP-encrypted (1:1 mesh calls) or SFrame-encrypted (group calls
  through the SFU). The SFU forwards encrypted frames without
  decryption.

- **Connection metadata at the partner-edge boundary.** Room IDs,
  partner IDs, timestamps, byte counters, and ICE candidate addresses
  are visible at the edge. We document this exposure explicitly rather
  than claiming zero metadata leakage. The design minimizes metadata
  to what is operationally necessary for call routing.

- **Partner node operator identity.** Minimized by default — operators
  are not visible to other partners unless they opt in to public
  listing. The control plane holds the mapping between partner IDs and
  operator identities.

- **Mesh topology and trust-score state.** Held by the control plane,
  not exposed to individual partner nodes. A compromised partner cannot
  enumerate the full mesh.

## Adversary classes

### Class A: network-level filtering infrastructure

**Capabilities.** Deep packet inspection (DPI), TLS fingerprinting at
scale, machine-learning traffic classification, active probing of
suspected proxy IP addresses, and dynamic IP/domain blocking.

**Operators.** National filtering systems deployed in Russia (ТСПУ /
TSPU), Iran, China (GFW), Belarus, and Cuba (ETECSA). These systems operate at ISP
level with state backing and can be updated rapidly in response to new
circumvention techniques.

**Motive.** Prevent users from reaching communication services that
operate outside state surveillance frameworks. Blocking is the primary
goal; decryption of content is secondary to preventing access entirely.

### Class B: coerced infrastructure

**Capabilities.** Legal compulsion of ISPs and certificate authorities
operating within filtering jurisdictions. This includes court-ordered
traffic redirection, compelled TLS interception via trusted root
certificates, and forced DNS poisoning.

**Operators.** ISPs and CAs subject to legal regimes that can compel
cooperation without public disclosure.

**Motive.** Enable targeted surveillance of specific users or degrade
the trust properties of encrypted connections within a jurisdiction.

### Class C: compromised partner operator

**Capabilities.** A node operator who is coerced, compelled, or who
voluntarily turns hostile. The compromised operator has full access to
the partner-edge node, including container logs, network captures, and
configuration files. They can attempt to deanonymize participants,
harvest metadata, or disrupt service.

**Motive.** Extract identifying information about users routing through
the node, or inject disruption to undermine trust in the mesh.

### Class D: passive global observer

**Capabilities.** Long-term traffic recording at scale, with the intent
to decrypt recorded traffic in the future if cryptographic primitives
weaken or quantum computing advances reach the necessary capability.

**Motive.** Record-now-decrypt-later. This adversary is patient and
well-resourced, collecting encrypted traffic flows today against the
possibility of future decryption.

## Mitigations per class

### Class A mitigations

- **VLESS + Reality + XHTTP transport.** The xray-client tunnel
  presents as standard HTTPS traffic to network-level observers. The
  Reality protocol uses the TLS certificates of legitimate domains,
  making the tunnel indistinguishable from genuine traffic to those
  domains. Configuration: `xray-client.json.tpl`.

- **ML-KEM-768 post-quantum encryption.** The tunnel layer uses
  ML-KEM-768 (NIST FIPS 203) on the xray connection, providing
  resistance to future quantum decryption of recorded tunnel traffic.

- **8-name SNI pool, daily per-node rotation.** The tunnel's server name indicator rotates across a pool of eight major-brand HTTPS domains supplied by the control plane (5 Samsung subdomains plus 3 Microsoft 365 subdomains — Outlook, Teams, login.microsoftonline). Per-node selection is deterministic via `sha256(node_id : YYYY-MM-DD) mod pool_size` and re-evaluated daily by a systemd timer at 04-06 UTC randomised. No two partner-edges look identical to a network observer correlating across nodes, and a node's SNI is non-stationary across days. Reduces the effectiveness of static SNI-based blocking rules and increases the cost of any single-brand block. Implemented in `oxpulse-partner-edge-sni-rotate.sh`.

- **Deterministic per-node SNI selection.** Each node selects its SNI
  value deterministically via `sha256(node_id)`, ensuring that the
  (IP, SNI) tuple is unique per node. This diversification prevents a
  single blocking rule from disabling multiple nodes simultaneously.

- **Cover page with active-probing defense.** Direct HTTP requests to
  the partner-edge domain receive a static cover page. The `@probe`
  Caddy matcher identifies and deflects active-probing attempts that
  filtering infrastructure uses to confirm proxy endpoints. Source:
  `cover/` directory and `Caddyfile.tpl`.

### Class B mitigations

- **AGPL transparency.** The full partner-edge source is publicly
  auditable. Partners and third parties can verify that no backdoor or
  covert interception mechanism exists in the open-source components.

- **Reproducible builds.** On the roadmap (not yet implemented). Once
  complete, partners will be able to verify that released container
  images match the published source.

- **Warrant canary.** Published in `TRANSPARENCY.md` and updated
  quarterly. Tracks whether OxPulse has received National Security
  Letters, FISA court orders, or requests to insert backdoors.

- **US legal jurisdiction.** OxPulse is being incorporated as a US
  Delaware C-Corp; the operating entity is subject to US legal process,
  which requires judicial oversight for surveillance orders. This is
  documented transparently, not presented as absolute protection.

- **Minimal data retention.** The partner-edge node does not store call
  content, participant identities, or session logs beyond what is
  necessary for real-time operation. Operational metadata (byte
  counters, health checks) is retained locally on the partner's own
  infrastructure.

### Class C mitigations

- **No plaintext exposure.** Even with full access to the partner-edge
  node, a compromised operator cannot decrypt media or message content.
  SFrame keys are negotiated end-to-end between participants and never
  transit through the edge node.

- **Control-plane trust scoring.** The OxPulse control plane
  continuously evaluates partner node behavior. Anomalous patterns
  (unusual traffic volumes, configuration deviations, connectivity
  irregularities) trigger trust-score degradation and, at threshold,
  automated disconnection from the mesh.

- **Automated disconnect.** Nodes that fall below the trust-score
  threshold are removed from active rotation automatically. Users are
  rerouted to other nodes without disruption.

- **Limited blast radius.** Each partner node receives independent
  credentials. Compromise of one node does not yield credentials or
  key material for any other node in the mesh.

### Class D mitigations

- **ML-KEM-768 forward-secrecy layer.** The post-quantum encryption on
  the tunnel transport ensures that recorded ciphertext cannot be
  decrypted even if classical key-exchange algorithms are broken by
  future quantum computers.

- **Ratchet key exchange with regular re-keying.** Group media keys use
  a ratchet-based key exchange (X25519 + ChaCha20-Poly1305) with
  periodic re-keying. Compromise of a single session key does not
  compromise past or future sessions.

- **No long-term plaintext storage.** No layer of the system stores
  plaintext content persistently. Call content exists only in memory
  during active sessions.

## Mesh underlay (AmneziaWG)

Partner-edges optionally form a layer-3 mesh between themselves over
AmneziaWG, an obfuscated WireGuard fork ([github.com/amnezia-vpn/amneziawg-go](https://github.com/amnezia-vpn/amneziawg-go))
that adds packet-shape randomization, junk-packet injection, and
configurable handshake-magic obfuscation to defeat WireGuard
fingerprinting at the DPI layer. The mesh is used for cascade-relay
hand-off (Phase 7 SFU relay) and inter-partner control-plane
heartbeats; it does **not** carry user media. SRTP frames remain
end-to-end encrypted client-to-client and would not be decryptable by
a compromised mesh peer.

**Adversaries and properties:**

- *Class A (network filtering).* AmneziaWG is the project's primary
  defense against WireGuard-handshake fingerprint blocking observed in
  Russian and Iranian DPI in 2024–2026. Each partner-edge derives
  AmneziaWG `Jc/Jmin/Jmax/S1/S2/H1..H4` parameters per node from the
  control-plane registration response, so no two partner-edges share
  the same wire-shape signature.
- *Class C (compromised partner operator).* A hostile partner that
  joins the mesh sees only encrypted partner-to-partner control
  packets and other partner-edges' source IPs. They do not see user
  media (different cryptographic boundary) and they cannot inject
  arbitrary peers (mesh peers are explicitly enumerated by the
  control-plane registration; AmneziaWG enforces the static peer
  set). The trust-scoring pipeline (Class C mitigations above) treats
  AmneziaWG-layer anomalies (excessive heartbeat misses, peer-count
  drift, unexpected cross-mesh traffic) as input signals.
- *Class D (passive global observer).* AmneziaWG headers are
  per-deployment-randomized, but a sufficiently capable global
  observer with traffic-analysis capability can in principle correlate
  encrypted flows by volume and timing. We do not claim resistance to
  this class for the mesh layer; user media is end-to-end encrypted
  independently of the mesh.

**Out of scope for the mesh layer:** anonymizing the existence of the
inter-partner connection itself. A peer in the mesh is a known
operator with a registered public key; we do not attempt to hide the
fact that two partner-edges are talking to each other. We do hide
*what* they are saying (encrypted) and *what protocol the link runs*
(AmneziaWG vs. plain WireGuard).

## Out of scope (residual risk)

The following risks are acknowledged but are outside the protection
boundary of the partner-edge system:

- **Compromised endpoint devices.** Malware on a user's phone or
  laptop defeats end-to-end encryption at the endpoint. OxPulse
  encrypts data in transit and at the application layer, but cannot
  protect against a compromised operating system or keylogger on the
  user's device.

- **Traffic-analysis-grade anonymization.** OxPulse is not Tor. Content
  is protected by end-to-end encryption, but transport-layer metadata
  (connection timing, packet sizes, IP addresses) is not anonymized
  beyond standard TLS. An observer who can see both ends of a
  connection can correlate them by timing analysis.

- **Social engineering of partner operators.** The trust-scoring system
  can detect behavioral anomalies, but cannot prevent an operator from
  being socially engineered into actions that do not manifest as
  detectable technical deviations.

- **Legal compulsion of the OxPulse operating entity.** OxPulse is
  being incorporated as a US Delaware C-Corp and will be subject to
  standard US legal process (subpoenas, court orders, National Security
  Letters). The warrant canary in `TRANSPARENCY.md` tracks this risk.
  The system is designed so that even under compulsion, the operating
  entity cannot decrypt end-to-end encrypted content — it does not
  possess the keys.

- **Compromise of upstream cryptographic libraries.** OxPulse depends
  on established libraries (libsodium, ring, xray-core, str0m). A
  vulnerability in these dependencies would affect OxPulse. We track
  CVEs and apply updates following the standard release process
  documented in `SECURITY.md`.

## Cryptographic primitives in use

| Use | Primitive | Source |
|---|---|---|
| Real-time media (1:1 mesh) | DTLS-SRTP, AES-128-GCM | WebRTC standard |
| Group media (3–6 SFU rooms) | SFrame + ratchet KX | IETF Proposed Standard RFC 9605 (2025) |
| Ratchet key exchange | X25519 + ChaCha20-Poly1305 | libsodium / ring |
| Post-quantum tunnel layer | ML-KEM-768 | xray 26.x (NIST FIPS 203) |
| Tunnel transport | VLESS + Reality + XHTTP | xray-core |
| Mesh underlay (partner ↔ partner) | AmneziaWG (WireGuard + obfuscation params) | amnezia-vpn/amneziawg-go |
| TLS / ACME | Caddy auto-TLS | TLS 1.3 (RFC 8446) |

## Assumptions

- Adversary cannot break standard cryptographic primitives under
  standard hardness assumptions (X25519, AES-128-GCM, ML-KEM-768).

- Adversary can compel some ISPs and certificate authorities within
  filtering jurisdictions but cannot compel all global infrastructure
  simultaneously.

- Adversary can run active probes against suspected proxy IP addresses
  but cannot break TLS 1.3 with current parameters.

- Partner operators are honest by default. The trust-scoring system
  detects and responds to behavioral drift over time, but does not
  assume adversarial intent from the outset.

## Document maintenance

- Reviewed quarterly, aligned with the `TRANSPARENCY.md` update cycle.
- Updated on any cryptographic primitive change, any architectural
  change, or any newly-disclosed adversary capability that materially
  affects the model.
- Material changes are summarized in `CHANGELOG.md` and called out in
  the next `TRANSPARENCY.md` update.
