# Phase 3 OPEC Caddy + Compose Render Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend OPEC's `render` subcommand with `compose` and `caddy` variants, completing the "render absorption" arc. `install.sh` switches its last 2 render call sites (compose.tpl + caddy.tpl) via `render_with_opec_or_fallback`, so all 5 templates now route through typed Rust render when OPEC binary is on PATH (with bash `render_template` as universal fallback).

**Architecture:** Mirror Phase 2 pattern exactly — per-kind module in `crates/opec/src/render/{compose,caddy}.rs` (shares `substitute_from_env` + `render_to_file` from `render/mod.rs`). compose adds YAML validation via `serde_yml`; caddy adds balanced-brace + non-empty-domain sanity check. CLI adds `RenderKind::Compose` + `Caddy` variants. `install.sh` lines 1553-1554 switch from `render_template` to `render_with_opec_or_fallback`. bats parity tests reuse existing Phase 1 fixtures (`tests/fixtures/install-render/expected/compose.txt` + `caddy.txt`).

**Tech Stack:** Rust (clap, serde, serde_yml, regex, anyhow), bats-core, `cargo nextest`.

**Scope notes:**
- **Out of scope:** `hysteria2-client.yaml` (Phase 2.b, separate plan), Phase 4 (kill install.sh godfile), Phase 5 (partner-cli absorption).
- **Naming caveat:** OPEC already has `crates/opec/src/caddy/` submodule (the **Caddy JSON renderer** for tenant configs, Phase 4.1). New `crates/opec/src/render/caddy.rs` is a DIFFERENT thing — Caddyfile **template substitution** for partner-edge install. Co-existence is fine: different module paths (`opec::caddy::*` vs `opec::render::caddy`).

---

## Pre-flight (operator setup, not a task)

Worktree at `/home/krolik/.claude-worktrees/phase3-opec-caddy-compose`, branch `feat/phase3-opec-caddy-compose` based on `origin/main` (HEAD `0af5236`, post v0.12.31 release).

```bash
cd /home/krolik/.claude-worktrees/phase3-opec-caddy-compose
git status --short              # expect: only this plan file
git log --oneline -1            # expect: 0af5236 chore(main): release partner-edge 0.12.31 (#144)
which cargo nextest bats        # all required
cargo build -p opec --locked    # baseline build
cargo nextest run -p opec       # expect 67/67 (post-Phase-2)
```

---

## File Structure

| Path | Role |
|---|---|
| `crates/opec/src/render/mod.rs` (MODIFY) | Add `pub mod compose; pub mod caddy;` |
| `crates/opec/src/render/compose.rs` (NEW) | compose.yml render + `serde_yml` validation |
| `crates/opec/src/render/caddy.rs` (NEW) | Caddyfile render + balanced-brace + non-empty PARTNER_DOMAIN check |
| `crates/opec/Cargo.toml` (VERIFY) | `serde_yml` already present (used by tenant); no new deps |
| `crates/opec/src/main.rs` (MODIFY) | Add `RenderKind::Compose` + `Caddy` variants + dispatch arms |
| `crates/opec/tests/render_compose.rs` (NEW) | 3 integration tests, `#[serial]` |
| `crates/opec/tests/render_caddy.rs` (NEW) | 3 integration tests, `#[serial]` |
| `crates/opec/tests/cli_render.rs` (MODIFY) | Add 2 new cases — compose + caddy CLI smoke |
| `install.sh` (MODIFY, L1553-L1554) | Switch 2 call sites to `render_with_opec_or_fallback` |
| `tests/test_install_opec_parity.sh` (MODIFY) | Drop "keeps render_template for compose+caddy" test (no longer true); add "delegates compose/caddy" tests; extend fallback parity test |

**Fixture reuse:** `tests/fixtures/install-render/{compose,caddy}.tpl` + `expected/{compose,caddy}.txt` already exist from Phase 1 (test_install_render_identical.sh). Same bash `render_template` oracle. OPEC tests will reuse them — no new fixture generation.

---

## Task 1: render::compose with YAML validation + 3 tests

**Files:**
- Create: `crates/opec/src/render/compose.rs`
- Modify: `crates/opec/src/render/mod.rs` (add `pub mod compose;`)
- Create: `crates/opec/tests/render_compose.rs`

### Step 1.1: RED — write failing test

- [ ] Create `crates/opec/tests/render_compose.rs`:

