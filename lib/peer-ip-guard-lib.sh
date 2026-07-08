#!/usr/bin/env bash
# lib/peer-ip-guard-lib.sh — SSRF / internal-IP classification guard.
#
# Provides:
#   _ip_is_internal IP                 # literal IPv4/IPv6 range classifier
#   _host_is_internal HOST             # top-level dial-time gate (literal or DNS)
#   _ipv4_literal_is_suspect HOST      # SEC-CR-301 non-canonical-encoding gate
#   _ipv6_embedded_v4 IPV6_LITERAL     # byte-level embedded-v4 extractor (SEC-CR-306)
#
# Requires (ambient env, all optional — read only, never written):
#   OXPULSE_PY_BIN       — python3 interpreter override for _ipv6_embedded_v4
#                           (default: python3). MISSING/unreachable → the
#                           interpreter call fails and _ipv6_embedded_v4 never
#                           returns 0 — callers fall into their fail-closed
#                           default arm (reject). This fail-closed behavior is
#                           the security invariant this lib exists to preserve;
#                           never "fix" it into a silent-allow.
#   OXPULSE_GETENT_BIN    — getent override for _host_is_internal (default: getent)
#   OXPULSE_GETENT_TIMEOUT — seconds bounding the getent ahosts call (default: 3)
#
# Extracted from oxpulse-channels-health-report.sh (was lines 610-784, moved
# verbatim — behavior-preserving) per the strangler-fig plan:
#   ~/deploy/krolik-server/plans/oxpulse-partner-edge/2026-07-08-health-report-lib-extraction.md
#   ADR-3 / ADR-7: leaf-first extraction — pure, no side effects beyond the
#   documented reads above, highest security value, smallest blast radius.
#
# Threat classes closed here (do not regress — see
# tests/test_peer_ip_guard_lib.sh for the ported assertions):
#   SEC-CR-301     non-canonical IPv4 literal encodings (hex/octal/decimal/
#                  short-form) that inet_aton would accept but getent/DNS
#                  never return — treated as adversarial, fail-closed.
#   SEC-CR-306     IPv4-mapped / NAT64 / IPv4-compatible v4-in-v6 embedding,
#                  classified by the 16-byte VALUE (python3 socket.inet_pton),
#                  not textual shape — closes the hex-compressed bypass
#                  (::ffff:7f00:1 etc.) that a dotted-only matcher missed.
#   SEC-CR-322-02  the vetted dial IP is echoed on stdout so the caller can
#                  pin the dial to it, closing the resolve-then-dial DNS-
#                  rebind TOCTOU window.
#   P2-SEC-CR-001  dial-time SSRF recheck (loopback/RFC-1918/link-local/ULA)
#                  independent of the central's roster-curation-time guard.
#
# Sourced by oxpulse-channels-health-report.sh. Not executable on its own.

# Guard against double-sourcing.
[[ "${_PEER_IP_GUARD_LIB_LOADED:-0}" -eq 1 ]] && return 0
_PEER_IP_GUARD_LIB_LOADED=1

# ---------- byte-level embedded-v4 extractor (closes SEC-CR-306) ----------
# An IPv6 literal can embed a v4 address in THREE families, each in ANY textual
# encoding (dotted, hex-compressed, uppercase):
#   * IPv4-mapped     ::ffff:a.b.c.d  /  ::ffff:0:0/96   (bytes[0:12]=…0000ffff)
#   * NAT64 well-known 64:ff9b::a.b.c.d /  64:ff9b::/96   (bytes[0:12]=0064ff9b…0)
#   * IPv4-compatible ::a.b.c.d / ::<hex> (deprecated)    (bytes[0:12]=all-zero)
# The PRIOR classifier matched the textual SHAPE (a dotted ".*.*.*.*" tail), so
# hex-compressed forms (::ffff:7f00:1, ::FFFF:7F00:1, ::7f00:1, 64:ff9b::7f00:1)
# slipped past the guard — getaddrinfo/turnutils later re-expand them to the
# internal v4 and connect. SEC-CR-306. We now classify by the 16-byte VALUE, not
# the string: normalize with python3 socket.inet_pton(AF_INET6,…) → if the upper
# 12 bytes match a known v4-bearing prefix, the lower 4 bytes ARE the embedded
# v4. Override the interpreter with OXPULSE_PY_BIN for tests.
#
# stdout: the embedded dotted-quad (when the literal embeds a v4).
# exit 0  → embeds a v4 (caller reclassifies the printed v4 via the v4 path)
# exit 1  → a pure IPv6 literal with NO embedded v4 (caller uses v6 range arms)
# exit 2  → not a parseable v6 literal / ambiguous (caller FAILS CLOSED = reject)
_ipv6_embedded_v4() {
    local py_bin="${OXPULSE_PY_BIN:-python3}"
    L="$1" "$py_bin" -c '
import socket, os, sys
lit = os.environ.get("L", "")
try:
    b = socket.inet_pton(socket.AF_INET6, lit)
except OSError:
    sys.exit(2)
prefix, v4 = b[:12], b[12:16]
MAPPED = bytes(10) + b"\xff\xff"          # ::ffff:0:0/96
NAT64  = b"\x00\x64\xff\x9b" + bytes(8)   # 64:ff9b::/96
ZERO   = bytes(12)                        # ::/96 (compat, ::, ::1)
if prefix in (MAPPED, NAT64, ZERO):
    sys.stdout.write(socket.inet_ntop(socket.AF_INET, v4))
    sys.exit(0)
sys.exit(1)
' 2>/dev/null
}

