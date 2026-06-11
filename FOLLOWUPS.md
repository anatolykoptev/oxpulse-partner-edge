# Follow-ups

## Phase 5.5 fail-soft for hydrate/refresh/update (MAJOR 1 deferred)

`hydrate.sh`, `oxpulse-partner-edge-refresh.sh`, and `update.sh` do not use
`render_channel_soft` / `CHANNELS_FAILED` and lack the compose-strip
post-processor added to `install.sh` in PR #186.

A render failure in these scripts can tear down healthy channels via
`docker compose up -d [--force-recreate]` because the compose file still
contains the failed channel's service block referencing a missing config file.

**Followup:**
- Extract `render_channel_soft` and the compose-strip python3 block into
  `lib/channel-render-lib.sh` (or a new `lib/channel-fallback-lib.sh`) so
  `hydrate.sh`, `refresh.sh`, and `update.sh` can source it.
- Replace unconditional `docker compose up -d --force-recreate` in refresh with
  surgical per-channel restart: only recreate containers whose channel was
  re-rendered successfully.
- Mirror `channels-status.env` atomic write in all three scripts.

**Severity:** HIGH on refresh/hydrate paths (daily scheduled runs); MEDIUM on
update.sh (operator-explicit only).

**File:line:** `hydrate.sh:234–266`, `oxpulse-partner-edge-refresh.sh:185–238`,
`update.sh` (compose-up call). Warning comments + this entry added in PR #186.

---

## Phase 5.5: opec render xray reads node-config.json natively

Phase 5.4 (fix/install-bugs-3-4-live-edge) added env-export plumbing in
`install.sh` to feed `XRAY_XHTTP_*` into `opec render xray`. This duplicates
the responsibility of reading node-config that opec already owns for secrets
subcommands.

**Followup:** add `opec render xray --node-cfg <path>` that reads
`channels[0].xray.xhttp` natively (mirror `scripts/read-xhttp.py` logic in
Rust), then drop the `install.sh` env-export block (the six `python3 - ...`
heredocs + the `export XRAY_XHTTP_*` line before `render_with_opec xray`).

**Acceptance:** `install.sh` `render_with_opec xray` invocation needs no
ambient `XRAY_XHTTP_*` env vars; opec reads node-config directly.

**File:line:** `install.sh` (around the `render_with_opec xray` call),
`crates/opec/src/render/` (add `--node-cfg` flag to xray subcommand).

---

## BLOCKER 2 follow-up: lib/install-systemd.sh hardcodes /usr/local/bin for oxpulse-xray-update.sh (2026-05-18)

`lib/install-systemd.sh:_systemd_install_xray_update_script()` installs
`oxpulse-xray-update.sh` to hardcoded `/usr/local/bin/oxpulse-xray-update.sh`
instead of `${PREFIX_BIN:-/usr/local/bin}`. This means installations that
override `PREFIX_BIN` via `OXPULSE_PREFIX_BIN` will leave the file at the
wrong path.

**Suggested fix:** Change the function to use `${PREFIX_BIN:-/usr/local/bin}`
as the install destination. Requires `PREFIX_BIN` to be in scope when
`install-systemd.sh` is sourced (it already is — exported from install.sh).

**Severity:** LOW — `PREFIX_BIN` is only overridden in tests; prod defaults
to `/usr/local/bin`. Uninstall.sh Phase 5.7 review-fix already handles
removal of the hardcoded path.

**File:line:** `lib/install-systemd.sh:_systemd_install_xray_update_script()` (~L206-213).

---

## awg_extract silent failure swallows JSON / python3 errors during install (2026-05-18)

**Severity:** P1 — install completes "successfully" with empty `AWG_*` vars and a dead `awg-quick@awg0` service. No surfacing log; operator sees install OK but the edge is non-functional until they tail journalctl.

**Investigation report:** `/home/user/deploy/server-config/reports/oxpulse-chat/investigations/2026-05-18-mesh-bridge-online-drop.md` (item 6).

**Original code-quality-reviewer claim:** "`awg_extract` under `set -euo pipefail` aborts the install silently if JSON is malformed or python3 missing." → **REFUTED in letter, CONFIRMED in spirit.**

**Actual mechanism (worse than original claim):** Under `set -euo pipefail`, bash exempts assignment right-hand-side from `set -e`. So a failing `$(awg_extract /nonexistent jc)` does NOT abort the script. Instead three layers swallow:

1. `lib/install-awg.sh:137` — `python3 ... 2>/dev/null` discards python error output
2. Assignment captures empty string into local var (RHS-exempt from `set -e`)
3. Call sites at `install.sh:594-607` use `awg_extract` outputs to populate `AWG_*` env vars without checking for empty
4. `configure_amneziawg` (line 208+) renders `awg0.conf` with empty values, then `awg-quick up awg0` either fails-soft or starts a broken interface

Result: full install run reports OK exit, but `awg-quick@awg0.service` exits 1 silently. No `die` ever fires.

**Suggested fix:**
- Validate non-empty after each `awg_extract` call site (or batch-validate the 14 `AWG_*` vars before render)
- Surface python3-missing as `die` (not silent fallback) — python3 is a build-deps invariant on Debian/RHEL/Ubuntu
- Add a smoke-step after `configure_amneziawg` that checks `systemctl status awg-quick@awg0` exit 0 before declaring install success

**File:line:** `lib/install-awg.sh:137`, `install.sh:594-607`, `lib/install-awg.sh:208+` (configure_amneziawg).

---

## ~~GAUGE-LEAK: chat_relay_active_channels never decremented on disconnect~~

