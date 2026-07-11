#!/usr/bin/env bats
# tests/test_ru_subnets_update.sh — bats coverage for oxpulse-partner-edge-ru-subnets-update
#
# Strategy: PATH-shim curl / python3 / systemctl as argv recorders.
# All filesystem paths overridden via env to avoid root.
#
# Invariants tested:
#   RU1  RIPE source tried first; aggregation runs; file written on success
#   RU2  ipdeny fallback when RIPE fails
#   RU3  MIN_ENTRIES guard aborts + keeps last-good file on too-few entries
#   RU4  Atomic mv: tmp in target dir; mv only on success; no leftover tmp files
#   RU5  chmod 644 applied after mv
#   RU6  try-restart called after successful update
#   RU7  try-restart failure is soft (unit absent — exit 0 overall)
#   RU8  Both sources fail; last-good file preserved; exit non-zero
#   RU9  Both sources fail with no last-good file; exit non-zero
#   RU10 Hardened curl flags (--proto --tlsv1.2 --max-time)
#   RU11 No relay-x-specific seed CIDRs hardcoded in script
#   RU12 Default OUTFILE is /etc/oxpulse-partner-edge/ru-subnets.txt (not relay-x path)
#
# Canon §1: the operator's internal split-routing settings canon (2026-05-27)
# Compat: bats < 1.5 — no bats_require_minimum_version, no 'run !'

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    SCRIPT="$REPO_ROOT/oxpulse-partner-edge-ru-subnets-update"
    TMP="$(mktemp -d)"
    CALLS="$TMP/calls.log"
    touch "$CALLS"

    mkdir -p "$TMP/bin"

    # Target dir (replaces /etc/oxpulse-partner-edge)
    TARGET_DIR="$TMP/etc-oxpulse"
    mkdir -p "$TARGET_DIR"
    OUTFILE="$TARGET_DIR/ru-subnets.txt"

    # RIPE fixture: pipe-delimited stats format (ripencc|RU|ipv4|ip|count|date|type)
    # 1100 entries; count=256 → /24; awk in script will convert to CIDRs
    FIXTURE_RIPE="$TMP/ripe-fixture.txt"
    python3 -c "
for i in range(1100):
    a = 100 + (i % 100)
    b = i // 100
    c = (i * 7) % 256
    print(f'ripencc|RU|ipv4|{a}.{b}.{c}.0|256|20230101|allocated')
" > "$FIXTURE_RIPE"

    # ipdeny fixture: plain CIDR lines (ipdeny.com format)
    FIXTURE_IPDENY="$TMP/ipdeny-fixture.txt"
    python3 -c "
for i in range(1100):
    a = 100 + (i % 100)
    b = i // 100
    c = (i * 7) % 256
    print(f'{a}.{b}.{c}.0/24')
" > "$FIXTURE_IPDENY"

    # Small RIPE fixture (only 5 entries — below MIN_ENTRIES=1000)
    FIXTURE_SMALL="$TMP/small-ripe-fixture.txt"
    python3 -c "
for i in range(5):
    print(f'ripencc|RU|ipv4|10.{i}.0.0|256|20230101|allocated')
" > "$FIXTURE_SMALL"

    # python3 shim — records call, pipes stdin through real python3 for aggregation
    cat > "$TMP/bin/python3" << 'STUB'
#!/usr/bin/env bash
echo "python3 $*" >> "$CALLS_FILE"
exec /usr/bin/python3 "$@"
STUB
    chmod +x "$TMP/bin/python3"

    # systemctl shim — records calls; try-restart exits 0 by default
    cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_FILE"
exit 0
STUB
    chmod +x "$TMP/bin/systemctl"

    export CALLS_FILE="$CALLS"
    export PATH="$TMP/bin:$PATH"
}

teardown() {
    rm -rf "$TMP"
}

# ─── RU1: RIPE-first happy path ──────────────────────────────────────────────

@test "RU1: RIPE source tried first, aggregation runs, file written on success" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
# ipdeny fallback — should NOT be reached
echo "ipdeny called unexpectedly" >&2
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    # RIPE URL was tried
    grep -q "ripe.net" "$CALLS"

    # python3 collapse_addresses was invoked
    grep -q "python3" "$CALLS"

    # Output file written and non-empty
    [ -f "$OUTFILE" ]
    [ -s "$OUTFILE" ]
}

# ─── RU2: ipdeny fallback ────────────────────────────────────────────────────

@test "RU2: ipdeny fallback when RIPE fails" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    exit 1
fi
if echo "$*" | grep -q "ipdeny"; then
    cat "$IPDENY_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        IPDENY_FIXTURE="$FIXTURE_IPDENY" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    # ipdeny URL was tried
    grep -q "ipdeny" "$CALLS"

    # Output file written
    [ -f "$OUTFILE" ]
    [ -s "$OUTFILE" ]
}

# ─── RU3: MIN_ENTRIES guard ──────────────────────────────────────────────────

