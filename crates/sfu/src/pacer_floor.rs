//! Feature flag for the pacer min-tick floor + softened suspend-debounce
//! (fork-collapse task #18).
//!
//! # Bug
//!
//! `registry::bwe::update_pacer_layers` fires once per `MediaData`
//! (~20-30ms nominal video cadence) and calls straight into
//! `Client::pacer_select_layer` -> `SubscriberPacer::update` with no
//! minimum-tick floor. The kit's `SUSPEND_STREAK` debounce (2 consecutive
//! below-threshold ticks) is designed assuming ticks land roughly
//! `PACER_MIN_TICK_INTERVAL` (100ms) apart -- an assumption this fork's call
//! site never enforced. Two below-threshold ticks inside the same ~20-40ms
//! window collapse the intended ~200ms debounce window down to ~40ms, so a
//! brief loss burst forces a spurious `SuspendVideo` and drops video for
//! everyone downstream of the affected publisher.
//!
//! # Fix
//!
//! Behind `SFU_PACER_FLOOR=1`:
//! 1. `update_pacer_layers` gates each subscriber's pacer advance on
//!    [`oxpulse_sfu_kit::bwe::PACER_MIN_TICK_INTERVAL`] via
//!    `Client::pacer_tick_ready` (mirrors the kit's own `Client` gate,
//!    `oxpulse_sfu_kit::client::accessors::pacer_tick_ready`, which this
//!    fork's separate `Client` type does not inherit -- fork-collapse
//!    verdict keeps Client/Registry separate from the kit's).
//! 2. `oxpulse_partner_edge_pacer_config` raises `suspend_streak` from the
//!    kit default (2, ~200ms at the 100ms floor) to [`SOFTENED_SUSPEND_STREAK`]
//!    (3, ~300ms) -- research grounding
//!    (`~/.claude/agent-memory/code-research/sfu-bwe-layer-hysteresis-constants.md`):
//!    LiveKit's 200ms is only an EARLY-WARNING threshold, not its ~400-600ms
//!    "congested" confirmation; GoogCC never fully suspends, only cuts 0.85x.
//!    A hard 200ms full-suspend sits at the aggressive edge of every reference
//!    implementation surveyed. `UPGRADE_STREAK` (3, unchanged) already keeps
//!    the LiveKit-style fast-down/slow-up asymmetry; this only softens the
//!    down side's timing, not the polarity.
//!
//! Default is **off** -- an operator canaries one edge via env before
//! enabling fleet-wide, and the existing pacer test suite (`hard_red_migration.rs`,
//! `multi_client.rs`, etc.) drives the pacer with back-to-back
//! `force_pacer_refresh_for_tests` calls that assume the pre-fix unthrottled
//! cadence; flipping the default on would silently start throttling those
//! calls (they land microseconds apart in wall-clock time) and break streak
//! counting the tests depend on.
//!
//! # OnceLock vs test-utils override
//!
//! Same pattern as [`crate::bwe_hint`]: `ENABLED` is a `OnceLock<bool>` in
//! production (env read once, then lock-free); under `test-utils` an
//! `ENABLED_OVERRIDE` mutex bypasses the `OnceLock` so tests can flip the
//! flag without `std::env::set_var` racing other parallel tests in the same
//! process (paired with `#[serial]` on any test that *does* use the env var
//! directly, matching `bwe_hint_test.rs`'s convention).

#[cfg(feature = "test-utils")]
use std::sync::Mutex;
use std::sync::OnceLock;

/// Env var gating the min-tick floor + softened suspend debounce.
/// `"1"` enables; unset or any other value keeps the pre-fix behaviour.
const ENV_VAR: &str = "SFU_PACER_FLOOR";

/// Softened `suspend_streak` applied by `oxpulse_partner_edge_pacer_config`
/// when the floor is enabled. See module docs for the research grounding.
pub const SOFTENED_SUSPEND_STREAK: u8 = 3;

/// Production cache -- set once, then lock-free. Bypassed entirely under
/// `test-utils` (see [`ENABLED_OVERRIDE`]).
static ENABLED: OnceLock<bool> = OnceLock::new();

/// Test-only override. `None` means "use the normal env-var path".
#[cfg(feature = "test-utils")]
static ENABLED_OVERRIDE: Mutex<Option<bool>> = Mutex::new(None);

/// Whether the min-tick floor + softened suspend debounce is active.
///
/// Reads `SFU_PACER_FLOOR` once per process via a `OnceLock` cache in
/// production. Under `test-utils` the override mutex is checked first so
/// tests can pin the flag without mutating process env (poison-recovered
/// the same way `bwe_hint::hint_min_interval_ms` is).
pub fn pacer_floor_enabled() -> bool {
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
pub fn set_pacer_floor_for_tests(enabled: bool) {
    *ENABLED_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()) = Some(enabled);
}

/// Test-only: clear the override so the next call re-reads the environment.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
#[cfg(feature = "test-utils")]
pub fn reset_pacer_floor_for_tests() {
    *ENABLED_OVERRIDE.lock().unwrap_or_else(|p| p.into_inner()) = None;
}

// These unit tests exercise the `test-utils`-only override machinery
// (`set_pacer_floor_for_tests` / the `ENABLED_OVERRIDE` path), so they must be
// gated behind `test-utils` as well — otherwise the featureless
// `cargo test --workspace` CI job compiles them and fails to find the helpers
// (E0425). The featured CI job (`cargo test -p oxpulse-sfu --features
// test-utils,vfm`) compiles and runs them, so this is not skip-to-green.
#[cfg(all(test, feature = "test-utils"))]
mod tests {
    use super::*;

    #[test]
    fn override_wins_over_env() {
        set_pacer_floor_for_tests(true);
        assert!(pacer_floor_enabled(), "override(true) must win");
        set_pacer_floor_for_tests(false);
        assert!(!pacer_floor_enabled(), "override(false) must win");
        reset_pacer_floor_for_tests();
    }

    #[test]
    fn reset_falls_back_to_env_when_no_override() {
        set_pacer_floor_for_tests(true);
        reset_pacer_floor_for_tests();
        // No SFU_PACER_FLOOR set in the test process env -> default off.
        assert!(
            !pacer_floor_enabled(),
            "after reset with no env var set, must default to off"
        );
    }
}
