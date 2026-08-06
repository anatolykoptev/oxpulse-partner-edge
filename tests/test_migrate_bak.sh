#!/bin/bash
# tests/test_migrate_bak.sh
# Tests scripts/migrate-bak-to-confd.sh with a edge-a-like .bak file.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MIGRATE="$REPO_ROOT/scripts/migrate-bak-to-confd.sh"

[[ -f "$MIGRATE" ]] || { echo "FAIL: migrate-bak-to-confd.sh not found"; exit 1; }
bash -n "$MIGRATE" || { echo "FAIL: migrate script syntax errors"; exit 1; }
echo "OK: syntax clean"

TMPDIR_ROOT=$(mktemp -d)
T_ETC="$TMPDIR_ROOT/etc"
T_CONFD="$T_ETC/conf.d"
mkdir -p "$T_ETC" "$T_CONFD"
trap 'rm -rf "$TMPDIR_ROOT"' EXIT

BAK_FILE="$T_ETC/Caddyfile.bak.pre-edge-a-20260508"
cat > "$BAK_FILE" << 'BAKEOF'
# Rendered by install.sh

{
    admin localhost:2019 {
        origins localhost 127.0.0.1 localhost:2019 127.0.0.1:2019
    }
    email admin@edge-a.example
    servers {
        protocols h1 h2
        listener_wrappers {
            layer4 {
                @turns tls sni turns.edge-a.example
                route @turns {
                    proxy tcp/host.docker.internal:5349
                }
            }
            tls
        }
    }
    log { format json; level INFO }
}

edge-a.example {
    encode gzip zstd
    handle /relay/* { reverse_proxy host.docker.internal:8912 }
    handle { import tunnel_upstream_default }
}

turns.edge-a.example {
    tls { issuer acme { disable_tlsalpn_challenge } }
    respond 421
}

# =============================================================================
# Phase 1 canary site -- 127.0.0.1:9080 ONLY
# =============================================================================
http://127.0.0.1:9080 {
    handle /canary/tunnel {
        reverse_proxy xray-client:3080/health {
            transport http { dial_timeout 2s; response_header_timeout 2s }
        }
    }
    handle /canary/config-hash { respond "abc123" 200 }
    handle /canary/route-table { respond `{"routes":["tunnel"]}` 200 }
}

# Operator additions
edge-a.example.ru {
    root * /srv/edge-a-static
    file_server
    encode gzip
}

www.edge-a.example {
    redir https://edge-a.example{uri} permanent
}
BAKEOF

echo "==> Test 1: dry-run — output shown, no files written"
DRY_OUT=$(PREFIX_ETC="$T_ETC" bash "$MIGRATE" "$BAK_FILE" 2>&1 || true)
echo "$DRY_OUT" | grep -i "edge-a" >/dev/null \
    || { echo "FAIL: no edge-a content in dry-run output"; echo "$DRY_OUT"; exit 1; }
echo "$DRY_OUT" | grep -i "dry.run" >/dev/null \
    || { echo "FAIL: dry-run notice missing"; echo "$DRY_OUT"; exit 1; }
CADDY_FILES=$(find "$T_CONFD" -name "*.caddy" 2>/dev/null | wc -l)
[[ "$CADDY_FILES" -eq 0 ]] \
    || { echo "FAIL: files written in dry-run mode ($CADDY_FILES found)"; exit 1; }
echo "OK: dry-run shows content, no files written"

echo "==> Test 2: --apply writes migrated-*.caddy and renames .bak"
PREFIX_ETC="$T_ETC" bash "$MIGRATE" "$BAK_FILE" --apply >/dev/null 2>&1
MIGRATED_FILE=$(find "$T_CONFD" -name "migrated-*.caddy" 2>/dev/null | head -1)
[[ -n "$MIGRATED_FILE" ]] || { echo "FAIL: no migrated-*.caddy created"; exit 1; }
echo "OK: migrated file: $MIGRATED_FILE"

grep -q "edge-a.example.ru" "$MIGRATED_FILE" \
    || { echo "FAIL: edge-a.example.ru missing from extracted content"; cat "$MIGRATED_FILE"; exit 1; }
grep -q "www.edge-a.example" "$MIGRATED_FILE" \
    || { echo "FAIL: www.edge-a.example missing from extracted content"; cat "$MIGRATED_FILE"; exit 1; }
echo "OK: extracted content has operator vhosts"

if grep -q "turns.edge-a.example" "$MIGRATED_FILE"; then
    echo "FAIL: auto-generated turns vhost leaked into extracted content"
    cat "$MIGRATED_FILE"
    exit 1
fi
echo "OK: auto-generated blocks not in extracted content"

[[ ! -f "$BAK_FILE" ]] || { echo "FAIL: original .bak still exists"; exit 1; }
[[ -f "${BAK_FILE}.migrated" ]] || { echo "FAIL: .bak.migrated not created"; exit 1; }
echo "OK: .bak renamed to .bak.migrated"

echo "==> Test 3: idempotent — second --apply skips"
cp "${BAK_FILE}.migrated" "$BAK_FILE"
BEFORE_COUNT=$(find "$T_CONFD" -name "migrated-*.caddy" | wc -l)
IDEM_OUT=$(PREFIX_ETC="$T_ETC" bash "$MIGRATE" "$BAK_FILE" --apply 2>&1 || true)
AFTER_COUNT=$(find "$T_CONFD" -name "migrated-*.caddy" | wc -l)
[[ "$AFTER_COUNT" -eq "$BEFORE_COUNT" ]] \
    || { echo "FAIL: second --apply created new files (before=$BEFORE_COUNT after=$AFTER_COUNT)"; exit 1; }
echo "$IDEM_OUT" | grep -i "skip\|already\|idempotent" >/dev/null \
    || { echo "FAIL: idempotency message missing"; echo "$IDEM_OUT"; exit 1; }
echo "OK: idempotent (count=$AFTER_COUNT, message OK)"

echo "==> Test 4: .bak.migrated input → dies with error"
ALREADY_OUT=$(PREFIX_ETC="$T_ETC" bash "$MIGRATE" "${BAK_FILE}.migrated" 2>&1 || true)
echo "$ALREADY_OUT" | grep -i "migrated" >/dev/null \
    || { echo "FAIL: .bak.migrated input did not mention 'migrated' in output"; echo "$ALREADY_OUT"; exit 1; }
echo "OK: .bak.migrated input produces error/warning"

echo ""
echo "PASS: all test_migrate_bak tests passed"
