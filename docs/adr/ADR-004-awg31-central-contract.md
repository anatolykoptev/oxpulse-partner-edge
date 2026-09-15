# ADR-004 — AWG 3.1 Central Contract (motherly repo)

**Status:** Accepted (P0, 2026-09-15) — normative for the central ("motherly") repo; edge-side conformance ships in the same plan's implementation phases.
**Scope:** The contract between the partner-edge fleet and the central orchestrator for AmneziaWG 3.1 obfuscation params: epoch JSONB schema, register projection, awg0.conf spelling, capability gating, cutover ordering, HPK handling.
**Supersedes:** the restart-last rotation ordering in `docs/AWG_PARAM_INVARIANT.md`, for must-match changes only (see "Flip rule" — the old ordering maximizes the outage window).
**Related:** ADR-002 (state schema — a different "schema" axis, see disambiguation below).

## Context

AmneziaWG 3.1 (edge pins: amneziawg-go `v3.1.20260828`, amneziawg-tools `v3.1.20260812`) adds anti-DPI params beyond the v1 set: S3, H1–H4 ranges, HeaderProtectionKey (HPK), I2–I5, ContentPaddingAddition, five timing ranges, RandomTrailers, DisableCookies.

This ADR is the handoff artifact for the motherly-repo implementer: every endpoint, field name, and type the edge fleet conforms to is pinned here, so the central half can be implemented without reading this repo.

Three data-plane facts drive every rule below:

- WireGuard's handshake ignores all obfuscation params; the DATA frames carry them. A param mismatch looks "up" (handshakes refresh, peer counters advance, nothing logged) while plaintext is silently dropped — the 2026-05-20 RCA in `docs/AWG_PARAM_INVARIANT.md`.
- `awg syncconf` emits only `WGDEVICE_HAS_*`-flagged fields (upstream `ipc-uapi.h`) — omission NEVER clears a kernel param. Removal needs an explicit zero form (Decision 3).
- Every mixed must-match state is wire-dead in at least one direction (Decision 6). There is no ordering that avoids the blackout — only its duration is controllable.

## Surfaces and endpoints

