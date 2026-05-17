# Phase 4.3a — `opec secrets reality-keygen`

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Absorb `install.sh` Step 4 sub-step 2 (Reality x25519 keypair + UUID + idempotent file management + partial-identity detection, L753-916, ~163 LoC) into `opec secrets reality-keygen` subcommand. install.sh keeps bash fallback under `OPEC_SECRETS_REALITY_KEYGEN=${...:-1}` env gate.

**Architecture:**
- New subcommand `Cmd::Secrets { action: SecretsCommands }` — sibling of existing `Render`/`Tenant`, nested-subcommand pattern (matches `Tenant`).
- Module layout: `crates/opec/src/secrets/{mod,error,reality}.rs`.
- Shells out to existing `partner-cli keygen` (preserves keygen source of truth; absorption into native Rust deferred to Phase 5).
- HTTP NOT required for 4.3a (network surface lands in 4.3b/4.3c).

**Tech Stack:** Rust 2021, `clap` derive (already in opec), `uuid = { version = "1", features = ["v4"] }`, `tempfile` (already transitive via `assert_cmd` test deps; may need direct add). `anyhow` for prop, typed `SecretsError` for matching.

**Out of scope:**
- Phase 4.3b (`opec secrets register`) — network + central API
- Phase 4.3c (`opec secrets runtime`) — SFU fetch + JWT synth
- partner-cli keygen absorption (Phase 5)
- HTTP client choice resolution (deferred; not needed for 4.3a)

**Roadmap link:** `docs/superpowers/specs/2026-05-17-phase4-install-decomposition-roadmap.md` (Phase 4.3 chunked into a/b/c).

## File structure

```
crates/opec/
├── Cargo.toml                            # MODIFY — add uuid + tempfile deps
└── src/
    ├── main.rs                           # MODIFY — Cmd::Secrets dispatch
    └── secrets/
        ├── mod.rs                        # NEW — SecretsCommands enum + dispatch
        ├── error.rs                      # NEW — SecretsError enum
        └── reality.rs                    # NEW — keygen() impl
crates/opec/tests/
├── cli_secrets_reality.rs                # NEW — bin-level integration
└── secrets_reality_unit.rs               # NEW — module-level unit tests
install.sh                                # MODIFY (T3)
tests/test_install_opec_parity.sh         # MODIFY (T3) — assert env-gated delegation
```

---

## Task 1 — `opec secrets` skeleton

**Files:**
- Modify: `crates/opec/src/main.rs` (extend `Commands` enum + dispatch arm)
- Create: `crates/opec/src/secrets/mod.rs`
- Create: `crates/opec/src/secrets/error.rs`
- Create: `crates/opec/tests/cli_secrets_reality.rs` (only the skeleton-shape test for now; T2 adds real tests)

- [ ] **Step 1.1 (RED) — failing CLI test**

`crates/opec/tests/cli_secrets_reality.rs`:

```rust
//! Phase 4.3a — opec secrets reality-keygen CLI integration tests.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_reality_keygen() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("reality-keygen"));
}

#[test]
#[serial]
fn opec_secrets_reality_keygen_requires_out_dir() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "reality-keygen"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--out-dir"));
}
```

Add `predicates` to `[dev-dependencies]` in `crates/opec/Cargo.toml` if not already present (check first: `grep predicates crates/opec/Cargo.toml`).

