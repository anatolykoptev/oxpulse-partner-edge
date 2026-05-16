#!/usr/bin/env bash
# scripts/migrate-bak-to-confd.sh — migrate Caddyfile.bak.* operator edits to conf.d/
#
# Usage:
#   sudo bash scripts/migrate-bak-to-confd.sh [/path/to/Caddyfile.bak.*]
#
# If no path given, auto-detects the most recent .bak.* file in
# /etc/oxpulse-partner-edge/.
#
# What it does:
#   1. Locates the operator-added section in the .bak file (content after the
#      last auto-generated block: the canary vhost or the TURNS stub).
#   2. Writes extracted content to /etc/oxpulse-partner-edge/conf.d/migrated-<epoch>.caddy
#   3. Renames the source .bak file to .bak.migrated (idempotent sentinel).
#
# Safety:
#   - Dry-run by default; pass --apply to write files.
#   - Never touches files already ending in .migrated.
#   - Output file is written atomically (tmp + mv).
#   - Idempotent: if output file already exists, exits 0 with a note.
#
# Sentinel logic:
#   The auto-generated Caddyfile ends with the canary vhost block (http://127.0.0.1:9080)
#   followed by its closing brace. Operator additions appear after that. If the
#   canary block is absent (pre-Phase-1 .bak), falls back to the TURNS stub
#   (the block for {{TURNS_SUBDOMAIN}}.{{PARTNER_DOMAIN}} or the rendered equivalent).
#   Always review the output before committing conf.d/ to operator config.
set -euo pipefail

PREFIX_ETC="${PREFIX_ETC:-/etc/oxpulse-partner-edge}"
CONFD_DIR="$PREFIX_ETC/conf.d"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
warn() { printf '\033[33m!!\033[0m  %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

APPLY=0
BAK_FILE=""

for arg in "$@"; do
    case "$arg" in
        --apply) APPLY=1 ;;
        --*) die "unknown flag: $arg" ;;
        *) BAK_FILE="$arg" ;;
    esac
done

# Auto-detect most recent .bak file if none given
if [[ -z "$BAK_FILE" ]]; then
    BAK_FILE=$(find "$PREFIX_ETC" -maxdepth 1 -name "Caddyfile.bak.*" \
        ! -name "*.migrated" -printf "%T@ %p\n" 2>/dev/null \
        | sort -rn | head -1 | awk '{print $2}') || true
    [[ -n "$BAK_FILE" ]] || die "no Caddyfile.bak.* file found in $PREFIX_ETC (and none given)"
fi

[[ -f "$BAK_FILE" ]] || die "file not found: $BAK_FILE"
[[ "$BAK_FILE" == *.migrated ]] && die "$BAK_FILE already migrated (ends in .migrated)"

log "source: $BAK_FILE"

# Extract operator section: everything after the canary closing brace (last line matching
# just "}" that ends the http://127.0.0.1:9080 block), or after the TURNS stub block.
# Strategy: scan for a comment sentinel or the last top-level closing brace that is
# followed by non-empty content. We use awk to track brace depth at column-0 level.
#
# The canary block starts with "http://127.0.0.1:9080 {" — we find its closing "}" and
# take everything after. If that yields nothing, try after the last "}" at brace-depth=0.

_extract_operator_section() {
    local src="$1"
    awk '
    BEGIN {
        found_canary = 0
        in_canary = 0
        depth = 0
        canary_end_line = 0
        last_toplevel_close = 0
        line_num = 0
    }
    {
        line_num++
        # Detect canary block start
        if (/^http:\/\/127\.0\.0\.1:9080[[:space:]]*\{/) {
            in_canary = 1
            depth = 1
            next
        }
        if (in_canary) {
            # Track brace depth
            n = split($0, a, "")
            for (i = 1; i <= n; i++) {
                if (a[i] == "{") depth++
                if (a[i] == "}") depth--
            }
            if (depth == 0) {
                found_canary = 1
                canary_end_line = line_num
                in_canary = 0
            }
            next
        }
        # Track top-level closing braces for fallback
        if (/^\}[[:space:]]*$/ && depth == 0) {
            last_toplevel_close = line_num
        }
        # When past canary, collect remaining lines
        if (found_canary) {
            print
        }
    }
    END {
        if (!found_canary) {
            # Fallback: print nothing (caller will handle)
            exit 1
        }
    }
    ' "$src"
}