~~**Opened:** Phase 8 T10 review-fixes (commit following f6eb52d)~~
~~**Severity:** Medium — reconnect storm inflates gauge monotonically; no alert~~
~~  fires on churn that doesn't exceed a steady-state threshold.~~

**Closed:** `fix/chat-relay-gauge-leak` branch — commit TBD (SHA filled on merge).
Both `Registry::reap_dead` (`crates/sfu/src/registry/bwe.rs`) and
`Registry::evict_for_steal` (`crates/sfu/src/registry/mod.rs`) now decrement
`chat_relay_active_channels{dc="data"}` and `{dc="ctrl"}` guarded by
`chat_data_cid.is_some()` / `chat_ctrl_cid.is_some()`, mirroring the T10 voice fix.
Tests: `chat_relay_active_channels_gauge_decremented_on_reap` +
`chat_relay_active_channels_gauge_decremented_on_steal` added to
`crates/sfu/tests/relay_chat_e2e.rs`.

### ~~Open: voice_relay_dropped{buffered_amount_too_high} branch lacks unit test~~
**Closed.** T10 fix-loop (commit `f92c54a`) added a `ch.buffered_amount() > VOICE_BUFFERED_AMOUNT_MAX` backpressure check in `crates/sfu/src/client/voice.rs:~101`. The drop counter `voice_relay_dropped{reason="buffered_amount_too_high"}` increments correctly at runtime, but no integration test in `tests/voice_relay.rs` covers the branch. Test seam approach: drive a mock channel that returns a non-zero `buffered_amount()` via `client::test_seed::new_client` + relay flush. Without coverage the counter can silently regress (wrong label, wrong threshold, missing `.inc()`) — exactly the class of bug T10 cycle was designed to catch. Reviewer (final) flagged as MINOR, deferred to keep T10 boundary clean.

**Resolution:** Added `voice_relay_drops_when_subscriber_buffered_amount_too_high` in `crates/sfu/tests/voice_relay.rs` (10th test). Seam: `Client::set_buffered_amount_for_tests(usize)` in `test_seed.rs` + `buffered_amount_override: Option<usize>` field (cfg-gated). Override checked before `rtc.channel()` in voice.rs test path so the branch fires despite no live SCTP. Test asserts: `buffered_amount_too_high` counter +1 on overloaded subscriber; healthy subscriber still reaches relay attempt (`dc_closed` in test seam). <!-- closed: <!-- placeholder SHA --> -->

---

## ch4 coturn probe — hairpin/NAT caveat and allocation leak (PR #304)

### Hairpin / pure-NAT edge

On a **pure-NAT edge** where the public IP is NOT locally bound (e.g. AWS/GCP
instances where the public IP lives on the gateway, not the NIC), the probe
sends a TURN Allocate to `$probe_target` (the public IP).  Clouds that **drop
hairpin** traffic from the instance back to its own public address will silently
drop the packets; `timeout` kills `turnutils_uclient` with exit 124; the probe
reports `handshake_ok=false` on a perfectly healthy coturn.

**Remedy:** set `OXPULSE_COTURN_PROBE_TARGET` to an address that IS reachable
from the instance without hairpin — typically the instance's private/LAN IP if
coturn listens there, or a second IP on a peer box.  Example:

```bash
# In /etc/oxpulse-partner-edge.env or equivalent:
OXPULSE_COTURN_PROBE_TARGET=10.0.0.5   # LAN IP coturn actually binds
```

The script's `warn` on repeated timeout in `probe_ch4` (around the
`loopback-fallback` branch and the failure logger) references this env override;
the `loopback-fallback` warn text in `oxpulse-channels-health-report.sh` also
cites the env escape hatch.

**Detection:** `COTURN_PROBE_TARGET_SOURCE=loopback-fallback` in
`/var/lib/oxpulse-partner-edge/coturn-probe-mode.env` (written every tick by
`_write_probe_mode_state`), or `channel_probe_reason=loopback-fallback` in the
central server POST payload (written when the fallback path is taken).

### Residual allocation leak on timeout

When `timeout` kills `turnutils_uclient` (exit 124) on a dead relay or
hairpin-drop edge, the client never sends a TURN Refresh(0) (graceful dealloc).
Coturn holds two dangling allocations per probe tick until its default
expiry (600 s).  At 60 s tick rate that is 2 leaks/60 s → **~10 leaked
allocations** outstanding at steady state.  The default user quota is 16, so a
probe username wedges into `486 Allocation Quota Reached` after roughly **8
minutes of continuous failure** on the default per-user quota.

`turnutils_uclient` has no `--lifetime` or allocation-duration flag (the `-l`
flag controls message length, not allocation lifetime; coturn-exporter confirms
no lifetime override exposed via the CLI).  The leak is therefore bounded only
by **coturn's `allocation-default-timeout` (default 600 s)** — the quota
recovers automatically once all timed-out allocations expire, but a
continuously-timing-out probe will keep the quota wedged.

**Mitigations:**
1. Fix the root cause: resolve hairpin via `OXPULSE_COTURN_PROBE_TARGET`
   (see above) so the probe succeeds and sends Refresh(0) gracefully.
2. As a safety net, set `max-allocate-lifetime=120` and
   `allocation-default-timeout=120` in `coturn.conf.tpl` to halve the wedge
   window (not yet done — tracked here).
3. The probe username `<ts>:healthprobe` is fixed per-edge, so the wedge is
   per-username and does not pollute other users' quotas.

**Comment updated** in `oxpulse-channels-health-report.sh` (around line 215)
to state the residual leak honestly rather than claiming it is solved.
