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

# 6. The required-nonempty list must keep covering the jc trio — the
#    2026-05-18 mesh-bridge-online-drop incident guard stays load-bearing
#    until Phase E shrinks it alongside the agent-side omission gate.
@test "install.sh required-nonempty list still covers AWG_JC AWG_JMIN AWG_JMAX" {
	guard_block=$(awk '
		/\[\[ -n "\$\{?AWG_ALLOCATED_IP/ { capture=1 }
		capture { print }
		capture && /^fi$/ { exit }
	' "$INSTALL")

	for _v in AWG_JC AWG_JMIN AWG_JMAX AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4; do
		echo "$guard_block" | grep -q "$_v" \
			|| { echo "required-nonempty list dropped $_v"; return 1; }
	done
}

# 7. AWG 3.1: the awg block is extracted by ONE awg_extract_all spawn feeding
#    a NUL-delimited read-loop (no eval, no ~30x per-key python3 spawns).
@test "install.sh extracts the awg block via one awg_extract_all read-loop" {
	grep -q "awg_extract_all" "$INSTALL" \
		|| { echo "install.sh does not call awg_extract_all"; return 1; }

	# The read-loop must be the NUL-delimited no-eval form.
	grep -q "read -r -d ''" "$INSTALL" \
		|| { echo "awg_extract_all consumer is not the NUL-delimited read-loop"; return 1; }
	# `run` + status check — a bare `!` mid-test silently masks under SC2314.
	run grep -qE "eval.*awg_extract_all" "$INSTALL"
	[ "$status" -ne 0 ] \
		|| { echo "eval found in awg_extract_all consumption"; return 1; }
}

# 8. The v3.1 optional keys must actually be populated (pre-init proves the
#    vars are wired even when extraction emits nothing).
@test "install.sh populates the v3.1 optional AWG_* vars" {
	for _v in AWG_S3 AWG_HPK AWG_I1 AWG_I5 AWG_CONTENT_PADDING_ADDITION \
	          AWG_REKEY_AFTER_TIME AWG_REKEY_TIMEOUT AWG_REJECT_AFTER_TIME \
	          AWG_KEEPALIVE_TIMEOUT AWG_MAX_HANDSHAKE_ATTEMPTS \
	          AWG_RANDOM_TRAILERS AWG_DISABLE_COOKIES; do
		grep -q "$_v" "$INSTALL" \
			|| { echo "install.sh never references $_v"; return 1; }
	done
}
