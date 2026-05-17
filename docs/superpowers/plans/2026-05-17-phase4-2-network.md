# Phase 4.2 — Extract IP + region detect into `lib/install-network.sh`

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `install.sh` Step 3 (public/private IP autodetect + region detect) — L642-702, ~62 LoC — into `lib/install-network.sh::network_run()`. install.sh shrinks ~1874 → ~1820 LoC.

**Architecture:** New module sourced via Phase-4.1 `_install_lib_source` helper. Sets globals `PUBLIC_IP`, `PRIVATE_IP`, `REGION`. Uses caller env overrides `OXPULSE_PUBLIC_IP`, `OXPULSE_PRIVATE_IP`, and caller-set `REGION` arg. Pre-Phase-4.1 conventions inherited: minimal `setup()` in bats, mock `die`=`exit 1`, sub-functions `_network_*` private.

**Tech Stack:** Bash 4+, bats-core. `ipinfo.io` is the region source — same external API as install.sh today.

**Out of scope:**
- Step 3b (ghcr-auth-lib + channel-render-lib bootstrap + docker pull loop) — scoped to Phase 4.2b due to mixed concerns (two foreign lib-loading systems need unification with `_install_lib_source` first)
- Any logic change to IP/region detect — pure code-move

**Roadmap link:** `docs/superpowers/specs/2026-05-17-phase4-install-decomposition-roadmap.md` (Phase 4.2 row, scope re-chunked from 133 → 62 LoC)

## File structure

```
lib/install-network.sh                    # NEW — network_run() {IP + region detect}
install.sh                                # MODIFY — source + call network_run
tests/test_install_network_module.sh      # NEW
tests/test_install_opec_parity.sh         # MODIFY — add network module invariants
.github/workflows/release.yml             # MODIFY — publish install-network.sh asset
tests/test_release_assets.sh              # MODIFY — assert asset present
```

---

## Task 1: `lib/install-network.sh`

**Files:**
- Create: `lib/install-network.sh`
- Create: `tests/test_install_network_module.sh`

- [ ] **Step 1: Write failing bats**

```bash
#!/usr/bin/env bats
# tests/test_install_network_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPBIN="$(mktemp -d)"
}

teardown() {
    rm -rf "$TMPBIN"
}

@test "network module sources cleanly" {
    run bash -c "source '$REPO_ROOT/lib/install-network.sh'; type network_run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"network_run is a function"* ]]
}

@test "network_run honors OXPULSE_PUBLIC_IP env override" {
    run bash -c "
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=203.0.113.42
        OXPULSE_PRIVATE_IP=10.0.0.5
        REGION=us-test
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
        echo PUBLIC_IP=\$PUBLIC_IP
        echo PRIVATE_IP=\$PRIVATE_IP
        echo REGION=\$REGION
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"PUBLIC_IP=203.0.113.42"* ]]
    [[ "$output" == *"PRIVATE_IP=10.0.0.5"* ]]
    [[ "$output" == *"REGION=us-test"* ]]
    # No detection attempted when overrides set — should not call curl
    [[ "$output" != *"region auto-detected"* ]]
}

@test "network_run dies if PUBLIC_IP cannot be resolved (mocked curl returns empty)" {
    # PATH shim: curl returns empty for everything
    cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
    chmod +x "$TMPBIN/curl"
    run bash -c "
        export PATH='$TMPBIN:/usr/bin:/bin'
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=
        REGION=
        log()  { :; }
        warn() { :; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unable to autodetect public IP"* ]]
}

@test "network_run warns when region detect fails but does not die" {
    cat > "$TMPBIN/curl" <<'EOF'
#!/usr/bin/env bash
# Empty body for ipinfo.io; valid IP otherwise via OXPULSE_PUBLIC_IP override.
exit 1
EOF
    chmod +x "$TMPBIN/curl"
    run bash -c "
        export PATH='$TMPBIN:/usr/bin:/bin'
        source '$REPO_ROOT/lib/install-network.sh'
        OXPULSE_PUBLIC_IP=198.51.100.10
        OXPULSE_PRIVATE_IP=10.0.0.5
        REGION=
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; exit 1; }
        network_run
        echo REGION_AFTER=\$REGION
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"region auto-detect failed"* ]]
    [[ "$output" == *"REGION_AFTER="* ]]
}
```

Run `bats tests/test_install_network_module.sh` — expect 4 FAIL.

- [ ] **Step 2: Create `lib/install-network.sh`**

