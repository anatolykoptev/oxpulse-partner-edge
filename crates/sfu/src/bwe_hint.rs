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
use std::sync::{Mutex, MutexGuard, OnceLock};
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
        return guard.unwrap();
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
            metrics
                .sfu_bwe_hint_registry_mutex_poisoned_total
                .inc();
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
/// poisoned (test-utils feature only).
///
/// Production callers that hold `SfuMetrics` should use this to make the
/// poison-recovery event observable.
pub fn hint_min_interval_ms_with_metrics(metrics: &crate::metrics::SfuMetrics) -> u64 {
    #[cfg(feature = "test-utils")]
    {
        let result = HINT_MIN_INTERVAL_OVERRIDE.lock();
        let guard = match result {
            Ok(g) => g,
            Err(poisoned) => {
                metrics
                    .sfu_bwe_hint_registry_mutex_poisoned_total
                    .inc();
                tracing::warn!(
                    "hint_min_interval_ms: override mutex poisoned, falling back to env/default"
                );
                poisoned.into_inner()
            }
        };
        if guard.is_none() {
            drop(guard);
            return std::env::var("SFU_BWE_HINT_MIN_INTERVAL_MS")
                .ok()
                .and_then(|v| v.parse::<u64>().ok())
                .unwrap_or(DEFAULT_MS)
                .max(1);
        }
        return guard.unwrap();
    }
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
