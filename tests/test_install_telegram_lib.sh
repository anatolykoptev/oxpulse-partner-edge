#!/usr/bin/env bash
# Phase 5.8 Task 6 — verify lib/install-systemd.sh installs
# telegram-alert-lib.sh to PREFIX_SBIN.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PREFIX_SBIN="$TMP/sbin"
PREFIX_LIBDIR="$TMP/lib/partner-edge"
mkdir -p "$PREFIX_SBIN" "$PREFIX_LIBDIR"

src_dir="$REPO_ROOT"
REPO_RAW="https://example.invalid"   # never reached if local file present
export PREFIX_SBIN PREFIX_LIBDIR src_dir REPO_RAW

# Shim install: forward real installs to temp dirs, swallow system-dir attempts
mkdir -p "$TMP/shims"
cat > "$TMP/shims/install" <<'STUB'
#!/usr/bin/env bash
mode=""
is_dir=0
args=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m) mode="$2"; shift 2 ;;
        -d) is_dir=1; shift ;;
        *)  args+=("$1"); shift ;;
    esac
done
if [[ $is_dir -eq 1 ]]; then
    # Silently succeed for absolute system paths that need root
    for d in "${args[@]}"; do
        [[ "$d" == /usr/* ]] && continue
        mkdir -p "$d"
    done
    exit 0
fi
n=${#args[@]}
src="${args[$((n-2))]}"
dst="${args[$((n-1))]}"
# Silently skip system path writes (need root)
if [[ "$dst" == /usr/* ]]; then
    exit 0
fi
mkdir -p "$(dirname "$dst")"
cp "$src" "$dst" 2>/dev/null || touch "$dst"
[[ -n "$mode" ]] && chmod "$mode" "$dst"
exit 0
STUB
chmod +x "$TMP/shims/install"

# Poison curl: should never be called for telegram-alert-lib.sh
cat > "$TMP/shims/curl" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [[ "$arg" == *"telegram-alert-lib.sh" ]]; then
        echo "POISON: curl called for telegram-alert-lib.sh — local fallback not used" >&2
        exit 77
    fi
done
dst=""
while [[ $# -gt 0 ]]; do
    [[ "$1" == "-o" ]] && { dst="$2"; shift 2; } || shift
done
[[ -n "$dst" ]] && touch "$dst" || true
exit 0
STUB
chmod +x "$TMP/shims/curl"

cat > "$TMP/shims/chmod" <<'STUB'
#!/usr/bin/env bash
# Delegate to real chmod — only skip for system paths needing root
for arg in "$@"; do
    if [[ "$arg" == /usr/* || "$arg" == /etc/* ]]; then
        exit 0
    fi
done
exec /bin/chmod "$@"
STUB
chmod +x "$TMP/shims/chmod"

# Run in subprocess with shimmed PATH
set +e
out=$(env PATH="$TMP/shims:/usr/bin:/bin" bash -c "
    set -euo pipefail
    src_dir='$REPO_ROOT'
    REPO_RAW='https://example.invalid'
    PREFIX_SBIN='$PREFIX_SBIN'
    PREFIX_LIBDIR='$PREFIX_LIBDIR'
    log()  { echo \"log: \$*\"; }
    warn() { echo \"warn: \$*\"; }
    die()  { echo \"die: \$*\" >&2; exit 1; }
    source '$REPO_ROOT/lib/install-systemd.sh'
    _systemd_install_lib_scripts
" 2>&1)
rc=$?
set -e

if [[ $rc -ne 0 ]]; then
    echo "FAIL: _systemd_install_lib_scripts exited $rc"
    echo "$out"
    exit 1
fi

if [[ ! -f "$PREFIX_SBIN/telegram-alert-lib.sh" ]]; then
    echo "FAIL: telegram-alert-lib.sh NOT installed to $PREFIX_SBIN"
    ls "$PREFIX_SBIN"
    exit 1
fi
if [[ ! -x "$PREFIX_SBIN/telegram-alert-lib.sh" ]]; then
    echo "FAIL: telegram-alert-lib.sh installed but not executable"
    ls -la "$PREFIX_SBIN/telegram-alert-lib.sh"
    exit 1
fi

# Verify content matches source
if ! diff -q "$REPO_ROOT/lib/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh" >/dev/null; then
    echo "FAIL: installed content differs from src"
    diff "$REPO_ROOT/lib/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh" | head
    exit 1
fi

echo "OK: telegram-alert-lib.sh installed to PREFIX_SBIN with correct content + perms"