```bash
#!/usr/bin/env bash
# lib/install-network.sh — Phase 4.2 extracted from install.sh Step 3.
#
# Exports: network_run
#
# Sets (caller globals):
#   PUBLIC_IP     non-empty IPv4 string
#   PRIVATE_IP    IPv4 or empty (no private IP detected / explicitly disabled)
#   REGION        lowercase '<country>-<city3>' or empty (auto-detect failed)
#
# Reads (caller globals):
#   OXPULSE_PUBLIC_IP    operator env override
#   OXPULSE_PRIVATE_IP   operator env override
#   REGION               operator arg override (kept if non-empty)
#   log warn die         functions (install.sh provides; die MUST exit, not return)

_network_detect_public_ipv4() {
    local ip
    ip=$(curl -fsS --max-time 2 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    ip=$(curl -fsS --max-time 3 https://api.ipify.org 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    ip=$(curl -fsS --max-time 3 https://ifconfig.me 2>/dev/null || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then printf '%s' "$ip"; return 0; fi
    return 1
}

_network_detect_region() {
    local payload cc city
    payload=$(curl -fsS --max-time 3 "https://ipinfo.io/${PUBLIC_IP}/json" 2>/dev/null || true)
    [[ -z "$payload" ]] && return 1
    cc=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("country") or "").lower())' 2>/dev/null || true)
    city=$(printf '%s' "$payload" | python3 -c 'import json,sys; d=json.load(sys.stdin); print((d.get("city") or "").lower())' 2>/dev/null || true)
    [[ -z "$cc" || -z "$city" ]] && return 1
    city=$(printf '%s' "$city" | tr -cd 'a-z' | cut -c1-3)
    [[ -z "$city" ]] && return 1
    printf '%s-%s' "$cc" "$city"
}

network_run() {
    log "[3/10] detecting IPs"
    PUBLIC_IP="${OXPULSE_PUBLIC_IP:-}"
    [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP=$(_network_detect_public_ipv4 || true)
    [[ -z "$PUBLIC_IP" ]] && die "unable to autodetect public IP — set OXPULSE_PUBLIC_IP"

    PRIVATE_IP="${OXPULSE_PRIVATE_IP:-}"
    if [[ -z "$PRIVATE_IP" ]]; then
        local iface cand
        iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
        if [[ -n "$iface" ]]; then
            cand=$(ip -4 -o addr show dev "$iface" 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -1 || true)
            [[ "$cand" != "$PUBLIC_IP" ]] && PRIVATE_IP="$cand"
        fi
    fi
    log "  public=$PUBLIC_IP private=${PRIVATE_IP:-<none>}"

    # Region auto-detect (skipped if operator passed REGION arg).
    if [[ -z "$REGION" ]]; then
        if REGION=$(_network_detect_region); then
            log "  region auto-detected: $REGION"
        else
            REGION=""
            warn "  region auto-detect failed (ipinfo.io unreachable or missing fields) — registering with NULL region"
        fi
    else
        log "  region (override): $REGION"
    fi
}
```

- [ ] **Step 3: Verify**

```bash
bats tests/test_install_network_module.sh 2>&1 | tail -10
shellcheck lib/install-network.sh tests/test_install_network_module.sh
bash -n lib/install-network.sh
```

Expected: 4/4 PASS; shellcheck clean.

- [ ] **Step 4: Commit**

```
feat(install): extract network_run into lib/install-network.sh

Phase 4.2 Task 1 — moves Step 3 (public IP autodetect via
metadata→ipify→ifconfig.me, private IP from default route, region
auto-detect via ipinfo.io) into network_run(). install.sh wiring
lands in Task 2.

Refs: docs/superpowers/plans/2026-05-17-phase4-2-network.md Task 1
```

---

## Task 2: Wire install.sh — source + call network_run

**Files:**
- Modify: `install.sh` (add `_install_lib_source install-network.sh`, replace L642-702 with `network_run`)
- Modify: `tests/test_install_opec_parity.sh`

- [ ] **Step 1: Extend parity bats**

Append:

```bash
@test "install.sh sources lib/install-network.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-network\.sh' install.sh
}

@test "install.sh calls network_run instead of inline Step 3" {
    grep -qE '^[[:space:]]*network_run([[:space:]]|$)' install.sh
}

@test "install.sh no longer inlines _detect_public_ipv4" {
    ! grep -qE '^_detect_public_ipv4\(\)' install.sh
}

@test "install.sh no longer inlines _detect_region" {
    ! grep -qE '^_detect_region\(\)' install.sh
}
```

Run `bats tests/test_install_opec_parity.sh` — expect 4 new FAIL.

- [ ] **Step 2: Add `_install_lib_source install-network.sh` next to existing two**

Find the block:
```bash
_install_lib_source install-preflight.sh
_install_lib_source install-deps.sh
```

Append:
```bash
_install_lib_source install-network.sh
```

- [ ] **Step 3: Replace Step 3 inline block with `network_run` call**

