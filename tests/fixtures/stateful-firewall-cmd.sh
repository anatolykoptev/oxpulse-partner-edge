#!/bin/bash
# Stateful firewall-cmd stub with real firewalld 1.3 coalescing semantics (verified in
# rockylinux:9 via firewall-offline-cmd, 2026-10-12). State: $FWS/perm and $FWS/run, one
# entry per line. add-port of a COVERED range is a no-op (ALREADY_ENABLED); remove-port
# removes only an EXACT entry. FW_ADD_NOOP=<LO-HI> makes add-port of that range a silent no-op;
# FW_ADD_NOOP_SCOPE=perm|run limits that to one scope (default both). Several --add-port /
# --remove-port options in ONE call are applied in order, like the real tool.
echo "firewall-cmd $*" >> "$FWS/calls"
scope=run
for a in "$@"; do case "$a" in --permanent) scope=perm ;; --state) exit 0 ;; esac; done
f="$FWS/$scope"; touch "$f"
for a in "$@"; do
	case "$a" in
		--list-ports) tr '\n' ' ' < "$f"; echo; exit 0 ;;
		--add-port=*|--remove-port=*)
			port=${a#*=}; port=${port%/udp}; lo=${port%-*}; hi=${port#*-}
			if [[ $a == --add-port=* ]]; then
				if [[ ${FW_ADD_NOOP:-} == "$port" && ( -z ${FW_ADD_NOOP_SCOPE:-} || $FW_ADD_NOOP_SCOPE == "$scope" ) ]]; then continue; fi
				covered=0
				while read -r e; do e=${e%/udp}; el=${e%-*}; eh=${e#*-}
					(( el <= lo && eh >= hi )) && covered=1
				done < "$f"
				if [[ $covered == 1 ]]; then echo "WARNING: ALREADY_ENABLED: '$port:udp' already in 'public'" >&2; else echo "$port/udp" >> "$f"; fi
			else
				if grep -qxF "$port/udp" "$f"; then grep -vxF "$port/udp" "$f" > "$f.n" || true; mv "$f.n" "$f"
				else echo "Warning: NOT_ENABLED" >&2; fi
			fi ;;
	esac
done
exit 0
