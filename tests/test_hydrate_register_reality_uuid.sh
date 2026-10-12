#!/usr/bin/env bash
# tests/test_hydrate_register_reality_uuid.sh
#
# oxpulse-chat #3369 makes POST /api/partner/register refuse (409) a request
# without a per-node reality_uuid. install.sh sends one (opec secrets
# reality-keygen -> reality.uuid); hydrate.sh, the cloud-init first-boot path,
# used to POST only partner_id/domain/token/public_ip and so would die on the
# first clone after #3369 deploys.
#
# This test runs hydrate.sh's real hydrate_register_body() (extracted from the
# script, not re-implemented) against a stub `opec`, and asserts:
#   1. the body carries reality_uuid == what opec wrote to reality.uuid
#   2. the other four fields survive, and hostile values (quotes) stay valid JSON
#   3. reality_public_key is NOT sent (it would be echoed back as the server key)
#   4. a failing / missing opec fails the function (hydrate then dies, no POST)
#   5. the curl POST uses the built body, not a hand-spliced JSON string
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
SCRIPT="$REPO_ROOT/hydrate.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

command -v jq >/dev/null || { echo "SKIP: jq not installed"; exit 0; }
[[ -f "$SCRIPT" ]] || fail "hydrate.sh not found at $SCRIPT"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Extract the real function body from hydrate.sh.
FN_FILE="$TMP/fn.sh"
sed -n '/^hydrate_register_body() {/,/^}/p' "$SCRIPT" > "$FN_FILE"
[[ -s "$FN_FILE" ]] || fail "hydrate_register_body() not found in hydrate.sh"

STUB_UUID="0b6f1c2e-5d4a-4f3b-9a7c-123456789abc"
mkdir -p "$TMP/bin" "$TMP/etc"
cat > "$TMP/bin/opec" <<STUB
#!/usr/bin/env bash
# stub: opec secrets reality-keygen --out-dir DIR
[[ "\$1 \$2" == "secrets reality-keygen" ]] || exit 64
[[ "\$3" == "--out-dir" ]] || exit 64
printf '%s\n' "$STUB_UUID" > "\$4/reality.uuid"
echo "stub opec: wrote identity" # stdout noise must not leak into the body
STUB
chmod +x "$TMP/bin/opec"

run_fn() { # run_fn <PATH> -> prints body on stdout, returns the function's rc
    PATH="$1" PREFIX_ETC="$TMP/etc" PARTNER_ID='partner"x' PARTNER_DOMAIN='call1.example.com' \
        REGISTRATION_TOKEN='ptkn_a"b\c' PUBLIC_IP='203.0.113.7' \
        "$BASH" -c 'warn() { echo "warn: $*" >&2; }; source "$1"; hydrate_register_body' _ "$FN_FILE"
}

# 1+2+3: happy path.
body=$(run_fn "$TMP/bin:$PATH") || fail "hydrate_register_body failed with a working opec"
[[ "$(jq -r .reality_uuid <<<"$body")" == "$STUB_UUID" ]] \
    || fail "reality_uuid missing or wrong in body: $body"
[[ "$(jq -r .partner_id <<<"$body")" == 'partner"x' ]] || fail "partner_id mangled: $body"
[[ "$(jq -r .token <<<"$body")" == 'ptkn_a"b\c' ]] || fail "token not JSON-escaped: $body"
[[ "$(jq -r .domain <<<"$body")" == 'call1.example.com' ]] || fail "domain wrong: $body"
[[ "$(jq -r .public_ip <<<"$body")" == '203.0.113.7' ]] || fail "public_ip wrong: $body"
[[ "$(jq 'has("reality_public_key")' <<<"$body")" == "false" ]] \
    || fail "reality_public_key must not be sent: $body"

# 4a: opec fails -> function fails, no body.
cat > "$TMP/bin/opec" <<'STUB'
#!/usr/bin/env bash
exit 3
STUB
if out=$(run_fn "$TMP/bin:$PATH" 2>/dev/null); then fail "must fail when opec fails (got: $out)"; fi
[[ -z "$out" ]] || fail "no body may be emitted when opec fails (got: $out)"

# 4b: opec absent from PATH -> function fails. (jq/bash resolved via absolute dirs)
mkdir -p "$TMP/nopec"; ln -sf "$(command -v jq)" "$TMP/nopec/jq"
ln -sf "$(command -v tr)" "$TMP/nopec/tr"
if run_fn "$TMP/nopec" >/dev/null 2>&1; then fail "must fail when opec is missing"; fi

# 5: the curl POST sends the built body.
register_block=$(awk '/X POST.*api\/partner\/register/,/-o.*tmp_resp/' "$SCRIPT")
grep -q -- '-d "\$register_body"' <<<"$register_block" \
    || fail "register curl must POST \"\$register_body\""
grep -q 'register_body=\$(hydrate_register_body)' "$SCRIPT" \
    || fail "hydrate.sh must build register_body via hydrate_register_body"

echo "PASS: test_hydrate_register_reality_uuid"
