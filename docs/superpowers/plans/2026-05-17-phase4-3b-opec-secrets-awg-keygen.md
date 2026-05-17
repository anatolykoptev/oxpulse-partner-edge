# Phase 4.3b — `opec secrets awg-keygen`

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development.

**Goal:** Absorb install.sh Step 4 AWG keypair block (L988-1009, ~22 LoC bash inside the register `else` branch) into `opec secrets awg-keygen` subcommand. Mirror Phase 4.3a `reality-keygen` structure — same patterns, different binary (`wg` instead of `partner-cli`).

**Architecture:**
- Add `SecretsCommands::AwgKeygen { out_dir, rotate, wg }` to existing `crates/opec/src/secrets/mod.rs`.
- New module `crates/opec/src/secrets/awg.rs` — shells out to `wg genkey` + `wg pubkey`.
- install.sh delegation wraps the inline block at L988-1009 under `OPEC_SECRETS_AWG_KEYGEN=${...:-1}` gate, preserves bash fallback for canary rollback.
- **Existing invariants to preserve** (caught at 4.3a quality round):
  - `DRY_RUN=1` → no side effects (OPEC path emits warn + placeholder `AWG_PUBKEY="dryrun-awg-pubkey-placeholder"`)
  - `FORCE_KEYGEN=1` → `--rotate` flag mapping
  - Skip both paths entirely when `MANUAL_CONFIG` is set (existing register-branch logic — DOES NOT need OPEC delegation; manual-config bypasses register entirely)
  - Skip when `wg` not on PATH AND `install_wg_tools_for_keygen` was the fallback — `command -v opec` check guards on the OPEC side; bash side preserves the `install_wg_tools_for_keygen` invocation

**Tech Stack:** Rust 2021, `clap`, `tempfile`, `which`. NO new deps (4.3a already added everything).

**Out of scope:**
- Phase 4.3c: register POST + branding body construction + response parse
- Phase 4.3d: SFU signing key fetch + JWT synthesis
- `install_wg_tools_for_keygen` — operator-level concern, stays in install.sh (would need apt-get/dnf shell-out — bad fit for OPEC subcommand)

**Roadmap ref:** `docs/superpowers/specs/2026-05-17-phase4-install-decomposition-roadmap.md` (Phase 4.3b row updated post-merge: AWG-only scope, register chunked into 4.3c)

## File structure

```
crates/opec/src/secrets/
├── mod.rs                                # MODIFY — add AwgKeygen variant + dispatch arm
└── awg.rs                                # NEW — keygen() impl
crates/opec/tests/
├── cli_secrets_awg.rs                    # NEW — CLI integration
└── secrets_awg_unit.rs                   # NEW — unit tests
install.sh                                # MODIFY (T3)
tests/test_install_opec_parity.sh         # MODIFY (T3)
```

---

## Task 1 — `opec secrets awg-keygen` skeleton + stub

**Files:**
- Modify: `crates/opec/src/secrets/mod.rs`
- Create: `crates/opec/src/secrets/awg.rs`
- Create: `crates/opec/tests/cli_secrets_awg.rs`

- [ ] **Step 1.1 (RED) — CLI integration tests**

`crates/opec/tests/cli_secrets_awg.rs`:

```rust
//! Phase 4.3b — opec secrets awg-keygen CLI integration tests.
use assert_cmd::Command;
use serial_test::serial;

#[test]
#[serial]
fn opec_secrets_help_lists_awg_keygen() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "--help"])
        .assert()
        .success()
        .stdout(predicates::str::contains("awg-keygen"));
}

#[test]
#[serial]
fn opec_secrets_awg_keygen_requires_out_dir() {
    Command::cargo_bin("opec")
        .unwrap()
        .args(["secrets", "awg-keygen"])
        .assert()
        .failure()
        .stderr(predicates::str::contains("--out-dir"));
}
```

Run `cargo nextest run -p opec --test cli_secrets_awg` — expect 2 FAIL.

- [ ] **Step 1.2 (GREEN) — extend SecretsCommands + stub**

In `crates/opec/src/secrets/mod.rs`:

```rust
pub mod awg;
```

(near existing `pub mod reality;`)

Extend the `SecretsCommands` enum:

```rust
    /// Generate or reuse AmneziaWG keypair (awg-private.key, awg-public.key).
    AwgKeygen {
        /// Directory to write keypair files to.
        #[arg(long)]
        out_dir: PathBuf,
        /// Force regeneration even when valid keypair exists.
        #[arg(long)]
        rotate: bool,
        /// Override wg binary path (test hook).
        #[arg(long, default_value = "wg")]
        wg: PathBuf,
    },
```

Extend `dispatch`:

