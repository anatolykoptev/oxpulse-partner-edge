.PHONY: build test test-doc test-all lint deny check lib-checksums

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

# Full pre-PR gate: build + tests + lint + deny
check: build test-all lint deny

# Regenerate lib/lib-checksums.txt to match release pipeline order.
# Run after editing any lib/install-*.sh or lib/render-*.sh file.
lib-checksums:
	(cd lib && sha256sum \
	  install-args.sh \
	  install-awg.sh \
	  install-awg-params-agent.sh \
	  install-deps.sh \
	  install-healthcheck.sh \
	  install-network.sh \
	  install-preflight.sh \
	  install-split-routing.sh \
	  install-systemd.sh \
	  render-channel-lib.sh \
	) > lib/lib-checksums.txt
	@echo "lib/lib-checksums.txt regenerated — commit the result"