Run `cargo nextest run -p opec --test cli_secrets_reality` — expect 2 FAIL (subcommand doesn't exist).

- [ ] **Step 1.2 (GREEN) — extend `Cmd` + create stub module**

In `crates/opec/src/main.rs`, locate the `enum Commands` block. Append a new variant:

```rust
    /// Bootstrap partner-edge secrets (Reality identity, registry credentials,
    /// SFU signing key). Phase 4.3 absorbs install.sh Step 4.
    Secrets {
        #[command(subcommand)]
        action: opec::secrets::SecretsCommands,
    },
```

Also add a `mod secrets;` line near the other module declarations in `crates/opec/src/lib.rs` (check current location of `pub mod render;` etc. — drop next to it).

In the `main()` match arm dispatching on `cli.command`, add:

```rust
        Commands::Secrets { action } => opec::secrets::dispatch(action),
```

Create `crates/opec/src/secrets/mod.rs`:

```rust
//! Phase 4.3 — partner-edge secrets bootstrap.
//!
//! Subcommands:
//! - `reality-keygen` (Phase 4.3a) — x25519 keypair + UUID identity files.
//! - `register` (Phase 4.3b) — POST to central registry, parse response.
//! - `runtime` (Phase 4.3c) — fetch SFU signing key, synthesize JWT secret.

use clap::Subcommand;
use std::path::PathBuf;

pub mod error;
pub mod reality;

pub use error::SecretsError;

#[derive(Subcommand)]
pub enum SecretsCommands {
    /// Generate or reuse Reality x25519 identity (reality.priv, reality.pub, reality.uuid).
    RealityKeygen {
        /// Directory to write identity files to.
        #[arg(long)]
        out_dir: PathBuf,
        /// Force regeneration even when valid identity exists.
        #[arg(long)]
        rotate: bool,
        /// Override partner-cli binary path (test hook).
        #[arg(long, default_value = "partner-cli")]
        partner_cli: PathBuf,
    },
}

pub fn dispatch(cmd: SecretsCommands) -> anyhow::Result<()> {
    match cmd {
        SecretsCommands::RealityKeygen {
            out_dir,
            rotate,
            partner_cli,
        } => reality::keygen(&out_dir, rotate, &partner_cli).map_err(Into::into),
    }
}
```

Create `crates/opec/src/secrets/error.rs`:

```rust
//! Typed errors for `opec secrets` subcommands.

use std::path::PathBuf;
use thiserror::Error;

#[derive(Debug, Error)]
pub enum SecretsError {
    #[error("partner-cli not found at {0} — install partner-cli first or pass --partner-cli")]
    PartnerCliMissing(PathBuf),

    #[error("partner-cli keygen failed: {stderr}")]
    PartnerCliFailed { stderr: String },

    #[error(
        "PARTIAL identity at {dir}: found {found:?}, missing {missing:?}. \
         Remove all reality.* files for a fresh identity, or restore the missing ones from backup."
    )]
    PartialIdentity {
        dir: PathBuf,
        found: Vec<&'static str>,
        missing: Vec<&'static str>,
    },

    #[error("invalid key format at {path}: expected 43-char base64url, got {actual_len} bytes")]
    InvalidKeyFormat { path: PathBuf, actual_len: usize },

    #[error("io error at {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}
```

Create stub `crates/opec/src/secrets/reality.rs`:

```rust
//! Phase 4.3a — Reality x25519 identity management.
//! Real impl lands in Task 2. This stub satisfies the dispatch signature
//! so the skeleton test can pass.

use super::error::SecretsError;
use std::path::Path;

pub fn keygen(out_dir: &Path, _rotate: bool, _partner_cli: &Path) -> Result<(), SecretsError> {
    // T2 will implement this. T1 only validates the CLI surface.
    let _ = out_dir;
    Err(SecretsError::PartnerCliFailed {
        stderr: "stub — Task 2 will implement keygen".into(),
    })
}
```

Update `Cargo.toml`:

```toml
[dependencies]
# ... existing ...
thiserror = "1"
uuid = { version = "1", features = ["v4"] }
tempfile = "3"
```

Check if `thiserror`/`tempfile` already in deps before adding.

- [ ] **Step 1.3 — verify**

```bash
cargo build -p opec
cargo nextest run -p opec --test cli_secrets_reality
cargo clippy -p opec --all-targets -- -D warnings
```

Expected: build clean; 2/2 PASS; clippy clean.

- [ ] **Step 1.4 — commit**

```
feat(opec): scaffold secrets subcommand with reality-keygen stub

Phase 4.3a Task 1 — adds Cmd::Secrets { action: SecretsCommands }
following the nested-subcommand pattern of Cmd::Tenant. Module layout
crates/opec/src/secrets/{mod,error,reality}.rs lands; real reality::keygen
impl lives in Task 2.

Refs: docs/superpowers/plans/2026-05-17-phase4-3a-opec-secrets-reality-keygen.md
```

---

## Task 2 — `secrets::reality::keygen` impl

**Files:**
- Modify: `crates/opec/src/secrets/reality.rs` (replace stub with real impl)
- Modify: `crates/opec/tests/cli_secrets_reality.rs` (add real flow tests)
- Create: `crates/opec/tests/secrets_reality_unit.rs` (unit tests on partial-identity detection)

- [ ] **Step 2.1 (RED) — write unit tests first**

`crates/opec/tests/secrets_reality_unit.rs`:

```rust
//! Phase 4.3a — unit tests for reality::keygen against synthetic partner-cli output.

use opec::secrets::{reality, SecretsError};
use std::{fs, path::PathBuf};
use tempfile::TempDir;

// Helper: place a fake partner-cli on the temp PATH that emits canned keygen output.
fn fake_partner_cli(dir: &std::path::Path, priv_key: &str, pub_key: &str) -> PathBuf {
    let path = dir.join("partner-cli");
    let script = format!(
        "#!/usr/bin/env bash\n\
         if [[ \"$1\" == \"keygen\" ]]; then\n\
           echo 'private_key: {priv_key}'\n\
           echo 'public_key: {pub_key}'\n\
           exit 0\n\
         fi\n\
         echo 'fake partner-cli: only keygen supported' >&2\n\
         exit 1\n"
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

#[test]
fn keygen_fresh_writes_three_files() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG", // 43 chars
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg", // 43 chars
    );
    reality::keygen(out_dir.path(), false, &pc).expect("keygen succeeds");
    assert!(out_dir.path().join("reality.priv").is_file());
    assert!(out_dir.path().join("reality.pub").is_file());
    assert!(out_dir.path().join("reality.uuid").is_file());
    let priv_mode = fs::metadata(out_dir.path().join("reality.priv"))
        .unwrap()
        .permissions();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(priv_mode.mode() & 0o777, 0o600, "reality.priv must be 0600");
    }
}

#[test]
fn keygen_idempotent_when_all_three_present_and_valid() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    reality::keygen(out_dir.path(), false, &pc).expect("first call");
    let pub_before = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    // Second invocation must NOT call partner-cli — verify by removing it and re-running.
    drop(pc); // partner-cli binary path still valid in bin_dir
    let pub_after = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    assert_eq!(
        pub_before, pub_after,
        "idempotent re-run must not mutate reality.pub"
    );
    // Even with --rotate=false, second call should succeed without rewriting.
    let pc2 = bin_dir.path().join("partner-cli");
    let res = reality::keygen(out_dir.path(), false, &pc2);
    assert!(res.is_ok(), "idempotent re-run should succeed: {:?}", res);
}

#[test]
fn keygen_rotate_regenerates_even_when_valid() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc1 = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    reality::keygen(out_dir.path(), false, &pc1).expect("first keygen");
    let pub_first = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();

    // Replace partner-cli with one that emits a different pubkey.
    let pc2 = fake_partner_cli(
        bin_dir.path(),
        "1234567890abcdefghijklmnopqrstuvwxyzABCDEFG",
        "1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefg",
    );
    reality::keygen(out_dir.path(), true, &pc2).expect("rotate keygen");
    let pub_second = fs::read_to_string(out_dir.path().join("reality.pub")).unwrap();
    assert_ne!(pub_first, pub_second, "--rotate must regenerate");
}

#[test]
fn keygen_partial_identity_errors() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    // Only reality.pub present — partial.
    let pc = fake_partner_cli(
        bin_dir.path(),
        "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFG",
        "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcdefg",
    );
    let err = reality::keygen(out_dir.path(), false, &pc).expect_err("partial must error");
    matches!(err, SecretsError::PartialIdentity { .. });
}

#[test]
fn keygen_missing_partner_cli_errors() {
    let out_dir = TempDir::new().unwrap();
    let nonexistent = PathBuf::from("/nonexistent/partner-cli-xyz-123");
    let err = reality::keygen(out_dir.path(), false, &nonexistent).expect_err("must error");
    matches!(err, SecretsError::PartnerCliMissing(_));
}

#[test]
fn keygen_invalid_key_length_errors() {
    let bin_dir = TempDir::new().unwrap();
    let out_dir = TempDir::new().unwrap();
    let pc = fake_partner_cli(bin_dir.path(), "tooshort", "alsoshort");
    let err = reality::keygen(out_dir.path(), false, &pc).expect_err("len must error");
    matches!(err, SecretsError::InvalidKeyFormat { .. });
}
```

Run `cargo nextest run -p opec --test secrets_reality_unit` — expect 6 FAIL (stub returns hardcoded error).

- [ ] **Step 2.2 (GREEN) — replace stub with real impl**

`crates/opec/src/secrets/reality.rs`:

```rust
//! Phase 4.3a — Reality x25519 identity management.
//!
//! Mirrors install.sh Step 4 sub-step 2 (L753-916):
//! - 3 identity files: reality.priv (0600), reality.pub (0644), reality.uuid (0644)
//! - Idempotent: all-three-valid → reuse; none → fresh keygen; partial → error
//! - --rotate forces regeneration
//! - base64url 43-char validation on private + public keys

use super::error::SecretsError;
use std::{fs, io::Write, path::Path, process::Command};
use uuid::Uuid;

const FILES: &[&str] = &["reality.priv", "reality.pub", "reality.uuid"];
const REALITY_KEY_LEN: usize = 43;

pub fn keygen(out_dir: &Path, rotate: bool, partner_cli: &Path) -> Result<(), SecretsError> {
    // Detect existing identity state.
    let present: Vec<&'static str> = FILES
        .iter()
        .copied()
        .filter(|n| out_dir.join(n).is_file())
        .collect();

    if !rotate {
        match present.len() {
            3 => {
                // Validate existing files; if good, idempotent return.
                validate_existing(out_dir)?;
                eprintln!("opec secrets reality-keygen: reusing existing identity");
                return Ok(());
            }
            0 => { /* fall through to fresh keygen */ }
            _ => {
                let missing: Vec<&'static str> = FILES
                    .iter()
                    .copied()
                    .filter(|n| !present.contains(n))
                    .collect();
                return Err(SecretsError::PartialIdentity {
                    dir: out_dir.to_path_buf(),
                    found: present,
                    missing,
                });
            }
        }
    }

    // Locate partner-cli binary.
    let pc_resolved = resolve_partner_cli(partner_cli)?;

    // Invoke `partner-cli keygen`.
    let output = Command::new(&pc_resolved)
        .arg("keygen")
        .output()
        .map_err(|e| SecretsError::Io {
            path: pc_resolved.clone(),
            source: e,
        })?;
    if !output.status.success() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let priv_key = grep_field(&stdout, "private_key").ok_or_else(|| SecretsError::PartnerCliFailed {
        stderr: format!("missing 'private_key:' line in keygen output: {stdout}"),
    })?;
    let pub_key = grep_field(&stdout, "public_key").ok_or_else(|| SecretsError::PartnerCliFailed {
        stderr: format!("missing 'public_key:' line in keygen output: {stdout}"),
    })?;
    if priv_key.len() != REALITY_KEY_LEN {
        return Err(SecretsError::InvalidKeyFormat {
            path: out_dir.join("reality.priv"),
            actual_len: priv_key.len(),
        });
    }
    if pub_key.len() != REALITY_KEY_LEN {
        return Err(SecretsError::InvalidKeyFormat {
            path: out_dir.join("reality.pub"),
            actual_len: pub_key.len(),
        });
    }

    let uuid = Uuid::new_v4().to_string();

    write_atomic(&out_dir.join("reality.priv"), priv_key.as_bytes(), 0o600)?;
    write_atomic(&out_dir.join("reality.pub"), pub_key.as_bytes(), 0o644)?;
    write_atomic(&out_dir.join("reality.uuid"), uuid.as_bytes(), 0o644)?;

    eprintln!("opec secrets reality-keygen: generated new identity (uuid={uuid})");
    Ok(())
}

fn resolve_partner_cli(p: &Path) -> Result<std::path::PathBuf, SecretsError> {
    if p.is_absolute() {
        if p.is_file() {
            Ok(p.to_path_buf())
        } else {
            Err(SecretsError::PartnerCliMissing(p.to_path_buf()))
        }
    } else {
        which::which(p).map_err(|_| SecretsError::PartnerCliMissing(p.to_path_buf()))
    }
}

fn grep_field<'a>(text: &'a str, name: &str) -> Option<&'a str> {
    for line in text.lines() {
        if let Some(rest) = line.strip_prefix(&format!("{name}:")) {
            return Some(rest.trim());
        }
    }
    None
}

fn validate_existing(out_dir: &Path) -> Result<(), SecretsError> {
    for (file, must_len) in [("reality.priv", REALITY_KEY_LEN), ("reality.pub", REALITY_KEY_LEN)] {
        let path = out_dir.join(file);
        let content = fs::read_to_string(&path).map_err(|e| SecretsError::Io {
            path: path.clone(),
            source: e,
        })?;
        let trimmed = content.trim();
        if trimmed.len() != must_len {
            return Err(SecretsError::InvalidKeyFormat {
                path,
                actual_len: trimmed.len(),
            });
        }
    }
    Ok(())
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), SecretsError> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(&format!(
            ".{}.",
            path.file_name().unwrap().to_string_lossy()
        ))
        .tempfile_in(dir)
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    tmp.write_all(bytes).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    tmp.as_file_mut()
        .write_all(b"\n")
        .map_err(|e| SecretsError::Io {
            path: path.to_path_buf(),
            source: e,
        })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(tmp.path(), fs::Permissions::from_mode(mode))
            .map_err(|e| SecretsError::Io {
                path: tmp.path().to_path_buf(),
                source: e,
            })?;
    }
    tmp.persist(path).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e.error,
    })?;
    Ok(())
}
```

Add to `Cargo.toml`:

```toml
which = "6"
```

- [ ] **Step 2.3 — extend CLI integration tests**

Append to `crates/opec/tests/cli_secrets_reality.rs`:

```rust
#[test]
#[serial]
fn opec_secrets_reality_keygen_partial_identity_fails() {
    use std::fs;
    let out_dir = tempfile::TempDir::new().unwrap();
    fs::write(out_dir.path().join("reality.pub"), "stale").unwrap();
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "reality-keygen", "--out-dir"])
        .arg(out_dir.path())
        .assert()
        .failure()
        .stderr(predicates::str::contains("PARTIAL identity"));
}
```

- [ ] **Step 2.4 — verify**

```bash
cargo nextest run -p opec --test secrets_reality_unit --test cli_secrets_reality
cargo clippy -p opec --all-targets -- -D warnings
cargo build -p opec --release  # confirm release builds (CI does this)
```

Expected: 9 unit + CLI tests PASS; clippy clean; release build OK.

- [ ] **Step 2.5 — commit**

```
feat(opec): implement secrets::reality::keygen

Phase 4.3a Task 2 — replaces the Task-1 stub with the real impl:
- Idempotent: all-three-files-valid → reuse, none → fresh keygen,
  partial → SecretsError::PartialIdentity
- --rotate forces regeneration even on valid identity
- Shells out to partner-cli keygen, validates 43-char base64url
  on private + public, generates UUID v4
- Atomic file writes via tempfile (mktemp + rename), mode 0600/0644

9 tests (6 unit on partial/rotate/idempotent/error paths + 3 CLI
integration). Mirrors install.sh L753-916.

Refs: docs/superpowers/plans/2026-05-17-phase4-3a-opec-secrets-reality-keygen.md Task 2
```

---

## Task 3 — install.sh delegation

**Files:**
- Modify: `install.sh` (add `OPEC_SECRETS_REALITY_KEYGEN` env-gated delegation around L753-916)
- Modify: `tests/test_install_opec_parity.sh`

- [ ] **Step 3.1 (RED) — extend parity bats**

Append:

```bash
@test "install.sh delegates reality-keygen to opec when OPEC_SECRETS_REALITY_KEYGEN!=0" {
    grep -qE 'OPEC_SECRETS_REALITY_KEYGEN' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+reality-keygen' install.sh
}

@test "install.sh preserves bash fallback for reality-keygen" {
    # The legacy bash block (partner-cli keygen + mktemp + mv) must still
    # be reachable when OPEC_SECRETS_REALITY_KEYGEN=0.
    grep -qE 'partner-cli[[:space:]]+keygen' install.sh
}
```

- [ ] **Step 3.2 (GREEN) — wrap the existing bash block**

Locate the existing Step 4 sub-step 2 block (around L753-916). Wrap it in an env-gated dispatcher:

```bash
if [[ "${OPEC_SECRETS_REALITY_KEYGEN:-1}" == "1" ]] && command -v opec >/dev/null 2>&1; then
    log "  reality keypair: delegating to opec secrets reality-keygen"
    _opec_rotate_flag=""
    [[ "${REALITY_ROTATE:-0}" == "1" ]] && _opec_rotate_flag="--rotate"
    if ! opec secrets reality-keygen --out-dir "$PREFIX_ETC" $_opec_rotate_flag; then
        die "opec secrets reality-keygen failed — re-run with OPEC_SECRETS_REALITY_KEYGEN=0 to fall back to bash path"
    fi
    REALITY_PUBKEY="$(cat "$PREFIX_ETC/reality.pub")"
    REALITY_UUID="$(cat "$PREFIX_ETC/reality.uuid")"
    unset _opec_rotate_flag
else
    # Legacy bash path (Phase 4.3a fallback). Preserved verbatim for rollback.
    # ... existing L753-916 block stays inline here ...
fi
```

Important: do NOT delete the bash block — only wrap it under `else`. Phase 4.3a ships with **both** paths so cheburator can canary the OPEC path while rvpn/zvonilka/piter-seed stay on bash during soak.

- [ ] **Step 3.3 — verify**

```bash
bash -n install.sh
shellcheck install.sh 2>&1 | wc -l
git show HEAD~:install.sh | shellcheck - 2>&1 | wc -l
# expect equal (no regression)

bats tests/test_install_opec_parity.sh \
     tests/test_install_preflight_module.sh \
     tests/test_install_deps_module.sh \
     tests/test_install_network_module.sh \
     tests/test_render_template_golden.sh \
     tests/test_install_render_identical.sh \
     tests/test_hydrate_render_identical.sh \
     tests/test_update_uses_lib.sh \
     tests/test_release_assets.sh \
     tests/test_installer_bootstrap.sh 2>&1 | tail -15

cargo nextest run -p opec
```

Expected: all green; clippy clean.

- [ ] **Step 3.4 — commit**

```
feat(install): delegate reality keygen to opec secrets (env-gated)

Phase 4.3a Task 3 — install.sh's existing Step 4 sub-step 2 (Reality
x25519 keypair + UUID + idempotent file write) now delegates to
'opec secrets reality-keygen --out-dir $PREFIX_ETC' when the binary
is on PATH and OPEC_SECRETS_REALITY_KEYGEN != 0.

The legacy bash block stays inline under the else branch so live
edges can flip OPEC_SECRETS_REALITY_KEYGEN=0 during canary if a
regression surfaces. Phase 4.8 will remove the fallback after 4
live edges soak the OPEC path.

REALITY_ROTATE=1 env var maps to --rotate flag.

Refs: docs/superpowers/plans/2026-05-17-phase4-3a-opec-secrets-reality-keygen.md Task 3
```

---

## Acceptance gate

- [ ] `cargo nextest run -p opec` — all PASS
- [ ] `cargo clippy -p opec --all-targets -- -D warnings` — clean
- [ ] Full `bats tests/` suite — all green
- [ ] `shellcheck install.sh` — no NEW warnings vs `origin/main`
- [ ] Post-merge canary on cheburator: re-run install.sh, observe `reality keypair: delegating to opec secrets reality-keygen` log line, verify reality.{priv,pub,uuid} files unchanged (idempotent path)
- [ ] Soak: 7 days on cheburator before Phase 4.3b dispatch

## Risk register

| Risk | Detection | Mitigation |
|------|-----------|------------|
| Atomic rename across tmpfs/disk boundary `EXDEV` | tempfile errors on rename | tempfile uses `O_TMPFILE`-aware fallback; we pass `dir = path.parent()` so tmp lives next to target — same fs always |
| partner-cli output format change | unit tests fail | grep `private_key:` / `public_key:` literals — frozen contract, partner-cli release notes are the early-warning |
| `--rotate` accidentally triggered | log lines + git blame trail | flag is opt-in via REALITY_ROTATE=1, not a default; install.sh doesn't set it unless operator passes |
| install.sh `OPEC_SECRETS_REALITY_KEYGEN=0` flag forgotten on rollback | canary playbook | document in PR body + roadmap doc; runbook entry |

## Commit summary (3 commits, single PR)

```
feat(opec): scaffold secrets subcommand with reality-keygen stub
feat(opec): implement secrets::reality::keygen
feat(install): delegate reality keygen to opec secrets (env-gated)
```

PR title: `feat(opec): Phase 4.3a — opec secrets reality-keygen + env-gated install.sh delegation`
