# Follow-ups

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

## awg_extract silent failure swallows JSON / python3 errors during install (2026-05-18)

**Severity:** P1 — install completes "successfully" with empty `AWG_*` vars and a dead `awg-quick@awg0` service. No surfacing log; operator sees install OK but the edge is non-functional until they tail journalctl.

**Investigation report:** `/home/krolik/deploy/krolik-server/reports/oxpulse-chat/investigations/2026-05-18-mesh-bridge-online-drop.md` (item 6).

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
