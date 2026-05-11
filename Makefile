.PHONY: build test test-doc test-all lint deny check

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