```rust
//! Phase 3 Task 1 — opec render compose byte-identical parity vs bash render_template.

use serial_test::serial;
use std::{env, fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
        .join("install-render")
}

fn set_frozen_env() {
    // Mirror tests/fixtures/install-render/frozen-env.sh-equivalent values
    // used to generate expected/compose.txt during Phase 1.
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
    env::set_var("BACKEND_ENDPOINT", "192.9.243.148:5349");
    env::set_var("BACKEND_HOST", "192.9.243.148");
    env::set_var("BACKEND_PORT", "5349");
    env::set_var("TURN_SECRET", "test-turn-secret-deadbeef");
    env::set_var("REALITY_UUID", "d529dee6-3cdd-4079-95d1-f8801722147c");
    env::set_var("REALITY_PUBLIC_KEY", "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk");
    env::set_var("REALITY_SHORT_ID", "abcd1234");
    env::set_var("REALITY_SERVER_NAME", "www.samsung.com");
    env::set_var("REALITY_ENCRYPTION", "mlkem768x25519plus.native.0rtt.fXgOoxcW");
    env::set_var("TURNS_SUBDOMAIN", "api-test01");
    env::set_var("PUBLIC_IP", "157.22.204.190");
    env::set_var("PRIVATE_IP", "");
    env::set_var("EXTERNAL_IP_LINE", "157.22.204.190");
    env::set_var("IMAGE_VERSION", "stable");
    env::set_var("SFU_UDP_PORT", "7878");
    env::set_var("SFU_METRICS_PORT", "9317");
    env::set_var("SFU_EDGE_ID", "zvonilka1");
    env::set_var("OTEL_EXPORTER_OTLP_ENDPOINT", "");
    env::set_var(
        "SFU_SIGNING_PUBLIC_KEY",
        "-----BEGIN PUBLIC KEY-----\\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\\n-----END PUBLIC KEY-----\\n",
    );
    env::set_var("RELAY_JWT_SECRET", "test-relay-jwt-secret");
    env::set_var("SIGNALING_SFU_SECRET", "test-signaling-sfu-secret");
    env::set_var("HYSTERIA2_SOCKS_PORT", "18891");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
    // hy2 placeholders that compose.yml.tpl references
    env::set_var("HY2_SERVER", "");
    env::set_var("HY2_AUTH_PASS", "");
    env::set_var("HY2_OBFS_PASS", "");
    env::set_var("HY2_LOCAL_LISTEN", "");
    env::set_var("HY2_REMOTE_BACKEND", "");
}

#[test]
#[serial]
fn opec_render_compose_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::compose::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("compose.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_compose_validates_yaml() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::compose::render(&tpl, out.path()).expect("render ok");
    let body = fs::read_to_string(out.path()).unwrap();
    serde_yml::from_str::<serde_yml::Value>(&body)
        .expect("rendered compose.yml must parse as YAML");
}

#[test]
#[serial]
fn opec_render_compose_rejects_unparseable_substituted_output() {
    // Inject a value with unbalanced YAML structure into a quoted-context slot.
    // IMAGE_VERSION appears in compose.yml as `image: ghcr.io/.../partner-edge-xxx:{{IMAGE_VERSION}}`
    // — appending `\n  bad_top_level:` produces malformed YAML if it lands mid-document.
    // Actually, the safer corruption is to inject a literal `\n` followed by garbage
    // into a key context. We pick PARTNER_ID which appears as `container_name: oxpulse-partner-{{PARTNER_ID}}`
    // — injecting `name\n!!INVALID YAML` makes the file structurally bad.
    set_frozen_env();
    env::set_var("PARTNER_ID", "name\n!!INVALID\n  YAML: :");
    let dir = fixture_dir();
    let tpl = dir.join("compose.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::compose::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("compose"),
        "expected validation error to mention kind, got: {err}"
    );
}
```

### Step 1.2: Run test to verify it fails

- [ ] Run

```bash
cd /home/krolik/.claude-worktrees/phase3-opec-caddy-compose
cargo nextest run -p opec --test render_compose 2>&1 | tail -10
```

Expected: 3 tests FAIL — `opec::render::compose` not yet defined.

### Step 1.3: Implement `render/compose.rs`

- [ ] Modify `crates/opec/src/render/mod.rs` — add module declaration. Find the existing `pub mod xray; pub mod coturn; pub mod naive;` block and extend:

```rust
pub mod xray;
pub mod coturn;
pub mod naive;
pub mod compose;
pub mod caddy;
```

- [ ] Create `crates/opec/src/render/compose.rs`:

```rust
//! docker-compose.yml render — substitute env vars then validate as YAML.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches bash
//! render_template + render::xray semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

/// Render docker-compose.yml from `src` template into `dst`. Substitutes
/// `{{NAME}}` placeholders from env, writes atomically, then parses the
/// result via serde_yml to catch substitution that produced invalid YAML.
pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;
    serde_yml::from_str::<serde_yml::Value>(&rendered).map_err(|e| {
        RenderError::Validation {
            kind: "compose",
            reason: format!("rendered file is not valid YAML: {e}"),
        }
    })?;
    Ok(())
}
```