# ---------- SSRF dial-time recheck (closes P2-SEC-CR-001) ----------
# Returns 0 (TRUE — internal, REJECT) when the host is, or resolves to, a
# loopback / RFC-1918 / link-local / ULA / ::1 address. Returns 1 (public, OK).
#
# Defeats split-horizon / DNS-rebinding: the central SSRF-guards the roster
# STRING at curation time but resolves no DNS (by design — TOCTOU). We resolve
# here, at the dialer, and classify EVERY returned A/AAAA. A host that is an IP
# literal is classified directly (no resolution needed).
#
# Resolution via getent ahosts (honours nsswitch; returns both v4 + v6). A
# resolution failure (NXDOMAIN / timeout) is treated as INTERNAL=reject — we do
# not dial a host we cannot vet (fail-closed). Override the resolver with
# OXPULSE_GETENT_BIN for tests.
_ip_is_internal() {
    local ip="$1"
    # Strip a [..] bracket wrapper (URL-form IPv6 literal: "[::1]") before
    # matching — SEC-CR-301 (brackets must not let ::1 slip past the case arms).
    ip="${ip#[}"; ip="${ip%]}"
    # IPv4-mapped / NAT64 / IPv4-compatible IPv6 ALL embed a v4 — in ANY encoding
    # (dotted, hex-compressed, uppercase). Classify by the 16-byte value, not the
    # textual shape (SEC-CR-306: the old dotted-".*.*.*.*" match let hex through).
    # Only run the byte-level extractor on literals that contain a colon (cheap
    # gate — a bare v4 literal has no ':' and needs no normalization).
    if [[ "$ip" == *:* ]]; then
        local _embedded_v4 _embed_rc
        _embedded_v4=$(_ipv6_embedded_v4 "$ip"); _embed_rc=$?
        case "$_embed_rc" in
            0)
                # Embeds a v4 → classify the embedded v4 via the v4 path. An
                # internal embedded v4 (loopback/RFC-1918/CGNAT/0.0.0.0/…) rejects;
                # a public one (e.g. ::ffff:8.8.8.8) falls through to public.
                _ip_is_internal "$_embedded_v4" && return 0
                return 1
                ;;
            1)
                # Pure IPv6, no embedded v4 → fall through to the v6 range arms
                # (::1 / fe80::/10 / fc00::/7) below.
                : ;;
            *)
                # rc=2 (unparseable / ambiguous v6 literal) OR any other code
                # (python3 unavailable / errored, e.g. 127) → FAIL CLOSED (treat as
                # internal, reject). We never dial a literal we cannot prove is a
                # public pure-v6 address.
                return 0
                ;;
        esac
    fi
    case "$ip" in
        # IPv4 loopback 127.0.0.0/8
        127.*) return 0 ;;
        # "this network" 0.0.0.0/8 (SEC-CR-301) — 0.0.0.0 is also unspecified
        0.*) return 0 ;;
        # RFC-1918 10.0.0.0/8
        10.*) return 0 ;;
        # RFC-1918 192.168.0.0/16
        192.168.*) return 0 ;;
        # link-local / cloud metadata 169.254.0.0/16
        169.254.*) return 0 ;;
        # RFC-1918 172.16.0.0/12 (172.16 – 172.31)
        172.1[6-9].*|172.2[0-9].*|172.3[0-1].*) return 0 ;;
        # CGNAT 100.64.0.0/10 (100.64 – 100.127) (SEC-CR-301)
        100.6[4-9].*|100.7[0-9].*|100.8[0-9].*|100.9[0-9].*|100.1[0-1][0-9].*|100.12[0-7].*) return 0 ;;
        # IPv6 loopback / unspecified
        ::1|::) return 0 ;;
        # IPv6 link-local fe80::/10  (fe80 – febf)
        [Ff][Ee][89AaBb]*:*) return 0 ;;
        # IPv6 ULA fc00::/7  (fc.. / fd..)
        [Ff][CcDd]*:*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------- is this token a NON-canonical IPv4 literal? (SEC-CR-301) ----------
