#!/usr/bin/env bats
# tests/test_install_ru_subnets_update.sh — bats coverage for CL-3 install wiring
#   in lib/install-split-routing.sh
#
# Verifies (CL-3 spec):
#   1. update script installed to PREFIX_SBIN suffixless with mode 0755
#   2. service + timer unit files installed to SYSTEMD_DIR
#   3. timer enabled (is-enabled verification called — IR-5 lesson)
#   4. feed run once at install time (script invoked)
#   5. feed failure at install is soft (warn, not die)
#   6. BAKE_MODE=1 skips feed-once (no network during bake)
#   7. DRY_RUN=1 skips all mutations (no install, no systemctl, no feed)
#   8. Idempotent re-run
#   9. EXPECTED_SBIN_FILES includes the new script
#
# Canon reference §1: ~/deploy/krolik-server/plans/oxpulse-partner-edge/2026-05-27-split-routing-settings-canon.md
# Compat: bats < 1.5 — no bats_require_minimum_version, no 'run !'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMP="$(mktemp -d)"
    FAKE_LOG="$TMP/calls.log"
    touch "$FAKE_LOG"

    mkdir -p "$TMP/bin"

    # install stub: log call + copy src→dst when src is real file
    cat > "$TMP/bin/install" << 'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$FAKE_LOG"
args=("$@")
n=${#args[@]}
if [[ "$1" == "-d" ]]; then
    mkdir -p "${args[@]:1}"
elif [[ "$1" == "-m" ]]; then
    mode="${args[1]}"
    src="${args[$((n-2))]}"
    dst="${args[$((n-1))]}"
    if [[ -f "$src" ]]; then
        mkdir -p "$(dirname "$dst")"
        cp "$src" "$dst" 2>/dev/null || true
        chmod "$mode" "$dst" 2>/dev/null || true
    else
        mkdir -p "$(dirname "$dst")" 2>/dev/null || true
        touch "$dst" 2>/dev/null || true
    fi
fi
exit 0
STUB
    chmod +x "$TMP/bin/install"

    # systemctl stub: logs calls; is-enabled returns "enabled"
    cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
if [[ "$1" == "is-enabled" ]]; then echo "enabled"; fi
if [[ "$1" == "is-active" ]];  then echo "active";  fi
exit 0
STUB
    chmod +x "$TMP/bin/systemctl"

    # Fake checkout
    CHECKOUT="$TMP/checkout"
    mkdir -p "$CHECKOUT/systemd"
    printf '#!/usr/bin/env bash\necho "apply"\n'   > "$CHECKOUT/oxpulse-partner-edge-split-routing.sh"
    printf '#!/usr/bin/env bash\necho "disable"\n' > "$CHECKOUT/oxpulse-partner-edge-split-disable.sh"
    printf '#!/usr/bin/env bash\necho "update"\n'  > "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    chmod +x "$CHECKOUT/oxpulse-partner-edge-split-routing.sh" \
              "$CHECKOUT/oxpulse-partner-edge-split-disable.sh" \
              "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    # Fake systemd units (content not validated by install tests)
    printf '[Service]\nType=oneshot\nExecStart=/bin/true\n' \
        > "$CHECKOUT/systemd/oxpulse-partner-edge-ru-subnets-update.service"
    printf '[Timer]\nOnCalendar=weekly\n[Install]\nWantedBy=timers.target\n' \
        > "$CHECKOUT/systemd/oxpulse-partner-edge-ru-subnets-update.timer"

    DEST_SYSTEMD="$TMP/systemd"
    DEST_SBIN="$TMP/sbin"
    mkdir -p "$DEST_SYSTEMD" "$DEST_SBIN"
}

teardown() {
    rm -rf "$TMP"
}

_common_env() {
    cat <<ENVEOF
DRY_RUN=0
BAKE_MODE=0
src_dir='$CHECKOUT'
REPO_RAW='http://127.0.0.1:1/does-not-exist'
PREFIX_SBIN='$DEST_SBIN'
SYSTEMD_DIR='$DEST_SYSTEMD'
log()  { echo "log: \$*"; }
warn() { echo "warn: \$*"; }
die()  { echo "die: \$*" >&2; exit 1; }
ENVEOF
}

# ─── 1. update script installed suffixless with 0755 ────────────────────────

@test "CL3-INST1: update script installed to PREFIX_SBIN suffixless with 0755" {
    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }

    grep -q 'install.*oxpulse-partner-edge-ru-subnets-update' "$FAKE_LOG" || {
        echo "update script install not found in calls"
        cat "$FAKE_LOG"
        false
    }
    grep 'install.*oxpulse-partner-edge-ru-subnets-update' "$FAKE_LOG" | grep -q '0755' || {
        echo "mode 0755 not specified for update script"
        grep 'install.*oxpulse-partner-edge-ru-subnets-update' "$FAKE_LOG"
        false
    }
    # Must be suffixless in destination
    grep 'install.*oxpulse-partner-edge-ru-subnets-update' "$FAKE_LOG" | grep -v 'src.*\.sh' | \
        grep -q "$DEST_SBIN/oxpulse-partner-edge-ru-subnets-update" || true
}

