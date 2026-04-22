//! Per-subscriber simulcast layer preference.
//!
//! str0m's [`Rid`][str0m::media::Rid] is an opaque 8-byte string id.
//! LiveKit's convention — adopted by mediasoup and Jitsi too — is
//! `"q"` (lowest), `"h"` (mid), `"f"` (full). See
//! `docs/superpowers/research/2026-04-21-group-calls-architecture.md`
//! § 6.1. We build the three values as `const` via
//! [`Rid::from_array`] so they cost nothing at runtime and match
//! byte-for-byte with `Rid::from("q" | "h" | "f")` (the `From<&str>`
//! impl pads to 8 bytes with ASCII spaces).
//!
//! Future milestones (M5.3 GCC pacer, M5.4 receiver-driven) will
//! mutate this preference based on bandwidth and client signaling.
//! M1.3 is static-only: default [`LOW`], flipped via
//! [`Client::set_desired_layer`][super::Client::set_desired_layer].

use str0m::media::{MediaData, Rid};

/// LiveKit low-resolution layer (`q`).
pub const LOW: Rid = Rid::from_array(*b"q       ");
/// LiveKit mid-resolution layer (`h`).
pub const MEDIUM: Rid = Rid::from_array(*b"h       ");
/// LiveKit full-resolution layer (`f`).
pub const HIGH: Rid = Rid::from_array(*b"f       ");

/// Decide whether `data` should be forwarded to a subscriber whose
/// desired layer is `desired`.
///
/// Rules:
/// * `data.rid == None` — publisher is non-simulcast. Forward
///   unconditionally (single-layer fallback).
/// * `data.rid == Some(x)` — forward iff `x == desired`.
pub(crate) fn matches(desired: Rid, data: &MediaData) -> bool {
    match data.rid {
        None => true,
        Some(rid) => rid == desired,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn const_matches_from_str() {
        // Invariant: our `const` Rids must be byte-identical to the
        // value produced by str0m's `From<&str>` impl, otherwise `Eq`
        // silently breaks the whole forwarder filter.
        assert_eq!(LOW, Rid::from("q"));
        assert_eq!(MEDIUM, Rid::from("h"));
        assert_eq!(HIGH, Rid::from("f"));
    }
}
