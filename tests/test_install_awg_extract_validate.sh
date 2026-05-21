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