@test "RU3: MIN_ENTRIES guard aborts and keeps last-good file when entry count too low" {
    printf '1.2.3.0/24\n4.5.6.0/24\n' > "$OUTFILE"
    LAST_GOOD_CONTENT=$(cat "$OUTFILE")

    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$SMALL_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    # Use real MIN_ENTRIES=1000 to trigger guard on 5-entry fixture
    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        SMALL_FIXTURE="$FIXTURE_SMALL" \
        PATH="$TMP/bin:$PATH" \
        bash "$SCRIPT"

    # Script must exit non-zero (guard tripped)
    [ "$status" -ne 0 ] || { echo "Expected non-zero exit from MIN_ENTRIES guard"; false; }

    # Last-good file must be PRESERVED
    [ -f "$OUTFILE" ]
    NEW_CONTENT=$(cat "$OUTFILE")
    [ "$LAST_GOOD_CONTENT" = "$NEW_CONTENT" ] || {
        echo "Last-good file was overwritten despite guard"
        echo "Expected: $LAST_GOOD_CONTENT"
        echo "Got: $NEW_CONTENT"
        false
    }
}

# ─── RU4: atomic mv in target dir; no leftover tmp ──────────────────────────

@test "RU4: atomic mv uses tmp file in target dir; no leftover tmp files after success" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    # No leftover tmp files in target dir
    leftover=$(find "$TARGET_DIR" \( -name '*.tmp*' -o -name '.*.tmp*' \) 2>/dev/null | wc -l)
    [ "$leftover" -eq 0 ] || {
        echo "Leftover tmp files found: $(find "$TARGET_DIR" -name '*.tmp*' -o -name '.*.tmp*')"
        false
    }

    [ -f "$OUTFILE" ]
}

# ─── RU5: chmod 644 ──────────────────────────────────────────────────────────

@test "RU5: output file has mode 0644 after successful update" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    perms=$(stat -c '%a' "$OUTFILE" 2>/dev/null || stat -f '%OLp' "$OUTFILE" 2>/dev/null)
    [ "$perms" = "644" ] || { echo "Expected mode 644, got $perms"; false; }
}

# ─── RU6: try-restart after success ─────────────────────────────────────────

@test "RU6: systemctl try-restart split-routing service called after success" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    grep -q "systemctl try-restart oxpulse-partner-edge-split-routing.service" "$CALLS" || {
        echo "try-restart not called"
        cat "$CALLS"
        false
    }
}

# ─── RU7: try-restart failure is soft ───────────────────────────────────────

@test "RU7: script succeeds even when try-restart returns non-zero (unit absent)" {
    # systemctl shim that always fails
    cat > "$TMP/bin/systemctl" << 'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS_FILE"
exit 5
STUB
    chmod +x "$TMP/bin/systemctl"

    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "Script must succeed even when try-restart fails: $output"; false; }
}

# ─── RU8: both sources fail; last-good preserved ────────────────────────────

@test "RU8: both sources fail; last-good file preserved; exit non-zero" {
    printf '10.0.0.0/24\n192.168.0.0/24\n' > "$OUTFILE"
    LAST_GOOD=$(cat "$OUTFILE")

    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        PATH="$TMP/bin:$PATH" \
        bash "$SCRIPT"

    [ "$status" -ne 0 ] || { echo "Expected non-zero exit when both sources fail"; false; }

    [ -f "$OUTFILE" ] || { echo "Last-good file was deleted"; false; }
    [ "$(cat "$OUTFILE")" = "$LAST_GOOD" ] || { echo "Last-good file content changed"; false; }
}

# ─── RU9: both sources fail; no last-good ───────────────────────────────────

@test "RU9: both sources fail with no last-good file; exit non-zero" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        PATH="$TMP/bin:$PATH" \
        bash "$SCRIPT"

    [ "$status" -ne 0 ] || { echo "Expected non-zero exit when no last-good + both sources fail"; false; }
}

# ─── RU10: hardened curl flags ───────────────────────────────────────────────

@test "RU10: curl invoked with --proto =https --tlsv1.2 --max-time flags" {
    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RIPE_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RIPE_FIXTURE="$FIXTURE_RIPE" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=10 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    grep "ripe.net" "$CALLS" | grep -q -- "--proto" || {
        echo "Missing --proto flag"
        grep "ripe.net" "$CALLS"
        false
    }
    grep "ripe.net" "$CALLS" | grep -q -- "--tlsv1.2" || {
        echo "Missing --tlsv1.2 flag"
        grep "ripe.net" "$CALLS"
        false
    }
    grep "ripe.net" "$CALLS" | grep -q -- "--max-time" || {
        echo "Missing --max-time flag"
        grep "ripe.net" "$CALLS"
        false
    }
}

# ─── RU11: no relay-x seed CIDRs ───────────────────────────────────────────────

