# Contributing to oxpulse-partner-edge

Thanks for considering a contribution. This repository is the public,
AGPL-licensed edge bundle of the OxPulse network — the trust-critical
component partners deploy on their own VPS. We take changes here seriously.

## Before you start

- Skim the [`README.md`](README.md) for the architecture overview.
- Read [`DECISION.md`](DECISION.md) for past architectural decisions.
- For non-trivial changes, open an issue first to discuss the design.

## Contribution flow

1. **Fork** the repository on GitHub.
2. **Branch** from `main` using a descriptive name:
   - `feat/<slug>` — new feature
   - `fix/<slug>` — bug fix
   - `chore/<slug>` — refactor, docs, build, or tooling
3. **Commit** following the [Conventional Commits](https://www.conventionalcommits.org/)
   spec: `type(scope): summary`. Examples:
   - `feat(install): add awg onboarding flow`
   - `fix(coturn): close ssrf path to cgnat ranges`
   - `chore(license): add dual-licensing scaffolding`
   Conventional commits feed our `release-please` automation, so the format
   is mandatory for changes that should appear in `CHANGELOG.md`.
4. **Test** locally — `cargo test --workspace` for Rust crates,
   `bash tests/<name>.sh` for shell harnesses.
5. **Push** your branch and open a pull request against `main`.
6. **Sign the CLA** — see below.
7. **Review** — at least one maintainer review is required before merge.

## Contributor License Agreement (CLA)

Every contribution must be covered by the OxPulse Contributor License
Agreement: [`CLA.md`](CLA.md).

The CLA is necessary because `oxpulse-partner-edge` operates a
**dual-licensing model**: contributions are accepted into the repo under
both the AGPL-3.0 (the public default) and the OxPulse commercial license
(used by organizations that cannot accept AGPL § 13 — see
[`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)). A DCO-style sign-off is
not enough — the CLA grants OxPulse the explicit relicensing right that
makes the dual track legally workable.

**Signing is automated.** When you open your first pull request, the
[CLA-assistant bot](https://cla-assistant.io/) will comment with a link to
review and accept the agreement. The check must pass before merge.

If you contribute on behalf of your employer, please ensure the entity has
signed the corporate CLA — contact `legal@oxpulse.chat` if unsure.

## Code style

Match the existing style of the file you are editing. Drift across a file
is a bug, not a cleanup target. Mention legacy inconsistencies in the PR
description rather than "fixing" them as a side effect of unrelated work.

- **Rust** — `cargo fmt` + `cargo clippy --workspace --all-targets -- -D warnings`.
- **Shell** — `shellcheck`-clean. POSIX `sh` for installer scripts that run
  on minimal Debian/Alma images, `bash` only when an `#!/usr/bin/env bash`
  shebang is already present.
- **Templates** (`*.tpl`) — preserve placeholder syntax (`{{ var }}`) that
  the install / hydrate scripts substitute.

## What to avoid

- Hardcoded secrets — `gitleaks` runs in CI and will block the PR.
- Drive-by refactors unrelated to the stated PR scope.
- Vendor lock-in to a specific cloud — partner edges run on arbitrary
  Debian/Ubuntu/Alma VPSes.

## License of contributions

By submitting a pull request you agree that your contribution is dual-licensed
under the **AGPL-3.0** (see [`LICENSE`](LICENSE)) and the **OxPulse commercial
license** (see [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)), as set out in
[`CLA.md`](CLA.md). This makes the AGPL-default trust contract with partners
durable while letting OxPulse fund continued development through a commercial
track for organizations that need it.
