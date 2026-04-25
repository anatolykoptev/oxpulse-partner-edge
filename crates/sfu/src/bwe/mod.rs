//! GoogCC v2 bandwidth estimation for the OxPulse SFU.
//! Replaces the simple hysteresis model with production-grade congestion control.

pub mod trendline;
pub mod aimd;
pub mod estimator;
