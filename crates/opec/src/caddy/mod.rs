//! Caddy admin-API JSON renderer and route diff logic.
//!
//! Sub-phase 4.1: pure-function rendering only. No HTTP calls.
//! HTTP client (PATCH /config/…) arrives in sub-phase 4.2.

pub mod diff;
pub mod render;