@test "RU11: no relay-x-specific seed CIDRs hardcoded in script (feed-only)" {
    run grep -E '77\.88\.8|81\.90\.180|82\.202\.224|95\.142\.192|87\.240\.128|94\.100\.176' "$SCRIPT"
    [ "$status" -ne 0 ] || {
        echo "Relay-x seed CIDRs found — must be removed"
        echo "$output"
        false
    }
}

# ─── RU12: default OUTFILE path ──────────────────────────────────────────────

@test "RU12: default OUTFILE is /etc/oxpulse-partner-edge/ru-subnets.txt (not relay-x path)" {
    run grep -E 'OUTFILE.*:-' "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "OUTFILE default not found"; false; }
    echo "$output" | grep -q "oxpulse-partner-edge" || {
        echo "OUTFILE default missing oxpulse-partner-edge path"
        echo "$output"
        false
    }
    # Must NOT have old relay-x path
    run grep -E 'OUTFILE.*:-.*(/etc/ru-subnets|relay-x)' "$SCRIPT"
    [ "$status" -ne 0 ] || {
        echo "Relay-x path in OUTFILE default"
        echo "$output"
        false
    }
}

# ─── RU13: RIPE non-power-of-2 count: exact range decomposition ──────────────
#
# Regression for the MAJOR finding in CL-3 review:
# The old awk `while(n>1){n/=2;bits++}; cidr=32-bits` assumes count is a power of 2.
# For a non-power-of-2 count AND a non-zero-aligned start (e.g. 10.0.0.128, count=768):
#   - awk emits 10.0.0.128/22 → python ip_network(strict=False) zeros host bits → 10.0.0.0/22
#   - 10.0.0.0/22 covers 1024 addresses, over-covering by 256 relative to the range
#     [10.0.0.128, 10.0.3.127]. Sends NON-RU traffic un-tunneled into ТСПУ.
# The fix: awk emits RANGE lines; python3 uses summarize_address_range to produce the
# exact minimal aligned CIDR set covering [start, start+count-1] with no over-cover.
#
# Expected CIDRs for 10.0.0.128+768: 10.0.0.128/25 + 10.0.1.0/24 + 10.0.2.0/24 + 10.0.3.0/25
# Total = 768 addresses, all within [10.0.0.128, 10.0.3.127].
@test "RU13: RIPE non-power-of-2 count decomposes to exact range; no over-cover outside [start,start+count-1]" {
    # Single RIPE row: non-power-of-2 count + non-zero-aligned start.
    # count=768 is not a power of 2; 10.0.0.128 is not aligned to /22.
    FIXTURE_RU13="$TMP/ripe-ru13.txt"
    printf 'ripencc|RU|ipv4|10.0.0.128|768|20230101|allocated\n' > "$FIXTURE_RU13"

    cat > "$TMP/bin/curl" << 'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CALLS_FILE"
if echo "$*" | grep -q "ripe.net"; then
    cat "$RU13_FIXTURE"
    exit 0
fi
exit 1
STUB
    chmod +x "$TMP/bin/curl"

    run env \
        CALLS_FILE="$CALLS" OUTFILE="$OUTFILE" \
        RU13_FIXTURE="$FIXTURE_RU13" \
        PATH="$TMP/bin:$PATH" MIN_ENTRIES=1 \
        bash "$SCRIPT"
    [ "$status" -eq 0 ] || { echo "SCRIPT FAILED: $output"; false; }

    [ -f "$OUTFILE" ] || { echo "OUTFILE not written"; false; }

    # Count total addresses covered by all output CIDRs
    total=$(python3 -c "
import ipaddress, sys
total = 0
for line in open('$OUTFILE'):
    line = line.strip()
    if line:
        total += ipaddress.ip_network(line, strict=True).num_addresses
print(total)
")
    # Must cover EXACTLY 768 addresses (the range), not 1024 (power-of-2 over-cover)
    [ "$total" -eq 768 ] || {
        echo "FAIL: expected 768 addresses covered, got $total"
        echo "Output CIDRs:"
        cat "$OUTFILE"
        false
    }

    # No emitted CIDR may contain an address outside [10.0.0.128, 10.0.3.127]
    outside=$(python3 -c "
import ipaddress, sys
start = int(ipaddress.ip_address('10.0.0.128'))
end   = int(ipaddress.ip_address('10.0.3.127'))
bad = 0
for line in open('$OUTFILE'):
    line = line.strip()
    if not line:
        continue
    net = ipaddress.ip_network(line, strict=True)
    if int(net.network_address) < start or int(net.broadcast_address) > end:
        bad += 1
        print(f'OVER-COVER: {net} extends outside [{\"10.0.0.128\"}, {\"10.0.3.127\"}]', file=sys.stderr)
print(bad)
" 2>&1)
    [ "$outside" = "0" ] || {
        echo "FAIL: some CIDRs extend outside the expected range"
        echo "$outside"
        echo "Output CIDRs:"
        cat "$OUTFILE"
        false
    }
}
