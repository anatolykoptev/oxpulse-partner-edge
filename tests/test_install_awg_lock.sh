#!/usr/bin/env bats
# tests/test_install_awg_lock.sh — awg0.conf lost-update race guard (Task 1).
#
# Finding (data_loss / critical): lib/install-awg.sh configure_amneziawg and the
# awg-params-agent daemon both write /etc/amnezia/amneziawg/awg0.conf with zero
# coordination, so a mid-install agent tick can revert just-rotated identity
# (PrivateKey/Endpoint/Jc/S1-S4/H1-H4). Fix: both writers flock(2) the SAME
# <conf>.lock file. This test exercises the REAL configure_amneziawg write and
# proves:
#   1. configure_amneziawg uses flock (acceptance: `grep flock` non-empty).
#   2. Under a concurrent locked writer (mock agent) that reverts whatever it
#      read, the installer's fresh identity SURVIVES — because the installer's
#      flock blocks the agent until the fresh write lands.
#
# The race test goes RED if the installer's flock is reverted: the mock agent's
# stale-snapshot restore then clobbers the installer's fresh Endpoint.

setup() {
	REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
	TMP="$(mktemp -d)"
}

teardown() {
	# Reap any stray competitor process, then clean up.
	[[ -n "${COMP_PID:-}" ]] && kill "$COMP_PID" 2>/dev/null
	rm -rf "$TMP"
}

# Frozen "fresh" (installer) AWG_* fixture — the values configure_amneziawg writes.
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
	export AWG_H4="4567890123"
	export AWG_CONF_DIR="$TMP/awg-conf"
	export AWG_LISTEN_PORT="43842"
	echo "FRESH-private-key-base64==" > "$TMP/awg-private.key"
	mkdir -p "$TMP/awg-conf"
}

# ---------------------------------------------------------------------------
# Test 1: acceptance criterion — configure_amneziawg uses flock.
# ---------------------------------------------------------------------------
@test "install-awg.sh serializes the awg0.conf write with flock" {
	run grep -n 'flock' "$REPO_ROOT/lib/install-awg.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"flock -w 10 9"* ]]
}

