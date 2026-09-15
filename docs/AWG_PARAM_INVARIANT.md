# AmneziaWG obfuscation-param invariant

**TL;DR — every partner-edge must run BYTE-IDENTICAL `S1–S4`, `H1–H4`, `HeaderProtectionKey`, and `RandomTrailers` state to motherly's live `awg0.conf`, or the data plane silently drops decrypted frames while the WireGuard handshake keeps succeeding. The client-side set (`Jc/Jmin/Jmax`, `I1–I5`, `ContentPaddingAddition`, timings, `DisableCookies`, `PersistentKeepalive`) is exempt — those params may differ per edge. See "Sidedness" below.**

This invariant is load-bearing. A single-byte drift between any two
peers on a MUST-MATCH param makes their link look "up" (regular
handshake, peer counters advancing, no errors logged) while plaintext
IP packets never reach the kernel `awg0` interface on either side. The
failure is indistinguishable from intermittent connectivity to an
operator who doesn't know to look for it.

## What the params are

AmneziaWG adds packet-shape obfuscation to WireGuard via several
session-wide parameters (set on `[Interface]` in `awg0.conf` unless
noted):

| Field | Side | Purpose |
|---|---|---|
| `S1` – `S4` | must-match | packet-shape signatures (pcap-fingerprint defense); `S3` added in AWG 3.1 |
| `H1` … `H4` | must-match | handshake-magic values replacing WireGuard's fixed magic; single `123` or range `x-y` |
| `HeaderProtectionKey` | must-match | 32-byte symmetric key XORing the packet-header type field (AWG 3.1) — a mismatch blackholes even the handshake |
| `RandomTrailers` | must-match | random trailer padding (AWG 3.1); receivers apply an exact-size gate, so mixed state is wire-dead |
| `Jc`, `Jmin`, `Jmax` | client-side | junk-packet count and min/max size of injected junk |
| `I1` … `I5` | client-side | optional init-packet patterns (`<b 0x..><r N>...` tag literals) |
| `ContentPaddingAddition` | client-side | extra padding band, `a-b` range |
| `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts` | client-side | handshake-timing ranges |
| `DisableCookies` | client-side | disables the inbound under-load cookie path — inert on outbound-only spoke edges |
| `PersistentKeepalive` | client-side, `[Peer]`-scoped | keepalive interval (static 25 on edges) |

WireGuard's handshake protocol does NOT consume these — it is pure
cryptography over UDP, so handshake succeeds with any param choice on
either side. The DATA frames carry the obfuscation; receiver decodes
using its own `[Interface]` params. If sender and receiver disagree
on even one byte of a must-match param, the decoded frame is rejected
as malformed and **silently dropped**. By design — silent drop is what
defeats DPI. (`HeaderProtectionKey` is the one partial exception: it
protects the header type field, so a mismatch blackholes the handshake
too — a louder, but still total, failure.)

## Sidedness — why the exemption is safe

Upstream (amneziawg-go) treats the client-side set as sender-local:
junk counts, I-tag patterns, padding and timing ranges shape what THIS
peer emits; the receiver does not need matching values to decode. The
must-match set is different in kind — S-fields are exact-size packet
envelopes, H-values are the header magic both directions check, HPK
XORs the type field both directions, and RandomTrailers changes the
expected frame size outright.

Today the client-side set is still centrally emitted for uniformity —
the register response and epochs carry `Jc/Jmin/Jmax` (and optionally
`I1`/`ContentPaddingAddition`), and the installer still requires the
jc trio non-empty. Phase E moves generation of `Jc/Jmin/Jmax`/`I1`/
`ContentPaddingAddition` to per-edge agents; the exemption above is
what makes that safe. The full sourcing table and per-field types are
normative in `docs/adr/ADR-004-awg31-central-contract.md`.

## Empirical reproduction (2026-05-20)

- Server (`motherly`) awg0: `S4 = 18`.
- Partner (edge-b.example) awg0: `S4 = 17` (drifted at install time).
- WireGuard handshake: refreshing every 25s (PersistentKeepalive).
- Encrypted bytes transferred: 16 MiB motherly→partner, 274 KiB ←.
- Plaintext on partner `/proc/net/dev awg0`: rx_packets = **0** since boot.
- `ping 10.9.0.6 -I awg0` from motherly: 100% loss for 24+ hours.

Fix: `sed -i 's/^S4 = 17$/S4 = 18/'` + `awg-quick down/up awg0` on
edge-b. Ping recovered immediately to 0% loss, 175ms RTT.

## What MUST be true

1. **Motherly's live `awg0.conf` is the source of truth for the
   must-match set.** Edges derive those params from the registration
   response and from `awg_params_epoch` updates — which are themselves
   generated FROM motherly's live conf, never independently (ADR-004,
   linchpin clause). Whatever the server has, partners must have.
2. **Must-match params MUST NOT change on motherly outside the epoch
   pipeline**, and every such change — enable or disable — follows the
   motherly-first flip order (see "Rotation" below). If you regenerate
   `S4`/`H1..H4`/`HeaderProtectionKey` without an epoch reaching all
   partners, every existing partner becomes unreachable on the mesh
   data plane within the next handshake cycle.
