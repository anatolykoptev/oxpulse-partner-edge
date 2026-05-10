//! Shared helpers for the bwe-hint rate gate.
//!
//! Both the WS session (`client_ws::session`) and the metrics layer
//! (`metrics::SfuMetrics::new`) need to read `SFU_BWE_HINT_MIN_INTERVAL_MS`.
//! Keeping the parse logic here guarantees they always agree and prevents
//! divergence bugs (Phase 2c round-3 MAJOR fix).
//!
//! # OnceLock vs test-utils override
//!
//! Production path: `HINT_MIN_INTERVAL_MS` is a `OnceLock` — env read once at
//! first call, then lock-free. This is intentional and by-design.
//!
//! Test path (`test-utils` feature): `HINT_MIN_INTERVAL_OVERRIDE` is a
//! `Mutex<Option<u64>>` layered on top. When `None` the env var is re-read so
//! tests can call `reset_hint_min_interval_for_tests()` and then set a fresh
//! env value. The OnceLock is bypassed entirely in test builds.

use std::collections::HashMap;
#[cfg(feature = "test-utils")]
use std::sync::MutexGuard;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Default minimum interval between accepted bwe-hint frames per peer (ms).
const DEFAULT_MS: u64 = 100;

/// Production cache — set once, then lock-free.
/// OnceLock prod cache by-design — env read once at first call.
/// Tests override via `HINT_MIN_INTERVAL_OVERRIDE` mutex, bypassing this cache.
static HINT_MIN_INTERVAL_MS: OnceLock<u64> = OnceLock::new();

/// Test-only override. `None` means "use the normal env-var path".
/// Only compiled under `test-utils`; in production this static doesn't exist.
#[cfg(feature = "test-utils")]
static HINT_MIN_INTERVAL_OVERRIDE: Mutex<Option<u64>> = Mutex::new(None);

