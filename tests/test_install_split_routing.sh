#!/usr/bin/env bats
# tests/test_install_split_routing.sh — bats coverage for lib/install-split-routing.sh
#
# Verifies (CL-2 spec):
#   1. Module sources cleanly and exports split_routing_run
#   2. Apply + disable scripts installed to PREFIX_SBIN with mode 0755
#   3. Rendered unit has correct After= ordering (both awg iface + params-agent)
#   4. Rendered unit has correct ExecStart (PREFIX_SBIN path)
#   5. Rendered unit is Type=oneshot, RemainAfterExit=yes, WantedBy=multi-user.target
#   6. Unit enabled (is-enabled check logged)
#   7. Idempotent re-run — no error, no dup
#   8. DRY_RUN=1 performs no mutations
# Ref: canon §8 ~/deploy/server-config/plans/oxpulse-partner-edge/2026-05-27-split-routing-settings-canon.md

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	FAKE_LOG="$TMP/calls.log"
	touch "$FAKE_LOG"

	# Fake binary dir for PATH shims
	mkdir -p "$TMP/bin"

	# install stub: log call + copy src→dst when src is real file
	cat > "$TMP/bin/install" << 'STUB'
#!/usr/bin/env bash
echo "install $*" >> "$FAKE_LOG"
args=("$@")
n=${#args[@]}
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
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

	# systemctl stub: log call + handle is-enabled query
	cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
# is-enabled returns "enabled" so the verification logic sees it as enabled
if [[ "$1" == "is-enabled" ]]; then
    echo "enabled"
fi
# is-active returns "active" so the activity check passes
if [[ "$1" == "is-active" ]]; then
    echo "active"
fi
exit 0
STUB
	chmod +x "$TMP/bin/systemctl"

	# Fake checkout with the CL-1 scripts
	CHECKOUT="$TMP/checkout"
	mkdir -p "$CHECKOUT"
	printf '#!/usr/bin/env bash\n# fake split-routing apply\necho "apply"\n' \
		> "$CHECKOUT/oxpulse-partner-edge-split-routing.sh"
	chmod +x "$CHECKOUT/oxpulse-partner-edge-split-routing.sh"
	printf '#!/usr/bin/env bash\n# fake split-routing disable\necho "disable"\n' \
		> "$CHECKOUT/oxpulse-partner-edge-split-disable.sh"
	chmod +x "$CHECKOUT/oxpulse-partner-edge-split-disable.sh"

	# Destination dirs
	DEST_SYSTEMD="$TMP/systemd"
	DEST_SBIN="$TMP/sbin"
	mkdir -p "$DEST_SYSTEMD" "$DEST_SBIN"
}

teardown() {
	rm -rf "$TMP"
}

# Minimal env shared by tests
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

# ─── 1. module sources cleanly ───────────────────────────────────────────────

@test "module sources cleanly and exports split_routing_run" {
	run bash -c "source '$REPO_ROOT/lib/install-split-routing.sh'; type split_routing_run"
	[ "$status" -eq 0 ]
	[[ "$output" == *"split_routing_run is a function"* ]]
}

# ─── 2. scripts installed to PREFIX_SBIN with mode 0755 ─────────────────────

@test "apply and disable scripts installed to PREFIX_SBIN with 0755" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_scripts
	"
	[ "$status" -eq 0 ]
	# install called for both scripts
	grep -q 'install.*oxpulse-partner-edge-split-routing.sh' "$FAKE_LOG"
	grep -q 'install.*oxpulse-partner-edge-split-disable.sh' "$FAKE_LOG"
	# mode 0755 specified in install calls
	grep 'install.*oxpulse-partner-edge-split-routing.sh' "$FAKE_LOG" | grep -q '0755'
	grep 'install.*oxpulse-partner-edge-split-disable.sh' "$FAKE_LOG" | grep -q '0755'
}

# ─── 3. rendered unit has correct After= ordering ────────────────────────────

@test "rendered unit contains After= with awg-quick@awg0.service" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_unit
	"
	[ "$status" -eq 0 ]
	[ -f "$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service" ]
	grep -q 'After=.*awg-quick@awg0\.service' "$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service"
}

@test "rendered unit contains After= with oxpulse-awg-params-agent.service" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_unit
	"
	[ "$status" -eq 0 ]
	grep -q 'After=.*oxpulse-awg-params-agent\.service' "$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service"
}

# ─── 4. rendered unit has correct ExecStart ──────────────────────────────────

@test "rendered unit ExecStart points to PREFIX_SBIN/oxpulse-partner-edge-split-routing (suffixless)" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_unit
	"
	[ "$status" -eq 0 ]
	grep -q "ExecStart=${DEST_SBIN}/oxpulse-partner-edge-split-routing" \
		"$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service"
}

