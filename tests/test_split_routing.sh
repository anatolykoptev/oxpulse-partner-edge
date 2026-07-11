#!/usr/bin/env bats
# tests/test_split_routing.sh — bats correctness gate for:
#   oxpulse-partner-edge-split-routing.sh  (apply)
#   oxpulse-partner-edge-split-disable.sh  (revert)
#
# Strategy: PATH-shim system binaries (nft, ip, sysctl, awg, getent) as
# argv+stdin recorders. Run the scripts against fixture files. Assert the
# 14 эталон invariants from the spec
# (the operator's internal split-routing settings canon (2026-05-27) §10).
#
# All file paths are overridden via env vars so the test runs without root.

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    APPLY="$REPO_ROOT/oxpulse-partner-edge-split-routing.sh"
    DISABLE="$REPO_ROOT/oxpulse-partner-edge-split-disable.sh"
    TMP="$(mktemp -d)"
    CALLS="$TMP/calls"
    mkdir -p "$CALLS"
    mkdir -p "$TMP/mocks"

    # --- mock: nft — records argv and stdin ---
    cat >"$TMP/mocks/nft" <<'MOCK'
#!/usr/bin/env bash
echo "nft $*" >> "$CALLS_DIR/argv.log"
if [[ "$*" == *"-f -"* || "$*" == *"-f-"* ]]; then
    cat >> "$CALLS_DIR/nft.stdin.log"
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/nft"

    # --- mock: ip — records argv; ip route show default returns fixture ---
    cat >"$TMP/mocks/ip" <<'MOCK'
#!/usr/bin/env bash
echo "ip $*" >> "$CALLS_DIR/argv.log"
# Provide a fake default route so auto-detect works.
if [[ "$*" == *"route show default"* || "$*" == "-4 route show default" || "$*" == "-4 route show default"* ]]; then
    echo "default via 10.0.0.1 dev ens3 proto dhcp src 10.0.0.100 metric 100"
fi
if [[ "$*" == *"route show table"* ]]; then
    : # empty table by default
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/ip"

    # --- mock: sysctl --- records argv ---
    cat >"$TMP/mocks/sysctl" <<'MOCK'
#!/usr/bin/env bash
echo "sysctl $*" >> "$CALLS_DIR/argv.log"
exit 0
MOCK
    chmod +x "$TMP/mocks/sysctl"

    # --- mock: awg --- records argv; show peers returns fixture pubkey ---
    cat >"$TMP/mocks/awg" <<'MOCK'
#!/usr/bin/env bash
echo "awg $*" >> "$CALLS_DIR/argv.log"
if [[ "$*" == "show awg0 peers" ]]; then
    echo "FIXTUREPUBKEY1234AAAA5678BBBB9012CCCC3456DDDD7890EEEE1234FFFF56789="
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/awg"

    # --- mock: getent --- resolves fixture endpoint host ---
    cat >"$TMP/mocks/getent" <<'MOCK'
#!/usr/bin/env bash
echo "getent $*" >> "$CALLS_DIR/argv.log"
# ahostsv4 <host> → return fixture IP
if [[ "$1" == "ahostsv4" ]]; then
    echo "203.0.113.10 STREAM hub.example.com"
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/getent"

    # --- mock: mkdir, cat (for state saving) ---
    # Let real mkdir/cat handle these (they run fine as non-root in TMP).

    # Fixture: awg conf with a known Endpoint + Peer pubkey.
    AWG_CONF_FIXTURE="$TMP/awg0.conf"
    cat >"$AWG_CONF_FIXTURE" <<'CONF'
[Interface]
Address = 10.9.0.42/32
PrivateKey = FIXTUREPRIVKEY=
Table = off
FwMark = off

