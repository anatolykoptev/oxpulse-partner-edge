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
