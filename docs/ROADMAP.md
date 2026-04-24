# oxpulse-partner-edge — Security & Operations Roadmap

> Production edge SFU bundle. Roadmap covers security hardening, compliance,
> and operational excellence for regulated industries (healthcare, legal, government).

---

## ✅ Phase 0 — Foundation (shipped v0.7.x / v0.8.x)

- oxpulse-sfu-kit migration: -1,881 lines of inlined code replaced by audited library
- Cascade relay client: `POST /relay/connect`, str0m offerer, `relay_source` DC
- release-please automated CHANGELOG + CI
- 3-node deployment: krolik (SJC), rvpn (R-VPN partner), piter (SPB)

---

## ✅ Phase 1 — Security Hardening (shipped 2026-04-24)

*Closed all CRITICAL/HIGH findings from internal security audit.*

| Finding | Fix |
|---------|-----|
| SSRF via unsigned upstream_url | JWT fields only, allow-list |
| Default `RELAY_JWT_SECRET` | Startup validation, refuses placeholder |
| DC relay_source without auth | `SIGNALING_SFU_SECRET` verification |
| JWT replay (no JTI) | JTI nonce store, 409 on duplicate |
| TURN TTL 24h | Reduced to 1h |
| Homegrown HMAC/base64 JWT | Migrated to `jsonwebtoken` RFC 7519 |
| Upstream allow-list in relay client | `wss://*.oxpulse.chat` only |

---

## Phase 2 — FIPS 140-3 + Asymmetric Auth  ·  Q3 2026

*Required for US federal procurement and HIPAA regulated clients.*

- **FIPS 140-3 provider** (`aws-lc-rs`) — all crypto through validated module
- **Ed25519 mTLS between edges** — each node has keypair; shared secret eliminated
- **Asymmetric room token signing** — signaling holds private key, edges hold public key only
- **WebAuthn/FIDO2 for admin console** — hardware-backed MFA, phishing-resistant

---

## Phase 3 — Key Transparency + MLS  ·  Q4 2026

*Cryptographic proof of key integrity; group forward secrecy.*

- **Key Transparency log** — Merkle log of SFrame public keys; clients verify MITM-free
- **MLS (RFC 9420) group key management** — O(log N) RotateKey, forward secrecy
- **Post-quantum MLS** — XWING hybrid (X25519 + ML-KEM-768)
- **SOC 2 Type II** audit preparation

---

## Phase 4 — Operator-Blind Execution  ·  2027

*Even oxpulse.chat infrastructure cannot read call content.*

- **Confidential Computing** — SFU runs inside Intel TDX / AMD SEV-SNP enclave
- **Remote attestation** — clients verify SGX/TDX measurement before sending media
- **Media over QUIC** — replace DTLS 1.2/SRTP; post-quantum TLS 1.3 natively

---

## go-pentest Coverage Plan

WebRTC security test suite (planned, separate session):

| Tool | Tests |
|------|-------|
| `sfu_room_auth_probe` | Unauthenticated SFU join (CRITICAL-3 class) |
| `relay_jwt_forge_probe` | Default secret + replay + SSRF |
| `dtls_cipher_probe` | DTLS version + weak ciphers |
| `sframe_integrity_probe` | Verify media payload is opaque |
| `turn_abuse_probe` | RFC1918 relay amplification |
| `vless_reality_probe` | TLS fingerprint + tunnel entropy |
