# Follow-ups

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