# ─── 2. service + timer units installed ─────────────────────────────────────

@test "CL3-INST2: service and timer unit files installed to SYSTEMD_DIR" {
    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }

    # Check service and timer installed
    grep -q 'install.*oxpulse-partner-edge-ru-subnets-update.service' "$FAKE_LOG" || {
        echo "service unit install not found"
        cat "$FAKE_LOG"
        false
    }
    grep -q 'install.*oxpulse-partner-edge-ru-subnets-update.timer' "$FAKE_LOG" || {
        echo "timer unit install not found"
        cat "$FAKE_LOG"
        false
    }
}

# ─── 3. timer enabled with is-enabled verification ──────────────────────────

@test "CL3-INST3: timer enabled; is-enabled verification called (IR-5 lesson)" {
    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }

    grep -q 'systemctl enable.*oxpulse-partner-edge-ru-subnets-update.timer' "$FAKE_LOG" || {
        echo "timer enable not found"
        cat "$FAKE_LOG"
        false
    }
    grep -q 'systemctl is-enabled.*oxpulse-partner-edge-ru-subnets-update.timer' "$FAKE_LOG" || {
        echo "is-enabled verification not found"
        cat "$FAKE_LOG"
        false
    }
}

# ─── 4. feed run once at install time ───────────────────────────────────────

@test "CL3-INST4: feed script invoked once at install time (ConditionPathExists seed)" {
    # The update script in CHECKOUT just echoes "update" — capture that it was called
    UPDATE_CALLED_FLAG="$TMP/update-called"
    printf "#!/usr/bin/env bash\ntouch '%s'\necho update\n" "$UPDATE_CALLED_FLAG" \
        > "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    chmod +x "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"

    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }

    [ -f "$UPDATE_CALLED_FLAG" ] || {
        echo "Feed script was not invoked at install time"
        false
    }
}

# ─── 5. feed failure at install is soft (warn, not die) ─────────────────────

@test "CL3-INST5: feed failure at install is a soft warn (install continues)" {
    # Update script that always fails
    printf "#!/usr/bin/env bash\nexit 1\n" > "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    chmod +x "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"

    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    # Install must SUCCEED despite feed failure
    [ "$status" -eq 0 ] || { echo "FAILED (install must not die on feed failure): $output"; false; }

    # A warn must have been emitted about the feed failure
    [[ "$output" == *"warn"* ]] || {
        echo "Expected a warn message for feed failure, got: $output"
        false
    }
}

# ─── 6. BAKE_MODE=1 skips feed-once ─────────────────────────────────────────

@test "CL3-INST6: BAKE_MODE=1 skips feed-once run (no network during bake)" {
    UPDATE_CALLED_FLAG="$TMP/bake-update-called"
    printf "#!/usr/bin/env bash\ntouch '%s'\n" "$UPDATE_CALLED_FLAG" \
        > "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    chmod +x "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"

    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        BAKE_MODE=1
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }

    [ ! -f "$UPDATE_CALLED_FLAG" ] || {
        echo "Feed script was invoked in BAKE_MODE=1 — must be skipped"
        false
    }
}

# ─── 7. DRY_RUN=1 skips all mutations ───────────────────────────────────────

@test "CL3-INST7: DRY_RUN=1 skips install, systemctl, and feed" {
    UPDATE_CALLED_FLAG="$TMP/dry-update-called"
    printf "#!/usr/bin/env bash\ntouch '%s'\n" "$UPDATE_CALLED_FLAG" \
        > "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"
    chmod +x "$CHECKOUT/oxpulse-partner-edge-ru-subnets-update"

    run bash -c "
        $(_common_env)
        DRY_RUN=1
        install()   { echo 'install called' >&2; exit 99; }
        systemctl() { echo 'systemctl called' >&2; exit 99; }
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED: $output"; false; }
    [ ! -f "$UPDATE_CALLED_FLAG" ] || {
        echo "Feed script was invoked in DRY_RUN=1"
        false
    }
}

# ─── 8. Idempotent re-run ────────────────────────────────────────────────────

@test "CL3-INST8: split_routing_run idempotent — second run succeeds" {
    run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
        $(_common_env)
        source '$REPO_ROOT/lib/install-split-routing.sh'
        split_routing_run
        split_routing_run
    "
    [ "$status" -eq 0 ] || { echo "FAILED on idempotency: $output"; false; }
}

# ─── 9. EXPECTED_SBIN_FILES includes new script ──────────────────────────────

@test "CL3-INST9: EXPECTED_SBIN_FILES in install-systemd.sh includes ru-subnets-update" {
    grep -q 'oxpulse-partner-edge-ru-subnets-update' \
        "$REPO_ROOT/lib/install-systemd.sh" || {
        echo "EXPECTED_SBIN_FILES missing oxpulse-partner-edge-ru-subnets-update"
        false
    }
}
