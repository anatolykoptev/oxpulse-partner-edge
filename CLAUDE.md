# oxpulse-partner-edge — notes for coding agents

The public, AGPL-licensed edge bundle that partners run on their own VPS: an installer
and upgrader (shell), Caddy/xray/coturn/AmneziaWG configuration templates, a TURN-only
relay profile, and Rust crates (SFU, partner CLI, AWG parameter agent). The code runs as
root on third-party hosts, so a change must do exactly what its message says. Overview in
[README.md](README.md); contribution rules in [CONTRIBUTING.md](CONTRIBUTING.md); every
document is listed in [docs/INDEX.md](docs/INDEX.md).

## Layout

- Root shell entry points and templates: `install.sh`, `upgrade.sh`, `hydrate.sh`,
  `healthcheck.sh`, the `oxpulse-partner-edge-*.sh` timers and guards, `Caddyfile.tpl`,
  `docker-compose.yml.tpl`, `coturn.conf.tpl`, `manifest.yaml`.
- `lib/` sourced shell libraries (`install-*.sh`, `render-*.sh`, `reconcile.sh`, ...) and
  `lib/lib-checksums.txt`, the pinned hashes of those files.
- `relay/` relay-only node installer; `systemd/` units; `config/` defaults and conf.d
  slots; `scripts/` helpers and `run-shell-tests.sh`.
- `crates/` Rust workspace (`sfu`, `partner-cli`, `awg-params-agent`, `opec`).
- `tests/` the shell test suite (about 220 files) with fixtures such as the Caddyfile
  golden file.

## Gate

CI (`.github/workflows/ci.yml`) runs `cargo fmt --check`, `cargo clippy --workspace -D
warnings`, a single-`str0m`-version check, `cargo test --workspace`, a FIPS build check and
the installer shell tests. Locally:

```sh
make check-rust    # build, nextest, doctests, clippy, cargo deny
make check         # check-rust plus scripts/run-shell-tests.sh (Linux only; bats needed)
make test-sh       # plain-bash half of the shell suite only
```

The shell suite assumes GNU userland and refuses to run elsewhere.

## Invariants easy to break

- After editing any file listed in the `lib-checksums` Makefile target, run
  `make lib-checksums` and commit `lib/lib-checksums.txt`; the release pipeline and
  `tests/test_lib_checksums_committed.sh` compare against it.
- Changing `Caddyfile.tpl` changes the golden fixture under `tests/fixtures/`; update it
  deliberately, never to make a failing case pass.
- A fix must contain the change its commit message claims; `Fixes #N` only when the diff
  removes the cause (CONTRIBUTING.md).
- A claim about live behaviour (metric, endpoint, timer, unit) needs a probe on a real
  host, not only a passing test.
- Relay-only nodes hold no registration material: never run `install.sh` or the register
  path on them (`docs/relay-only-node.md`).
- This repository is public: no internal host names, addresses or operator paths in code,
  comments or docs.
- Commits follow Conventional Commits; release-please builds `CHANGELOG.md` and bumps
  `VERSION`, do not edit either by hand.