# ---------------------------------------------------------------------------
# Test 2: lock path is derived as "<conf>.lock" (shared byte-for-byte with the
# agent's OXPULSE_AWG_CONF_LOCK_PATH default), and the lock file is created.
# ---------------------------------------------------------------------------
@test "configure_amneziawg creates the <conf>.lock lock file" {
	_load_awg_globals
	local conf_path="$TMP/awg-conf/awg0.conf"

	run bash -c "
		source '$REPO_ROOT/lib/install-awg.sh'
		log()       { :; }
		warn()      { :; }
		die()       { echo \"DIE: \$*\" >&2; exit 1; }
		systemctl() { :; }
		awg()       { :; }
		sleep()     { :; }
		$(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
			AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
			AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
			AWG_CONF_DIR AWG_LISTEN_PORT)
		configure_amneziawg
	"
	[ "$status" -eq 0 ]
	[ -f "${conf_path}.lock" ]
}

# ---------------------------------------------------------------------------
# Test 3: RACE — a concurrent locked agent must NOT revert the installer's fresh
# identity. Mock agent = take the shared lock, snapshot the conf (read), delay,
# restore the snapshot (write) — reverting whatever the installer wrote. With
# the installer's flock, the agent blocks until the fresh write lands, so the
# fresh Endpoint survives. Without it (regression), the stale snapshot wins.
# ---------------------------------------------------------------------------
@test "concurrent locked agent does not revert configure_amneziawg's fresh identity" {
	_load_awg_globals
	local conf_path="$TMP/awg-conf/awg0.conf"
	local lock_path="${conf_path}.lock"
	local snap="$TMP/agent_snapshot"

	# Pre-seed the conf with a DISTINCT "old" identity the agent will snapshot.
	cat > "$conf_path" <<-OLDCONF
		[Interface]
		PrivateKey = OLD-private-key-base64==
		Address = 192.168.100.42/32
		ListenPort = 43842
		Jc = 99

		[Peer]
		PublicKey = MOTHERLY_PUBKEY_FIXTURE_AAAA1234=
		Endpoint = 9.9.9.9:51820
		AllowedIPs = 192.168.100.1/32
		PersistentKeepalive = 25
	OLDCONF

	# Mock agent in a SEPARATE process (real sleep, not the installer's stub):
	# lock → read(snapshot) → delay → write(restore snapshot / revert).
	bash -c '
		conf="'"$conf_path"'"; lock="'"$lock_path"'"; snap="'"$snap"'"
		exec 8>"$lock"
		flock -w 20 8
		cp "$conf" "$snap"     # agent read
		sleep 2                # widened read->write window
		cp "$snap" "$conf"     # agent write (reverts to snapshot)
	' &
	COMP_PID=$!

	# Head start: let the agent grab the lock + snapshot OLD before the installer.
	sleep 0.5

	# The REAL installer write (fresh identity). Under the fix it blocks on the
	# agent's lock until ~t=2s, then writes the fresh Endpoint 10.0.0.1:51820.
	run bash -c "
		source '$REPO_ROOT/lib/install-awg.sh'
		log()       { :; }
		warn()      { :; }
		die()       { echo \"DIE: \$*\" >&2; exit 1; }
		systemctl() { :; }
		awg()       { :; }
		sleep()     { :; }
		$(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
			AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
			AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
			AWG_CONF_DIR AWG_LISTEN_PORT)
		configure_amneziawg
	"
	[ "$status" -eq 0 ]

	# Wait for the mock agent to finish its (reverting) write.
	wait "$COMP_PID"
	COMP_PID=""

	# The installer's fresh identity must have survived the concurrent revert.
	# Assert the FULL identity set the spec names (PrivateKey/Endpoint/Jc/S1-S4),
	# each discriminating: the OLD snapshot the agent restores has Endpoint
	# 9.9.9.9, Jc=99 and NO S* lines, so the installer's fresh values below can
	# only be present if its flocked write won the race.
	run cat "$conf_path"
	[[ "$output" == *"Endpoint = 10.0.0.1:51820"* ]]
	[[ "$output" != *"9.9.9.9:51820"* ]]
	[[ "$output" == *"PrivateKey = FRESH-private-key-base64=="* ]]
	[[ "$output" == *"Jc = 5"* ]]
	[[ "$output" != *"Jc = 99"* ]]
	[[ "$output" == *"S1 = 17"* ]]
	[[ "$output" == *"S2 = 13"* ]]
	[[ "$output" == *"S4 = 6"* ]]
}

# ---------------------------------------------------------------------------
# Test 4: LOCK-CONTENDED FAIL-SOFT — when the shared lock is held past the
# installer's `flock -w 10`, configure_amneziawg must:
#   (a) leave awg0.conf UNTOUCHED (never a partial unlocked write),
#   (b) drop a durable `<conf>.rotation-skipped` marker so a scripted /
#       non-interactive install has an observable trace of the dropped rotation,
#   (c) NOT falsely claim the agent self-heals identity (the agent only
#       reconciles obfuscation params, never PrivateKey/Endpoint/Address),
#   (d) still return 0 so `set -e` does not abort the install and skip
#       firewall_apply.
# Reverting the marker/warn-text fix makes (b) or (c) go RED.
# ---------------------------------------------------------------------------
@test "lock-contended install skips write, drops a durable marker, and does not falsely claim agent self-heal" {
	_load_awg_globals
	local conf_path="$TMP/awg-conf/awg0.conf"
	local lock_path="${conf_path}.lock"
	local marker="${conf_path}.rotation-skipped"

	# Pre-seed a DISTINCT OLD identity that must remain byte-untouched on the skip.
	cat > "$conf_path" <<-OLDCONF
		[Interface]
		PrivateKey = OLD-private-key-base64==
		Address = 192.168.100.42/32
		Endpoint = 9.9.9.9:51820
	OLDCONF

	# Competitor holds the shared lock LONGER than the installer's flock -w 10.
	bash -c 'exec 8>"'"$lock_path"'"; flock 8; sleep 12' &
	COMP_PID=$!

	# Head start so the competitor provably owns the lock before the installer tries.
	sleep 0.5

	# Real installer write. Under the fix it blocks ~10s on flock, times out, then
	# fail-softs (warn + marker + return 0). warn() is stubbed to stdout so the
	# emitted text is asserted below. Only sleep() is stubbed — flock -w uses its
	# own internal timeout, so the 10s wait is the REAL contention path.
	run bash -c "
		source '$REPO_ROOT/lib/install-awg.sh'
		log()       { :; }
		warn()      { echo \"WARN: \$*\"; }
		die()       { echo \"DIE: \$*\" >&2; exit 1; }
		systemctl() { :; }
		awg()       { :; }
		sleep()     { :; }
		$(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
			AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
			AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
			AWG_CONF_DIR AWG_LISTEN_PORT)
		configure_amneziawg
	"

	# Competitor no longer needed; reap it now (don't wait its full 12s).
	kill "$COMP_PID" 2>/dev/null
	COMP_PID=""

	# (d) Fail-soft: returns 0 so the install continues to firewall_apply.
	[ "$status" -eq 0 ]

	# (a) Conf untouched — OLD identity intact, no FRESH bytes written unlocked.
	grep -q 'PrivateKey = OLD-private-key-base64==' "$conf_path"
	! grep -q 'FRESH-private-key-base64==' "$conf_path"

	# (b) Durable marker written and points the operator at the real recovery path.
	[ -f "$marker" ]
	grep -q 're-run' "$marker"

	# (c) Warn text does NOT claim the agent reconciles (identity is NOT self-healing);
	#     it DOES tell the operator to re-run.
	[[ "$output" != *"reconciles on its next poll"* ]]
	[[ "$output" == *"re-run the install"* ]]
	[[ "$output" == *"NOT identity"* ]]
}

# ---------------------------------------------------------------------------
# Test 5: the successful write path clears any stale skip marker so a prior
# contended run's marker cannot linger as a false "rotation dropped" signal.
# ---------------------------------------------------------------------------
@test "successful configure_amneziawg clears a stale rotation-skipped marker" {
	_load_awg_globals
	local conf_path="$TMP/awg-conf/awg0.conf"
	local marker="${conf_path}.rotation-skipped"

	# Simulate a stale marker left by an earlier lock-contended run.
	: > "$marker"
	[ -f "$marker" ]

	run bash -c "
		source '$REPO_ROOT/lib/install-awg.sh'
		log()       { :; }
		warn()      { :; }
		die()       { echo \"DIE: \$*\" >&2; exit 1; }
		systemctl() { :; }
		awg()       { :; }
		sleep()     { :; }
		$(declare -p AWG_PRIV_PATH AWG_PUB_PATH AWG_MOTHERLY_PUBKEY AWG_MOTHERLY_ENDPOINT \
			AWG_MOTHERLY_AWG_IP AWG_ALLOCATED_IP AWG_JC AWG_JMIN AWG_JMAX \
			AWG_S1 AWG_S2 AWG_S4 AWG_H1 AWG_H2 AWG_H3 AWG_H4 \
			AWG_CONF_DIR AWG_LISTEN_PORT)
		configure_amneziawg
	"
	[ "$status" -eq 0 ]

	# Fresh write succeeded → conf has FRESH identity and the stale marker is gone.
	grep -q 'PrivateKey = FRESH-private-key-base64==' "$conf_path"
	[ ! -f "$marker" ]
}
