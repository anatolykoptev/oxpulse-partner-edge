# Follow-ups

Open issues / deferred TODOs noted during PR reviews. Each entry includes observable symptom, location in code, why it matters, and a concrete next step.

---

### 1. Legacy tests reference removed `deploy/partner-edge/` path

**Where:** `tests/test_sfu_compose.sh`, `tests/test_install_ships_cover.sh`, `tests/test_install_wires_cert_watch.sh` (and possibly siblings) hardcode `REPO_ROOT=$(...)/deploy/partner-edge/` or similar legacy sub-path that no longer exists in this repo layout.

**Symptom:** scripts exit immediately or read non-existent fixtures. Effectively dead tests.

**Why it matters:** false sense of coverage. CI / shellcheck won't catch it because the scripts are not wired into automation; manual smoke runs would, but they're noted as broken in PR #49 and skipped.

**Next step:** audit `tests/test_*.sh`. For each: either update `REPO_ROOT` to repo root + adjust path prefixes (matching PR #49's `tests/test_install_die_on_empty_sfu_secret.sh` pattern), or delete the test if its target was removed in a prior layout change. ~30 min of grep + path fixes.

**Files:** `tests/test_*.sh` — count via `ls tests/test_*.sh | wc -l`.

**Discovered:** PR #49 review (2026-05-06).

---

## How to use this file
- Adding an entry: append below. Include observable symptom, where in code, why it matters, and a concrete next step.
- Closing an entry: ~~strikethrough the title and body~~ with `(closed YYYY-MM-DD via SHA)` appended. Keep the entry — history matters.

---

### 2. update.sh template fetch missing `--retry` (review of #113)

`update.sh:157` — template curl from `REPO_RAW` has `--max-time 30` but no `--retry`. API curl got `--retry 3 --retry-delay 2 --retry-connrefused` in the same amendment; template curl was missed. Transient CDN timeout = single-shot `die`. Russian partner nodes (Hetzner/Cloudflare path) — high failure probability.

**Fix:** add `--retry 3 --retry-delay 2 --retry-connrefused` to template curl. Same flag set as API curl.

### 3. Missing test scenarios (review of #113)

Tests T7/T8/T9 cover docker restart failure, missing compose file, curl `--retry` flag presence. Prior reviewer's explicit asks not yet covered:
- **Malformed API JSON**: API returns `{"error": "..."}` (valid JSON, no `node_id`). Current code dies via `die "reality_uuid missing"` — needs explicit test.
- **SIGTERM mid-render**: verify `xray-client.json` is not left zero-length after Ctrl+C between download and install. Current trap chain is probably safe; add test to prove.

### 4. `install -m 0600` on log file failure mode

`update.sh:47` — `install -m 0600 /dev/null "$LOG_FILE" 2>/dev/null || true` silently swallows error if log directory doesn't exist. Script then fails later at first `tee -a` with cryptic write error. Either pre-create directory or die clearly.


---

### N. Installer should run post-install mesh-reachability probe

**Where:** `install.sh` after the `configure_amneziawg` call (~Step 4 / Phase 4.10).

**Symptom:** if the AmneziaWG obfuscation params drift between the server-side
`awg0.conf` and what the partner installer wrote, the data plane silently
drops decrypted frames. WireGuard handshake still works (so
`awg show awg0` looks healthy with recent handshake), but
`ping -I awg0 <motherly_awg_ip>` returns 100% packet loss. Operator has
no signal until end-user reports a connection failure. See
`docs/AWG_PARAM_INVARIANT.md` and the 2026-05-20 zvonilka.net outage RCA.

**Why it matters:** any future change to server-side `Jc/Jmin/S1..S4/H1..H4`
that is not synchronously rolled to all partners re-introduces this class of
failure. A 5-second post-install probe (3 ICMP pings to
`${AWG_MOTHERLY_AWG_IP}`) catches drift at install time, when the operator
is at the keyboard and can fix it immediately, rather than 24h later
during an incident.

**Next step:**

1. After `configure_amneziawg` succeeds, run `ping -c 3 -W 2 -I awg0 "${AWG_MOTHERLY_AWG_IP}"`.
2. If 0% loss, log "mesh: reachability OK" and continue.
3. If non-zero loss, log a clear diagnostic referencing
   `docs/AWG_PARAM_INVARIANT.md`, suggest the byte-diff command from that
   doc, and exit non-zero so the installer does not report success.

**Files:** `install.sh` (Step 4 region) + new test
`tests/test_install_mesh_reachability_check.sh`.

**Discovered:** 2026-05-20 zvonilka.net mesh outage (S4 = 17 vs server S4 = 18).


---

### O. Consolidate production SFU binary into `oxpulse-sfu-kit`

**Where:** `crates/sfu/` in this (partner-edge) repo today; should live in
the [`oxpulse-sfu-kit`](https://github.com/anatolykoptev/oxpulse-sfu-kit) repo
alongside the reusable kit primitives.

**Symptom:** today `oxpulse-sfu-kit` exposes a *library* (`SfuConfig` with
`bind_address`/`metrics_port`/etc.) and an example binary `basic-sfu.rs`,
but the *production* binary that runs on partner-edges is built from
`crates/sfu/` in this repo and has its own larger `SfuConfig` (adds
`relay_api_port`, `client_ws_port`, `relay_auth_secret`, `sfu_signing_public_key`,
`stats_interval_secs`, `solo_kick_after_secs`, etc.). The two configs have
drifted: changes to one don't reach the other, and any feature the kit's
example added would require copy-paste into this repo.

**Why it matters:** memory `feedback_sfu_kit_reuse` says "kit owns
active-speaker, BWE, fanout, layer-select; check kit before writing new SFU
code." The split today violates that: production code that should be in the
kit (relay API, client WS, JWT verification, solo-kick policy) lives in
partner-edge instead. Concrete cost — the 2026-05-21 split-bind work
(this PR) had to be done in partner-edge; the same fix in the kit's
`basic-sfu.rs` example was not made and the kit example still binds
metrics on `bind_address`.

**Next step:**

1. Spin off `crates/sfu/` from this repo into `oxpulse-sfu-kit` as a new
   crate `oxpulse-sfu-bin` (binary) that depends on the kit library.
2. Or alternatively: pull the kit's `src/` into this repo as a vendored
   subcrate and deprecate the standalone kit repo. (Per `feedback_sfu_kit_reuse`,
   the kit is the long-term home — option 1 is preferred.)
3. After consolidation, port the changes from THIS PR
   (`SFU_METRICS_BIND` / `SFU_RELAY_API_BIND` / `SFU_CLIENT_WS_BIND`) into
   `examples/basic-sfu.rs` so the canonical example doesn't drift.

**Files:** `crates/sfu/`, `oxpulse-sfu-kit/`. Estimated cost: 1–2 days.

**Discovered:** 2026-05-21 audit, while implementing the split-bind fix.


---

### P. Run in-house SFU capacity benchmark to ground RAM recommendation

**Where:** `docs/HOSTING_REQUIREMENTS.md` currently recommends 2 GiB minimum / 4 GiB comfortable, with the caveat that MiB-per-participant growth has not been measured in-house. Industry-standard WebRTC SFUs (Jitsi videobridge, LiveKit) suggest 2-4 GiB for moderate loads, but our str0m-based SFU has its own memory profile.

**Symptom:** today operators choosing a VPS plan have to pick between "2 GiB just to fit" or "8 GiB just in case." A real benchmark turns guess into number.

**Why it matters:** with ~10 partners in onboarding queue (per `oxpulse-partner-edge-pipeline`), each picking a hosting plan, an authoritative MiB-per-participant figure prevents both under-provisioning (mid-call OOM) and over-provisioning (operator cost waste).

**Next step:**

1. Build a load harness (Playwright + WebRTC bot, or real client at scale) that ramps participants from 1 -> 50 -> 100 -> 200 in a single SFU room.
2. Capture `oxpulse-partner-sfu` RSS at each step from `docker stats --no-stream` and from cgroup `memory.current`.
3. Publish the MiB-per-participant curve in `docs/HOSTING_REQUIREMENTS.md` (replacing the current "not yet measured in-house" note) and emit `sfu_memory_per_participant_bytes` as a derived metric for capacity alerts.

**Files:** new `tests/load/sfu-room-ramp.ts` (or similar), `docs/HOSTING_REQUIREMENTS.md` update.

**Discovered:** 2026-05-22 README refresh -- current RAM recommendation is industry-extrapolated, not measured.
