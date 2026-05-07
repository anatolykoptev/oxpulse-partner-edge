# Follow-ups

## GAUGE-LEAK: chat_relay_active_channels never decremented on disconnect

**Opened:** Phase 8 T10 review-fixes (commit following f6eb52d)
**Severity:** Medium — reconnect storm inflates gauge monotonically; no alert
  fires on churn that doesn't exceed a steady-state threshold.

**Context:** `Client::with_chat_dcs` increments
`chat_relay_active_channels{dc="data"}` and `{dc="ctrl"}` (two inc calls).
Neither `Registry::reap_dead` nor `Registry::evict_for_steal` decrements
these gauges. The MAJOR-2 fix in T10 closed the equivalent bug for
`voice_relay_active_channels`; the chat gauge was deferred because it
was a pre-existing latent bug outside the T10 scope.

**Fix:** In `crates/sfu/src/registry/bwe.rs::reap_dead`, after the voice dec
block:

```rust
// chat gauge dec — mirror voice path
if c.chat_data_cid.is_some() {
    metrics.chat_relay_active_channels.with_label_values(&["data"]).dec();
}
if c.chat_ctrl_cid.is_some() {
    metrics.chat_relay_active_channels.with_label_values(&["ctrl"]).dec();
}
```

And the same in `registry/mod.rs::evict_for_steal` for the `old` client.
Add a unit test mirroring `voice_relay_active_channels_gauge_decremented`.

### Open: voice_relay_dropped{buffered_amount_too_high} branch lacks unit test
T10 fix-loop (commit `f92c54a`) added a `ch.buffered_amount() > VOICE_BUFFERED_AMOUNT_MAX` backpressure check in `crates/sfu/src/client/voice.rs:~101`. The drop counter `voice_relay_dropped{reason="buffered_amount_too_high"}` increments correctly at runtime, but no integration test in `tests/voice_relay.rs` covers the branch. Test seam approach: drive a mock channel that returns a non-zero `buffered_amount()` via `client::test_seed::new_client` + relay flush. Without coverage the counter can silently regress (wrong label, wrong threshold, missing `.inc()`) — exactly the class of bug T10 cycle was designed to catch. Reviewer (final) flagged as MINOR, deferred to keep T10 boundary clean.
