#!/usr/bin/env bats
# tests/test_channel_health_lib_fitness.sh — fitness functions for the P2
# strangler-fig extraction (2026-07-08 plan:
# ~/deploy/krolik-server/plans/oxpulse-partner-edge/
# 2026-07-08-health-report-lib-extraction.md).
#
# Extracted probe_ch1-4, _resolve_coturn_probe_target, _elapsed_ms,
# _write_probe_mode_state, _post_channel, _check_upstream_transitions,
# _emit_serveability out of oxpulse-channels-health-report.sh into
# lib/channel-health-lib.sh. This lib bears BOTH externally-depended wire
# contracts (POST /api/partner/channel-health body shape, and the
# ^chN=(OK|DOWN)$ --serveability stdout upgrade.sh's auto-rollback settle gate
# greps) — a regression here is not caught by a type system, only by these
# structural guards + the existing black-box behavioral corpus
# (test_settle_serveability.sh, test_upstream_transition_negative.sh,
# test_upstream_transition_alert.sh, test_channels_health_report.sh, …).
#
# Covers:
#   1. one-function-one-file: each extracted function name is defined
#      (top-level `name() {`) in exactly one *.sh file in the repo — guards
#      against a forgotten deletion at the old site (silent shadow/duplicate)
#      and a future accidental re-add.
#   2. the orchestrator no longer defines any of the extracted functions
#      itself (the specific, sharper half of check 1 for the known old site).
#   3. the orchestrator sources lib/channel-health-lib.sh fail-closed (a
#      `source` call with a preceding `die` on not-found — not a soft warn).
#   4. lib/channel-health-lib.sh has the double-source guard (repo convention
#      — lib/reconcile.sh:1-22 template).
#   5. ADR-5 fail-loud precondition: _emit_serveability declares the
#      `declare -F probe_ch1 || die` guard before its dynamic dispatch.
#
# bats <1.5 compat: no bats_require_minimum_version, no 'run !'.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	LIB="$REPO_ROOT/lib/channel-health-lib.sh"
	ORCH="$REPO_ROOT/oxpulse-channels-health-report.sh"
	FUNCS=(
		probe_ch1
		probe_ch2
		probe_ch3
		probe_ch4
		_resolve_coturn_probe_target
		_elapsed_ms
		_write_probe_mode_state
		_post_channel
		_check_upstream_transitions
		_emit_serveability
	)
}

@test "lib/channel-health-lib.sh and oxpulse-channels-health-report.sh both exist" {
	[ -f "$LIB" ]
	[ -f "$ORCH" ]
}

@test "each extracted function is defined in exactly one *.sh file in the repo" {
	[ -f "$LIB" ] || skip "lib missing"
	local fn count hits
	for fn in "${FUNCS[@]}"; do
		# Top-level definitions only (column 0), across every tracked *.sh file.
		hits=$(cd "$REPO_ROOT" && git ls-files '*.sh' | xargs grep -lE "^${fn}\\(\\)" 2>/dev/null || true)
		count=$(printf '%s\n' "$hits" | grep -c . || true)
		if [ "$count" -ne 1 ]; then
			echo "function '$fn' defined in $count file(s), expected exactly 1:"
			echo "$hits"
			false
		fi
	done
}

@test "each extracted function's sole definition site is lib/channel-health-lib.sh" {
	[ -f "$LIB" ] || skip "lib missing"
	local fn hits
	for fn in "${FUNCS[@]}"; do
		hits=$(cd "$REPO_ROOT" && git ls-files '*.sh' | xargs grep -lE "^${fn}\\(\\)" 2>/dev/null || true)
		if [ "$hits" != "lib/channel-health-lib.sh" ]; then
			echo "function '$fn' expected to live only in lib/channel-health-lib.sh, found in:"
			echo "$hits"
			false
		fi
	done
}

@test "oxpulse-channels-health-report.sh no longer defines any extracted function" {
	[ -f "$ORCH" ] || skip "orchestrator missing"
	local fn
	for fn in "${FUNCS[@]}"; do
		if grep -qE "^${fn}\\(\\)" "$ORCH"; then
			echo "orchestrator still defines '$fn' — extraction incomplete (stale duplicate)"
			false
		fi
	done
}