[Peer]
PublicKey = FIXTUREPUBKEY1234AAAA5678BBBB9012CCCC3456DDDD7890EEEE1234FFFF56789=
Endpoint = 203.0.113.10:443
AllowedIPs = 203.0.113.10/32
Jc = 5
CONF

    # Fixture: ru-subnets — a handful of real RU CIDRs.
    RU_FILE_FIXTURE="$TMP/ru-subnets.txt"
    printf '5.8.0.0/21\n5.8.8.0/24\n5.8.9.0/24\n77.88.0.0/18\n178.154.128.0/18\n' \
        >"$RU_FILE_FIXTURE"

    # State dir (replaces /run and /etc/sysctl.d for test).
    STATE_DIR="$TMP/state"
    SYSCTL_PERSIST_DIR="$TMP/sysctl.d"
    mkdir -p "$STATE_DIR" "$SYSCTL_PERSIST_DIR"

    export CALLS_DIR="$CALLS"
    export PATH="$TMP/mocks:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

# ─── helpers ────────────────────────────────────────────────────────────────

# Run the apply script with all env overrides.
_run_apply() {
    run bash "$APPLY" \
        --vpn-if awg0 \
        --conf "$AWG_CONF_FIXTURE" \
        --ru-file "$RU_FILE_FIXTURE" \
        --state-dir "$STATE_DIR" \
        --sysctl-persist-dir "$SYSCTL_PERSIST_DIR"
}

# Run the disable script with all env overrides.
_run_disable() {
    run bash "$DISABLE" \
        --vpn-if awg0 \
        --state-dir "$STATE_DIR" \
        --sysctl-persist-dir "$SYSCTL_PERSIST_DIR"
}

# ─── invariant 1: ip_forward set BEFORE rp_filter ───────────────────────────
@test "INV1: ip_forward is set before rp_filter in sysctl calls" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # The kernel resets per-iface conf params when ip_forward changes (эталон §2).
    # We check only WRITE calls (-qw flags) — state-snapshot reads (-n) are allowed
    # to precede ip_forward in the log because they do not mutate kernel state.
    grep -q "sysctl -qw net.ipv4.ip_forward=1" "$CALLS/argv.log" || {
        echo "sysctl -qw ip_forward=1 not found"
        cat "$CALLS/argv.log"
        false
    }
    fwd_line=$(grep -n "sysctl -qw net.ipv4.ip_forward=1" "$CALLS/argv.log" | head -1 | cut -d: -f1)
    rpf_line=$(grep -n "sysctl -qw.*rp_filter"            "$CALLS/argv.log" | head -1 | cut -d: -f1)
    [[ -n "$fwd_line" ]] || { echo "sysctl -qw ip_forward=1 not found"; cat "$CALLS/argv.log"; false; }
    [[ -n "$rpf_line" ]] || { echo "sysctl -qw rp_filter not found"; cat "$CALLS/argv.log"; false; }
    [[ "$fwd_line" -lt "$rpf_line" ]] || {
        echo "ip_forward WRITE (line $fwd_line) must come before rp_filter WRITE (line $rpf_line)"
        cat "$CALLS/argv.log"
        false
    }
}

# ─── invariant 2: rp_filter=2 on all, WAN iface, awg0 ──────────────────────
@test "INV2: rp_filter=2 set on all, WAN iface (ens3), and awg0" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q "net.ipv4.conf.all.rp_filter=2"  "$CALLS/argv.log" || { echo "missing all.rp_filter=2"; cat "$CALLS/argv.log"; false; }
    grep -q "net.ipv4.conf.ens3.rp_filter=2" "$CALLS/argv.log" || { echo "missing ens3.rp_filter=2"; cat "$CALLS/argv.log"; false; }
    grep -q "net.ipv4.conf.awg0.rp_filter=2" "$CALLS/argv.log" || { echo "missing awg0.rp_filter=2"; cat "$CALLS/argv.log"; false; }
    # Must NOT set rp_filter=0
    ! grep -q "rp_filter=0" "$CALLS/argv.log" || { echo "rp_filter=0 found — must not disable"; false; }
}