```rust
        SecretsCommands::AwgKeygen { out_dir, rotate, wg } => {
            awg::keygen(&out_dir, rotate, &wg).map_err(Into::into)
        }
```

Create `crates/opec/src/secrets/awg.rs` (stub):

```rust
//! Phase 4.3b — AmneziaWG (wg-tools) keypair management.
//! Task 1 ships the CLI surface only; the real impl arrives in Task 2.

use super::error::SecretsError;
use std::path::Path;

/// Stub — Task 2 replaces this.
pub fn keygen(_out_dir: &Path, _rotate: bool, _wg: &Path) -> Result<(), SecretsError> {
    unimplemented!("opec::secrets::awg::keygen — Task 2 implements this")
}
```

- [ ] **Step 1.3 — verify**

```bash
cargo build -p opec
cargo nextest run -p opec --test cli_secrets_awg
cargo clippy -p opec --all-targets -- -D warnings
```

Expected: 2/2 PASS; clippy clean.

- [ ] **Step 1.4 — commit**

```
feat(opec): scaffold secrets awg-keygen subcommand with stub

Phase 4.3b Task 1 — adds SecretsCommands::AwgKeygen variant alongside
existing RealityKeygen. New module crates/opec/src/secrets/awg.rs with
unimplemented!() stub; real impl lives in Task 2.

Refs: docs/superpowers/plans/2026-05-17-phase4-3b-opec-secrets-awg-keygen.md
```

---

## Task 2 — `secrets::awg::keygen` real impl

**Files:**
- Modify: `crates/opec/src/secrets/awg.rs`
- Modify: `crates/opec/tests/cli_secrets_awg.rs`
- Create: `crates/opec/tests/secrets_awg_unit.rs`

- [ ] **Step 2.1 (RED) — unit tests**

`crates/opec/tests/secrets_awg_unit.rs`:

```rust
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
    matches!(err, SecretsError::PartnerCliMissing(_));
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
```

Run `cargo nextest run -p opec --test secrets_awg_unit` — expect 5 FAIL (stub panics).

- [ ] **Step 2.2 (GREEN) — real impl**

`crates/opec/src/secrets/awg.rs`:

```rust
//! Phase 4.3b — AmneziaWG (wg-tools) keypair management.
//!
//! Mirrors install.sh Step 4 AWG block (L988-1009):
//! - 2 files: awg-private.key (0600), awg-public.key (0644)
//! - Idempotent: existing priv → derive pub via `wg pubkey`; missing priv → fresh keygen
//! - --rotate forces regeneration of priv
//! - Empty/missing priv on idempotent path = treat as missing (regenerate)

use super::error::SecretsError;
use std::{fs, io::Write, path::Path, process::Command};

const PRIV_FILE: &str = "awg-private.key";
const PUB_FILE: &str = "awg-public.key";

pub fn keygen(out_dir: &Path, rotate: bool, wg: &Path) -> Result<(), SecretsError> {
    let priv_path = out_dir.join(PRIV_FILE);
    let pub_path = out_dir.join(PUB_FILE);

    let wg_resolved = resolve_wg(wg)?;

    // Decide whether we need fresh keygen.
    let priv_exists_nonempty = match fs::metadata(&priv_path) {
        Ok(m) => m.is_file() && m.len() > 0,
        Err(_) => false,
    };

    if rotate || !priv_exists_nonempty {
        let priv_key = run_wg(&wg_resolved, &["genkey"], None)?;
        let priv_trimmed = priv_key.trim();
        if priv_trimmed.is_empty() {
            return Err(SecretsError::PartnerCliFailed {
                stderr: "wg genkey emitted empty output".into(),
            });
        }
        write_atomic(&priv_path, priv_trimmed.as_bytes(), 0o600)?;
    }

    // Derive pub from priv (re-derive every run so a stale awg-public.key
    // gets refreshed even on idempotent re-runs).
    let priv_content = fs::read_to_string(&priv_path).map_err(|e| SecretsError::Io {
        path: priv_path.clone(),
        source: e,
    })?;
    let pub_key = run_wg(&wg_resolved, &["pubkey"], Some(&priv_content))?;
    let pub_trimmed = pub_key.trim();
    if pub_trimmed.is_empty() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: "wg pubkey emitted empty output".into(),
        });
    }
    write_atomic(&pub_path, pub_trimmed.as_bytes(), 0o644)?;

    eprintln!("opec secrets awg-keygen: awg-public.key = {pub_trimmed}");
    Ok(())
}

fn resolve_wg(p: &Path) -> Result<std::path::PathBuf, SecretsError> {
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

fn run_wg(bin: &Path, args: &[&str], stdin: Option<&str>) -> Result<String, SecretsError> {
    let mut cmd = Command::new(bin);
    cmd.args(args);
    let output = if let Some(s) = stdin {
        cmd.stdin(std::process::Stdio::piped());
        cmd.stdout(std::process::Stdio::piped());
        cmd.stderr(std::process::Stdio::piped());
        let mut child = cmd.spawn().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?;
        if let Some(mut sin) = child.stdin.take() {
            sin.write_all(s.as_bytes()).map_err(|e| SecretsError::Io {
                path: bin.to_path_buf(),
                source: e,
            })?;
        }
        child.wait_with_output().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?
    } else {
        cmd.output().map_err(|e| SecretsError::Io {
            path: bin.to_path_buf(),
            source: e,
        })?
    };
    if !output.status.success() {
        return Err(SecretsError::PartnerCliFailed {
            stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
        });
    }
    Ok(String::from_utf8_lossy(&output.stdout).into_owned())
}

fn write_atomic(path: &Path, bytes: &[u8], mode: u32) -> Result<(), SecretsError> {
    let dir = path.parent().unwrap_or_else(|| Path::new("."));
    let mut tmp = tempfile::Builder::new()
        .prefix(&format!(
            ".{}.",
            path.file_name().unwrap_or_default().to_string_lossy()
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
    tmp.as_file_mut().write_all(b"\n").map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e,
    })?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(tmp.path(), fs::Permissions::from_mode(mode)).map_err(|e| {
            SecretsError::Io {
                path: tmp.path().to_path_buf(),
                source: e,
            }
        })?;
    }
    tmp.persist(path).map_err(|e| SecretsError::Io {
        path: path.to_path_buf(),
        source: e.error,
    })?;
    Ok(())
}
```

