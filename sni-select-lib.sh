#!/usr/bin/env bash
# sni-select-lib.sh — single source of truth for Reality SNI selection.
#
# Deterministic pick: sha256(node_id:YYYY-MM-DD) mod pool_size.
# Same node+date+pool -> same name; different nodes spread across the pool.
#
# Sourced by BOTH:
#   - oxpulse-partner-edge-sni-rotate.sh (daily timer)
#   - channel-render-lib.sh (every render / upgrade / key refresh / refetch)
#
# Keeping the arithmetic in ONE place guarantees the renderer and the rotator
# never disagree on which SNI a node presents. Before this helper existed the
# renderer took names[0] unconditionally while the rotator hashed — and since
# the renderer runs far more often than the daily timer, every node converged
# to index 0 (fleet-wide SNI uniformity, an anti-censorship regression).
#
# No shebang execution — this file is only ever sourced, never run directly.

command -v warn >/dev/null 2>&1 || warn() { printf 'WARN: %s\n' "$*" >&2; }

# sni_select <node_id> <date_YYYY-MM-DD> <pool_newline_separated>
#
# Prints the chosen SNI to stdout. Returns 0 on success, 1 if the pool is empty.
# If node_id is empty/missing, warns and falls back to index 0 — the ONLY
# remaining path to index 0. A single-entry pool always yields that entry
# (hash mod 1 == 0), preserving prior behaviour.
sni_select() {
	local node_id="$1" date="$2" pool="$3"
	local pool_size
	pool_size=$(printf '%s\n' "$pool" | grep -c .)
	if [[ "$pool_size" -lt 1 ]]; then
		return 1
	fi
	if [[ -z "$node_id" ]]; then
		warn "sni_select: node_id empty — falling back to index 0"
		printf '%s\n' "$pool" | sed -n '1p'
		return 0
	fi
	local pick_idx
	pick_idx=$(python3 -c "
import hashlib, sys
seed = '{}:{}'.format(sys.argv[1], sys.argv[2])
h = int(hashlib.sha256(seed.encode()).hexdigest(), 16)
print(h % int(sys.argv[3]))
" "$node_id" "$date" "$pool_size")
	printf '%s\n' "$pool" | sed -n "$((pick_idx + 1))p"
}