Delete L642-702 (the entire `# ---------- Step 3: public/private IP autodetect ----------` section including `_detect_public_ipv4`, `_detect_region`, IP/region detect logic, and the closing `else log "  region (override): $REGION"` branch). Replace with:

```bash
network_run
```

- [ ] **Step 4: Verify**

```bash
bash -n install.sh
shellcheck install.sh 2>&1 | wc -l
git show HEAD:install.sh | shellcheck - 2>&1 | wc -l
# Expect: counts equal (no shellcheck regression)

bats tests/test_install_opec_parity.sh tests/test_install_network_module.sh \
     tests/test_install_preflight_module.sh tests/test_install_deps_module.sh \
     tests/test_render_template_golden.sh \
     tests/test_install_render_identical.sh \
     tests/test_hydrate_render_identical.sh \
     tests/test_update_uses_lib.sh \
     tests/test_release_assets.sh \
     tests/test_installer_bootstrap.sh 2>&1 | tail -15

wc -l install.sh
```

Expected: all bats PASS; `wc -l install.sh` in [1810, 1840].

- [ ] **Step 5: Commit**

```
feat(install): wire network_run into install.sh

Phase 4.2 Task 2 — install.sh sources lib/install-network.sh via the
existing _install_lib_source helper (4-tier lookup). Inline Step 3
block (IP detect + region detect) replaced by network_run() call.

LoC: install.sh ~1874 -> ~1820.

Refs: docs/superpowers/plans/2026-05-17-phase4-2-network.md Task 2
```

---

## Task 3: Publish `install-network.sh` as release asset

**Files:**
- Modify: `.github/workflows/release.yml`
- Modify: `tests/test_release_assets.sh`

- [ ] **Step 1: Extend bats**

Append to `tests/test_release_assets.sh`:

```bash
@test "release.yml stages lib/install-network.sh as install-network.sh asset" {
    grep -qE 'cp[[:space:]]+lib/install-network\.sh[[:space:]]+install-network\.sh' .github/workflows/release.yml
}

@test "release.yml SHA256SUMS line covers install-network.sh" {
    grep -A14 -E 'sha256sum' .github/workflows/release.yml | grep -q 'install-network.sh'
}

@test "release.yml uploads install-network.sh to GitHub release" {
    grep -A14 'gh release upload' .github/workflows/release.yml | grep -q 'install-network.sh'
}
```

Run `bats tests/test_release_assets.sh` — expect 3 new FAIL.

- [ ] **Step 2: Extend release.yml stage step**

Find the `Stage artifacts` step. After the existing `cp lib/install-deps.sh install-deps.sh` line, add:

```yaml
          cp lib/install-network.sh    install-network.sh
```

Extend the `sha256sum` argument list — add `install-network.sh \` after `install-deps.sh \`.

Extend the `gh release upload` argument list — add `install-network.sh \` after `install-deps.sh \`.

- [ ] **Step 3: Verify**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "yaml ok"
bats tests/test_release_assets.sh 2>&1 | tail -10
```

Expected: yaml ok; all release-asset bats PASS.

- [ ] **Step 4: Commit**

```
feat(release): publish lib/install-network.sh as release asset

Phase 4.2 Task 3 — extends the per-file asset pattern (established in
Phase 4.1) to ship lib/install-network.sh as an individual GitHub
release asset. SHA256SUMS + 'gh release upload' both cover it.

Refs: docs/superpowers/plans/2026-05-17-phase4-2-network.md Task 3
```

---

## Acceptance gate

- [ ] `bats tests/` full suite PASS
- [ ] `wc -l install.sh` in [1810, 1840]
- [ ] `shellcheck install.sh lib/*.sh` — no NEW warnings vs main baseline
- [ ] Post-merge canary on cheburator: install.sh fresh-run logs `[3/10] detecting IPs` + `public=… private=…` + region line, identical to pre-Phase-4.2 baseline

## Risk register

| Risk | Detection | Mitigation |
|------|-----------|------------|
| `_install_lib_source install-network.sh` runs BEFORE `network_run` ordering — module not loaded | shellcheck + bats parity | source happens at top of install.sh, all three module loads grouped; function call below |
| `REGION` arg parsing happens AFTER source but BEFORE `network_run` — env override still respected | manual install.sh trace | grep arg-parse block precedes `network_run` call |
| `python3` not on PATH on rare minimal images | live install fails at region detect line | matches current install.sh behaviour; not a Phase 4.2 regression |

## Commit summary (3 commits, single PR)

```
feat(install): extract network_run into lib/install-network.sh
feat(install): wire network_run into install.sh
feat(release): publish lib/install-network.sh as release asset
```

PR title: `feat(install): Phase 4.2 — extract IP + region detect into lib/install-network.sh`