_extract_fallback() {
    # Fallback: everything after the last top-level closing brace
    local src="$1"
    awk '
    BEGIN { depth = 0; lines[0]="" }
    {
        # Track brace depth (simplified — only counts { and } chars)
        n = split($0, a, "")
        prev_depth = depth
        for (i = 1; i <= n; i++) {
            if (a[i] == "{") depth++
            if (a[i] == "}") depth--
        }
        if (prev_depth > 0 && depth == 0) {
            # Just closed a top-level block
            delete collected
            collected_n = 0
        } else if (depth == 0) {
            collected[++collected_n] = $0
        }
    }
    END {
        for (i = 1; i <= collected_n; i++) {
            if (collected[i] ~ /[^[:space:]]/) {
                print collected[i]
            }
        }
    }
    ' "$src"
}

# Try canary-sentinel extraction first
EXTRACTED=""
if EXTRACTED=$(_extract_operator_section "$BAK_FILE" 2>/dev/null); then
    # Strip leading blank lines
    EXTRACTED=$(printf '%s' "$EXTRACTED" | sed '/./,$!d')
    EXTRACTION_METHOD="post-canary"
else
    warn "canary block not found in $BAK_FILE — trying fallback (post-last-block)"
    EXTRACTED=$(_extract_fallback "$BAK_FILE" 2>/dev/null || true)
    EXTRACTED=$(printf '%s' "$EXTRACTED" | sed '/./,$!d')
    EXTRACTION_METHOD="fallback"
fi

if [[ -z "$EXTRACTED" ]]; then
    warn "no operator content found after auto-generated blocks in $BAK_FILE"
    warn "the .bak file may be a pure auto-generated snapshot with no operator edits"
    warn "review the file manually: less $BAK_FILE"
    exit 0
fi

EPOCH=$(date +%s)
OUT_FILENAME="migrated-${EPOCH}.caddy"
OUT_PATH="$CONFD_DIR/$OUT_FILENAME"

log "extraction method: $EXTRACTION_METHOD"
log "extracted lines: $(echo "$EXTRACTED" | wc -l)"
log ""
log "--- extracted content ---"
printf '%s\n' "$EXTRACTED" >&2
log "--- end ---"
log ""

if [[ $APPLY -eq 0 ]]; then
    warn "[DRY-RUN] would write to: $OUT_PATH"
    warn "[DRY-RUN] would rename:   $BAK_FILE → ${BAK_FILE}.migrated"
    warn "[DRY-RUN] run with --apply to commit"
    exit 0
fi

[[ -d "$CONFD_DIR" ]] || die "conf.d/ not found: $CONFD_DIR (run install.sh first)"

# Idempotency: if any migrated-*.caddy already exists, warn and exit 0
if compgen -G "$CONFD_DIR/migrated-*.caddy" >/dev/null 2>&1; then
    warn "migrated-*.caddy already exists in $CONFD_DIR — skipping (idempotent)"
    warn "to re-migrate, remove existing migrated-*.caddy files first"
    exit 0
fi

# Atomic write
TMP_OUT="$CONFD_DIR/.${OUT_FILENAME}.tmp.$$"
printf '%s\n' "$EXTRACTED" > "$TMP_OUT"
mv -f "$TMP_OUT" "$OUT_PATH"
chmod 0644 "$OUT_PATH"

# Rename .bak to .bak.migrated
mv -f "$BAK_FILE" "${BAK_FILE}.migrated"

log "written: $OUT_PATH"
log "renamed: $BAK_FILE → ${BAK_FILE}.migrated"
log "done — review $OUT_PATH before relying on it in production"
