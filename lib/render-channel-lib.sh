#!/usr/bin/env bash
# lib/render-channel-lib.sh — Phase 5.5 MAJOR 1: shared fail-soft channel render helpers.
#
# Extracted from install.sh so that hydrate.sh, update.sh, and
# oxpulse-partner-edge-refresh.sh can share the same render_channel_soft
# semantics and compose-strip post-processor.
#
# No shebang execution — this file is only ever sourced, never run directly.
#
# Exports:
#   _in_array()                       — array membership test
#   CHANNELS_FAILED                   — global accumulator (declared on source)
#   render_channel_soft()             — fail-soft opec render wrapper
#   compose_strip_failed_channels()   — remove failed-channel service blocks from compose YAML
#
# Requires (caller globals):
#   PREFIX_LIB   path, e.g. /var/lib/oxpulse-partner-edge (for secure tmp dir)
#   log()        function — informational output
#   warn()       function — warning output
#   die()        function — fatal error + exit (only called on hard failure)

# Defensive fallbacks: callers that already define log/warn/die keep their
# styling; other consumers get a working implementation.
command -v log  >/dev/null 2>&1 || log()  { printf '%s\n' "$*" >&2; }
command -v warn >/dev/null 2>&1 || warn() { log "WARN: $*"; }
command -v die  >/dev/null 2>&1 || die()  { log "ERR: $*"; exit 1; }

# Returns 0 if $1 is in the remaining arguments.  Used for CHANNELS_FAILED lookup.
_in_array() { local needle=$1; shift; local el; for el in "$@"; do [[ "$el" == "$needle" ]] && return 0; done; return 1; }

# Phase 5.5 — global accumulator.
# Declared here so it is never unbound when _in_array / ${CHANNELS_FAILED[@]:-}
# is evaluated even if an early return path skips the render block.
CHANNELS_FAILED=()

# Phase 5.5 — fail-soft render for bypass channels (xray, naive, hysteria2).
# Chassis renders (compose, caddy, coturn) stay strict via render_with_opec.
# On failure: logs a warning, appends channel name to CHANNELS_FAILED array,
# returns non-zero. Callers must NOT die on non-zero — install continues and
# the failed channel is excluded from the running compose stack.
render_channel_soft() {
	local kind=$1 src=$2 dst=$3
	# Use a private tmp dir (0700) so opec error fragments (which may contain
	# REALITY_PRIVATE_KEY excerpts) are not readable by other local users.
	local _rcs_tmpdir="${PREFIX_LIB:-/tmp}/tmp"
	install -d -m 0700 "$_rcs_tmpdir" 2>/dev/null || _rcs_tmpdir=/tmp
	local _rcs_err
	_rcs_err=$(mktemp "$_rcs_tmpdir/opec-render-err-${kind}-XXXXXX")
	# Trap ensures tmp file is removed on any exit path (RETURN or early die).
	# shellcheck disable=SC2064
	trap "rm -f '${_rcs_err}'" RETURN
	if command -v opec >/dev/null 2>&1; then
		if opec render "$kind" --tpl "$src" --out "$dst" 2>"$_rcs_err"; then
			return 0
		fi
		warn "channel $kind render failed — will skip this channel"
		warn "  opec error: $(cat "$_rcs_err" 2>/dev/null || echo '<no output>')"
	else
		warn "channel $kind render skipped — opec not on PATH"
	fi
	CHANNELS_FAILED+=("$kind")
	return 1
}

# Strip service blocks for failed channels from a rendered docker-compose.yml.
# Removes the service block for each failed channel AND any depends_on references
# to those services from remaining services.
#
# Args:
#   $1  compose_file — path to the rendered docker-compose.yml (modified in-place)
#   $@  failed channels — e.g. "xray" "naive"
#
# Returns 0 on success; non-zero if python3 or yaml fails (caller should warn).
compose_strip_failed_channels() {
	local compose_file=$1
	shift
	[[ $# -eq 0 ]] && return 0          # nothing to strip
	[[ -f "$compose_file" ]] || { warn "compose_strip_failed_channels: $compose_file not found"; return 1; }

	log "  stripping failed channels from compose: $*"
	python3 - "$compose_file" "$@" <<'PYEOF'
import sys, yaml, pathlib
compose_path = pathlib.Path(sys.argv[1])
failed = set(sys.argv[2:])
with compose_path.open() as f:
    doc = yaml.safe_load(f)
# Remove failed service blocks.
for kind in failed:
    doc.get('services', {}).pop(kind, None)
# Remove depends_on references to failed services from remaining services.
for _svc, conf in doc.get('services', {}).items():
    deps = conf.get('depends_on')
    if isinstance(deps, list):
        conf['depends_on'] = [d for d in deps if d not in failed]
        if not conf['depends_on']:
            del conf['depends_on']
    elif isinstance(deps, dict):
        for d in list(deps):
            if d in failed:
                del deps[d]
        if not deps:
            del conf['depends_on']
# Atomic write via tmp+rename.
tmp = compose_path.with_suffix('.tmp')
with tmp.open('w') as f:
    yaml.safe_dump(doc, f, sort_keys=False, default_flow_style=False)
tmp.replace(compose_path)
PYEOF
}
