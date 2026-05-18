//! Phase 5.3 — retained native AWG keygen tests.
//!
//! All legacy shell-out tests (OPEC_AWG_KEYGEN_LEGACY=1) were removed in Phase 5.3.
//! The gap tests (empty-priv, whitespace-only-priv) live in secrets_awg_native.rs.
//! This file retains only the rotate test (different concern from the native suite).

use opec::secrets::awg;
use serial_test::serial;
use std::fs;
use tempfile::TempDir;

#[test]
#[serial]
fn awg_keygen_rotate_regenerates_priv() {
    // Native path: two calls — rotate=false then rotate=true — pubs must differ.
    let out = TempDir::new().unwrap();
    awg::keygen(out.path(), false).expect("first");
    let pub_first = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    awg::keygen(out.path(), true).expect("rotate");
    let pub_second = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}