# ─── invariant 3: numeric table id, never name "vpn" ───────────────────────
@test "INV3: routing table uses numeric id 13573, not name 'vpn'" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q "table 13573" "$CALLS/argv.log" || { echo "numeric table 13573 not found"; cat "$CALLS/argv.log"; false; }
    ! grep -q "table vpn"  "$CALLS/argv.log" || { echo "table vpn found — must use numeric id"; false; }
    # Must not touch /etc/iproute2/rt_tables (assert the path does not appear anywhere)
    ! grep -q "rt_tables"  "$CALLS/argv.log" || { echo "rt_tables edited — must not"; false; }
}

# ─── invariant 4: exactly fwmark 0x1 rule, no not-fwmark rule ──────────────
@test "INV4: exactly one fwmark 0x1 ip rule added, no not-fwmark rule" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # At least one add of fwmark 0x1
    grep -q "ip rule add fwmark 0x1" "$CALLS/argv.log" || { echo "fwmark 0x1 rule not added"; cat "$CALLS/argv.log"; false; }
    # No not-fwmark rule (full-tunnel inversion)
    ! grep -q "not fwmark" "$CALLS/argv.log" || { echo "not-fwmark rule found — design inversion"; cat "$CALLS/argv.log"; false; }
}

# ─── invariant 5: masquerade scoped to non-mesh dst ────────────────────────
@test "INV5: masquerade scoped to oifname awg0 ip daddr != 10.9.0.0/24" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q 'daddr != 10.9.0.0/24 masquerade\|daddr != 10\.9\.0\.0/24 masquerade' "$CALLS/nft.stdin.log" || {
        echo "scoped masquerade not found"
        cat "$CALLS/nft.stdin.log"
        false
    }
    # Must NOT appear as unscoped oifname awg0 masquerade on its own line
    ! grep -Eq '^[[:space:]]*oifname "awg0" masquerade' "$CALLS/nft.stdin.log" || {
        echo "unscoped masquerade found"
        cat "$CALLS/nft.stdin.log"
        false
    }
}

# ─── invariant 6: cgroup match in output chain only, no prerouting/forward ──
@test "INV6: cgroupv2 mark only in output chain, no prerouting/forward mangle hook" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q 'socket cgroupv2 level 1 "user.slice"' "$CALLS/nft.stdin.log" || {
        echo "cgroup match not found in nft stdin"
        cat "$CALLS/nft.stdin.log"
        false
    }
    # Our mangle must not add a prerouting hook (that is the full-tunnel pattern)
    ! grep -qE 'hook prerouting.*priority mangle|type filter hook prerouting.*mangle' "$CALLS/nft.stdin.log" || {
        echo "prerouting mangle hook found — must be output-only"
        cat "$CALLS/nft.stdin.log"
        false
    }
    # Must not add a forward hook
    ! grep -q "hook forward" "$CALLS/nft.stdin.log" || {
        echo "forward hook found in nft stdin"
        cat "$CALLS/nft.stdin.log"
        false
    }
}

# ─── invariant 7: wg fwmark set on awg0; endpoint re-derived from conf ──────
@test "INV7: awg fwmark set on awg0; endpoint exemption uses fixture IP from conf" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # wg FwMark set (0xCA6D)
    grep -q "awg set awg0 fwmark" "$CALLS/argv.log" || { echo "awg set fwmark not found"; cat "$CALLS/argv.log"; false; }

    # endpoint exemption route uses the IP parsed from conf (203.0.113.10) — NOT hardcoded
    grep -q "ip route replace 203.0.113.10/32" "$CALLS/argv.log" || {
        echo "endpoint exemption route 203.0.113.10/32 not found"
        cat "$CALLS/argv.log"
        false
    }
}

