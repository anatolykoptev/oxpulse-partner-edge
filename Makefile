.PHONY: build test test-doc test-all lint deny check check-rust check-sh test-sh lib-checksums

# Build all targets (locked — matches dozor production build)
build:
	cargo build --locked --all-targets

# Run integration + unit tests via nextest (faster, better output)
test:
	cargo nextest run --locked --all-features

# Run doc tests (nextest does not run doctests)
test-doc:
	cargo test --locked --doc

# Run all tests: nextest + doc tests
test-all: test test-doc

# Clippy with warnings-as-errors
lint:
	cargo clippy --locked --all-targets --all-features -- -D warnings

# Supply-chain checks: licenses, advisories, banned crates, sources
deny:
	cargo deny check

# The shell suite — the SAME enumeration CI runs, via the same script, so a
# local pass and a CI pass cannot disagree about which tests exist.
#
# This repo is mostly shell: 190 test files against install.sh, upgrade.sh, the
# lib/ helpers and the compose/Caddy templates, and they are what catch our
# real defect classes. Until now `check` ran cargo only, so the way to find out
# whether they passed was to push and wait — measured 2026-08-08, 243s of CI
# per attempt against about 5s locally for the static guards.
#
# test-sh runs only the plain-bash half; check-sh adds bats and needs it
# installed (apt-get install bats / brew install bats-core).
#
# Both require Linux. The suite assumes GNU userland: measured 2026-08-08, the
# same commit scores 133/134 on the ubuntu runner and 107/134 on macOS, the
# differences being BSD-vs-GNU flag handling rather than defects. The runner
# refuses off-Linux rather than reporting 27 phantom failures — a gate that
# cries wolf is worse than no gate. Portability is tracked in its own issue;
# `scripts/run-shell-tests.sh --native` shows the local result as information,
# explicitly not as a verdict.
test-sh:
	scripts/run-shell-tests.sh --plain

check-sh:
	scripts/run-shell-tests.sh

# The cargo half on its own. Kept as a target because it is the whole gate a
# non-Linux machine can honestly run, and `check` below would otherwise leave
# those developers with nothing.
check-rust: build test-all lint deny

# Full pre-PR gate: the cargo half plus the shell suite. Needs Linux — krolik
# has the repo at ~/src/oxpulse-partner-edge. Before this, `check` was
# documented as the full gate and ran none of the 190 shell tests, so the only
# way to learn whether they passed was to push and wait 243s.
check: check-rust check-sh

# Regenerate lib/lib-checksums.txt to match release pipeline order.
# Run after editing any lib/install-*.sh or lib/render-*.sh file.
lib-checksums:
	(cd lib && sha256sum \
	  install-args.sh \
	  install-awg.sh \
	  install-awg-params-agent.sh \
	  install-deps.sh \
	  install-firewall.sh \
	  install-healthcheck.sh \
	  install-network.sh \
	  install-preflight.sh \
	  install-split-routing.sh \
	  install-systemd.sh \
	  render-channel-lib.sh \
	  reconcile.sh \
	  telegram-alert-lib.sh \
	  compose-lib.sh \
	  healthcheck-lib.sh \
	  host-scripts-lib.sh \
	  peer-ip-guard-lib.sh \
	  channel-health-lib.sh \
	  cross-probe-lib.sh \
	  metric-sink-lib.sh \
	  surgical-restart-lib.sh \
	  xprb-refresh-lib.sh \
	) > lib/lib-checksums.txt
	@echo "lib/lib-checksums.txt regenerated — commit the result"