# getent / DNS only ever return canonical dotted-decimal v4 or canonical v6.
# A roster host that is an IP LITERAL in any OTHER numeric encoding — hex
# (0x7f000001), octal (0177.0.0.1), bare decimal (2130706433), or short/mixed
# dotted forms (127.1, 10.0x2.3) — can only be an attacker trying to smuggle an
# internal address past a naive dotted-quad classifier. inet_aton accepts ALL of
# them; our regex-based range arms do NOT. We cannot enumerate every encoding,
# so we FAIL CLOSED: any IP-literal-shaped host that is not an UNAMBIGUOUS
# canonical public dotted-quad (four 0-255 octets) is treated as internal.
# Returns 0 (TRUE — suspect, reject) / 1 (clean canonical dotted-quad).
_ipv4_literal_is_suspect() {
    local h="$1"
    # Canonical dotted-quad: exactly four decimal octets, each 0-255, no leading
    # zeros (a leading zero = octal interpretation by inet_aton).
    local o='(0|[1-9][0-9]?|1[0-9][0-9]|2[0-4][0-9]|25[0-5])'
    if [[ "$h" =~ ^${o}\.${o}\.${o}\.${o}$ ]]; then
        return 1   # clean canonical dotted-quad — let the range arms decide
    fi
    return 0       # any other all-numeric-ish literal → suspect → reject
}

_host_is_internal() {
    local host="$1"
    [[ -z "$host" ]] && return 0   # empty host → reject

    # Strip a [..] IPv6-URL-literal wrapper for the literal-shape tests below.
    local bare="$host"
    bare="${bare#[}"; bare="${bare%]}"

    # IPv6 literal (contains a colon, possibly bracketed) → classify directly.
    if [[ "$bare" == *:* ]]; then
        _ip_is_internal "$bare" && return 0
        printf '%s' "$bare"   # SEC-CR-322-02: echo the vetted dial IP (the literal itself)
        return 1
    fi

    # A host that LOOKS like a numeric IPv4 literal (starts with a digit, no DNS
    # label letters, or a hex/octal lead) is classified WITHOUT resolution and
    # fail-closed on any non-canonical encoding (SEC-CR-301). This catches
    # 0x7f000001, 0177.0.0.1, 2130706433, 127.1, etc. — inet_aton would dial
    # them as 127.0.0.1, but they never come from getent, so a literal in this
    # shape is adversarial.
    if [[ "$bare" =~ ^0[xX][0-9a-fA-F]+$ \
       || "$bare" =~ ^[0-9]+$ \
       || "$bare" =~ ^[0-9]+(\.[0-9xXa-fA-F]+)+$ ]]; then
        if _ipv4_literal_is_suspect "$bare"; then
            return 0   # non-canonical numeric literal → reject
        fi
        # Canonical dotted-quad → range classification.
        _ip_is_internal "$bare" && return 0
        printf '%s' "$bare"   # SEC-CR-322-02: echo the vetted dial IP (the literal itself)
        return 1
    fi

    # Hostname → resolve and classify every returned address. Fail-closed:
    # a resolution failure rejects (we never dial an un-vettable host).
    local getent_bin resolved ip
    getent_bin="${OXPULSE_GETENT_BIN:-getent}"
    # 3s (was 5s) — bounds the per-peer SSRF-recheck slice of the budget
    # arithmetic in _run_peer_probe_loop (getent 3 + probe 8 + post 8 = 19s/peer).
    resolved=$(timeout "${OXPULSE_GETENT_TIMEOUT:-3}" "$getent_bin" ahosts "$host" 2>/dev/null | awk '{print $1}' | sort -u)
    if [[ -z "$resolved" ]]; then
        return 0   # unresolvable → reject
    fi
    local first_ip=""
    while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        [[ -z "$first_ip" ]] && first_ip="$ip"
        if _ip_is_internal "$ip"; then
            return 0   # ANY internal address → reject the whole host
        fi
    done <<< "$resolved"
    # SEC-CR-322-02: echo the first vetted IP so the caller can PIN the dial to it
    # (-connect <ip> -servername <host>) — neither openssl nor turnutils then
    # re-resolves the hostname, closing the resolve-then-dial DNS-rebind TOCTOU.
    # "first" = lexically-smallest (the list is `sort -u`'d above); for a single-
    # homed edge (the norm) it is the only address. A multi-homed peer whose
    # lexically-first public IP is unreachable would be pinned to it — acceptable:
    # the central needs ≥2 distinct probers to withdraw, so one prober's pin choice
    # cannot unilaterally evict, and ALL its addresses were already vetted public.
    printf '%s' "$first_ip"
    return 1   # all resolved addresses public → allow
}