# ─── invariant 8: dedicated nft tables only, docker ip nat untouched ────────
@test "INV8: only ip mangle and ip split_nat tables created; docker ip nat not deleted" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # Our two tables appear
    grep -q "table ip mangle"    "$CALLS/nft.stdin.log" || { echo "table ip mangle not defined"; cat "$CALLS/nft.stdin.log"; false; }
    grep -q "table ip split_nat" "$CALLS/nft.stdin.log" || { echo "table ip split_nat not defined"; cat "$CALLS/nft.stdin.log"; false; }

    # Must NOT delete docker's ip nat
    ! grep -q "delete table ip nat" "$CALLS/argv.log" || {
        echo "docker's ip nat table was deleted — must not touch it"
        cat "$CALLS/argv.log"
        false
    }
    # Must not reference inet firewalld
    ! grep -q "inet firewalld" "$CALLS/nft.stdin.log" || {
        echo "inet firewalld referenced in nft stdin — must not touch it"
        false
    }
}

# ─── invariant 9: MSS clamp on awg0 SYN ────────────────────────────────────
@test "INV9: MSS clamp tcp option maxseg size set rt mtu on oifname awg0" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q 'tcp option maxseg size set rt mtu' "$CALLS/nft.stdin.log" || {
        echo "MSS clamp not found"
        cat "$CALLS/nft.stdin.log"
        false
    }
    grep -q 'oifname.*awg0.*tcp flags syn\|oifname "awg0" tcp flags syn' "$CALLS/nft.stdin.log" || {
        echo "MSS clamp not scoped to awg0 SYN"
        cat "$CALLS/nft.stdin.log"
        false
    }
}

# ─── invariant 10: AllowedIPs re-asserted LIVE via awg set ──────────────────
@test "INV10: awg set peer allowed-ips 0.0.0.0/0 called to re-assert live" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    grep -q "awg set awg0 peer.*allowed-ips 0.0.0.0/0" "$CALLS/argv.log" || {
        echo "live awg AllowedIPs re-assert not found"
        cat "$CALLS/argv.log"
        false
    }
}

# ─── invariant 11: disable restores state and removes tables/rules ───────────
@test "INV11: disable removes nft tables, ip rules/routes and restores rp_filter" {
    # First apply to set state.
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED before disable test: $output"; false; }

    # Reset call log for disable.
    rm -f "$CALLS/argv.log" "$CALLS/nft.stdin.log"

    _run_disable
    [ "$status" -eq 0 ] || { echo "DISABLE FAILED: $output"; false; }

    # nft delete calls for our two tables
    grep -q "nft delete table ip mangle"    "$CALLS/argv.log" || { echo "mangle not deleted on disable"; cat "$CALLS/argv.log"; false; }
    grep -q "nft delete table ip split_nat" "$CALLS/argv.log" || { echo "split_nat not deleted on disable"; cat "$CALLS/argv.log"; false; }

    # ip rule del for fwmark 0x1 and suppress_prefixlength
    grep -q "ip rule del fwmark 0x1"       "$CALLS/argv.log" || { echo "fwmark rule not removed on disable"; cat "$CALLS/argv.log"; false; }
    grep -q "ip rule del.*suppress_prefixlength" "$CALLS/argv.log" || { echo "suppress rule not removed on disable"; cat "$CALLS/argv.log"; false; }

    # sysctl rp_filter restore (any rp_filter call indicates restore attempt)
    grep -q "sysctl.*rp_filter" "$CALLS/argv.log" || { echo "rp_filter not restored on disable"; cat "$CALLS/argv.log"; false; }
}

# ─── invariant 12: apply is idempotent (del-then-add pattern) ───────────────
@test "INV12: second apply is idempotent — ip rule del precedes each ip rule add" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "FIRST APPLY FAILED: $output"; false; }
    rm -f "$CALLS/argv.log" "$CALLS/nft.stdin.log"

    _run_apply
    [ "$status" -eq 0 ] || { echo "SECOND APPLY FAILED: $output"; false; }

    # ip rule del fwmark must precede ip rule add fwmark (line numbers)
    del_line=$(grep -n "ip rule del fwmark 0x1" "$CALLS/argv.log" | head -1 | cut -d: -f1)
    add_line=$(grep -n "ip rule add fwmark 0x1" "$CALLS/argv.log" | head -1 | cut -d: -f1)
    [[ -n "$del_line" ]] || { echo "ip rule del fwmark not found on second apply"; cat "$CALLS/argv.log"; false; }
    [[ -n "$add_line" ]] || { echo "ip rule add fwmark not found on second apply"; cat "$CALLS/argv.log"; false; }
    [[ "$del_line" -lt "$add_line" ]] || {
        echo "del (line $del_line) must precede add (line $add_line) for idempotency"
        cat "$CALLS/argv.log"
        false
    }
}

