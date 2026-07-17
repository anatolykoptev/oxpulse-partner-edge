#!/usr/bin/env bats
# tests/test_install_awg_extract_validate.sh
#
# Regression guard: install.sh MUST validate that each AWG_* var extracted
# from /api/partner/register is non-empty when the backend says it allocated
# an AWG IP. Otherwise `awg_extract` silently returns "" on python3/JSON
# failure (RHS of assignment is exempt from `set -e`), 14 AWG_* vars all
# end up empty, `awg0.conf` is rendered with empty PublicKey/Endpoint, and
# `awg-quick@awg0` silently fails — install still reports green exit.
#
# Bug class: 2026-05-18 mesh-bridge-online-drop incident (FOLLOWUPS.md P1).
# Investigation report: reports/oxpulse-chat/investigations/
#                        2026-05-18-mesh-bridge-online-drop.md (item 6).
#
# Same fail-loud-not-warn-and-continue pattern as
# test_install_die_on_empty_sfu_secret.sh.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	INSTALL="$REPO_ROOT/install.sh"
	[[ -f "$INSTALL" ]] || skip "install.sh not at expected path"
}

# 1. There must be a validation block that gates on AWG_ALLOCATED_IP being
#    non-empty (legacy backend without awg block → no validation), and then
#    checks each AWG_* var.
@test "install.sh validates AWG_* vars are non-empty after awg_extract calls" {
	# Capture the validation block: starts at the [[ -n "${AWG_ALLOCATED_IP" ]]
	# guard, ends at the matching fi. awk-grep so the block can move within
	# the file without breaking the test.
	guard_block=$(awk '
		/\[\[ -n "\$\{?AWG_ALLOCATED_IP/ { capture=1 }
		capture { print }
		capture && /^fi$/ { exit }
	' "$INSTALL")

	[[ -n "$guard_block" ]] \
		|| { echo "expected AWG_ALLOCATED_IP non-empty guard block; not found"; return 1; }

	# Block must call die when ANY AWG_* var is empty.
	echo "$guard_block" | grep -q 'die ' \
		|| { echo "AWG guard block does not call die"; return 1; }
}

# 2. The validation must cover the critical AWG_* fields rendered into
#    awg0.conf (PublicKey + Endpoint at minimum — broken conf if either empty).
@test "install.sh validation block covers AWG_MOTHERLY_PUBKEY and AWG_MOTHERLY_ENDPOINT" {
	guard_block=$(awk '
		/\[\[ -n "\$\{?AWG_ALLOCATED_IP/ { capture=1 }
		capture { print }
		capture && /^fi$/ { exit }
	' "$INSTALL")

	echo "$guard_block" | grep -q 'AWG_MOTHERLY_PUBKEY' \
		|| { echo "validation does not cover AWG_MOTHERLY_PUBKEY"; return 1; }

	echo "$guard_block" | grep -q 'AWG_MOTHERLY_ENDPOINT' \
		|| { echo "validation does not cover AWG_MOTHERLY_ENDPOINT"; return 1; }
}

# 3. The die message must be actionable — tell the operator WHERE the
#    bad data came from (register response) so they don't waste time
#    debugging local install state.
@test "install.sh AWG empty-var die message points operator to register response" {
	guard_block=$(awk '
		/\[\[ -n "\$\{?AWG_ALLOCATED_IP/ { capture=1 }
		capture { print }
		capture && /^fi$/ { exit }
	' "$INSTALL")

	echo "$guard_block" | grep -qE '/api/partner/register|register response|backend.*response' \
		|| { echo "die message does not point to register response"; return 1; }
}

# 4. install.sh MUST guard python3 availability before awg_extract calls.
#    awg_extract() has no sed fallback (unlike json_get); if python3 is
#    missing, ALL awg_extract returns empty, AWG_ALLOCATED_IP is empty,
#    the validation block is skipped, and install proceeds without AWG.
@test "install.sh guards python3 availability before awg_extract calls" {
	grep -q "command -v python3" "$INSTALL" \
		|| { echo "install.sh does not guard python3 before awg_extract"; return 1; }

	# The guard must be BEFORE the first awg_extract call.
	python3_line=$(grep -n "command -v python3" "$INSTALL" | head -1 | cut -d: -f1)
	awg_extract_line=$(grep -n "AWG_ALLOCATED_IP=\$(awg_extract" "$INSTALL" | head -1 | cut -d: -f1)

	[[ -n "$python3_line" && -n "$awg_extract_line" ]] \
		|| { echo "could not locate python3 guard or first awg_extract call"; return 1; }

	[[ "$python3_line" -lt "$awg_extract_line" ]] \
		|| { echo "python3 guard (line $python3_line) is AFTER first awg_extract (line $awg_extract_line)"; return 1; }
}

# 5. deps_install MUST include python3 in the package list.
@test "install-deps.sh includes python3 in deps_install package list" {
	DEPS="$REPO_ROOT/lib/install-deps.sh"
	[[ -f "$DEPS" ]] || skip "install-deps.sh not at expected path"

	grep -q "python3" "$DEPS" \
		|| { echo "install-deps.sh does not install python3"; return 1; }

	# Must be in the for _pkg in ... loop.
	grep -E "for _pkg in .* python3" "$DEPS" >/dev/null 2>&1 \
		|| { echo "python3 not in deps_install for-loop"; return 1; }
}
