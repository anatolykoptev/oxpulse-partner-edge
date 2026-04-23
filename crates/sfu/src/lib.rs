//! OxPulse SFU — str0m-based edge selective forwarding unit.
//!
//! M1.5: Prometheus `/metrics` endpoint + integration test coverage.
//! See `docs/superpowers/plans/2026-04-21-group-calls-execution.md`.

pub mod client;
pub mod config;
pub mod fanout;
pub mod metrics;
pub mod pacer;
pub mod propagate;
pub mod registry;
pub mod relay;
pub mod udp_loop;

pub use client::Client;
pub use config::SfuConfig;
pub use metrics::SfuMetrics;
pub use oxpulse_sfu_kit::bwe::estimator::BandwidthEstimator;
pub use pacer::Pacer;
pub use propagate::{ClientId, Propagated};
pub use registry::Registry;
pub use udp_loop::run_udp_loop;