# ─── invariant 13: apply errors on missing/empty ru-subnets ─────────────────
@test "INV13: apply exits non-zero with clear error when ru-subnets missing" {
    run bash "$APPLY" \
        --vpn-if awg0 \
        --conf "$AWG_CONF_FIXTURE" \
        --ru-file /nonexistent/ru-subnets.txt \
        --state-dir "$STATE_DIR" \
        --sysctl-persist-dir "$SYSCTL_PERSIST_DIR"
    [ "$status" -ne 0 ] || { echo "Expected non-zero exit for missing RU file"; false; }
    [[ "$output" =~ [Ee][Rr][Rr]|[Mm][Ii][Ss][Ss] ]] || { echo "No error message for missing file: $output"; false; }
}

@test "INV13b: apply exits non-zero with clear error when ru-subnets empty" {
    EMPTY_RU="$TMP/empty-ru.txt"
    true > "$EMPTY_RU"
    run bash "$APPLY" \
        --vpn-if awg0 \
        --conf "$AWG_CONF_FIXTURE" \
        --ru-file "$EMPTY_RU" \
        --state-dir "$STATE_DIR" \
        --sysctl-persist-dir "$SYSCTL_PERSIST_DIR"
    [ "$status" -ne 0 ] || { echo "Expected non-zero exit for empty RU file"; false; }
}