@test "orchestrator sources lib/channel-health-lib.sh fail-closed" {
	[ -f "$ORCH" ] || skip "orchestrator missing"
	grep -q 'channel-health-lib.sh' "$ORCH"
	# A die() call must appear between the resolution loop and the source line
	# — i.e. missing-lib is a hard exit, not a soft warn-and-continue (unlike
	# the optional telegram-alert-lib.sh runtime load a few hundred lines
	# later in this same script).
	local block
	block=$(awk '/_CHANNEL_HEALTH_LIB=/{found=1} found{print} /^source "\$_CHANNEL_HEALTH_LIB"/{exit}' "$ORCH")
	echo "$block" | grep -q 'die ' || {
		echo "no die() found in the channel-health-lib.sh source block — not fail-closed"
		false
	}
	echo "$block" | grep -q '^source "\$_CHANNEL_HEALTH_LIB"' || {
		echo "no 'source \"\$_CHANNEL_HEALTH_LIB\"' line found"
		false
	}
}

@test "lib/channel-health-lib.sh has the double-source guard" {
	[ -f "$LIB" ] || skip "lib missing"
	grep -q '_CHANNEL_HEALTH_LIB_LOADED' "$LIB"
}

@test "ADR-5: _emit_serveability has the fail-loud probe_ch1 precondition" {
	[ -f "$LIB" ] || skip "lib missing"
	local body
	body=$(awk '/^_emit_serveability\(\)/{found=1} found{print} /^}$/ && found{exit}' "$LIB")
	echo "$body" | grep -q "declare -F probe_ch1" || {
		echo "_emit_serveability is missing the 'declare -F probe_ch1' fail-loud guard"
		false
	}
	echo "$body" | grep -q "declare -F probe_ch1 >/dev/null || die" || {
		echo "the guard does not die on missing probe_ch1 — not fail-loud"
		false
	}
}

@test "ADR-5 guard actually fires: _emit_serveability dies when probe_ch1 is undefined" {
	[ -f "$LIB" ] || skip "lib missing"
	# Static-text checks above only confirm the guard STRING is present; this
	# proves it actually EXECUTES and halts before reaching the dispatch loop
	# (a load-order/partial-source regression must not silently fall through
	# to reporting a false all-DOWN, which would trip upgrade.sh's rollback
	# gate on a healthy box — code-quality-reviewer NIT, 2026-07-08 review).
	run bash -c "
		die() { printf 'DIED: %s\n' \"\$*\" >&2; exit 1; }
		source '$LIB'
		unset -f probe_ch1
		_emit_serveability
	"
	[ "$status" -eq 1 ]
	echo "$output" | grep -q "DIED:.*probe functions not loaded"
}

@test "wire contract #1: _post_channel JSON envelope fields unchanged" {
	[ -f "$LIB" ] || skip "lib missing"
	local body
	body=$(awk '/^_post_channel\(\)/{found=1} found{print} /^}$/ && found{exit}' "$LIB")
	# The jq filter that builds the POST body must still merge exactly these
	# fields onto the probe's own payload — node_id / channel_probed_at always,
	# installer_version conditionally. A rename/drop here breaks the central
	# server's ingest schema.
	echo "$body" | grep -q 'node_id: \$node_id' || { echo "node_id field missing from _post_channel jq filter"; false; }
	echo "$body" | grep -q 'channel_probed_at: \$ts' || { echo "channel_probed_at field missing"; false; }
	echo "$body" | grep -qF '/api/partner/channel-health' || { echo "POST target path changed"; false; }
}

@test "wire contract #2: _emit_serveability stdout is still ^chN=(OK|DOWN)\$" {
	[ -f "$LIB" ] || skip "lib missing"
	local body
	body=$(awk '/^_emit_serveability\(\)/{found=1} found{print} /^}$/ && found{exit}' "$LIB")
	echo "$body" | grep -qF "printf '%s=OK\\n' \"\$_canon\"" || { echo "OK line format changed"; false; }
	echo "$body" | grep -qF "printf '%s=DOWN\\n' \"\$_canon\"" || { echo "DOWN line format changed"; false; }
}
