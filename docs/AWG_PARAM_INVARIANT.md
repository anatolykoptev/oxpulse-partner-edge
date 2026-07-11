# AmneziaWG obfuscation-param invariant

**TL;DR — all partner-edges must use BYTE-IDENTICAL `Jc/Jmin/Jmax/S1/S2/S4/H1..H4/I1..I5` values, or the data plane silently drops decrypted frames while WireGuard handshake keeps succeeding.**

This invariant is load-bearing. A single-byte drift between any two
peers makes their link look "up" (regular handshake, peer counters
advancing, no errors logged) while plaintext IP packets never reach
the kernel `awg0` interface on either side. The failure is
indistinguishable from intermittent connectivity to an operator who
doesn't know to look for it.

## What the params are

AmneziaWG adds packet-shape obfuscation to WireGuard via several
session-wide parameters (set on `[Interface]` in `awg0.conf`):

| Field | Purpose |
|---|---|
| `Jc` | junk-packet count per handshake |
| `Jmin`, `Jmax` | min/max size of injected junk |
| `S1`, `S2`, `S4` | packet-shape signatures (pcap-fingerprint defense) |
| `H1` … `H4` | handshake-magic hashes (replace WireGuard's fixed magic with per-deployment values) |
| `I1` … `I5` | optional init-packet patterns (some deployments use, some omit) |

WireGuard's handshake protocol does NOT consume these — it is pure
cryptography over UDP, so handshake succeeds with any param choice on
either side. The DATA frames carry the obfuscation; receiver decodes
using its own `[Interface]` params. If sender and receiver disagree
on even one byte, the decoded frame is rejected as malformed and
**silently dropped**. By design — silent drop is what defeats DPI.

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

1. **Server-side `awg0.conf` is the source of truth.** All other
   partners derive their params from the registration response that
   `register.rs` issues. Whatever the server has, partners must have.
2. **Server-side params MUST NOT change after the first partner is
   installed**, unless the operator immediately reissues registration
   to every existing partner. If you regenerate `Jc/S4/H1..H4`
   without re-onboarding all partners, every existing partner becomes
   unreachable on the mesh data plane within the next handshake
   cycle.
3. **The installer (`install.sh` → `lib/install-awg.sh` →
   `configure_amneziawg`) MUST write the param values it received in
   the registration response verbatim**, no re-randomization, no
   fallback defaults, no rounding. This is enforced by `awg_extract`
   in `install.sh` plus the literal `${AWG_S4}` template substitution
   in `lib/install-awg.sh` — do not introduce computed values in this
   path.

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
sections) means partner params drifted from server. The fix is to
edit the partner's `/etc/amnezia/amneziawg/awg0.conf` to match the
server, then `awg-quick down awg0 && awg-quick up awg0`.

## When you'd rotate params (and how)

Rotating obfuscation params is a real operation — for example, if a
specific `Jc/S1` combination starts getting detected by a new DPI
rule. The correct procedure is:

1. Compute new param values once (cryptographically random within
   AmneziaWG's accepted ranges).
2. Update server-side `awg0.conf`.
3. **Simultaneously** push new registration responses to every
   existing partner via `awg_params_epoch_added` NOTIFY pipeline (see
   `cmd/orchestrator/awg_params.go`). The orchestrator's
   `applyAwgParamsToConf` writes the new `[Interface]` block on the
   server side; partner-edge `update.sh` must apply the same on
   every partner.
4. Restart `awg0` on the server **last**, after all partners have
   acked the new epoch. Otherwise partners hit drift between the
   server's restart and their own update.

This pipeline exists in `cmd/orchestrator/awg_params.go` — read
that file before considering a manual rotation, and never
hand-edit `awg0.conf` on the server without also walking the
update pipeline.

## Related

- `docs/THREAT-MODEL.md` § "Mesh underlay (AmneziaWG)" — Class A/D
  adversary model.
- `cmd/orchestrator/awg_params.go` — the rotation pipeline this
  document's invariant is the constraint on.
- `lib/install-awg.sh` — caller-globals contract for `AWG_S4` etc.
- 2026-05-20 edge-b.example mesh outage post-mortem (operator's internal ops runbook).