# ─── invariant 14: no kill-switch policy drop, no unbound ───────────────────
@test "INV14: no drop policy, no kill-switch, no unbound references" {
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # No policy drop in any nft table
    ! grep -q "policy drop" "$CALLS/nft.stdin.log" || { echo "policy drop found — no kill-switch allowed"; false; }
    # No unbound
    ! grep -q "unbound" "$CALLS/argv.log" || { echo "unbound found — must not configure DNS"; false; }
    ! grep -q "unbound" "$CALLS/nft.stdin.log" || { echo "unbound in nft — must not configure DNS"; false; }
}
# ─── NEW TEST: reboot-lifecycle ──────────────────────────────────────────────
# BLOCKER fix: STATE_DIR must default to /var/lib/oxpulse-partner-edge (persistent).
# Proof: apply#1 snapshots rp_filter=1 (mock). We simulate post-reboot by
# starting fresh (no state dir deletion needed because the dir IS persistent).
# apply#2 mock returns rp_filter=2 (sysctl.d took effect). Because the guard
# `[[ ! -f STATE_FILE ]]` SKIPS snapshot on second apply, STATE_FILE still has
# the original value from apply#1 → disable restores 1 (not 2).
@test "NEW1: reboot-lifecycle — persistent STATE_DIR retains pristine rp_filter after 2nd apply" {
    # Assert the script default is the persistent path.
    grep -q 'STATE_DIR.*=.*\${STATE_DIR:-/var/lib/oxpulse-partner-edge}' "$APPLY" || {
        echo "BLOCKER: apply script default STATE_DIR is not /var/lib/oxpulse-partner-edge"
        grep 'STATE_DIR.*:-' "$APPLY" || echo "(no STATE_DIR default found)"
        false
    }
    grep -q 'STATE_DIR.*=.*\${STATE_DIR:-/var/lib/oxpulse-partner-edge}' "$DISABLE" || {
        echo "BLOCKER: disable script default STATE_DIR is not /var/lib/oxpulse-partner-edge"
        grep 'STATE_DIR.*:-' "$DISABLE" || echo "(no STATE_DIR default found)"
        false
    }

    # Mock sysctl to return rp_filter=1 on first reads (pristine state before sysctl.d).
    cat >"$TMP/mocks/sysctl" <<'MOCK'
#!/usr/bin/env bash
echo "sysctl $*" >> "$CALLS_DIR/argv.log"
# For snapshot reads (-n), return 1 (strict RPF = pristine value before sysctl.d changes things).
if [[ "$*" == *"-n"* ]]; then
    echo "1"
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/sysctl"

    # Apply#1: snapshot captures rp_filter=1.
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY#1 FAILED: $output"; false; }

    # Verify state file was written with original=1.
    STATE_FILE="$STATE_DIR/oxpulse-split-routing.state"
    [ -f "$STATE_FILE" ] || { echo "STATE_FILE not created: $STATE_FILE"; false; }
    grep -q "SAVED_RP_FILTER_ALL=1" "$STATE_FILE" || {
        echo "STATE_FILE does not record rp_filter=1"
        cat "$STATE_FILE"
        false
    }

    # Now simulate a reboot: sysctl.d applied ip_forward=1 and rp_filter=2.
    # The STATE_FILE survives (persistent dir). Mock now returns 2 for reads.
    cat >"$TMP/mocks/sysctl" <<'MOCK'
#!/usr/bin/env bash
echo "sysctl $*" >> "$CALLS_DIR/argv.log"
# Post-reboot: sysctl.d has set rp_filter=2, ip_forward=1.
if [[ "$*" == *"-n"* ]]; then
    echo "2"
fi
exit 0
MOCK
    chmod +x "$TMP/mocks/sysctl"

    # Reset call log before apply#2.
    rm -f "$CALLS/argv.log"

    # Apply#2: guard [[ ! -f STATE_FILE ]] MUST skip re-snapshot → FILE UNCHANGED.
    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY#2 FAILED: $output"; false; }

    # STATE_FILE must still record the pristine value (1), NOT the post-sysctl.d value (2).
    grep -q "SAVED_RP_FILTER_ALL=1" "$STATE_FILE" || {
        echo "REBOOT LIFECYCLE BUG: STATE_FILE was overwritten on 2nd apply with post-sysctl.d value"
        cat "$STATE_FILE"
        false
    }

    # Disable must restore rp_filter=1 (the pristine value, not 2).
    rm -f "$CALLS/argv.log"
    _run_disable
    [ "$status" -eq 0 ] || { echo "DISABLE FAILED: $output"; false; }

    # Assert disable issued sysctl with =1 (the restored pristine), not =2.
    grep -q "sysctl.*rp_filter=1" "$CALLS/argv.log" || {
        echo "DISABLE did not restore rp_filter=1"
        cat "$CALLS/argv.log"
        false
    }
    ! grep -q "sysctl.*rp_filter=2" "$CALLS/argv.log" || {
        echo "DISABLE incorrectly restored rp_filter=2 (the post-sysctl.d value, not pristine)"
        cat "$CALLS/argv.log"
        false
    }

    # ip_forward must also be saved and restored.
    grep -q "SAVED_IP_FORWARD=" "$STATE_FILE" 2>/dev/null || {
        # Check if disable restored ip_forward (it may have been deleted by now).
        # At minimum, apply must have saved it. Check the restored state from the disable call.
        # Since disable already deleted STATE_FILE, check that disable did restore ip_forward.
        grep -q "sysctl.*ip_forward=" "$CALLS/argv.log" || {
            echo "MAJOR: disable did not restore ip_forward"
            cat "$CALLS/argv.log"
            false
        }
    }
}

