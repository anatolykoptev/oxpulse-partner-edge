#!/bin/bash
# Stateful firewall-cmd stub with real firewalld 1.3 coalescing semantics (verified in
# rockylinux:9 via firewall-offline-cmd, 2026-10-12). State: $FWS/perm and $FWS/run, one
# entry per line. add-port of a COVERED range is a no-op (ALREADY_ENABLED); remove-port
# removes only an EXACT entry. FW_ADD_NOOP=<LO-HI> makes add-port of that range a silent no-op.
echo "firewall-cmd $*" >> "$FWS/calls"
scope=run; arg=""
for a in "$@"; do case "$a" in --permanent) scope=perm ;; --state) exit 0 ;; --list-ports) arg=list ;; --add-port=*|--remove-port=*|--query-port=*) arg="$a" ;; esac; done
f="$FWS/$scope"; touch "$f"
[[ $arg == list ]] && { tr '\n' ' ' < "$f"; echo; exit 0; }
port=${arg#*=}; port=${port%/udp}; lo=${port%-*}; hi=${port#*-}
case "$arg" in
	--add-port=*)
		[[ ${FW_ADD_NOOP:-} == "$port" ]] && exit 0
		while read -r e; do e=${e%/udp}; el=${e%-*}; eh=${e#*-}
			if (( el <= lo && eh >= hi )); then echo "WARNING: ALREADY_ENABLED: '$port:udp' already in 'public'" >&2; exit 0; fi
		done < "$f"
		echo "$port/udp" >> "$f" ;;
	--remove-port=*)
		grep -qxF "$port/udp" "$f" || { echo "Warning: NOT_ENABLED" >&2; exit 0; }
		grep -vxF "$port/udp" "$f" > "$f.n" || true; mv "$f.n" "$f" ;;
esac
exit 0
