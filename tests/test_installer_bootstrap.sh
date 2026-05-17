#!/usr/bin/env bats
# Guards for one-command install bootstrap fixes.
# See: fix(install): fetch channel-render-lib.sh in source block, not just Step 8

setup() {
  cd "$BATS_TEST_DIRNAME/.."
}

@test "install.sh source block fetches channel-render-lib.sh from REPO_RAW when missing" {
  # The source block (around line 766) must have a third fallback that
  # fetches the lib via curl into $_chan_lib_tmp. Anchor on the variable
  # name + the curl pattern within the source-block range.
  awk '/^_chan_lib_local=/{found=1} found && /^unset _chan_lib_local/{exit} found{print}' install.sh \
    | grep -qE 'curl.*"\$REPO_RAW/channel-render-lib\.sh".*_chan_lib_tmp'
}

@test "install.sh Step 8 install of channel-render-lib.sh handles tmp-fetched lib" {
  # Step 8 must use $_chan_lib_tmp when set (avoids re-fetching).
  grep -qE 'install -m 0644 "\$_chan_lib_tmp"' install.sh
}

@test "install.sh fetches opec binary from release assets if missing" {
  grep -qE 'releases/latest/download/opec-' install.sh
}