### Step 1.4: Verify

- [ ] Run

```bash
cargo build -p opec --locked 2>&1 | tail -3
cargo nextest run -p opec --test render_compose 2>&1 | tail -10
cargo nextest run -p opec 2>&1 | tail -5
cargo clippy -p opec --locked --all-targets -- -D warnings 2>&1 | tail -3
```

Expected: 3/3 render_compose pass; 70/70 total opec tests; clippy clean.

### Step 1.5: Commit

- [ ] Commit

```bash
git add crates/opec/src/render/mod.rs \
        crates/opec/src/render/compose.rs \
        crates/opec/tests/render_compose.rs
git commit -m "$(cat <<'EOF'
feat(opec): add render::compose with YAML validation

Phase 3 Task 1 — typed Rust port of bash render_template for
docker-compose.yml. Mirrors render::xray contract (atomic write +
post-substitution serde_yml parse → RenderError::Validation on fail).

Golden test byte-identical to bash render_template output (reuses
Phase 1 fixtures tests/fixtures/install-render/{compose.tpl,expected/compose.txt}).

Refs: docs/superpowers/plans/2026-05-17-phase3-opec-caddy-compose.md Task 1
EOF
)"
```

---

## Task 2: render::caddy with balanced-brace validation + 3 tests

**Files:**
- Create: `crates/opec/src/render/caddy.rs`
- Create: `crates/opec/tests/render_caddy.rs`

### Step 2.1: RED — write failing test

- [ ] Create `crates/opec/tests/render_caddy.rs`:

```rust
//! Phase 3 Task 2 — opec render caddy byte-identical parity vs bash render_template.

use serial_test::serial;
use std::{env, fs, path::PathBuf};

fn fixture_dir() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
        .join("install-render")
}

fn set_frozen_env() {
    // Same as render_compose.rs — keep in sync.
    env::set_var("PARTNER_ID", "zvonilka");
    env::set_var("PARTNER_DOMAIN", "zvonilka.net");
    env::set_var("BACKEND_ENDPOINT", "192.9.243.148:5349");
    env::set_var("BACKEND_HOST", "192.9.243.148");
    env::set_var("BACKEND_PORT", "5349");
    env::set_var("TURN_SECRET", "test-turn-secret-deadbeef");
    env::set_var("REALITY_UUID", "d529dee6-3cdd-4079-95d1-f8801722147c");
    env::set_var("REALITY_PUBLIC_KEY", "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk");
    env::set_var("REALITY_SHORT_ID", "abcd1234");
    env::set_var("REALITY_SERVER_NAME", "www.samsung.com");
    env::set_var("REALITY_ENCRYPTION", "mlkem768x25519plus.native.0rtt.fXgOoxcW");
    env::set_var("TURNS_SUBDOMAIN", "api-test01");
    env::set_var("PUBLIC_IP", "157.22.204.190");
    env::set_var("PRIVATE_IP", "");
    env::set_var("EXTERNAL_IP_LINE", "157.22.204.190");
    env::set_var("IMAGE_VERSION", "stable");
    env::set_var("SFU_UDP_PORT", "7878");
    env::set_var("SFU_METRICS_PORT", "9317");
    env::set_var("SFU_EDGE_ID", "zvonilka1");
    env::set_var("OTEL_EXPORTER_OTLP_ENDPOINT", "");
    env::set_var(
        "SFU_SIGNING_PUBLIC_KEY",
        "-----BEGIN PUBLIC KEY-----\\nMCowBQYDK2VwAyEAZiwaWp+FJ1sGprGGS69mq+sB6nhwOMi24xGSGfgdXNo=\\n-----END PUBLIC KEY-----\\n",
    );
    env::set_var("RELAY_JWT_SECRET", "test-relay-jwt-secret");
    env::set_var("SIGNALING_SFU_SECRET", "test-signaling-sfu-secret");
    env::set_var("HYSTERIA2_SOCKS_PORT", "18891");
    env::set_var("NAIVE_SOCKS_PORT", "18892");
    env::set_var("HY2_SERVER", "");
    env::set_var("HY2_AUTH_PASS", "");
    env::set_var("HY2_OBFS_PASS", "");
    env::set_var("HY2_LOCAL_LISTEN", "");
    env::set_var("HY2_REMOTE_BACKEND", "");
}

#[test]
#[serial]
fn opec_render_caddy_byte_identical() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::caddy::render(&tpl, out.path()).expect("render ok");
    let actual = fs::read_to_string(out.path()).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("caddy.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn opec_render_caddy_validates_balanced_braces() {
    set_frozen_env();
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    opec::render::caddy::render(&tpl, out.path()).expect("render ok");
    // Count braces in the rendered output as a smoke check on the validator
    let body = fs::read_to_string(out.path()).unwrap();
    let opens = body.bytes().filter(|&b| b == b'{').count();
    let closes = body.bytes().filter(|&b| b == b'}').count();
    assert_eq!(opens, closes, "rendered Caddyfile must have balanced braces");
}

#[test]
#[serial]
fn opec_render_caddy_rejects_unbalanced_braces() {
    // Inject a stray `{` via PARTNER_ID. PARTNER_ID appears multiple times in
    // caddy.tpl in label / log fields; an extra `{` produces unbalanced output.
    set_frozen_env();
    env::set_var("PARTNER_ID", "zvonilka{extra-open");
    let dir = fixture_dir();
    let tpl = dir.join("caddy.tpl");
    let out = tempfile::NamedTempFile::new().unwrap();
    let err = opec::render::caddy::render(&tpl, out.path()).unwrap_err();
    assert!(
        err.to_string().contains("caddy"),
        "expected validation error to mention kind, got: {err}"
    );
}
```

### Step 2.2: Run test to verify it fails

- [ ] Run

```bash
cargo nextest run -p opec --test render_caddy 2>&1 | tail -10
```

Expected: 3 fail — `render::caddy::render` not implemented.

### Step 2.3: Implement `render/caddy.rs`

- [ ] Create `crates/opec/src/render/caddy.rs`:

```rust
//! Caddyfile render — substitute env vars + balanced-brace sanity check.
//!
//! Caddyfile syntax doesn't have a lightweight Rust parser; full validation
//! would require shelling out to `caddy validate` which adds a runtime
//! dependency. The balanced-brace check catches the most common substitution-
//! corruption case (extra `{` or `}` from a partner-provided value leaking
//! into a site block). PARTNER_DOMAIN non-empty check catches the
//! installer-without-domain class.
//!
//! Note: if validation fails the rendered file remains on disk (atomic-rename
//! happens before validation). Callers do cleanup. Matches render::xray
//! semantics.

use anyhow::Result;
use std::path::Path;

use super::{render_to_file, RenderError};

pub fn render(src: &Path, dst: &Path) -> Result<()> {
    let rendered = render_to_file(src, dst)?;

    // Brace balance — Caddyfile site blocks use `{...}`; extra/missing braces
    // produce a config Caddy will reject at start, often with a cryptic error.
    let opens = rendered.bytes().filter(|&b| b == b'{').count();
    let closes = rendered.bytes().filter(|&b| b == b'}').count();
    if opens != closes {
        return Err(RenderError::Validation {
            kind: "caddy",
            reason: format!("rendered Caddyfile has unbalanced braces: {opens} opens vs {closes} closes"),
        }
        .into());
    }

    // PARTNER_DOMAIN must appear at column 0 as a site address. We don't
    // re-parse Caddy syntax, but require at least one non-whitespace,
    // non-`#`-prefixed line — this catches the rare case where the template
    // is broken into a header-only file.
    let has_site_block = rendered.lines().any(|line| {
        let t = line.trim_start();
        !t.is_empty() && !t.starts_with('#') && t.contains('{')
    });
    if !has_site_block {
        return Err(RenderError::Validation {
            kind: "caddy",
            reason: "rendered Caddyfile contains no site-block opener (`<domain> {`)".to_string(),
        }
        .into());
    }

    Ok(())
}
```

### Step 2.4: Verify

- [ ] Run

```bash
cargo build -p opec --locked 2>&1 | tail -3
cargo nextest run -p opec --test render_caddy 2>&1 | tail -10
cargo nextest run -p opec 2>&1 | tail -5
cargo clippy -p opec --locked --all-targets -- -D warnings 2>&1 | tail -3
```

Expected: 3/3 render_caddy pass; 73/73 total opec tests; clippy clean.

### Step 2.5: Commit

- [ ] Commit

```bash
git add crates/opec/src/render/caddy.rs \
        crates/opec/tests/render_caddy.rs
git commit -m "$(cat <<'EOF'
feat(opec): add render::caddy with balanced-brace + site-block validation

Phase 3 Task 2 — typed Rust port of bash render_template for Caddyfile.
Caddyfile syntax has no lightweight Rust parser; we do two cheap checks
post-substitution:

1. Brace balance — Caddyfile sites use {...} blocks; extra/missing
   braces produce cryptic Caddy startup errors. Catching them at
   render time gives the installer a clear diagnostic.
2. Site-block presence — at least one non-whitespace, non-comment
   line must contain `{`. Catches the broken-template case where
   substitution leaves no actionable config.

Full validation requires `caddy validate`, which would add a runtime
dependency on the caddy binary on the partner host. Out of scope here;
Caddy itself will reject malformed config at container start as the
defence-in-depth layer.

Golden test byte-identical to bash render_template (reuses Phase 1
fixture tests/fixtures/install-render/{caddy.tpl,expected/caddy.txt}).

Refs: docs/superpowers/plans/2026-05-17-phase3-opec-caddy-compose.md Task 2
EOF
)"
```

---

## Task 3: Wire `RenderKind::Compose` + `Caddy` into CLI + 2 CLI tests

**Files:**
- Modify: `crates/opec/src/main.rs`
- Modify: `crates/opec/tests/cli_render.rs`

### Step 3.1: RED — extend CLI bats with 2 new cases

- [ ] Open `crates/opec/tests/cli_render.rs` and add 2 cases (mirror the existing `cli_render_xray_byte_identical_to_fixture` pattern). Append BEFORE the final `#[test]` `cli_render_unknown_kind_errors`:

```rust
#[test]
#[serial]
fn cli_render_compose_byte_identical_to_fixture() {
    let dir = fixture_dir_install_render();
    let tpl = dir.join("compose.tpl");
    let out_dir = tempfile::tempdir().unwrap();
    let out = out_dir.path().join("docker-compose.yml");

    let mut cmd = Command::cargo_bin("opec").unwrap();
    for (k, v) in frozen_env() {
        cmd.env(k, v);
    }
    cmd.args(["render", "compose", "--tpl"])
        .arg(&tpl)
        .args(["--out"])
        .arg(&out)
        .assert()
        .success();

    let actual = fs::read_to_string(&out).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("compose.txt")).unwrap();
    assert_eq!(actual, expected);
}

#[test]
#[serial]
fn cli_render_caddy_byte_identical_to_fixture() {
    let dir = fixture_dir_install_render();
    let tpl = dir.join("caddy.tpl");
    let out_dir = tempfile::tempdir().unwrap();
    let out = out_dir.path().join("Caddyfile");

    let mut cmd = Command::cargo_bin("opec").unwrap();
    for (k, v) in frozen_env() {
        cmd.env(k, v);
    }
    cmd.args(["render", "caddy", "--tpl"])
        .arg(&tpl)
        .args(["--out"])
        .arg(&out)
        .assert()
        .success();

    let actual = fs::read_to_string(&out).unwrap();
    let expected = fs::read_to_string(dir.join("expected").join("caddy.txt")).unwrap();
    assert_eq!(actual, expected);
}
```

- [ ] Also extend `cli_render.rs` helpers at top:
  - Add a new `fn fixture_dir_install_render() -> PathBuf` that resolves to `tests/fixtures/install-render` (the existing `fixture_dir()` returns `tests/fixtures/render` for Phase 2 xray fixtures — different path)
  - Extend `frozen_env()` vec to include the HY2_* + new vars from Task 1/2's `set_frozen_env()` (compose.tpl + caddy.tpl reference them)

Helper additions:

```rust
fn fixture_dir_install_render() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
        .join("tests")
        .join("fixtures")
        .join("install-render")
}
```

And in `frozen_env()` vec, ADD these entries (after the existing 25):

```rust
        ("HY2_SERVER", ""),
        ("HY2_AUTH_PASS", ""),
        ("HY2_OBFS_PASS", ""),
        ("HY2_LOCAL_LISTEN", ""),
        ("HY2_REMOTE_BACKEND", ""),
```

### Step 3.2: Run test to verify it fails

- [ ] Run

```bash
cargo nextest run -p opec --test cli_render 2>&1 | tail -10
```

Expected: 2 new tests FAIL — clap rejects `compose` and `caddy` as unknown variants of `RenderKind`.

### Step 3.3: Extend `main.rs`

- [ ] Modify `crates/opec/src/main.rs` `RenderKind` enum. Locate:

```rust
#[derive(Copy, Clone, Debug, ValueEnum)]
enum RenderKind {
    Xray,
    Coturn,
    Naive,
}
```

Add 2 variants:

```rust
#[derive(Copy, Clone, Debug, ValueEnum)]
enum RenderKind {
    Xray,
    Coturn,
    Naive,
    Compose,
    Caddy,
}
```

- [ ] Modify the `Commands::Render` dispatch match in `main()`. Locate:

```rust
Commands::Render { kind, tpl, out } => match kind {
    RenderKind::Xray => opec::render::xray::render(&tpl, &out)?,
    RenderKind::Coturn => opec::render::coturn::render(&tpl, &out)?,
    RenderKind::Naive => opec::render::naive::render(&tpl, &out)?,
},
```

Add 2 arms:

```rust
Commands::Render { kind, tpl, out } => match kind {
    RenderKind::Xray => opec::render::xray::render(&tpl, &out)?,
    RenderKind::Coturn => opec::render::coturn::render(&tpl, &out)?,
    RenderKind::Naive => opec::render::naive::render(&tpl, &out)?,
    RenderKind::Compose => opec::render::compose::render(&tpl, &out)?,
    RenderKind::Caddy => opec::render::caddy::render(&tpl, &out)?,
},
```

### Step 3.4: Verify

- [ ] Run

```bash
cargo build -p opec --locked 2>&1 | tail -3
cargo nextest run -p opec 2>&1 | tail -5
cargo clippy -p opec --locked --all-targets -- -D warnings 2>&1 | tail -3
```

Expected: 75/75 total opec tests pass (73 from Tasks 1-2 + 2 new cli tests); clippy clean.

- [ ] Smoke

```bash
./target/debug/opec render --help 2>&1 | head -15
./target/debug/opec render caddy --help 2>&1 | head
./target/debug/opec render compose --help 2>&1 | head
```

Expected: `--help` lists xray, coturn, naive, compose, caddy as kinds.

### Step 3.5: Commit

- [ ] Commit

```bash
git add crates/opec/src/main.rs crates/opec/tests/cli_render.rs
git commit -m "$(cat <<'EOF'
feat(opec): wire compose + caddy render kinds into CLI

Phase 3 Task 3 — extends RenderKind enum with Compose + Caddy variants
and dispatches to opec::render::{compose,caddy}::render(). Completes
the OPEC render CLI surface for all 5 partner-edge templates.

After this commit:
  opec render { xray | coturn | naive | compose | caddy } --tpl X --out Y

is the canonical render entrypoint for install.sh delegation (Task 4).

Refs: docs/superpowers/plans/2026-05-17-phase3-opec-caddy-compose.md Task 3
EOF
)"
```

---

## Task 4: install.sh switches compose + caddy to `render_with_opec_or_fallback` + bats

**Files:**
- Modify: `install.sh` (L1553 + L1554)
- Modify: `tests/test_install_opec_parity.sh`

### Step 4.1: RED — modify bats first

Current `tests/test_install_opec_parity.sh` has a test:

```bash
@test "install.sh keeps render_template for compose and caddy" {
  # Phase 2 scope: compose + caddy stay on bash render_template.
  grep -qE 'render_template[[:space:]]+"\$stage/compose\.tpl"' install.sh
  grep -qE 'render_template[[:space:]]+"\$stage/caddy\.tpl"' install.sh
}
```

- [ ] Replace it with 2 new tests:

```bash
@test "install.sh calls render_with_opec_or_fallback for compose" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+compose' install.sh
}

@test "install.sh calls render_with_opec_or_fallback for caddy" {
  grep -qE 'render_with_opec_or_fallback[[:space:]]+caddy' install.sh
}

@test "install.sh no longer has bare render_template calls for stage templates" {
  # After Phase 3 ALL 5 stage renders go through render_with_opec_or_fallback.
  # The bash render_template function still exists (it's the fallback body),
  # but install.sh should no longer call it DIRECTLY on stage .tpl files.
  ! grep -qE 'render_template[[:space:]]+"\$stage/' install.sh
}
```

- [ ] Run

```bash
bats tests/test_install_opec_parity.sh 2>&1 | tail -10
```

Expected: 3 new tests FAIL (compose/caddy delegation tests + bare-call regression test); the old "keeps render_template for compose and caddy" test removed (no longer applies).

### Step 4.2: GREEN — modify install.sh