3. **The installer (`install.sh` → `lib/install-awg.sh` →
   `configure_amneziawg`) MUST write the param values it received in
   the registration response verbatim**, no re-randomization, no
   fallback defaults, no rounding. This is enforced by `awg_extract`
   in `install.sh` plus the literal `${AWG_S4}` template substitution
   in `lib/install-awg.sh` — do not introduce computed values in this
   path. (Client-side params are the defined exception: the
   awg-params-agent may generate defaults for keys absent from both
   epoch and conf — never for must-match keys.)
4. **Removing a previously-set param needs an explicit zero form —
   omission never clears.** `awg syncconf` emits only `HAS_`-flagged
   fields, and the agent merge treats absent keys as preserve, so a
   param that simply disappears from the epoch leaves the stale value
   live on every edge forever. Remove-signals: `S3 = 0`,
   `RandomTrailers = off`, `HeaderProtectionKey = <base64 of 32 zero
   bytes>`. The register surface may omit instead (it renders a
   complete file, where absent = off) — the asymmetry and its
   rationale are normative in ADR-004.
5. **Both writers serialize on the same lock.** The installer and the
   awg-params-agent both write `awg0.conf` under an advisory flock on
   `<conf>.lock` plus atomic tmp+rename; hand edits must respect the
   same protocol or risk a torn conf racing an agent tick.

## Verification after partner install

The installer SHOULD run a post-install reachability check:

```bash
ping -c 3 -W 2 -I awg0 "${AWG_MOTHERLY_AWG_IP}"
```

If this fails post-install but `awg show awg0` shows a recent
handshake (< 60s), the param invariant is violated. Compare
parameters byte-by-byte:

```bash
diff <(ssh motherly 'sudo awg show awg0 | grep -E "^  [jshi]"') \
     <(sudo awg show awg0 | grep -E "^  [jshi]")
```

Any non-zero diff between the two `awg show` outputs (excluding peer
sections) means partner params drifted from server — while everything
is still centrally emitted, that is; post-Phase-E, diffs confined to
the client-side set are expected and only must-match diffs indicate a
violation. The fix is to
edit the partner's `/etc/amnezia/amneziawg/awg0.conf` to match the
server, then `awg-quick down awg0 && awg-quick up awg0`.

## When you'd rotate params (and how)

Rotating obfuscation params is a real operation — for example, if a
specific `S1/H` combination starts getting detected by a new DPI
rule, or HPK handling requires a re-key. For the MUST-MATCH set the
correct procedure is:

1. Compute new param values once (within the wire preconditions:
   `S1+56 ≠ S2`, H bands pairwise non-overlapping ≤ 2³¹−1,
   HPK ⇒ all S1–S4 ≥ 12 — ADR-004 Decision 2).
2. **Update motherly's `awg0.conf` and restart it FIRST.** This is
   the motherly-first flip rule, and it supersedes the earlier
   "restart the server last" guidance: every mixed must-match state
   is wire-dead (HPK de-XORs garbage both directions; S-fields are
   exact-size envelopes; an RT-on peer still SENDS trailers that
   RT-off receivers drop), so no ordering avoids the blackout — only
   its duration is controllable. Motherly-first bounds it to ~one
   poll interval because the control plane (HTTPS epoch poll) is
   off-mesh and unaffected by the dead data plane; edges-first leaves
   the whole fleet dark until a human restarts motherly.
3. **Then publish a dedicated single-purpose epoch** (one must-match
   flip per epoch). Edges converge on their next ~30s poll as they
   fetch the already-published values.
4. Keep the previous epoch's values on hand; revert = publish a NEW
   epoch carrying the old values + re-flip motherly. Rehearse this
   before any cutover.

This pipeline exists in `cmd/orchestrator/awg_params.go` — read
that file before considering a manual rotation, and never
hand-edit `awg0.conf` on the server without also walking the
update pipeline.

Client-side params need no ordering — they may legitimately differ
per edge, so a stale value degrades shaping diversity, never the link.

## DisableCookies residual

`DisableCookies` gates only the inbound under-load cookie path, which
is inert on outbound-only spoke edges — and edges do NOT default it
on: absent = cookies enabled = the DoS mitigation is kept for free.
If central ever emits `disable_cookies: true` fleet-wide (upstream
recommends it client-side — cookie replies are a DPI fingerprint),
the residual is flood-exposure on each edge's publicly reachable
`ListenPort`: a fake-initiation flood then costs full handshake CPU
work with no cookie throttling. `peer_roster` exists — edge-to-edge
peering would make the path live and change the calculus. Keep it an
epoch Option so the posture can be reverted centrally.

## Related

- `docs/adr/ADR-004-awg31-central-contract.md` — normative central
  contract: per-surface field/type tables, zero-form remove-signals,
  schema=2 capability gate, installer floor, motherly-first flip
  mechanics, HPK handling.
- `docs/THREAT-MODEL.md` § "Mesh underlay (AmneziaWG)" — Class A/D
  adversary model.
- `cmd/orchestrator/awg_params.go` — the rotation pipeline this
  document's invariant is the constraint on.
- `lib/install-awg.sh` — caller-globals contract for `AWG_S4` etc.
- 2026-05-20 edge-b.example mesh outage post-mortem (operator's internal ops runbook).