# ─── NEW TEST: malformed RU file ─────────────────────────────────────────────
# MAJOR fix: paste -sd, blindly joins comments/blank lines → malformed nft set.
# After fix, grep/filter must strip comments and blanks before building the element.
@test "NEW2: malformed-RU-file — comments and blanks stripped before nft set element" {
    # Fixture with comment, blank, and valid CIDRs.
    MALFORMED_RU="$TMP/malformed-ru.txt"
    printf '# This is a comment\n\n1.2.3.0/24\n4.5.6.0/24\n\n# another comment\n7.8.9.0/24\n' \
        >"$MALFORMED_RU"

    run bash "$APPLY" \
        --vpn-if awg0 \
        --conf "$AWG_CONF_FIXTURE" \
        --ru-file "$MALFORMED_RU" \
        --state-dir "$STATE_DIR" \
        --sysctl-persist-dir "$SYSCTL_PERSIST_DIR"
    [ "$status" -eq 0 ] || { echo "APPLY FAILED with malformed RU: $output"; false; }

    # The nft add element line must contain valid CIDRs only — no '#' or empty tokens.
    grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log" || {
        echo "nft add element not found"
        cat "$CALLS/nft.stdin.log"
        false
    }
    # Must NOT contain '#' anywhere in the element line.
    ! grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log" | grep -q '#' || {
        echo "Comment appeared in nft set element — sanitization broken"
        grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log"
        false
    }
    # Must contain the 3 valid CIDRs.
    grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log" | grep -q "1.2.3.0/24" || {
        echo "Valid CIDR 1.2.3.0/24 missing from nft element"
        grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log"
        false
    }
    grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log" | grep -q "7.8.9.0/24" || {
        echo "Valid CIDR 7.8.9.0/24 missing from nft element"
        grep "add element ip mangle ru_nets" "$CALLS/nft.stdin.log"
        false
    }
}

# ─── NEW TEST: auto-bump table id ─────────────────────────────────────────────
# MAJOR fix: disable must flush the RECORDED table id, not hardcoded 13573.
# This test: mock ip route show table 13573 as occupied → apply bumps to 13574,
# records 13574 in TBL_FILE. Then disable must flush 13574, not 13573.
@test "NEW3: auto-bump — bumped table id recorded in TBL_FILE; disable flushes bumped id" {
    # ip mock: 13573 is occupied, 13574 is empty.
    cat >"$TMP/mocks/ip" <<'MOCK'
#!/usr/bin/env bash
echo "ip $*" >> "$CALLS_DIR/argv.log"
if [[ "$*" == *"route show default"* || "$*" == "-4 route show default"* ]]; then
    echo "default via 10.0.0.1 dev ens3 proto dhcp src 10.0.0.100 metric 100"
fi
if [[ "$*" == *"route show table 13573"* ]]; then
    # Table 13573 is occupied — return a non-empty route to trigger auto-bump.
    echo "someuser via 10.0.0.1 dev ens3"
fi
# 13574 and others: empty (available)
exit 0
MOCK
    chmod +x "$TMP/mocks/ip"

    _run_apply
    [ "$status" -eq 0 ] || { echo "APPLY FAILED: $output"; false; }

    # TBL_FILE must record 13574 (the bumped id).
    TBL_FILE="$STATE_DIR/oxpulse-split-routing.tbl"
    [ -f "$TBL_FILE" ] || { echo "TBL_FILE not created"; false; }
    recorded=$(cat "$TBL_FILE")
    [ "$recorded" = "13574" ] || {
        echo "TBL_FILE records '$recorded' instead of 13574"
        false
    }

    # Disable must flush table 13574 (the bumped id), NOT 13573.
    rm -f "$CALLS/argv.log"
    _run_disable
    [ "$status" -eq 0 ] || { echo "DISABLE FAILED: $output"; false; }

    grep -q "ip route flush table 13574" "$CALLS/argv.log" || {
        echo "DISABLE did not flush the bumped table id 13574"
        cat "$CALLS/argv.log"
        false
    }
    # Must NOT flush 13573 (the wrong/hardcoded id).
    ! grep -q "ip route flush table 13573" "$CALLS/argv.log" || {
        echo "DISABLE flushed hardcoded 13573 instead of the recorded 13574"
        cat "$CALLS/argv.log"
        false
    }
}
