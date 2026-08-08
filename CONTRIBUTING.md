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

## Your patch must contain the change your message describes

This is the bar we enforce most strictly, because it is the one that has
actually cost us. A commit message, a PR title and a `Fixes #N` trailer are
all read by humans and by automation as claims about the diff. When they
describe work the diff does not contain, review degrades into trusting the
narration — and on a repository that partners deploy as root on their own
VPS, that is not an acceptable failure mode.

Concretely:

- **Every behaviour your message names must be visible in the diff.** If
  the message says a metric is added, `git grep` for that metric name in
  the patch has to find it. We check this.
- **A closing keyword is a claim that the defect is gone.** Use
  `Fixes #N` / `Closes #N` only when the diff removes the cause. If your
  change improves the situation without resolving it, write `Refs #N` and
  say in the body what remains. A merged `Fixes #N` closes the issue
  automatically, so an overstated trailer silently retires a live bug.
- **Do not delete the fixture that represents the failing case.** Changing
  a test input so the failing condition is no longer exercised makes CI
  greener and the system no safer. If a fixture must change, say why in
  the PR body.
- **A claim about live behaviour needs a probe, not a passing test.** New
  metric, endpoint, flag, timer or systemd unit — show it working on a
  real host, or say plainly that you could not and what you did instead.
  A green suite is evidence the code compiles and the assertions you chose
  hold; it is not evidence the thing works where it runs.

None of this asks for a perfect patch. It asks that the description and the
patch be the same object, and that anything you are unsure of be stated
rather than smoothed over. "I could not test this on a real edge" is a
welcome sentence. A confident summary of work that is not in the diff is
not.

### Automated and AI-assisted pull requests

Using an assistant to write a patch is fine, and we do it ourselves. The
output is still yours, and the bar above applies to it unchanged — you are
expected to have read the diff you are opening.

What we close without review:

- PRs whose description was generated from the issue text rather than from
  the change, so that the summary describes an intended fix and the diff
  contains something else.
- Bulk, unsolicited PRs opened across many repositories, where this
  repository was selected by a crawler rather than by interest in it.

We would much rather have one patch from someone who understands what an
edge node does than fifty that pattern-match our issue titles. If you are
new here and want somewhere real to start, open an issue describing what
you observed — a good bug report is worth more to us than a speculative
fix, and it is the contribution we are actually short of.

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
- A description that outruns the diff — see
  [Your patch must contain the change your message describes](#your-patch-must-contain-the-change-your-message-describes).

## License of contributions

By submitting a pull request you agree that your contribution is dual-licensed
under the **AGPL-3.0** (see [`LICENSE`](LICENSE)) and the **OxPulse commercial
license** (see [`LICENSE-COMMERCIAL.md`](LICENSE-COMMERCIAL.md)), as set out in
[`CLA.md`](CLA.md). This makes the AGPL-default trust contract with partners
durable while letting OxPulse fund continued development through a commercial
track for organizations that need it.
