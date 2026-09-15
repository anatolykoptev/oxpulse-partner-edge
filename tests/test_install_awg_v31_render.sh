#!/usr/bin/env bats
# tests/test_install_awg_v31_render.sh — bats matrix for the AWG 3.1 render
# surface of configure_amneziawg (lib/install-awg.sh).
#
# Covers:
#   * byte-identical golden render when every v3.1 var is empty/unset
#     (backwards compat — the pre-3.1 fixture is the contract),
#   * full v3.1 golden render (all optional params present),
#   * render-if-present per key (set -> line, empty -> absent),
#   * the HPK precondition (effective S1-S4 all >= 12, absent S3 = 0),
#   * the conf-injection charset guard per field class:
#       client-side drop -> line omitted + .param-dropped marker,
#       must-match drop  -> line omitted + marker + AWG_CONF_DEGRADED=1,
#       identity/required drop -> conf NOT written + marker + degraded,
#   * stale-marker hygiene on a clean pass.
#
# flock is stubbed only where the flock(1) binary is absent (macOS) — on Linux
# CI the real lock acquisition runs. Locking itself is covered by
# tests/test_install_awg_lock.sh.
#
# bats <1.5 compat: negations use `run <cmd>; [ "$status" -ne 0 ]`, never a
# bare `! cmd` (SC2314 masking).

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
	_load_awg_globals
}

teardown() {
	rm -rf "$TMP"
}

# Frozen AWG_* fixture globals — same values as tests/test_install_awg_module.sh
# so the pre-3.1 golden fixture stays the compat baseline. AWG_S4 stays 6 (< 12
# — the fixture value); tests that need HPK to render export S4>=18 themselves.
# AWG_S3 stays unset (absent = 0 cases).
_load_awg_globals() {
	export AWG_PRIV_PATH="$TMP/awg-private.key"
	export AWG_PUB_PATH="$TMP/awg-public.key"
	export AWG_MOTHERLY_PUBKEY="MOTHERLY_PUBKEY_FIXTURE_AAAA1234="
	export AWG_MOTHERLY_ENDPOINT="10.0.0.1:51820"
	export AWG_MOTHERLY_AWG_IP="192.168.100.1"
	export AWG_ALLOCATED_IP="192.168.100.42/32"
	export AWG_JC="5"
	export AWG_JMIN="20"
	export AWG_JMAX="70"
	export AWG_S1="17"
	export AWG_S2="13"
	export AWG_S4="6"
	export AWG_H1="1234567890"
	export AWG_H2="2345678901"
	export AWG_H3="3456789012"
	export AWG_H4="4234567890"
	export AWG_CONF_DIR="$TMP/awg-conf"
	export AWG_LISTEN_PORT="43842"
	echo "mocked-private-key-base64==" > "$TMP/awg-private.key"
	mkdir -p "$TMP/awg-conf"
}