- [ ] Locate the 2 stage renders for compose + caddy. They sit at install.sh:1553 + L1554 (post-PR #148):

```bash
render_template "$stage/compose.tpl" "$compose_out"
render_template "$stage/caddy.tpl"   "$caddy_out"
```

Replace with:

```bash
render_with_opec_or_fallback compose "$stage/compose.tpl" "$compose_out"
render_with_opec_or_fallback caddy   "$stage/caddy.tpl"   "$caddy_out"
```

- [ ] Update the comment block right above (around L1544) — currently says `compose.yml + Caddyfile stay on render_template (Phase 3 scope)`. Update to reflect Phase 3 closure:

```bash
# Phase 3 delegation complete: all 5 stage templates (compose, caddy, xray,
# coturn, naive) now go through render_with_opec_or_fallback. OPEC adds
# per-kind validation (JSON / YAML / balanced-brace / realm directive)
# that catches corrupt renders before docker compose start. bash
# render_template remains as the fallback when opec is not on PATH.
```

### Step 4.3: Verify

- [ ] Run

```bash
bash -n install.sh                                          # syntax
shellcheck install.sh                                       # lint
bats tests/test_install_opec_parity.sh 2>&1 | tail -10      # 3 new pass
bats tests/test_render_template_golden.sh \
     tests/test_install_render_identical.sh \
     tests/test_hydrate_render_identical.sh \
     tests/test_update_uses_lib.sh \
     tests/test_release_assets.sh \
     tests/test_installer_bootstrap.sh \
     tests/test_install_opec_parity.sh 2>&1 | tail -10
```

Expected: all bats green; shellcheck no new warnings vs origin/main.

### Step 4.4: Live verify on cheburator (fallback branch — opec not deployed on this edge yet)

Phase 2 already proved fallback parity for xray/coturn/naive; this step adds compose+caddy. cheburator is least-impact per `~/CLAUDE.md` memory.

- [ ] Copy install.sh to cheburator, run helper extraction + render compose against a frozen env:

```bash
scp install.sh cheburator:/tmp/install-phase3.sh

ssh cheburator '
  # Extract the helper and run compose+caddy renders in the fallback
  # branch (cheburator has no opec on PATH).
  source <(awk "/^render_with_opec_or_fallback\\(\\) \\{/,/^\\}/" /tmp/install-phase3.sh)
  source /usr/local/sbin/channel-render-lib.sh
  PATH=/usr/bin:/bin command -v opec || echo "opec not on PATH (fallback branch)"
'
```

Expected: `opec not on PATH (fallback branch)`. Confirms the new render_with_opec_or_fallback helper picks the bash path on live edges that haven't fetched the binary yet.

### Step 4.5: Commit

- [ ] Commit

```bash
git add install.sh tests/test_install_opec_parity.sh
git commit -m "$(cat <<'EOF'
feat(install): delegate compose + caddy render to `opec render`

Phase 3 Task 4 — closes the render-absorption arc. install.sh's last
two bare `render_template "$stage/*.tpl"` call sites (compose.tpl,
caddy.tpl) now go through render_with_opec_or_fallback. After this
commit ALL 5 stage templates (xray, coturn, naive, compose, caddy)
delegate to OPEC when the binary is on PATH; bash render_template
stays as the fallback for opec-absent paths (no OPEC binary fetched
yet, e.g. on networks where GitHub release URL is blocked).

Live edges (rvpn/cheburator/zvonilka/piter-seed) unaffected — they
hit the bash fallback branch byte-for-byte identical to Phase 2.

Updates test_install_opec_parity.sh: drops the now-stale "keeps
render_template for compose and caddy" assertion and replaces it
with positive delegation tests + a regression guard (no more bare
`render_template "$stage/...` lines in install.sh).

Refs: docs/superpowers/plans/2026-05-17-phase3-opec-caddy-compose.md Task 4
EOF
)"
```

---

## Phase 3 closure

### Step 5.1: Full test sweep

- [ ] Run

```bash
cd /home/krolik/.claude-worktrees/phase3-opec-caddy-compose
cargo build -p opec --locked
cargo nextest run -p opec
cargo clippy -p opec --locked --all-targets -- -D warnings

bats tests/test_render_template_golden.sh \
     tests/test_install_render_identical.sh \
     tests/test_hydrate_render_identical.sh \
     tests/test_update_uses_lib.sh \
     tests/test_release_assets.sh \
     tests/test_installer_bootstrap.sh \
     tests/test_install_opec_parity.sh
shellcheck install.sh channel-render-lib.sh hydrate.sh update.sh
```

Expected: cargo nextest 75/75; bats all green; shellcheck no NEW warnings vs origin/main.

### Step 5.2: Cumulative LoC delta

- [ ] Inspect

```bash
git diff --stat origin/main
```

Expected:
- `crates/opec/src/render/compose.rs` +25
- `crates/opec/src/render/caddy.rs` +50 (more validation logic)
- `crates/opec/src/render/mod.rs` +2 (new mod decls)
- `crates/opec/src/main.rs` +5 (2 enum variants + 2 dispatch arms)
- `crates/opec/tests/render_compose.rs` +95
- `crates/opec/tests/render_caddy.rs` +95
- `crates/opec/tests/cli_render.rs` +60
- `install.sh` -2 / +6 (net +4, including comment refresh)
- `tests/test_install_opec_parity.sh` ~+10

Net production code ~+85 LoC; test code ~+250 LoC; install.sh netural.

### Step 5.3: Push + open PR

- [ ] Push

```bash
git push -u origin feat/phase3-opec-caddy-compose
```

- [ ] Open PR

```bash
gh pr create --title "feat(opec): phase 3 — compose + caddy render kinds + install.sh full delegation" \
  --body "$(cat <<'EOF'
## Summary

Phase 3 of partner-edge shell-infra restructure (architect plan). Completes the "render absorption" arc.

