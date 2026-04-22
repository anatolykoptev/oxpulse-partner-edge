#!/usr/bin/env bash
# bootstrap.sh — one-command partner-edge installer.
#
# Downloads the release tarball from GitHub, verifies SHA256, and runs the
# real install.sh with your arguments. This is the file published as
# `partner-edge-installer.sh` on every partner-edge-v* release.
#
# Usage (latest release):
#   curl -fsSL https://github.com/anatolykoptev/oxpulse-partner-edge/releases/latest/download/partner-edge-installer.sh \
#     | sudo bash -s -- --domain=<your-domain> --partner-id=<id> --token=<bootstrap-token>
#
# Pin a specific version:
#   VERSION=0.2.0 curl -fsSL ... | sudo bash -s -- ...
#
# Override repository (for forks):
#   OXPULSE_REPO=myorg/myfork curl -fsSL ... | sudo bash ...
set -euo pipefail

REPO="${OXPULSE_REPO:-anatolykoptev/oxpulse-partner-edge}"
VERSION="${VERSION:-}"

log()  { printf '\033[32m==>\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERR\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "must run as root (sudo bash)"

for cmd in curl tar sha256sum; do
	command -v "$cmd" >/dev/null 2>&1 || die "missing required tool: $cmd"
done

if [[ -z "$VERSION" ]]; then
	log "resolving latest partner-edge release from github.com/$REPO"
	VERSION=$(curl -fsSL --proto '=https' --tlsv1.2 \
		"https://api.github.com/repos/${REPO}/releases" \
		| grep -oE '"tag_name":[[:space:]]*"partner-edge-v[0-9]+\.[0-9]+\.[0-9]+"' \
		| head -1 \
		| sed -E 's/.*"partner-edge-v([0-9.]+)".*/\1/')
	[[ -n "$VERSION" ]] || die "no partner-edge-v* releases found in $REPO"
fi
log "partner-edge v$VERSION"

TAG="partner-edge-v${VERSION}"
BASE="https://github.com/${REPO}/releases/download/${TAG}"
ASSET="partner-edge-${VERSION}.tar.gz"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

log "downloading ${ASSET}"
curl -fsSL --proto '=https' --tlsv1.2 "${BASE}/${ASSET}"     -o "$WORK/bundle.tar.gz"
curl -fsSL --proto '=https' --tlsv1.2 "${BASE}/SHA256SUMS"   -o "$WORK/SHA256SUMS"

log "verifying SHA256"
(cd "$WORK" && grep -F " ${ASSET}" SHA256SUMS \
	| awk -v f=bundle.tar.gz '{print $1"  "f}' \
	| sha256sum -c -) >/dev/null \
	|| die "SHA256 mismatch — aborting"

log "extracting"
tar -xzf "$WORK/bundle.tar.gz" -C "$WORK"
BUNDLE_DIR="$WORK/partner-edge-${VERSION}"
[[ -d "$BUNDLE_DIR" && -x "$BUNDLE_DIR/install.sh" ]] \
	|| die "unexpected archive layout (no install.sh at $BUNDLE_DIR)"

log "running install.sh $*"
exec bash "$BUNDLE_DIR/install.sh" "$@"
