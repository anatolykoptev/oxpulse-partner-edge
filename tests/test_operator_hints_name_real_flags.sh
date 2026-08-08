#!/usr/bin/env bash
# tests/test_operator_hints_name_real_flags.sh
#
# Every `oxpulse-partner-edge-upgrade --flag` an operator is TOLD to run must be
# a flag upgrade.sh actually parses.
#
# Earned 2026-08-07: `--image-only` was named in three operator-facing places
# (upgrade.sh's caddy-conflict hint, lib/reconcile.sh's Caddyfile-refusal die,
# and a comment citing that hint) and has never existed in the parser. Worse, a
# test PINNED the string, so the phantom read as intended behaviour. The remedy
# is handed to an operator at the moment a template apply has just been refused
# — precisely when they will paste it verbatim and get "unknown option".
#
# The valid set is DERIVED from the parser's own case arms, never from a list
# maintained here: a hand-kept list cannot detect a flag that was removed, which
# is the same class of defect one level up.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
fails=0
ok()  { printf '  ok   %s\n' "$1"; }
bad() { printf '  FAIL %s\n' "$1"; fails=$((fails + 1)); }

echo "=== operator hints name real upgrade.sh flags ==="

# ---- ground truth: the parser's own case arms -------------------------------
# Long flags: `--foo)` / `--foo=*)` arms inside the arg-parsing while loop.
# Deliberately POSIX awk + grep, no gawk 3-arg match() and no mapfile: this
# suite is run on macOS and on the Linux runner, and a gawk-only extractor
# yields an empty set on the other box — which the S1 floor would report as
# "the parser was reshaped" rather than "wrong awk".
# Anchored on `case "$arg" in` ... `esac` — the arg parser is a for/case, not a
# while/shift loop. A flag counts when it is followed by `)`, `|` or `=`, which
# is what makes it a case ARM rather than a mention inside an arm's body; the
# `|` form is required or `--allow-unverified|--no-integrity` loses its second
# spelling and a correct hint would be reported as phantom.
PARSED_RAW=$(
    awk '
        /^[[:space:]]*case[[:space:]]+"\$arg"[[:space:]]+in/ { inc = 1; next }
        inc && /^[[:space:]]*esac/                           { exit }
        inc                                                  { print }
    ' upgrade.sh | grep -oE '\-\-[a-z0-9-]+[)|=]' | sed 's/.$//' | sort -u
)
PARSED=()
while IFS= read -r _f; do [[ -n "$_f" ]] && PARSED+=("$_f"); done <<<"$PARSED_RAW"

# S1 anti-vacuous floor. If the parser is reshaped and the awk stops matching,
# PARSED goes empty, every mention "is not in the set" and this test would fail
# LOUDLY — but a floor makes the reason explicit instead of showing N confusing
# failures.
if [[ "${#PARSED[@]}" -ge 5 ]]; then
    ok "S1 derived ${#PARSED[@]} flags from upgrade.sh's parser: ${PARSED[*]}"
else
    bad "S1 derived only ${#PARSED[@]} flags from the parser — the extractor no longer matches it; fix the awk before trusting anything below"
    echo "FAILED=$fails"
    exit 1
fi

is_real() {
    local f=$1 p
    for p in "${PARSED[@]}"; do [[ "$p" == "$f" ]] && return 0; done
    return 1
}

# ---- every mention next to the binary name ----------------------------------
# Scan shell, docs and the manifest for `oxpulse-partner-edge-upgrade` followed
# by a long flag on the same line. Tests are excluded: a test may legitimately
# assert on a rejected/unknown flag.
mentions=0
while IFS= read -r hit; do
    file=${hit%%:*}
    rest=${hit#*:}
    line=${rest#*:}
    lineno=${rest%%:*}
    # Pull every --flag appearing after the binary name on this line.
    while read -r flag; do
        [[ -z "$flag" ]] && continue
        mentions=$((mentions + 1))
        if is_real "$flag"; then
            ok "$file:$lineno names $flag — parsed"
        else
            bad "$file:$lineno tells an operator to run '$flag', which upgrade.sh does not parse (valid: ${PARSED[*]})"
        fi
    done < <(printf '%s\n' "${line#*oxpulse-partner-edge-upgrade}" |
             grep -oE '(^|[[:space:]])--[a-z0-9-]+' | tr -d ' ' | sort -u)
done < <(grep -rn 'oxpulse-partner-edge-upgrade[^"]*--[a-z]' \
             --include='*.sh' --include='*.md' --include='*.yaml' . 2>/dev/null |
         grep -v '^\./tests/' | grep -v '^\./\.git/')

# S2: a second anti-vacuous floor. Zero mentions means the scan is broken (the
# binary is named in operator hints all over this repo), not that the repo is
# clean — and a silent zero is exactly how this class hides.
if [[ "$mentions" -ge 1 ]]; then
    ok "S2 checked $mentions flag mention(s) outside tests/"
else
    bad "S2 found NO operator-facing flag mentions — the scan matched nothing, so every assertion above was vacuous"
fi

echo "FAILED=$fails"
[[ "$fails" -eq 0 ]]
