//! Phase 4.3b — unit tests for awg::keygen with a fake wg binary.
//!
//! Tests that exercise the shell-out path require OPEC_AWG_KEYGEN_LEGACY=1
//! (Phase 5.2: native wg_keypair is now the default). These tests are annotated
//! with #[serial] because they mutate the process environment.

use opec::secrets::{awg, SecretsError};
use serial_test::serial;
use std::{fs, path::PathBuf};
use tempfile::TempDir;

/// Place a fake `wg` shim on the temp dir that emits canned keygen output.
/// `wg genkey` → priv (44 chars base64, like the real binary)
/// `wg pubkey` → pub (reads stdin, fails if no priv piped — catches a
///                   regression where run_wg forgets to wire stdin)
fn fake_wg(dir: &std::path::Path, priv_key: &str, pub_key: &str) -> PathBuf {
    let path = dir.join("wg");
    let script = format!(
        "#!/usr/bin/env bash\n\
         case \"$1\" in\n\
           genkey) echo '{priv_key}'; exit 0 ;;\n\
           pubkey)\n\
             read -r piped_priv\n\
             if [[ -z \"$piped_priv\" ]]; then\n\
               echo 'fake wg pubkey: empty stdin — caller did not pipe priv' >&2\n\
               exit 2\n\
             fi\n\
             echo '{pub_key}'\n\
             exit 0\n\
             ;;\n\
           *) echo 'fake wg: unsupported subcommand' >&2; exit 1 ;;\n\
         esac\n"
    );
    fs::write(&path, script).unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perm = fs::metadata(&path).unwrap().permissions();
        perm.set_mode(0o755);
        fs::set_permissions(&path, perm).unwrap();
    }
    path
}

const PRIV_44: &str = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQR="; // 44 chars (43 + '=')
const PUB_44: &str = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefgh=";

#[test]
#[serial]
fn awg_keygen_fresh_writes_both_files() {
    // This test exercises the legacy shell-out path with a fake wg binary.
    // Set OPEC_AWG_KEYGEN_LEGACY=1 to activate the wg shell-out branch (Phase 5.2+).
    std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1");
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    let result = awg::keygen(out.path(), false, &wg);
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    result.expect("fresh keygen succeeds");
    assert!(out.path().join("awg-private.key").is_file());
    assert!(out.path().join("awg-public.key").is_file());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(out.path().join("awg-private.key"))
            .unwrap()
            .permissions()
            .mode()
            & 0o777;
        assert_eq!(mode, 0o600, "awg-private.key must be 0600");
    }
    let pub_content = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert!(pub_content.trim() == PUB_44);
}

#[test]
#[serial]
fn awg_keygen_idempotent_when_priv_present() {
    // Legacy path: both calls use wg binary; second call re-derives pub from priv.
    std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1");
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    let r1 = awg::keygen(out.path(), false, &wg);
    let pub_before = fs::read_to_string(out.path().join("awg-public.key")).ok();
    // Second call must reuse priv (re-derives pub from existing priv).
    let r2 = awg::keygen(out.path(), false, &wg);
    let pub_after = fs::read_to_string(out.path().join("awg-public.key")).ok();
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    r1.expect("first call");
    r2.expect("idempotent call");
    assert_eq!(pub_before, pub_after);
}

#[test]
fn awg_keygen_rotate_regenerates_priv() {
    // Native path: two calls with rotate=false then rotate=true — pubs must differ.
    // The wg path arg is ignored on the native path, so any value works.
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    let out = TempDir::new().unwrap();
    let fake_wg_path = PathBuf::from("/nonexistent/wg");
    awg::keygen(out.path(), false, &fake_wg_path).expect("first");
    let pub_first = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    awg::keygen(out.path(), true, &fake_wg_path).expect("rotate");
    let pub_second = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

#[test]
#[serial]
fn awg_keygen_missing_wg_errors() {
    // Legacy path: with OPEC_AWG_KEYGEN_LEGACY=1, a nonexistent wg binary must fail.
    std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1");
    let out = TempDir::new().unwrap();
    let nonexistent = PathBuf::from("/nonexistent/wg-xyz-123");
    let err = awg::keygen(out.path(), false, &nonexistent).expect_err("must error");
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing, got: {err:?}"
    );
    // PartnerCliMissing reused for "external binary missing" — generic enough.
    // (If clearer naming desired, file as followup.)
}

#[test]
#[serial]
fn awg_keygen_corrupted_priv_on_idempotent_path_regenerates() {
    // Legacy path: empty priv triggers regeneration via wg genkey.
    std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1");
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    // Plant empty private key — idempotent check should detect & regenerate.
    fs::write(out.path().join("awg-private.key"), "").unwrap();
    let result = awg::keygen(out.path(), false, &wg);
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    result.expect("regenerates on empty");
    let priv_content = fs::read_to_string(out.path().join("awg-private.key")).unwrap();
    assert_eq!(priv_content.trim(), PRIV_44);
}

#[test]
#[serial]
fn awg_keygen_whitespace_only_priv_treated_as_missing() {
    // Legacy path: whitespace-only priv triggers regeneration via wg genkey.
    std::env::set_var("OPEC_AWG_KEYGEN_LEGACY", "1");
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    // File exists with non-zero length but trims to empty — must regenerate.
    fs::write(out.path().join("awg-private.key"), "   \n\t  \n").unwrap();
    let result = awg::keygen(out.path(), false, &wg);
    std::env::remove_var("OPEC_AWG_KEYGEN_LEGACY");
    result.expect("regenerates on whitespace");
    let priv_after = fs::read_to_string(out.path().join("awg-private.key")).unwrap();
    assert_eq!(
        priv_after.trim(),
        PRIV_44,
        "whitespace-only priv must trigger regeneration"
    );
}