/// Returns the configured bwe-hint rate-limit interval in milliseconds.
///
/// Reads `SFU_BWE_HINT_MIN_INTERVAL_MS` once per process start via a
/// `OnceLock` cache. Clamped to ≥ 1 ms to prevent a zero-interval from
/// effectively disabling the gate.
///
/// Under `test-utils` the override mutex is checked first so that tests can
/// set a fresh env value after calling [`reset_hint_min_interval_for_tests`].
///
/// Poison recovery: if the override mutex is poisoned the guard is recovered
/// via `into_inner()` — we drop poisoned state and re-read from env rather
/// than propagating the panic to request-handler callers.
pub fn hint_min_interval_ms() -> u64 {
    #[cfg(feature = "test-utils")]
    {
        // Poison recovery: unwrap_or_else recovers the guard from a poisoned mutex
        // instead of panicking. Poisoned state is treated as None (env re-read).
        let guard = HINT_MIN_INTERVAL_OVERRIDE
            .lock()
            .unwrap_or_else(|p| p.into_inner());
        if guard.is_none() {
            drop(guard);
            // Re-read env every time override is None (reset was called).
            return std::env::var("SFU_BWE_HINT_MIN_INTERVAL_MS")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(DEFAULT_MS)
                .max(1);
        }
        return guard.expect("guard is Some — is_none() returned false above");
    }
    #[allow(unreachable_code)]
    *HINT_MIN_INTERVAL_MS.get_or_init(|| {
        std::env::var("SFU_BWE_HINT_MIN_INTERVAL_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(DEFAULT_MS)
            .max(1)
    })
}

/// Removes `peer_id` from the rate-gate registry on session exit.
///
/// Called after `park_until_close_or_steal` returns so that disconnected
/// peers do not accumulate entries in the map forever. Other entries are left
/// intact (Phase 2c round-3 MINOR fix).
///
/// Poison recovery: if the registry mutex is poisoned the error is logged
/// via `tracing::warn!` instead of silently discarded. The function never
/// panics — a poisoned registry at scrub time is non-fatal.
pub fn scrub_hint_registry(registry: &std::sync::Arc<Mutex<HashMap<u64, Instant>>>, peer_id: u64) {
    match registry.lock() {
        Ok(mut m) => {
            m.remove(&peer_id);
        }
        Err(poisoned) => {
            tracing::warn!(
                peer_id,
                "scrub_hint_registry: registry mutex poisoned, peer entry may leak"
            );
            // Recover and attempt the remove anyway to minimise cardinality leak.
            poisoned.into_inner().remove(&peer_id);
        }
    }
}

/// Same as [`scrub_hint_registry`] but increments
/// `sfu_bwe_hint_registry_mutex_poisoned_total` on mutex poison.
///
/// Call sites that have access to [`crate::metrics::SfuMetrics`] should prefer
/// this variant. The no-metrics variant is preserved for call sites in the test
/// harness that construct a bare `Arc<Mutex<HashMap>>`.
pub fn scrub_hint_registry_with_metrics(
    registry: &std::sync::Arc<Mutex<HashMap<u64, Instant>>>,
    peer_id: u64,
    metrics: &crate::metrics::SfuMetrics,
) {
    match registry.lock() {
        Ok(mut m) => {
            m.remove(&peer_id);
        }
        Err(poisoned) => {
            metrics.sfu_bwe_hint_registry_mutex_poisoned_total.inc();
            tracing::warn!(
                peer_id,
                "scrub_hint_registry: registry mutex poisoned, peer entry may leak"
            );
            poisoned.into_inner().remove(&peer_id);
        }
    }
}

/// Same as [`hint_min_interval_ms`] but increments
/// `sfu_bwe_hint_registry_mutex_poisoned_total` when the override mutex is
/// poisoned (only reachable under the `test-utils` feature where the override
/// mutex exists; in production the OnceLock path has no mutex to poison so the
/// counter is never triggered but the increment path is compiled and wired in
/// all builds).
///
/// Production callers that hold `SfuMetrics` should use this to make the
/// poison-recovery event observable.
pub fn hint_min_interval_ms_with_metrics(
    // Used only under test-utils to increment the poison counter; in
    // production the override mutex does not exist so the parameter is unused.
    #[cfg_attr(not(feature = "test-utils"), allow(unused_variables))]
    metrics: &crate::metrics::SfuMetrics,
) -> u64 {
    #[cfg(feature = "test-utils")]
    {
        let result = HINT_MIN_INTERVAL_OVERRIDE.lock();
        let (guard, poisoned) = match result {
            Ok(g) => (g, false),
            Err(p) => {
                tracing::warn!(
                    "hint_min_interval_ms: override mutex poisoned, falling back to env/default"
                );
                (p.into_inner(), true)
            }
        };
        if poisoned {
            // Counter is compiled and wired in all builds; the increment path
            // is only reachable under test-utils where the override mutex exists.
            metrics.sfu_bwe_hint_registry_mutex_poisoned_total.inc();
            drop(guard);
            // Fall back to env/default after recovering from poison.
            return std::env::var("SFU_BWE_HINT_MIN_INTERVAL_MS")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(DEFAULT_MS)
                .max(1);
        }
        if guard.is_some() {
            return guard.expect("guard is Some — is_none() returned false above");
        }
        // guard is None: re-read env (override was reset).
        drop(guard);
        return std::env::var("SFU_BWE_HINT_MIN_INTERVAL_MS")
            .ok()
            .and_then(|v| v.parse::<u64>().ok())
            .unwrap_or(DEFAULT_MS)
            .max(1);
    }

    // Production (no test-utils): use OnceLock — no override mutex, no poison
    // possible on this path. Counter is wired in test-utils builds above.
    #[allow(unreachable_code)]
    hint_min_interval_ms()
}

/// Resets the override so the next call to [`hint_min_interval_ms`] re-reads
/// the environment variable.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
/// Production code must never call this function.
#[cfg(feature = "test-utils")]
pub fn reset_hint_min_interval_for_tests() {
    *HINT_MIN_INTERVAL_OVERRIDE
        .lock()
        .unwrap_or_else(|p| p.into_inner()) = None;
}

/// Returns a `MutexGuard` for the override mutex so tests can poison it by
/// holding it across a panic.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
#[cfg(feature = "test-utils")]
pub fn poison_override_for_tests() -> MutexGuard<'static, Option<u64>> {
    HINT_MIN_INTERVAL_OVERRIDE
        .lock()
        .unwrap_or_else(|p| p.into_inner())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::SfuMetrics;
    use std::collections::HashMap;
    use std::sync::{Arc, Mutex};
    use std::time::Instant;

    fn make_poisoned_registry() -> Arc<Mutex<HashMap<u64, Instant>>> {
        let registry: Arc<Mutex<HashMap<u64, Instant>>> = Arc::new(Mutex::new(HashMap::new()));
        let reg_clone = Arc::clone(&registry);
        let _ = std::panic::catch_unwind(move || {
            let _guard = reg_clone.lock().unwrap();
            panic!("intentional poison");
        });
        assert!(
            registry.is_poisoned(),
            "mutex must be poisoned after caught panic"
        );
        registry
    }

    /// Prod-path: `scrub_hint_registry_with_metrics` bumps the poison counter
    /// when the registry mutex is poisoned.
    ///
    /// This is the session-equivalent test: it simulates what the session exit
    /// path does. Before the fix the call site used the bare
    /// `scrub_hint_registry` which silently drops the metric — this test
    /// calls `scrub_hint_registry_with_metrics` directly and will stay green
    /// once the call site is switched.
    #[test]
    fn scrub_with_metrics_bumps_counter_on_poisoned_registry() {
        let registry = make_poisoned_registry();
        let metrics = SfuMetrics::default();
        let before = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();

        // This is the call that the session exit path must use (not the bare
        // scrub_hint_registry which does NOT increment the counter).
        scrub_hint_registry_with_metrics(&registry, 42, &metrics);

        let after = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();
        assert_eq!(
            after,
            before + 1,
            "counter must increment on poisoned registry"
        );
    }

    /// Regression guard: the bare `scrub_hint_registry` must NOT bump the
    /// poison counter (it has no metrics handle). This ensures the two variants
    /// remain distinct — the bare variant is for test harnesses without
    /// SfuMetrics; the `_with_metrics` variant is for production call sites.
    #[test]
    fn bare_scrub_does_not_bump_counter() {
        let registry = make_poisoned_registry();
        let metrics = SfuMetrics::default();
        let before = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();

        scrub_hint_registry(&registry, 99);

        let after = metrics.sfu_bwe_hint_registry_mutex_poisoned_total.get();
        assert_eq!(after, before, "bare scrub must not touch metrics counter");
    }
}