| Surface | Transport | Direction |
|---|---|---|
| **Epoch** | `awg_params_epoch.params` JSONB, served by `GET /api/partner/awg-params/latest?component=awg&schema=N` as `{"epoch": <i64, monotonic BIGINT>, "params": {...}}` | central → each edge's awg-params-agent (30s poll, per-node bearer token) |
| **Applied report** | `POST /api/partner/awg-params/applied` body `{"component":"awg","epoch":<i64>}` | edge → central, best-effort after a successful apply |
| **Register** | `POST /api/partner/register` response `awg` object (present only when motherly's AWG pubkey is configured AND the edge sent its `awg_pubkey`); request header `X-Installer-Version: <release>` | central → installing edge, once |
| **Conf** | `/etc/amnezia/amneziawg/awg0.conf` on each peer, `Key = value` | rendered independently on motherly and every edge — the thing the epoch and register surfaces must keep coherent |

## Decision 1 — Epoch `params` field table (v2 superset)

PascalCase keys. The v1 set (Jc/Jmin/Jmax/S1/S2/S4/H1–H4/I1) is extended; everything new is optional so old rows and old agents decode unchanged (edge agents ignore unknown keys — additive-only is safe in both directions).

| Key | JSON type | Presence | Class |
|---|---|---|---|
| `S1`, `S2`, `S4` | number (i64) | **required** every epoch | must-match |
| `S3` | number (i64) | optional; `0` = remove-signal | must-match |
| `H1`–`H4` | **IntOrRange**: `123` or `"123-456"` | **required** every epoch | must-match |
| `HeaderProtectionKey` | string, base64 of 32 bytes (`awg genkey` output) | optional; base64(32 zero bytes) = remove-signal | must-match |
| `RandomTrailers` | boolean | optional; `false` = remove-signal | must-match |
| `Jc`, `Jmin`, `Jmax` | number (i64) | optional in v2 (required in v1) | client-side |
| `I1`–`I5` | string, I-tag literal `<b 0x..><r N><rd N><rc N><t>` | optional; `""` decodes as absent | client-side |
| `ContentPaddingAddition` | string range `"lo-hi"` | optional | client-side |
| `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout` | string range `"lo-hi"` (seconds) | optional | client-side |
| `MaxHandshakeAttempts` | string range `"lo-hi"` (count) | optional | client-side |
| `DisableCookies` | boolean | optional | client-side |

Representation rules a motherly implementer MUST match:

- **IntOrRange is an untagged union**: a JSON number for a single value, a JSON string `"lo-hi"` for a range. NOT an array, NOT an object. A range written as a bare numeric string (`"123"`) is out of contract — emit the number `123` for the degenerate case.
- **Option semantics**: absent = preserve the edge's existing value; present = validate + replace-or-insert. There is NO delete path. An explicit JSON `null` deserializes as absent (preserve) — `null` is NOT a remove-signal; use the zero forms in Decision 3.
- **Booleans on the wire are JSON `true`/`false`**; the conf rendering is `on`/`off` (upstream `parse_bool` also accepts `0`/`1`, but `on`/`off` is the canonical spelling).
- **No conf-destined string may contain `\n`, `\r`, `[`, `]`** — those are the injection primitives (a newline + `[Peer]` splices an attacker peer into the kernel peer table). Edges enforce this at their merge/render choke points and will drop the offending value; central MUST NOT emit them in the first place.
- Epoch numbers strictly increase. Reverting to previous values means a NEW epoch number carrying the old params — never reuse a number (edges apply only on `epoch > last_seen`).

### Register `awg` object (snake_case projection)

The same value source projected with snake_case keys; types carry over unchanged (numbers stay numbers, range strings stay `"lo-hi"`, bools stay JSON bools, HPK stays base64). Absent params MAY be omitted entirely — full-file render semantics, see Decision 3 for why omission is safe here but not on the epoch surface.

| register key | epoch key | class / notes |
|---|---|---|
| `s1`, `s2`, `s4` | `S1`, `S2`, `S4` | must-match; required today |
| `s3` | `S3` | must-match; optional |
| `h1`–`h4` | `H1`–`H4` | must-match; number or `"x-y"` string; required today |
| `header_protection_key` | `HeaderProtectionKey` | must-match; optional |
| `random_trailers` | `RandomTrailers` | must-match; bool |
| `jc`, `jmin`, `jmax` | `Jc`, `Jmin`, `Jmax` | client-side; required-nonempty on the edge today (Phase E owns the shrink) |
| `i1`–`i5` | `I1`–`I5` | client-side; strings |
| `content_padding_addition` | `ContentPaddingAddition` | client-side; `"a-b"` string |
| `rekey_after_time`, `rekey_timeout`, `reject_after_time`, `keepalive_timeout`, `max_handshake_attempts` | `RekeyAfterTime`, `RekeyTimeout`, `RejectAfterTime`, `KeepaliveTimeout`, `MaxHandshakeAttempts` | client-side; `"a-b"` strings |
| `disable_cookies` | `DisableCookies` | client-side; bool |
| `allocated_ip`, `motherly_pubkey`, `motherly_endpoint`, `motherly_awg_ip`, `edge_id`, `otel_endpoint` | — | identity fields, unchanged from v1 |

### awg0.conf spelling

Canonical line form is `Key = value` (PascalCase key, single space around `=`). Bool fields render `on`/`off`; ranges render `lo-hi` unquoted; HPK and I-tags render their raw literals. Every obfuscation key above is `[Interface]`-scoped by upstream grammar (`config.c`) — none may ever appear under `[Peer]`. `PersistentKeepalive` is the inverse: `[Peer]`-scoped and edge-owned (static 25), so it never appears on either central surface. Identity lines (`PrivateKey`, `Address`, `ListenPort`, `Table`, `MTU`, `[Peer]` block) are likewise edge/motherly-local, not contract fields.

## Decision 2 — Sidedness law and wire preconditions

**Must-match set** — `S1`–`S4`, `H1`–`H4`, `HeaderProtectionKey`, `RandomTrailers`: central-sourced ONLY. Edges never generate, default, or alter these; a value that differs from motherly's live conf by one byte silently drops the data plane.

**Client-side set** — `Jc`/`Jmin`/`Jmax`, `I1`–`I5`, `ContentPaddingAddition`, the five timings, `DisableCookies`, `PersistentKeepalive` (edge-owned, `[Peer]`-scoped, static 25): may differ per edge (upstream recommends client-side generation). Central MAY still emit any of them via epoch Option fields or the register projection — both channels stay open; nothing is foreclosed. What central emits always wins when present.

### Contractual wire preconditions (NORMATIVE)

Motherly's generator and the edge validators both enforce these; upstream `mergeWithDevice` checks them before any Store, so a violating set fails atomically — but only at apply time. Central MUST generate conformant values:

1. `HeaderProtectionKey` set (non-zero) ⇒ **all of S1–S4 ≥ 12** on the resolved conf (absent S3 counts as 0 and fails).
2. `S1 + 56 ≠ S2`.
3. `H1`–`H4` bands pairwise non-overlapping. Two bounds apply: central MUST emit values/bounds ≤ **2147483647** (2³¹−1 — the amneziawg-windows client caps there; an emitted value above it wedges that client); the edge validator accepts up to the wire bound **u32::MAX** that upstream `UintRange` permits — acceptor stricter than the grammar would break peer interop, emitter looser than 2³¹−1 would break the windows peer.
4. Absent param = 0/off — a v3.1 peer running the v1 param set is wire-identical to 2.x, so interop with a pre-flip motherly is safe by construction.

### Generation bands (ADVISORY — explicitly non-normative)

Suggested defaults derived from MHSanaei/3x-ui's `GenerateObfuscation31`; motherly MAY adjust them. Only the preconditions above are contractual.

- `S1`, `S2`: 15–150 (subject to precondition 2)
- `S3`: 12–55; `S4`: 12–27 — all ≥ 12 so the HPK precondition holds by construction
- `H1`–`H4`: distinct non-overlapping bands ≤ 2³¹−1
- `HeaderProtectionKey`: `awg genkey` (32-byte base64)

Edge-generated client defaults (informational only — the edge's own business): `I1 = <r 32-256>` with I2–I5 empty per Amnezia convention, `ContentPaddingAddition` lo 8–24 / hi = lo+8–40 ≤ 64, `Jc` 3–6 / `Jmin` 40–89 / `Jmax` = Jmin+50–250. Edges generate these ONLY when absent from both epoch and conf.

**Linchpin clause (NORMATIVE):** epoch params are generated FROM motherly's live conf — render motherly's `awg0.conf` first, then project that same value set into the epoch row and the register response. NEVER generate an independent param set for the epoch. This single rule is what keeps all three surfaces coherent.

## Decision 3 — Zero-form remove-signals and the omission asymmetry

`syncconf` cannot clear a param by omission (it emits only `HAS_`-flagged fields), and the edge merge treats absent keys as preserve. Therefore, to REMOVE a must-match param that any prior epoch carried, the epoch MUST carry the explicit zero form:

| Param | Remove-signal in epoch `params` | Rendered conf line |
|---|---|---|
| `S3` | `"S3": 0` | `S3 = 0` |
| `RandomTrailers` | `"RandomTrailers": false` | `RandomTrailers = off` |
| `HeaderProtectionKey` | `"HeaderProtectionKey": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA="` (base64 of 32 zero bytes) | `HeaderProtectionKey = AAAA…=` |

The register surface MAY simply omit an absent param — no zero forms needed there.

**The asymmetry is intentional and the WHY is normative:** register renders a COMPLETE fresh conf — an absent key means no line is written, and a missing line is upstream's 0/off. An epoch MERGES into an existing conf — an absent key preserves whatever line (and kernel value) is already there. Two surfaces legitimately differ. Do NOT "harmonize" them: an implementer who makes the epoch omit cleared params reintroduces silent drift (edges keep the stale value forever); emitting explicit zeros in register is harmless but unnecessary.

## Decision 4 — `schema=2` capability gate

The agent's poll URL carries `&schema=N`; agents at the v2-aware release send `schema=2`. Absent param = schema 1. Old backends ignore unknown query params, so the agent side is safe to deploy first.

NORMATIVE requirements on the central side:

1. **Per-node persistence**: record each node's max-seen schema and last-seen timestamp.
2. **Writer-gate**: the epoch writer REFUSES v3.1-only content (`S3`, `HeaderProtectionKey`, `I2`–`I5`, `ContentPaddingAddition`, the five timings, `RandomTrailers`, `DisableCookies`, range-form `H` values) while ANY node active within a **7-day window** (contract default, central-tunable) reports `schema<2`. A forced-ack escape (explicit operator acknowledgement, logged) MAY override the refusal — it is an escape hatch, not the path.
3. **Post-cutover withhold-v2**: after the first v2-content epoch ships, the poll endpoint withholds v2 epochs from `schema<2` nodes — serve the last-safe (pre-v2) epoch or 204. A returning stale node then fails loudly (its applied epoch never advances past last-safe) instead of silently partially-applying fields it half-understands and reporting success.
4. **Applied-lag alerting**: alert when a node's applied epoch (via `/applied`) lags the latest published epoch beyond a small multiple of the poll interval.
5. **Contract test (required in the motherly PR)**: a `schema=1` poller MUST NOT be served v2 content. This is the regression test that proves the gate exists.

**Disambiguation** — three different "version" axes that must not be conflated:

- `schema=N` (poll param) — the RUNNING agent binary's capability. This is the gate signal.
- `X-Installer-Version` / `installer_version` telemetry — the installer BUNDLE version. Diverges from agent capability until binary delivery lands (the bundle ships scripts; the running agent may be older). Cannot substitute for `schema=2`; usable as a cross-check.
- `install.env SCHEMA_VERSION` — the edge state-FILE schema (ADR-002). Unrelated axis; the shared word is coincidence.

**Residual**: `schema` is self-reported — a misbuilt agent can claim 2. Detection is edge-side `param_rejected`/`apply_failures`/`applied-lag` signals. The edge cannot enforce central behavior; the gate + withhold + contract test are non-optional in the motherly PR.

## Decision 5 — Register installer floor

Edges send `X-Installer-Version: <release>` on the register POST (from `OXPULSE_IMAGE_VERSION`; absent header = treated-as-old = fail-safe).

Post-v3.1-cutover, a below-floor installer cannot extract the v2 keys — it would render a v1-only conf and produce a dead-on-arrival edge that reports green (the handshake check is warn-only). The register handler MUST make this LOUD: either an explicit error (4xx naming the floor) or omission of a required `awg` key so the edge's required-nonempty validation dies with an actionable message. NEVER silently build a dead edge — the install path is exactly what a returning node re-runs to recover.

The required-nonempty set the floor plays against: `jc`, `jmin`, `jmax`, `s1`, `s2`, `s4`, `h1`–`h4` plus identity fields (`allocated_ip`, `motherly_pubkey`, `motherly_endpoint`, `motherly_awg_ip`). Until Phase E, register MUST keep emitting all of them to at-or-above-floor installers — key omission is the floor mechanism and must fire ONLY for installers the floor genuinely excludes.

## Decision 6 — Uniform motherly-first flip rule (replaces restart-last)

**Rule**: EVERY change to a must-match param — enable AND disable, for S-fields, H-ranges, HPK, and RandomTrailers alike — follows the same order: **motherly flips its live conf FIRST, then the epoch is published.** No exceptions per param, no per-direction exceptions.

Why this is the only sane ordering — corrected wire physics:

- HPK mismatch is a TOTAL blackhole including handshake (the header type field is XOR'd — both directions de-XOR garbage).
- S-fields are exact-size envelopes — the receiver drops mismatched sizes.
- RandomTrailers: an RT-on peer still SENDS trailer'd packets that an RT-off receiver drops at the exact-size gate, pre-type-check. The "receiver-on accepts both shapes" reading covers only the inbound direction; every mixed state is dead in at least one direction.

No ordering avoids the blackout — the only controllable variable is its duration. Motherly-first bounds it to ~one poll interval because the control plane (HTTPS poll to the backend API) is OFF-MESH and unaffected by the dead data plane: edges self-heal as they fetch the already-published epoch. Edges-first makes the window human-bound — the operator must restart motherly while the whole fleet is already dark. This REPLACES the restart-last convention the old rotation pipeline used; that ordering maximized an unbounded human-latency window.

Contract mechanics (all normative):

- Flips ship in **dedicated single-purpose epochs** — one must-match flip per epoch, never bundled with unrelated content.
- The epoch writer **self-verifies motherly's live state** before accepting a flip epoch (e.g. refuses `RandomTrailers: true` while motherly's conf has RT off) — a mechanical precondition, not a runbook step.
- Revert = publish a NEW epoch carrying the previous values + motherly re-flip, rehearsed before cutover. Previous-epoch params are kept on hand.
- Checkpoint value of edges-first (applied-reports before committing motherly) is largely covered by the writer-gate + validators; its one unique protection — value-mismatch — it cannot catch anyway (an edge reports "applied" for a wrong-but-valid HPK).

Client-side params need no ordering — they may legitimately differ per edge.

## Decision 7 — HeaderProtectionKey handling

HPK is a **fleet-shared symmetric secret**: one 32-byte key held by motherly and every edge, served in the register response and re-served on every 30s poll. Transport is TLS + per-node bearer token; edge storage is `awg0.conf` 0600 in a 0700 dir plus a second durable copy in `node-config.json` 0600.

Leak impact: a passive observer with HPK de-obfuscates the XOR'd header type field → DPI re-identifies handshake/data/cookie packet types fleet-wide. Payload confidentiality is unaffected; detection is impossible — the anti-DPI property silently dies.

Contract (normative):

- **Rotation procedure**: dedicated epoch under the motherly-first flip rule (Decision 6). No other mechanism exists — syncconf cannot clear by omission, and the zero form removes rather than rotates.
- **Never in logs, on EITHER repo**: validators name the field, never the value; tool stderr/stdout (awg-quick strip / awg syncconf echo the offending conf lines on parse failure) is scrubbed of `Key =` material — PrivateKey/HPK/PresharedKey — before entering any error chain. The edge side implements this scrub; motherly MUST do the same.
- **Leak-response runbook**: rotate HPK immediately AND audit bearer-token usage — a stolen node token can fetch the epoch endpoint and re-read the current HPK.
- **Cadence**: operator decision, due BEFORE cutover — the procedure is contractual, the schedule is a security-ops policy call.

## Rollout (P6–P9 summary)

- **P6 — release + fleet converge (ops)**: tag the edge release, roll `desired_release`, verify `schema=2` counts climb and `installer_version` telemetry flows; probe a real edge (conf carries generated I1/CPA lines, apply metrics green, handshake healthy).
- **P7 — central implementation (motherly repo, this contract)**: JSONB superset + generation-from-live-conf + register projection + installer floor + per-node schema tracking + writer-gate + withhold-v2 + applied-lag alert + the contract test. Plumbing only — NO v3.1 epoch content yet.
- **P8 — v3.1 cutover (operator-ack gate)**: writer-gate reports all-active `schema≥2` → motherly flips its live conf FIRST → a dedicated epoch carries the flip (S3 + range-H/I-shapes + HPK) → fleet self-heals within ~one poll interval. RandomTrailers rides its OWN dedicated epoch under the same rule. Unavoidable fleet-wide dead interval bounded to ~one poll interval; revert drill rehearsed beforehand.
- **P9 — Phase E (deferred)**: central stops emitting `jc`/`jmin`/`jmax` — register omission gated on the installer floor, epoch omission gated on `schema=2`. The Option fields already landed, so no agent release is needed.

## Consequences

- The motherly implementer can ship the central half from this document alone; every endpoint, field name, type, and ordering rule is pinned above.
- The epoch/register omission asymmetry and the motherly-first flip rule are the two places a future "consistency cleanup" would silently re-break the fleet — both carry their normative WHY inline.
- Residuals accepted and documented: self-reported schema; the central-side gate is unenforceable from this repo (contract test is the proxy); P8's bounded blackout is physics, not a defect.