- [ ] **Step 2.3 — verify**

```bash
cargo nextest run -p opec --test secrets_awg_unit --test cli_secrets_awg
cargo nextest run -p opec
cargo clippy -p opec --all-targets -- -D warnings
cargo build -p opec --release
```

Expected: 5 unit + 2 CLI PASS; clippy clean; release OK.

- [ ] **Step 2.4 — commit**

```
feat(opec): implement secrets::awg::keygen

Phase 4.3b Task 2 — real impl shells out to `wg genkey` + `wg pubkey`.
Mirrors install.sh L988-1009 verbatim semantically:
- Idempotent on priv-exists-and-nonempty (re-derive pub each run)
- --rotate forces fresh priv keygen
- Empty priv treated as missing (regenerate)
- File modes: priv 0600, pub 0644, atomic writes via tempfile

5 unit + 2 CLI tests (fresh, idempotent, rotate, missing-wg, empty-priv).

Refs: docs/superpowers/plans/2026-05-17-phase4-3b-opec-secrets-awg-keygen.md Task 2
```

---

## Task 3 — install.sh delegate AWG keygen

**Files:**
- Modify: `install.sh` (wrap L988-1009 in `OPEC_SECRETS_AWG_KEYGEN` gate)
- Modify: `tests/test_install_opec_parity.sh`

- [ ] **Step 3.1 (RED) — extend parity bats**

```bash
@test "install.sh delegates awg-keygen to opec when OPEC_SECRETS_AWG_KEYGEN!=0" {
    grep -qE 'OPEC_SECRETS_AWG_KEYGEN' install.sh
    grep -qE 'opec[[:space:]]+secrets[[:space:]]+awg-keygen' install.sh
}

@test "install.sh preserves bash fallback for awg-keygen" {
    grep -qE 'wg[[:space:]]+genkey' install.sh
    grep -qE 'wg[[:space:]]+pubkey' install.sh
}

@test "install.sh OPEC awg path honors DRY_RUN" {
    awk '/OPEC_SECRETS_AWG_KEYGEN/,/^[[:space:]]*else$/' install.sh \
        | grep -qE 'DRY_RUN[[:space:]]*-eq[[:space:]]*1|dryrun-awg-pubkey-placeholder'
}

@test "install.sh OPEC awg path maps FORCE_KEYGEN to --rotate" {
    awk '/OPEC_SECRETS_AWG_KEYGEN/,/^[[:space:]]*else$/' install.sh \
        | grep -qE 'FORCE_KEYGEN[[:space:]]*-eq[[:space:]]*1.*--rotate|--rotate.*FORCE_KEYGEN'
}
```

- [ ] **Step 3.2 (GREEN) — wrap the AWG block**

In `install.sh`, locate the AWG keypair block (current L988-1009, the `if [[ $DRY_RUN -eq 0 ]]; then ... AWG_PUBKEY=... else AWG_PUBKEY="dryrun..." fi` chunk inside the register `else` branch).

Wrap it:

```bash
		if [[ "${OPEC_SECRETS_AWG_KEYGEN:-1}" == "1" ]] && command -v opec >/dev/null 2>&1; then
			if [[ $DRY_RUN -eq 1 ]]; then
				warn "  [dry-run] would invoke: opec secrets awg-keygen --out-dir $PREFIX_ETC$([[ $FORCE_KEYGEN -eq 1 ]] && echo ' --rotate')"
				AWG_PUBKEY="dryrun-awg-pubkey-placeholder"
			else
				log "  awg keypair: delegating to opec secrets awg-keygen"
				install -d -m 0700 "$PREFIX_ETC"
				if ! command -v wg >/dev/null 2>&1; then
					install_wg_tools_for_keygen
				fi
				_opec_args=(secrets awg-keygen --out-dir "$PREFIX_ETC")
				[[ $FORCE_KEYGEN -eq 1 ]] && _opec_args+=(--rotate)
				if ! opec "${_opec_args[@]}"; then
					die "opec secrets awg-keygen failed — re-run with OPEC_SECRETS_AWG_KEYGEN=0 to fall back to bash path"
				fi
				AWG_PUBKEY="$(cat "$AWG_PUB_PATH")" \
					|| die "post-awg-keygen: failed to read $AWG_PUB_PATH"
				log "  awg pubkey: $AWG_PUBKEY"
				unset _opec_args
			fi
		else
			# === Legacy bash path (Phase 4.3b fallback). Preserved for rollback. ===
			# (existing AWG_PRIV_PATH/AWG_PUB_PATH/wg-genkey/wg-pubkey block stays here)
			...existing L988-1009 block...
		fi
```

Notes:
- `install -d -m 0700 "$PREFIX_ETC"` was inside the bash branch; keep it in the OPEC branch too — OPEC writes into PREFIX_ETC, dir must exist.
- `install_wg_tools_for_keygen` invocation also stays in the OPEC branch — OPEC depends on `wg` binary, so we still need to install wg-tools.
- `AWG_PRIV_PATH` and `AWG_PUB_PATH` are set just BEFORE the dispatcher (currently L988-989: `AWG_PRIV_PATH="$PREFIX_ETC/awg-private.key"`). Those vars stay outside the wrapper.

- [ ] **Step 3.3 — verify**

```bash
bash -n install.sh
shellcheck install.sh 2>&1 | wc -l
git show HEAD:install.sh | shellcheck - 2>&1 | wc -l
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

cargo nextest run -p opec 2>&1 | tail -5
```

Expected: all green; clippy clean.

- [ ] **Step 3.4 — commit**

```
feat(install): delegate AWG keygen to opec secrets (env-gated)

Phase 4.3b Task 3 — install.sh's AWG keypair block (L988-1009, inside
the register else branch) now delegates to 'opec secrets awg-keygen
--out-dir $PREFIX_ETC' when the binary is on PATH and
OPEC_SECRETS_AWG_KEYGEN != 0.

Carries the lessons from 4.3a quality review:
- DRY_RUN guard preserved (placeholder AWG_PUBKEY emitted)
- FORCE_KEYGEN maps to --rotate
- install_wg_tools_for_keygen still invoked on the OPEC path so the wg
  binary is available before OPEC tries to spawn it
- Legacy bash block intact under else for canary rollback

Refs: docs/superpowers/plans/2026-05-17-phase4-3b-opec-secrets-awg-keygen.md Task 3
```

---

## Acceptance gate

- [ ] `cargo nextest run -p opec` — all PASS (target 92/92 = 85 prior + 7 new)
- [ ] `cargo clippy -p opec --all-targets -- -D warnings` — clean
- [ ] `cargo machete -p opec` — no unused deps
- [ ] Full bats — all PASS
- [ ] `shellcheck install.sh` — no NEW warnings vs origin/main
- [ ] Post-merge canary on cheburator: re-run install.sh, observe `awg keypair: delegating to opec secrets awg-keygen` log, verify `awg-private.key`/`awg-public.key` unchanged on idempotent path

## Risk register

| Risk | Detection | Mitigation |
|------|-----------|------------|
| `wg pubkey` stdin pipe race | unit test with fake wg + assertion | use `wait_with_output` (synchronous), not raw spawn |
| Idempotent path stale pub (priv rotated externally, pub not updated) | re-derive on every run | always re-run `wg pubkey` even on idempotent priv path |
| `install_wg_tools_for_keygen` only on bash side | OPEC path fails with "wg not found" | invocation lives in BOTH branches |
| Empty priv key file | unit test `awg_keygen_corrupted_priv_on_idempotent_path_regenerates` | treat empty file as missing → regenerate |

## Commit summary (3 commits, single PR)

```
feat(opec): scaffold secrets awg-keygen subcommand with stub
feat(opec): implement secrets::awg::keygen
feat(install): delegate AWG keygen to opec secrets (env-gated)
```

PR title: `feat(opec): Phase 4.3b — opec secrets awg-keygen + env-gated install.sh delegation`