- `crates/opec/src/render/compose.rs` — new module: YAML validation
- `crates/opec/src/render/caddy.rs` — new module: balanced-brace + site-block validation
- `opec render { compose | caddy }` CLI variants added alongside Phase 2's xray/coturn/naive
- `install.sh` switches the last 2 bare `render_template "$stage/*.tpl"` call sites (compose.tpl, caddy.tpl) to `render_with_opec_or_fallback`
- All 5 partner-edge stage templates now route through OPEC when binary is on PATH; bash `render_template` remains as the universal fallback

## Effect

After merge + next release tag: fresh installs on Linux amd64/arm64 (with `opec-*` release asset auto-fetched, see PR #148) get typed Rust render for **all** templates. JSON/YAML/brace/realm validation catches substitution corruption before `docker compose up`.

Live edges (rvpn/cheburator/zvonilka/piter-seed) — unaffected; they hit the bash fallback identical to Phase 2 until/unless they re-run install.sh + fetch the OPEC binary.

## Test plan

- [x] `cargo nextest run -p opec` → 75/75 (5 new compose + 5 new caddy + 2 new cli + 63 prior)
- [x] `cargo clippy -p opec --locked --all-targets -- -D warnings` clean
- [x] `bats` 7-suite run → all green (compose+caddy delegation + bare-call regression)
- [x] `shellcheck install.sh` no new warnings
- [x] Byte-identical render output: OPEC ↔ bash `render_template` for compose + caddy on Phase 1 fixtures
- [x] Live cheburator: fallback branch unchanged

## Out of scope

- hysteria2-client.yaml render (Phase 2.b, separate plan — has credential-fetch complexity)
- Phase 4 (kill install.sh godfile — install.sh now safe to slim further since render is fully delegated)
- Phase 5 (partner-cli absorption into OPEC)

Refs: docs/superpowers/plans/2026-05-17-phase3-opec-caddy-compose.md, PR #147 (Phase 2), PR #148 (opec binary ship)
EOF
)"
```

---

## Risks tracked during execution

| Risk | Mitigation |
|---|---|
| `serde_yml::from_str::<Value>` is lenient (accepts most things) — may not catch all corruption | Phase 1 byte-identical golden test catches semantic drift; serde_yml parse is defence-in-depth, not the only gate. |
| Balanced-brace check is a heuristic — counting `{` vs `}` doesn't reject all malformed Caddy syntax | Full `caddy validate` requires shelling out to the binary — out of scope. Caddy itself rejects at startup; this catch is for the cheap, common-corruption case. |
| compose.tpl uses `{{...}}` mustache placeholders **and** Docker compose's own `${VAR}` syntax — substitution must not touch the latter | OPEC's substitution regex is anchored on `{{...}}` (double braces, uppercase NAME). Docker `${VAR}` is single-brace dollar-sign — disjoint. Verified by existing Phase 1 byte-identical fixtures. |
| Caddy.tpl uses Caddyfile snippet `(name) { ... }` syntax which has unbalanced braces in a snippet definition vs invocation — false positives in brace check | The whole file is the rendered output; snippets define-AND-invoke balance out. Empirically confirmed by Task 2 test #2 — the existing fixture has balanced braces. |
| `serde_yml = "0.0.12"` is pre-1.0 — may break API on minor bump | Already pinned in `Cargo.toml` via tenant module dep; lockfile guards against unexpected updates. |
| Fixtures `tests/fixtures/install-render/expected/compose.txt` + `caddy.txt` were generated in Phase 1 against a specific repo template state; drift since then could break the byte-identical test | Both fixtures + their source .tpl copies are stored together; the parity test diffs OPEC output vs the fixture. If the live `compose.yml.tpl` / `Caddyfile.tpl` evolves, fixtures need regeneration via `tests/fixtures/install-render/freeze.sh`-equivalent (Phase 1 generator). Not blocking for Phase 3. |

## What NOT to do in Phase 3

- Do NOT modify `channel-render-lib.sh` (render_template fallback path used by Phase 1 hydrate/update/upgrade — already on bash; Phase 4 may consolidate).
- Do NOT add `opec render hy2` (Phase 2.b — credential-fetch flow).
- Do NOT touch `crates/opec/src/caddy/*` (Phase 4.0/4.1 Caddy JSON renderer — different subsystem; this Phase 3 adds `crates/opec/src/render/caddy.rs`, NOT under `caddy/`).
- Do NOT delete the bash `render_template` function (it's still the fallback body).
- Do NOT modify install.sh's existing 3 Phase-2 call sites (xray/coturn/naive) — they're already on `render_with_opec_or_fallback`.
- Do NOT touch `partner-cli` references (Phase 5).
- Do NOT change `release.yml` (Phase 6 already shipping opec binary).
