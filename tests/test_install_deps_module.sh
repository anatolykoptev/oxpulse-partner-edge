#!/usr/bin/env bats
# tests/test_install_deps_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPBIN="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPBIN"
}

@test "deps module sources cleanly" {
    run bash -c "source '$REPO_ROOT/lib/install-deps.sh'; type deps_install"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deps_install is a function"* ]]
}

@test "deps_install skips jq/curl install when both present" {
    run bash -c "
        source '$REPO_ROOT/lib/install-deps.sh'
        DRY_RUN=1
        OS_FAMILY=debian
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        deps_install
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"installing missing runtime dep"* ]]
}

@test "deps_install dry-run skips docker install" {
    run bash -c "
        source '$REPO_ROOT/lib/install-deps.sh'
        DRY_RUN=1
        OS_FAMILY=debian
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        deps_install
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] skipping docker install"* ]]
}