# ─── 5. unit has correct Type, RemainAfterExit, WantedBy ─────────────────────

@test "rendered unit has Type=oneshot RemainAfterExit=yes WantedBy=multi-user.target" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_unit
	"
	[ "$status" -eq 0 ]
	unit_file="$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service"
	grep -q 'Type=oneshot'           "$unit_file"
	grep -q 'RemainAfterExit=yes'    "$unit_file"
	grep -q 'WantedBy=multi-user.target' "$unit_file"
}

# ─── 6. unit enabled and verification issued ─────────────────────────────────

@test "unit enabled and is-enabled verification called" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_enable_unit
	"
	[ "$status" -eq 0 ]
	grep -q 'systemctl daemon-reload'                                       "$FAKE_LOG"
	grep -q 'systemctl enable.*oxpulse-partner-edge-split-routing.service'  "$FAKE_LOG"
	grep -q 'systemctl is-enabled.*oxpulse-partner-edge-split-routing'      "$FAKE_LOG"
}

# ─── 7. idempotent re-run ────────────────────────────────────────────────────

@test "split_routing_run idempotent — second run exits 0 and unit still present" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		split_routing_run  # first run
		split_routing_run  # second run — must not fail
	"
	[ "$status" -eq 0 ]
	[ -f "$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service" ]
}

# ─── 8. DRY_RUN skips all mutations ──────────────────────────────────────────

@test "DRY_RUN=1 skips install, systemctl, and unit rendering" {
	run bash -c "
		$(_common_env)
		DRY_RUN=1
		source '$REPO_ROOT/lib/install-split-routing.sh'
		install()   { echo 'install called in dry-run' >&2; exit 99; }
		systemctl() { echo 'systemctl called in dry-run' >&2; exit 99; }
		split_routing_run
	"
	[ "$status" -eq 0 ]
	[[ "$output" == *"[dry-run] skipping split-routing install"* ]]
	[[ "$output" != *"install called in dry-run"* ]]
	[[ "$output" != *"systemctl called in dry-run"* ]]
	# unit file must NOT be created in dry-run
	[ ! -f "$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service" ]
}

# ─── 9. BAKE_MODE: enable without --now ──────────────────────────────────────

@test "BAKE_MODE=1: enable without --now" {
	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" bash -c "
		$(_common_env)
		BAKE_MODE=1
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_enable_unit
	"
	[ "$status" -eq 0 ]
	# enable must be called
	grep -q 'systemctl enable.*oxpulse-partner-edge-split-routing' "$FAKE_LOG"
	# must NOT use enable --now in bake mode
	run grep -q 'systemctl enable --now' "$FAKE_LOG"
	[ "$status" -ne 0 ]  # enable --now must NOT be used (After=awg-quick ordering)
}

# ─── 10. IR-5: warn emitted when is-enabled returns disabled ─────────────────
# Ref: feedback_systemctl_enable_not_running — enable exit=0 ≠ unit actually enabled.
# This test ensures the warn() branch fires when systemctl is-enabled returns "disabled".

@test "IR-5: warn emitted when is-enabled returns disabled" {
	# Stub systemctl so is-enabled returns "disabled" to exercise the warn branch.
	cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$FAKE_LOG"
if [[ "$1" == "is-enabled" ]]; then
    echo "${STUB_IS_ENABLED:-enabled}"
fi
if [[ "$1" == "is-active" ]]; then
    echo "active"
fi
exit 0
STUB
	chmod +x "$TMP/bin/systemctl"

	run env FAKE_LOG="$FAKE_LOG" PATH="$TMP/bin:$PATH" STUB_IS_ENABLED="disabled" bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_enable_unit
	"
	[ "$status" -eq 0 ]
	# The warn path must have fired
	[[ "$output" == *"may not be enabled"* ]]
}

# ─── 11. ConditionPathExists in rendered unit ─────────────────────────────────
# Ref: CL-2 review finding — unit must skip (not fail) when ru-subnets.txt is absent.
# ConditionPathExists= causes systemd to silently skip rather than fail the unit.

@test "rendered unit contains ConditionPathExists for ru-subnets.txt" {
	run bash -c "
		$(_common_env)
		source '$REPO_ROOT/lib/install-split-routing.sh'
		_split_routing_install_unit
	"
	[ "$status" -eq 0 ]
	unit_file="$DEST_SYSTEMD/oxpulse-partner-edge-split-routing.service"
	grep -q 'ConditionPathExists=.*ru-subnets\.txt' "$unit_file"
}
