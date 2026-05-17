//! Phase 4.3b — unit tests for awg::keygen with a fake wg binary.

use opec::secrets::{awg, SecretsError};
use std::{fs, path::PathBuf};
use tempfile::TempDir;

/// Place a fake `wg` shim on the temp dir that emits canned keygen output.
/// `wg genkey` → priv (44 chars base64, like the real binary)
/// `wg pubkey` → pub (reads from stdin, emits canned pubkey)
fn fake_wg(dir: &std::path::Path, priv_key: &str, pub_key: &str) -> PathBuf {
    let path = dir.join("wg");
    let script = format!(
        "#!/usr/bin/env bash\n\
         case \"$1\" in\n\
           genkey) echo '{priv_key}'; exit 0 ;;\n\
           pubkey) cat >/dev/null; echo '{pub_key}'; exit 0 ;;\n\
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
const PUB_44: &str  = "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefgh=";

#[test]
fn awg_keygen_fresh_writes_both_files() {
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    awg::keygen(out.path(), false, &wg).expect("fresh keygen succeeds");
    assert!(out.path().join("awg-private.key").is_file());
    assert!(out.path().join("awg-public.key").is_file());
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mode = fs::metadata(out.path().join("awg-private.key"))
            .unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600, "awg-private.key must be 0600");
    }
    let pub_content = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert!(pub_content.trim() == PUB_44);
}

#[test]
fn awg_keygen_idempotent_when_priv_present() {
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    awg::keygen(out.path(), false, &wg).expect("first call");
    let pub_before = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    // Second call must reuse priv (re-derives pub from existing priv).
    awg::keygen(out.path(), false, &wg).expect("idempotent call");
    let pub_after = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert_eq!(pub_before, pub_after);
}

#[test]
fn awg_keygen_rotate_regenerates_priv() {
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg1 = fake_wg(bin.path(), PRIV_44, PUB_44);
    awg::keygen(out.path(), false, &wg1).expect("first");
    let pub_first = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    let wg2 = fake_wg(bin.path(), "DIFFERENT_PRIV_KEY_44CHARS_xxxxxxxxxxxxxx=", "DIFFERENT_PUB_44CHARS_xxxxxxxxxxxxxxxxxxxxxx=");
    awg::keygen(out.path(), true, &wg2).expect("rotate");
    let pub_second = fs::read_to_string(out.path().join("awg-public.key")).unwrap();
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

#[test]
fn awg_keygen_missing_wg_errors() {
    let out = TempDir::new().unwrap();
    let nonexistent = PathBuf::from("/nonexistent/wg-xyz-123");
    let err = awg::keygen(out.path(), false, &nonexistent).expect_err("must error");
    assert!(
        matches!(err, SecretsError::PartnerCliMissing(_)),
        "expected PartnerCliMissing, got: {err:?}"
    );
    // PartnerCliMissing reused for "external binary missing" — generic enough.
    // (If clearer naming desired, file as followup.)
}

#[test]
fn awg_keygen_corrupted_priv_on_idempotent_path_regenerates() {
    let bin = TempDir::new().unwrap();
    let out = TempDir::new().unwrap();
    let wg = fake_wg(bin.path(), PRIV_44, PUB_44);
    // Plant empty private key — idempotent check should detect & regenerate.
    fs::write(out.path().join("awg-private.key"), "").unwrap();
    awg::keygen(out.path(), false, &wg).expect("regenerates on empty");
    let priv_content = fs::read_to_string(out.path().join("awg-private.key")).unwrap();
    assert_eq!(priv_content.trim(), PRIV_44);
}
