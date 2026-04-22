# Architectural Decision — 2026-04-18

## TURNS-on-:443 SNI multiplex pattern

**Chosen: Variant A' (caddy-l4 with unified TLS + L4 passthrough in one Caddy process).**

## Rationale

Per PoC decision gate (Phase 2 of `docs/superpowers/plans/2026-04-18-turns-on-443.md`),
both variants were scaffolded + measured empirically. Results at
`deploy/partner-edge/poc/results.md`.

Summary:

| Criterion | A' | B | Decision impact |
|---|---|---|---|
| C1 — Caddyfile / nginx.conf parses with SNI routing directive | PASS | PASS | Both technically viable |
| C2 — HTTP/3 (UDP 18443) closed | PASS | PASS | Neutral |
| C3 — Cert reload via SIGUSR2 | FAIL (PoC artifact) | FAIL (PoC artifact) | Both need systemd path unit in Phase 3 |
| C4 — TLS handshake on both SNIs | PASS | PASS | Both route SNI correctly |
| C5 — HTTPS latency p50 | FAIL (5.21ms bridge) | FAIL (7.40ms bridge) | A' marginally better |

## Reasons A' wins

1. **Fewer moving parts in production compose**: A' = 1 Caddy container owning :443.
   B = nginx sidecar + Caddy on :8443 + coturn = 3 containers total, coordinated startup,
   additional failure domain.
2. **Install-step parity**: both variants deliver zero new manual steps for the partner
   (install.sh image-pull path unchanged). But the maintenance surface differs — one
   less Docker image to keep updated with A'.
3. **Performance**: A' measured p50 = 5.21ms vs B p50 = 7.40ms in PoC. In production
   host-network topology both will be sub-millisecond, but the directional advantage
   is A'.
4. **Pattern alignment**: A' matches LiveKit's `external_tls: true` conceptual model
   (proxy owns cert, single TLS stack visible from outside). B leaves coturn's
   OpenSSL TLS stack visible alongside Caddy's Go TLS stack — two JA3S fingerprints
   on one IP:443. Residual ТСПУ risk is accepted but A' has lower surface.
5. **Upstream alignment**: the Caddy 2.11 + caddy-l4 v0.1.0 stack is current and
   maintained by mholt (Caddy author). Not abandoned.

## Residual risks accepted

- **caddy-l4 v0.1.0** is marked "breaking changes may occur" upstream. We pin the
  exact version in `Dockerfile.caddy`. If upstream v0.2 breaks the API, partner-edge
  image stays on v0.1.0 until we re-validate.
- **Dual TLS stacks (Caddy + coturn) under A' passthrough**: Caddy peeks SNI,
  forwards raw bytes to coturn which terminates its own TLS. Two fingerprints
  on same IP keyed by SNI. Not current ТСПУ doctrine to fingerprint server-side
  JA3S-per-SNI, but documented as residual. Multi-SNI rotation (design §5.4)
  is the blast-radius escape if ТСПУ ever adds this rule.

## Pivot path

If production Phase 3A reveals caddy-l4-specific issues (e.g., HTTP/3 fallthrough
regression in future Caddy releases, or a plugin bug we can't route around), the
implementation plan has Phase 3B pre-written with Variant B task list. The pivot
cost is ~1 dev-day, not a full redesign.

## What unblocks now

- **Phase 3A execution** in the implementation plan can begin.
- **Phase 3B** stays in the plan as documented fallback but is not actively scheduled.

## Evidence

- PoC sandbox: `deploy/partner-edge/poc/`
- Measurement script: `deploy/partner-edge/poc/measure.sh`
- Full results: `deploy/partner-edge/poc/results.md`
- Commits on this decision: `607c59f` (scaffold), `6d11772` (README fixup),
  `18b6d55` (initial run + blocker discovery), `1f391e3` (blocker fixes + rerun),
  `c7b2cc0` (A' Caddyfile fix + final verdict).

## Decision maker

Anatoly Koptev, via senior-subagent-driven PoC. Advisor review pre-committed
to design doc.