# Run the REAL configure_amneziawg in a child shell with every system-facing
# call stubbed. Exported AWG_* vars inherit. Prints CONFIGURE_EXIT and the
# AWG_CONF_DEGRADED out-param for assertions.
_configure() {
	run bash -c "
		source '$REPO_ROOT/lib/install-awg.sh'
		log()       { :; }
		warn()      { echo \"WARN: \$*\"; }
		die()       { echo \"DIE: \$*\" >&2; exit 1; }
		systemctl() { :; }
		awg()       { :; }
		sleep()     { :; }
		command -v flock >/dev/null 2>&1 || flock() { return 0; }
		configure_amneziawg
		echo \"CONFIGURE_EXIT=\$?\"
		echo \"DEGRADED=\${AWG_CONF_DEGRADED:-}\"
	"
}

_conf()    { printf '%s' "$TMP/awg-conf/awg0.conf"; }
_marker()  { printf '%s' "$TMP/awg-conf/awg0.conf.param-dropped"; }

# ---------------------------------------------------------------------------
# Golden renders
# ---------------------------------------------------------------------------
@test "v3.1: all optional vars unset -> conf byte-identical to pre-3.1 fixture" {
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONFIGURE_EXIT=0"* ]]
	diff "$REPO_ROOT/tests/fixtures/install-awg/expected-awg0.conf" "$TMP/awg-conf/awg0.conf"
	# no param-drop marker on a clean render
	[ ! -f "$(_marker)" ]
}

@test "v3.1: all optional vars explicitly empty -> conf byte-identical to pre-3.1 fixture" {
	export AWG_S3="" AWG_HPK="" AWG_I1="" AWG_I2="" AWG_I3="" AWG_I4="" AWG_I5=""
	export AWG_CONTENT_PADDING_ADDITION="" AWG_REKEY_AFTER_TIME="" AWG_REKEY_TIMEOUT=""
	export AWG_REJECT_AFTER_TIME="" AWG_KEEPALIVE_TIMEOUT="" AWG_MAX_HANDSHAKE_ATTEMPTS=""
	export AWG_RANDOM_TRAILERS="" AWG_DISABLE_COOKIES=""
	_configure
	[ "$status" -eq 0 ]
	diff "$REPO_ROOT/tests/fixtures/install-awg/expected-awg0.conf" "$TMP/awg-conf/awg0.conf"
}

@test "v3.1: full optional set renders byte-identical to the v3.1 golden fixture" {
	export AWG_S3="15" AWG_S4="18"          # all-S>=12 so HPK renders
	export AWG_H2="2000000000-2000000099"   # IntOrRange range-form passthrough
	export AWG_I1="<r 32><b 0x0100><rd 4><rc 8><t>"
	export AWG_I2="<rd 3>" AWG_I3="<rc 5>" AWG_I4="<r 16>" AWG_I5="<t>"
	export AWG_HPK="QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="
	export AWG_CONTENT_PADDING_ADDITION="8-24"
	export AWG_REKEY_AFTER_TIME="100-140" AWG_REKEY_TIMEOUT="3-6"
	export AWG_REJECT_AFTER_TIME="170-230" AWG_KEEPALIVE_TIMEOUT="8-12"
	export AWG_MAX_HANDSHAKE_ATTEMPTS="15-25"
	export AWG_RANDOM_TRAILERS="on" AWG_DISABLE_COOKIES="off"
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" == *"CONFIGURE_EXIT=0"* ]]
	[[ "$output" == *"DEGRADED="* && "$output" != *"DEGRADED=1"* ]]
	diff "$REPO_ROOT/tests/fixtures/install-awg/expected-awg0-v31.conf" "$TMP/awg-conf/awg0.conf"
}

# ---------------------------------------------------------------------------
# render-if-present per key: set -> the line appears; absent -> it does not.
# (The unset case for ALL keys is proven by the pre-3.1 golden above.)
# ---------------------------------------------------------------------------
@test "v3.1: each optional key renders only when set" {
	# var-name|ConfKey|value triples; one var set at a time.
	local cases="
AWG_S3|S3|15
AWG_I1|I1|<r 32><t>
AWG_I2|I2|<rd 3>
AWG_I3|I3|<rc 5>
AWG_I4|I4|<r 16>
AWG_I5|I5|<t>
AWG_CONTENT_PADDING_ADDITION|ContentPaddingAddition|8-24
AWG_REKEY_AFTER_TIME|RekeyAfterTime|100-140
AWG_REKEY_TIMEOUT|RekeyTimeout|3-6
AWG_REJECT_AFTER_TIME|RejectAfterTime|170-230
AWG_KEEPALIVE_TIMEOUT|KeepaliveTimeout|8-12
AWG_MAX_HANDSHAKE_ATTEMPTS|MaxHandshakeAttempts|15-25
AWG_RANDOM_TRAILERS|RandomTrailers|on
AWG_DISABLE_COOKIES|DisableCookies|off
"
	local _var _key _val
	while IFS='|' read -r _var _key _val; do
		[[ -z "$_var" ]] && continue
		# </dev/null: the inner bash -c must not consume the loop's herestring.
		env "$_var=$_val" bash -c "
			source '$REPO_ROOT/lib/install-awg.sh'
			log() { :; }; warn() { :; }; die() { exit 1; }
			systemctl() { :; }; awg() { :; }; sleep() { :; }
			command -v flock >/dev/null 2>&1 || flock() { return 0; }
			configure_amneziawg
		" < /dev/null
		grep -q "^${_key} = ${_val}$" "$TMP/awg-conf/awg0.conf" \
			|| { echo "FAIL: $_key line missing when $_var set"; return 1; }
		rm -f "$TMP/awg-conf/awg0.conf" "$TMP/awg-conf/awg0.conf.param-dropped"
	done <<< "$cases"
}

@test "v3.1: H range-form value (x-y) renders verbatim" {
	export AWG_H2="2000000000-2000000099"
	_configure
	[ "$status" -eq 0 ]
	grep -q "^H2 = 2000000000-2000000099$" "$TMP/awg-conf/awg0.conf"
}

# ---------------------------------------------------------------------------
# HPK precondition: renders only when ALL effective S1..S4 >= 12 (absent S3=0)
# ---------------------------------------------------------------------------
@test "v3.1: HPK renders when S3 present and all S >= 12" {
	export AWG_S3="15" AWG_S4="18"   # lift S4 over the >= 12 floor
	export AWG_HPK="QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="
	_configure
	[ "$status" -eq 0 ]
	grep -q "^HeaderProtectionKey = QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI=$" "$TMP/awg-conf/awg0.conf"
	[[ "$output" != *"DEGRADED=1"* ]]
	[ ! -f "$(_marker)" ]
}

@test "v3.1: HPK omitted + marker + degraded when S3 absent (absent = 0 < 12)" {
	# _load_awg_globals deliberately never sets AWG_S3.
	export AWG_HPK="QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="
	_configure
	[ "$status" -eq 0 ]
	# check $output before any later `run` call overwrites it
	[[ "$output" == *"DEGRADED=1"* ]]
	run grep -q "HeaderProtectionKey" "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	[ -f "$(_marker)" ]
	grep -q "header_protection_key" "$(_marker)"
}

@test "v3.1: HPK omitted + degraded when any S < 12" {
	export AWG_S3="15" AWG_S4="6"   # S4 below the >= 12 floor
	export AWG_HPK="QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="
	_configure
	[ "$status" -eq 0 ]
	run grep -q "HeaderProtectionKey" "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	[ -f "$(_marker)" ]
}

@test "v3.1: non-numeric required must-match S1 skips the write entirely" {
	export AWG_S3="15" AWG_S1="abc"
	export AWG_HPK="QUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUJDQUI="
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" == *"DEGRADED=1"* ]]
	# S1 is a required field — an out-of-grammar value renders a conf
	# `awg syncconf` refuses outright (dead-but-green), so the whole write
	# is skipped and the marker names the field. Same fail-closed contract
	# as the agent's merge (params.rs validate_s_value).
	[ ! -f "$TMP/awg-conf/awg0.conf" ]
	[ -f "$(_marker)" ]
	grep -q "AWG_S1" "$(_marker)"
}

# ---------------------------------------------------------------------------
# Charset guard — the bytes NEVER render, per field class
# ---------------------------------------------------------------------------
@test "v3.1: i1 carrying '\n[Peer]' is not rendered; marker written; not degraded (client-side)" {
	export AWG_I1=$'<r 2>\n[Peer]\nAllowedIPs = 0.0.0.0/0'
	_configure
	[ "$status" -eq 0 ]
	# client-side drop degrades a feature, not the link — assert before a
	# later `run` overwrites $output and the check goes vacuous
	[[ "$output" != *"DEGRADED=1"* ]]
	run grep -q "^I1 = " "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	run grep -q "0.0.0.0/0" "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	# exactly one [Peer] section — the legit one
	[ "$(grep -c '^\[Peer\]' "$TMP/awg-conf/awg0.conf")" -eq 1 ]
	[ -f "$(_marker)" ]
	grep -q "i1" "$(_marker)"
}

@test "v3.1: client-side grammar failure omits just that line (i1 free text)" {
	export AWG_I1="not-a-tag-blob"
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" != *"DEGRADED=1"* ]]
	run grep -q "^I1 = " "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	[ -f "$(_marker)" ]
	grep -q "i1(grammar)" "$(_marker)"
}

@test "v3.1: must-match charset failure drops the line + marker + degraded (s3)" {
	export AWG_S3=$'15\n[Peer]'
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" == *"DEGRADED=1"* ]]
	[[ "$output" == *"will NOT come up"* ]]
	run grep -q "^S3 = " "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	[ "$(grep -c '^\[Peer\]' "$TMP/awg-conf/awg0.conf")" -eq 1 ]
	[ -f "$(_marker)" ]
	grep -q "s3" "$(_marker)"
}

@test "v3.1: identity-field injection skips the whole write, preserves existing conf" {
	export AWG_MOTHERLY_ENDPOINT=$'10.0.0.1:51820\n[Peer]\nAllowedIPs = 0.0.0.0/0'
	echo "PREEXISTING-GOOD-CONF" > "$TMP/awg-conf/awg0.conf"
	_configure
	[ "$status" -eq 0 ]
	[[ "$output" == *"DEGRADED=1"* ]]
	[[ "$output" == *"will NOT come up"* ]]
	# the existing conf is byte-untouched — a scrubbed render would kill it
	grep -q "PREEXISTING-GOOD-CONF" "$TMP/awg-conf/awg0.conf"
	run grep -q "0.0.0.0/0" "$TMP/awg-conf/awg0.conf"
	[ "$status" -ne 0 ]
	[ -f "$(_marker)" ]
	grep -q "AWG_MOTHERLY_ENDPOINT" "$(_marker)"
}

@test "v3.1: required-param charset failure skips the write (jc)" {
	export AWG_JC=$'5\n[Peer]'
	_configure
	[ "$status" -eq 0 ]
	# no conf written at all on a fresh render
	[ ! -f "$TMP/awg-conf/awg0.conf" ]
	[ -f "$(_marker)" ]
	grep -q "AWG_JC" "$(_marker)"
	[[ "$output" == *"DEGRADED=1"* ]]
}

@test "v3.1: a clean pass clears a stale .param-dropped marker" {
	: > "$(_marker)"
	_configure
	[ "$status" -eq 0 ]
	[ ! -f "$(_marker)" ]
	grep -q "PrivateKey = mocked-private-key-base64==" "$TMP/awg-conf/awg0.conf"
}

@test "v3.1: grammar-invalid must-match drops the line + marker + degraded (s3)" {
	# A charset-clean but grammar-invalid must-match value must NOT render:
	# upstream S fields are u16 — `awg syncconf` would reject the whole conf
	# (dead-but-green). Drop the line, keep the rest, mark degraded.
	export AWG_S3="15x"   # charset-clean, grammar-odd
	_configure
	[ "$status" -eq 0 ]
	! grep -q "^S3" "$TMP/awg-conf/awg0.conf"
	grep -q "^Jc = " "$TMP/awg-conf/awg0.conf"   # rest of the conf still rendered
	grep -q "s3(grammar)" "$(_marker)"
	[[ "$output" == *"DEGRADED=1"* ]]
}

# ---------------------------------------------------------------------------
# I-tag strict-parity — upstream splits each <…> token on the FIRST literal
# space (strings.Cut) and hands the WHOLE remainder to the arg parser. Any
# normalisation a whitespace-split would apply (extra args dropped, runs of
# space collapsed, tabs treated as separators) accepts values upstream
# rejects → the rendered conf wedges syncconf. Each value below must take
# the i-tag grammar-drop path (client-side: line omitted, marker, no
# degraded). Reverting _awg_itag to `read -ra` flips these RED.
# ---------------------------------------------------------------------------
@test "v3.1: I-tag values upstream rejects are dropped (first-space parity)" {
	local cases=(
		'<r 5 junk>'       # extra arg — upstream Atoi("5 junk") fails
		'<b abcd extra>'   # extra arg — upstream hex-decode fails
		'<r  5>'           # double space — upstream Atoi(" 5") fails
		'<r	5>'            # literal tab — not the cut char → unknown key "r\t5"
		'<r 5 >'           # trailing space — upstream Atoi("5 ") fails
		'<r>'              # missing arg — upstream Atoi("") fails
		'<b>'              # missing arg — upstream hex-decode("") fails
		'<b 0x>'           # empty hex after prefix strip
		'<r 65536>'        # above the u16-junk bound
		'<r5>'             # no separator → unknown key
		'<xyz 5>'          # unknown tag
	)
	local v
	for v in "${cases[@]}"; do
		env "AWG_I1=$v" bash -c "
			source '$REPO_ROOT/lib/install-awg.sh'
			log() { :; }; warn() { :; }; die() { exit 1; }
			systemctl() { :; }; awg() { :; }; sleep() { :; }
			command -v flock >/dev/null 2>&1 || flock() { return 0; }
			configure_amneziawg
		" < /dev/null
		grep -q "^I1 = " "$TMP/awg-conf/awg0.conf" \
			&& { echo "FAIL: I1 value ${v@Q} rendered but upstream rejects it"; return 1; }
		grep -q "i1(grammar)" "$(_marker)" \
			|| { echo "FAIL: i1(grammar) drop not recorded for ${v@Q}"; return 1; }
		rm -f "$TMP/awg-conf/awg0.conf" "$(_marker)"
	done
}

@test "v3.1: I-tag values upstream accepts still render (no over-reject)" {
	# t/d/ds args are ignored upstream → an arg is legal there (only the
	# numeric-arg tags must stay strict).
	local cases=(
		'<r 5>'
		'<b 0xabcd>'
		'<b abCD01>'
		'<t>'
		'<t anything-here>'
		'<dz 0><rd 65535><r 32><t>'
	)
	local v
	for v in "${cases[@]}"; do
		env "AWG_I1=$v" bash -c "
			source '$REPO_ROOT/lib/install-awg.sh'
			log() { :; }; warn() { :; }; die() { exit 1; }
			systemctl() { :; }; awg() { :; }; sleep() { :; }
			command -v flock >/dev/null 2>&1 || flock() { return 0; }
			configure_amneziawg
		" < /dev/null
		grep -q "^I1 = $v\$" "$TMP/awg-conf/awg0.conf" \
			|| { echo "FAIL: upstream-valid I1 value ${v@Q} was not rendered"; return 1; }
		rm -f "$TMP/awg-conf/awg0.conf" "$(_marker)"
	done
}
