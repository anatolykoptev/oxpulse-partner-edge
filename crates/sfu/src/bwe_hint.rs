//! Shared helpers for the bwe-hint rate gate.
//!
//! Both the WS session (`client_ws::session`) and the metrics layer
//! (`metrics::SfuMetrics::new`) need to read `SFU_BWE_HINT_MIN_INTERVAL_MS`.
//! Keeping the parse logic here guarantees they always agree and prevents
//! divergence bugs (Phase 2c round-3 MAJOR fix).
//!
//! In production the value is cached in a `OnceLock` (zero-cost after first
//! read). Under the `test-utils` feature a `Mutex<Option<u64>>` override
//! layer is layered on top so tests can reset between runs without unsafe code.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
use std::time::Instant;

/// Default minimum interval between accepted bwe-hint frames per peer (ms).
const DEFAULT_MS: u64 = 100;

/// Production cache — set once, then lock-free.
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
pub fn hint_min_interval_ms() -> u64 {
    #[cfg(feature = "test-utils")]
    {
        let guard = HINT_MIN_INTERVAL_OVERRIDE.lock().unwrap();
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
pub fn scrub_hint_registry(registry: &std::sync::Arc<Mutex<HashMap<u64, Instant>>>, peer_id: u64) {
    if let Ok(mut m) = registry.lock() {
        m.remove(&peer_id);
    }
}

/// Resets the override so the next call to [`hint_min_interval_ms`] re-reads
/// the environment variable.
///
/// **Test-only.** Only compiled when `#[cfg(feature = "test-utils")]`.
/// Production code must never call this function.
#[cfg(feature = "test-utils")]
pub fn reset_hint_min_interval_for_tests() {
    *HINT_MIN_INTERVAL_OVERRIDE.lock().unwrap() = None;
}
