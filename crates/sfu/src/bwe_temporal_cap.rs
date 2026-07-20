//! Feature flag for the SFU-BWE-driven per-subscriber temporal-layer cap
//! (G3 P3b).
//!
//! # What it gates
//!
//! When `SFU_BWE_TEMPORAL_CAP=1`, `registry::bwe::update_pacer_layers`
//! derives a per-subscriber temporal-layer cap from the BWE estimate and
//! applies it alongside the client-DC `max_vfm_temporal_layer` cap via
//! `Client::effective_temporal_cap` (MIN combiner). The cap engages only
//! in the sub-spatial-floor "grace band" (`audio_only_bps ≤ budget <
//! `low_min_bps`) — the only place a budget-driven temporal cap composes
//! without double-counting budget the kit's `SubscriberPacer` already
//! spent on spatial layer selection. See the G3 P3b spec for the full
//! regime rationale.
//!
//! # Default OFF + restart-gated
//!
//! Matches [`crate::pacer_floor`] discipline: an operator canaries one
//! edge via env before enabling fleet-wide. The flag is read once per
//! process via a `OnceLock` cache in production; under `test-utils` an
//! `ENABLED_OVERRIDE` mutex bypasses the `OnceLock` so tests can flip
//! the flag without `std::env::set_var` racing other parallel tests in
//! the same process (paired with `#[serial]` on any test that *does*
//! use the env var directly, matching `bwe_hint_test.rs`'s convention).
//!
//! # OnceLock vs test-utils override
//!
//! Same pattern as [`crate::pacer_floor`] and [`crate::bwe_hint`]:
//! `ENABLED` is a `OnceLock<bool>` in production (env read once, then
//! lock-free); under `test-utils` an `ENABLED_OVERRIDE` mutex bypasses
//! the `OnceLock` so tests can flip the flag without `std::env::set_var`
//! racing other parallel tests in the same process.

#[cfg(feature = "test-utils")]
use std::sync::Mutex;
use std::sync::OnceLock;

/// Env var gating the SFU-BWE-driven temporal-layer cap.
/// `"1"` enables; unset or any other value keeps the cap inert.
const ENV_VAR: &str = "SFU_BWE_TEMPORAL_CAP";

/// Production cache -- set once, then lock-free. Bypassed entirely under
/// `test-utils` (see [`ENABLED_OVERRIDE`]).
static ENABLED: OnceLock<bool> = OnceLock::new();

/// Test-only override. `None` means "use the normal env-var path".
#[cfg(feature = "test-utils")]
static ENABLED_OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);

/// Whether the SFU-BWE-driven per-subscriber temporal-layer cap is active.
///
/// Reads `SFU_BWE_TEMPORAL_CAP` once per process via a `OnceLock` cache in
/// production. Under `test-utils` the override mutex is checked first so
/// tests can pin the flag without mutating process env (poison-recovered
/// the same way `pacer_floor::pacer_floor_enabled` is).
pub fn bwe_temporal_cap_enabled() -> bool {
    #[cfg(feature = "test-utils")]
    {
        let guard = ENABLED_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner());
        if let Some(v) = *guard {
            return v;
        }
        drop(guard);
        return read_env();
    }
    #[allow(unreachable_code)]
    *ENABLED.get_or_init(read_env)
}

fn read_env() -> bool {
    std::env::var(ENV_VAR).is_ok_and(|v| v == "1")
}

/// Test-only: pin the flag to `enabled`, bypassing env entirely.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
#[cfg(feature = "test-utils")]
pub fn set_bwe_temporal_cap_for_tests(enabled: bool) {
    *ENABLED_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()) = Some(enabled);
}

/// Test-only: clear the override so the next call re-reads the environment.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
#[cfg(feature = "test-utils")]
pub fn reset_bwe_temporal_cap_for_tests() {
    *ENABLED_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

// These unit tests exercise the `test-utils`-only override machinery
// (`set_bwe_temporal_cap_for_tests` / the `ENABLED_OVERRIDE` path), so they
// must be gated behind `test-utils` as well — otherwise the featureless
// `cargo test --workspace` CI job compiles them and fails to find the helpers
// (E0425). The featured CI job (`cargo test -p oxpulse-sfu --features
// test-utils,vfm`) compiles and runs them, so this is not skip-to-green.
#[cfg(all(test, feature = "test-utils"))]
mod tests {
    use super::*;

    #[test]
    fn override_wins_over_env() {
        set_bwe_temporal_cap_for_tests(true);
        assert!(bwe_temporal_cap_enabled(), "override(true) must win");
        set_bwe_temporal_cap_for_tests(false);
        assert!(!bwe_temporal_cap_enabled(), "override(false) must win");
        reset_bwe_temporal_cap_for_tests();
    }

    #[test]
    fn reset_falls_back_to_env_when_no_override() {
        set_bwe_temporal_cap_for_tests(true);
        reset_bwe_temporal_cap_for_tests();
        // No SFU_BWE_TEMPORAL_CAP set in the test process env -> default off.
        assert!(
            !bwe_temporal_cap_enabled(),
            "after reset with no env var set, must default to off"
        );
    }
}
