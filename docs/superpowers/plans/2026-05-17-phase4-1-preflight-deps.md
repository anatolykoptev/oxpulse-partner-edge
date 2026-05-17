# Phase 4.1 — Extract preflight + deps modules

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Move `install.sh` Step 1 (preflight) + Step 1b (firewall) + Step 1c (dnf cache) + Step 1b'-runtime (jq/curl) + Step 2 (Docker) — ~155 LoC — into two sourced bash modules. install.sh shrinks to ~1836 LoC.

**Architecture:** Two modules sourced at install.sh top — `lib/install-preflight.sh` exposes `preflight_run()`, `lib/install-deps.sh` exposes `deps_install()`. Modules use globals already in install.sh scope (`OS_FAMILY`, `SFU_UDP_PORT`, `DRY_RUN`, `log`/`die`/`warn` helpers) — they do NOT redefine helpers. `_install_lib_source` resolves modules via lookup order: `$INSTALL_LIB_DIR` env → `/usr/local/lib/partner-edge/` → `$(dirname "$0")/lib/` → curl from `$REPO_RAW/lib/`. release.yml tarball bundles `lib/*.sh`.

**Tech Stack:** Bash 4+, bats-core, GitHub Actions (release.yml).

**Out of scope:**
- AWG (`install_amneziawg`, Phase 4.10)
- Step 3 IP detect (Phase 4.2)
- Any logic change — pure code-move + indirection layer

**Roadmap link:** `docs/superpowers/specs/2026-05-17-phase4-install-decomposition-roadmap.md`

---

## File structure

```
lib/
├── install-preflight.sh   # NEW — preflight_run() {OS detect + port check + firewall + dnf cache}
└── install-deps.sh         # NEW — deps_install()    {jq/curl + Docker + compose plugin}
install.sh                  # MODIFY — source both, call preflight_run/deps_install at L580/L714
tests/
├── test_install_preflight_module.sh   # NEW
├── test_install_deps_module.sh         # NEW
└── test_install_opec_parity.sh         # MODIFY — add module-source invariant
.github/workflows/release.yml           # MODIFY — bundle lib/ in tarball
```

---

## Task 1: `lib/install-preflight.sh`

**Files:**
- Create: `lib/install-preflight.sh`
- Create: `tests/test_install_preflight_module.sh`

- [ ] **Step 1: Write failing bats test**

```bash
#!/usr/bin/env bats
# tests/test_install_preflight_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPMOD="$(mktemp -d)"
    # Mock helpers install.sh provides
    log()  { :; }
    warn() { :; }
    die()  { echo "die: $*" >&2; return 1; }
    export -f log warn die
    DRY_RUN=1  # skip side-effecting branches
    SFU_UDP_PORT=7878
    SFU_METRICS_PORT=9317
}

teardown() {
    rm -rf "$TMPMOD"
}

@test "preflight module sources cleanly without side effects" {
    run bash -c "source '$REPO_ROOT/lib/install-preflight.sh'; type preflight_run"
    [ "$status" -eq 0 ]
    [[ "$output" == *"preflight_run is a function"* ]]
}

@test "preflight_run detects debian family from /etc/os-release fixture" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=ubuntu
ID_LIKE=debian
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die >&2; return 1; }
        preflight_run
        echo OS_FAMILY=\$OS_FAMILY
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS_FAMILY=debian"* ]]
}

@test "preflight_run detects rhel family from /etc/os-release fixture" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=almalinux
ID_LIKE="rhel centos fedora"
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die >&2; return 1; }
        preflight_run
        echo OS_FAMILY=\$OS_FAMILY
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"OS_FAMILY=rhel"* ]]
}

@test "preflight_run dies on unsupported OS" {
    fake_os="$TMPMOD/os-release"
    cat > "$fake_os" <<'EOF'
ID=arch
ID_LIKE=
EOF
    run bash -c "
        OS_RELEASE_PATH='$fake_os'
        source '$REPO_ROOT/lib/install-preflight.sh'
        DRY_RUN=1
        SFU_UDP_PORT=7878
        SFU_METRICS_PORT=9317
        log()  { :; }
        warn() { :; }
        die()  { echo die: \"\$*\" >&2; return 1; }
        preflight_run
    "
    [ "$status" -ne 0 ]
    [[ "$output" == *"unsupported OS"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails (module doesn't exist)**

Run: `bats tests/test_install_preflight_module.sh 2>&1 | tail -5`
Expected: 4 FAIL (no such file).

- [ ] **Step 3: Create `lib/install-preflight.sh`**

```bash
#!/usr/bin/env bash
# lib/install-preflight.sh — Phase 4.1 extracted from install.sh Step 1/1b/1c.
#
# Exports: preflight_run
#
# Requires (caller globals):
#   OS_ID OS_FAMILY    set by this function
#   DRY_RUN            int, skip side-effecting branches when 1
#   SFU_UDP_PORT       int
#   SFU_METRICS_PORT   int
#   log warn die       functions (install.sh provides)
#
# Optional overrides (test hooks):
#   OS_RELEASE_PATH    default /etc/os-release

preflight_run() {
    local os_release_path="${OS_RELEASE_PATH:-/etc/os-release}"
    log "[1/10] preflight checks"
    OS_ID=""; OS_FAMILY=""
    if [[ -r "$os_release_path" ]]; then
        # shellcheck source=/dev/null
        . "$os_release_path"
        OS_ID="$ID"
        case " $ID ${ID_LIKE:-} " in
            *" debian "*|*" ubuntu "*) OS_FAMILY=debian ;;
            *" rhel "*|*" fedora "*|*" centos "*|*" almalinux "*|*" rocky "*) OS_FAMILY=rhel ;;
            *) die "unsupported OS: ID=$ID ID_LIKE=${ID_LIKE:-<empty>} (need Debian/Ubuntu/AlmaLinux/Rocky/RHEL)" ;;
        esac
    fi
    log "  os=$OS_ID family=$OS_FAMILY"

    if [[ $DRY_RUN -eq 0 ]]; then
        local owned_by_oxpulse=0
        if command -v docker >/dev/null 2>&1 \
            && docker ps --filter 'name=oxpulse-partner-' --format '{{.Names}}' 2>/dev/null \
            | grep -q .; then
            owned_by_oxpulse=1
        fi
        _preflight_check_port_free() {
            local port=$1 proto=$2
            ss -ln"${proto}" 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$" || return 0
            if [[ $owned_by_oxpulse -eq 1 ]]; then
                warn "port $port/$proto held by existing oxpulse-partner-* container — re-install path, continuing"
                return 0
            fi
            die "port $port/$proto is already in use — free it before installing"
        }
        local p
        for p in 80 443 3478 5349 "$SFU_METRICS_PORT"; do _preflight_check_port_free "$p" t; done
        _preflight_check_port_free 3478 u
        _preflight_check_port_free "$SFU_UDP_PORT" u
        log "  ports 80/443/3478/5349/${SFU_UDP_PORT}(udp)/${SFU_METRICS_PORT}(tcp) preflight done (oxpulse-owned=${owned_by_oxpulse})"
    fi

    _preflight_firewall
    _preflight_dnf_cache_sanity
}

_preflight_firewall() {
    local fw_specs=(80/tcp 443/tcp 3478/tcp 3478/udp 5349/tcp \
        "${SFU_UDP_PORT}/udp" "${SFU_METRICS_PORT}/tcp")
    if [[ $DRY_RUN -eq 0 ]] \
        && command -v firewall-cmd >/dev/null 2>&1 \
        && systemctl is-active --quiet firewalld; then
        log "[1b] opening firewalld ports"
        local fw_added=0 spec
        for spec in "${fw_specs[@]}"; do
            if ! firewall-cmd --query-port="$spec" >/dev/null 2>&1; then
                firewall-cmd --add-port="$spec" --permanent >/dev/null
                fw_added=1
                log "  + $spec"
            fi
        done
        if [[ $fw_added -eq 1 ]]; then
            firewall-cmd --reload >/dev/null
            log "  firewalld reloaded"
        else
            log "  all required ports already open"
        fi
    elif [[ $DRY_RUN -eq 0 ]] \
        && command -v ufw >/dev/null 2>&1 \
        && ufw status 2>/dev/null | head -1 | grep -qi 'Status: active'; then
        log "[1b] opening ufw ports"
        local spec
        for spec in "${fw_specs[@]}"; do
            ufw allow "$spec" >/dev/null
            log "  + $spec"
        done
    fi
}

_preflight_dnf_cache_sanity() {
    if [[ $DRY_RUN -eq 0 && $OS_FAMILY == rhel ]] && command -v dnf >/dev/null 2>&1; then
        if ! dnf -q makecache --setopt=metadata_expire=0 >/dev/null 2>&1; then
            warn "  dnf makecache failed — checking for commented metalinks in /etc/yum.repos.d"
            local repaired=0 f
            for f in /etc/yum.repos.d/centos.repo /etc/yum.repos.d/centos-addons.repo; do
                [[ -f "$f" ]] || continue
                if grep -q '^#metalink=https://mirrors.centos.org' "$f"; then
                    sed -i 's|^#metalink=https://mirrors.centos.org|metalink=https://mirrors.centos.org|g' "$f"
                    log "  re-enabled metalinks in $f"
                    repaired=1
                fi
            done
            if [[ $repaired -eq 1 ]]; then
                dnf -q makecache --setopt=metadata_expire=0 >/dev/null 2>&1 \
                    || die "dnf still broken after metalink re-enable — inspect /etc/yum.repos.d/ manually"
                log "  dnf cache rebuilt"
            else
                die "dnf makecache failed and no commented-metalink pattern matched — inspect /etc/yum.repos.d/ and DNS"
            fi
        fi
    fi
}
```

- [ ] **Step 4: Run test — PASS expected**

Run: `bats tests/test_install_preflight_module.sh 2>&1 | tail -5`
Expected: 4 PASS.

- [ ] **Step 5: shellcheck the module**

Run: `shellcheck lib/install-preflight.sh`
Expected: 0 warnings (SC1091 about `source /etc/os-release` is acceptable, suppressed via the existing `# shellcheck source=/dev/null` comment).

- [ ] **Step 6: Commit**

```bash
git add lib/install-preflight.sh tests/test_install_preflight_module.sh
git commit -m "feat(install): extract preflight into lib/install-preflight.sh

Phase 4.1 Task 1 — moves Step 1 (OS detect + port checks),
Step 1b (firewall auto-open), Step 1c (dnf cache sanity)
into preflight_run(). install.sh wiring lands in Task 3."
```

---

## Task 2: `lib/install-deps.sh`

**Files:**
- Create: `lib/install-deps.sh`
- Create: `tests/test_install_deps_module.sh`

- [ ] **Step 1: Write failing bats test**

```bash
#!/usr/bin/env bats
# tests/test_install_deps_module.sh

setup() {
    REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
    TMPBIN="$(mktemp -d)"
    PATH="$TMPBIN:$PATH"
    DRY_RUN=0
    OS_FAMILY=debian
    log()  { :; }
    warn() { :; }
    die()  { echo "die: $*" >&2; return 1; }
    export -f log warn die
}

teardown() {
    rm -rf "$TMPBIN"
}

@test "deps module sources cleanly" {
    run bash -c "source '$REPO_ROOT/lib/install-deps.sh'; type deps_install"
    [ "$status" -eq 0 ]
    [[ "$output" == *"deps_install is a function"* ]]
}

@test "deps_install skips jq/curl install when both present" {
    # Both jq and curl available via /usr/bin in CI
    run bash -c "
        source '$REPO_ROOT/lib/install-deps.sh'
        DRY_RUN=1   # skip docker install branch
        OS_FAMILY=debian
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; return 1; }
        deps_install
    "
    [ "$status" -eq 0 ]
    [[ "$output" != *"installing missing runtime dep"* ]]
}

@test "deps_install dry-run skips docker install" {
    run bash -c "
        source '$REPO_ROOT/lib/install-deps.sh'
        DRY_RUN=1
        OS_FAMILY=debian
        log()  { echo \"log: \$*\"; }
        warn() { echo \"warn: \$*\"; }
        die()  { echo \"die: \$*\" >&2; return 1; }
        deps_install
    "
    [ "$status" -eq 0 ]
    [[ "$output" == *"[dry-run] skipping docker install"* ]]
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bats tests/test_install_deps_module.sh 2>&1 | tail -5`
Expected: 3 FAIL.

- [ ] **Step 3: Create `lib/install-deps.sh`**

```bash
#!/usr/bin/env bash
# lib/install-deps.sh — Phase 4.1 extracted from install.sh Step 1b'/Step 2.
#
# Exports: deps_install
#
# Requires (caller globals):
#   OS_FAMILY      'debian' or 'rhel'
#   DRY_RUN        int
#   log warn die   functions

deps_install() {
    if [[ $DRY_RUN -eq 0 ]]; then
        local _pkg
        for _pkg in jq curl; do
            if ! command -v "$_pkg" >/dev/null 2>&1; then
                log "  installing missing runtime dep: $_pkg"
                if [[ $OS_FAMILY == rhel ]]; then
                    dnf install -y "$_pkg" >/dev/null 2>&1 \
                        || die "dnf install $_pkg failed — install manually then re-run"
                else
                    apt-get install -y -q "$_pkg" >/dev/null 2>&1 \
                        || die "apt-get install $_pkg failed"
                fi
            fi
        done
    fi

    log "[2/10] ensuring docker + compose plugin"
    if [[ $DRY_RUN -eq 0 ]]; then
        if ! command -v docker >/dev/null 2>&1; then
            log "  docker not found — installing via get.docker.com"
            curl -fsSL --proto '=https' --tlsv1.2 https://get.docker.com -o /tmp/get-docker.sh
            sh /tmp/get-docker.sh
            rm -f /tmp/get-docker.sh
        fi
        if ! docker compose version >/dev/null 2>&1; then
            if [[ $OS_FAMILY == debian ]]; then
                apt-get update -q && apt-get install -y -q docker-compose-plugin dnsutils
            else
                dnf install -y docker-compose-plugin bind-utils || dnf install -y docker-compose bind-utils
            fi
        fi
        systemctl enable --now docker
        log "  docker $(docker --version | awk '{print $3}' | tr -d ,) ready"
    else
        warn "  [dry-run] skipping docker install"
    fi
}
```

- [ ] **Step 4: Run test — PASS expected**

Run: `bats tests/test_install_deps_module.sh 2>&1 | tail -5`
Expected: 3 PASS.

- [ ] **Step 5: shellcheck the module**

Run: `shellcheck lib/install-deps.sh`
Expected: 0 new warnings.

- [ ] **Step 6: Commit**

```bash
git add lib/install-deps.sh tests/test_install_deps_module.sh
git commit -m "feat(install): extract deps_install into lib/install-deps.sh

Phase 4.1 Task 2 — moves Step 1b' (jq/curl) + Step 2 (Docker +
compose plugin) into deps_install(). install.sh wiring lands
in Task 3."
```

---

## Task 3: Wire install.sh — source modules + replace inline blocks

**Files:**
- Modify: `install.sh` (add `_install_lib_source` helper, replace L580-734 with module calls)
- Modify: `tests/test_install_opec_parity.sh` (add module-source invariant)

- [ ] **Step 1: Modify parity bats — add new tests**

Append to `tests/test_install_opec_parity.sh`:

```bash
@test "install.sh sources lib/install-preflight.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-preflight\.sh' install.sh
}

@test "install.sh sources lib/install-deps.sh module" {
    grep -qE '_install_lib_source[[:space:]]+install-deps\.sh' install.sh
}

@test "install.sh calls preflight_run instead of inline Step 1" {
    grep -qE '^preflight_run$' install.sh
}

@test "install.sh calls deps_install instead of inline Step 2" {
    grep -qE '^deps_install$' install.sh
}

@test "install.sh no longer inlines OS_FAMILY detection" {
    ! grep -qE '^\s+\*" debian "\*\|\*" ubuntu "\*\) OS_FAMILY=debian' install.sh
}
```

- [ ] **Step 2: Run parity bats — 5 FAIL expected**

Run: `bats tests/test_install_opec_parity.sh 2>&1 | tail -10`
Expected: 5 new FAIL.

- [ ] **Step 3: Insert `_install_lib_source` helper in install.sh**

Locate the section just BEFORE `# ---------- Step 1: preflight ----------` (currently L580). Insert:

```bash
# ---------- Phase 4.1: lib module loader ----------
# Resolves a lib/install-*.sh module via lookup order:
#   1. $INSTALL_LIB_DIR/<name>         (operator override / test)
#   2. /usr/local/lib/partner-edge/<name>   (FHS default, set by release tarball)
#   3. $(dirname "$0")/lib/<name>       (dev / running from checkout)
#   4. fetch $REPO_RAW/lib/<name>       (curl|bash flow, no tarball on disk yet)
_install_lib_source() {
    local name=$1
    local candidate
    for candidate in \
        "${INSTALL_LIB_DIR:-}/$name" \
        "/usr/local/lib/partner-edge/$name" \
        "$(dirname "$0")/lib/$name"; do
        [[ -n "$candidate" ]] || continue
        if [[ -r "$candidate" ]]; then
            # shellcheck source=/dev/null
            . "$candidate"
            return 0
        fi
    done
    # Fallback: fetch from REPO_RAW (curl|bash flow without tarball)
    local tmp
    tmp=$(mktemp)
    if curl -fsSL --proto '=https' --tlsv1.2 --max-time 30 \
        "${REPO_RAW}/lib/$name" -o "$tmp"; then
        # shellcheck source=/dev/null
        . "$tmp"
        rm -f "$tmp"
        return 0
    fi
    rm -f "$tmp"
    die "lib module $name not found in INSTALL_LIB_DIR / /usr/local/lib/partner-edge / \$(dirname \$0)/lib and fetch from \$REPO_RAW failed"
}

_install_lib_source install-preflight.sh
_install_lib_source install-deps.sh
```

- [ ] **Step 4: Replace L580-691 (Step 1 + 1b + 1c) with `preflight_run`**

Delete the entire block from `# ---------- Step 1: preflight ----------` through the closing `fi` of `# ---------- Step 1c: dnf cache sanity ----------` (was ~111 LoC). Insert:

```bash
preflight_run
```

- [ ] **Step 5: Replace L693-734 (Step 1b' + Step 2) with `deps_install`**

Delete `# ---------- Step 1b: runtime deps (jq, curl) ----------` through the closing `fi`/`else`/`fi` block of `# ---------- Step 2: Docker ----------` (was ~42 LoC). Insert:

```bash
deps_install
```

- [ ] **Step 6: Verify syntax + shellcheck**

```bash
bash -n install.sh
shellcheck install.sh
```

Expected: clean; no NEW warnings vs `origin/main` (the existing warning count should not increase).

- [ ] **Step 7: Run parity bats — 5 NEW PASS, all prior tests still PASS**

```bash
bats tests/test_install_opec_parity.sh 2>&1 | tail -10
bats tests/test_install_preflight_module.sh 2>&1 | tail -5
bats tests/test_install_deps_module.sh 2>&1 | tail -5
```

Expected: all green.

- [ ] **Step 8: Run full bats suite — every previously-green test stays green**

```bash
bats tests/test_render_template_golden.sh \
     tests/test_install_render_identical.sh \
     tests/test_hydrate_render_identical.sh \
     tests/test_update_uses_lib.sh \
     tests/test_release_assets.sh \
     tests/test_installer_bootstrap.sh \
     tests/test_install_opec_parity.sh \
     tests/test_install_preflight_module.sh \
     tests/test_install_deps_module.sh 2>&1 | tail -15
```

Expected: all PASS.

- [ ] **Step 9: install.sh LoC sanity check**

```bash
wc -l install.sh
```

Expected: 1991 → ~1840 (149-155 LoC removed plus ~30 LoC of `_install_lib_source` helper added = net ~120 LoC reduction; absolute count between 1850-1880 acceptable).

- [ ] **Step 10: Commit**

```bash
git add install.sh tests/test_install_opec_parity.sh
git commit -m "feat(install): wire preflight + deps modules into install.sh

Phase 4.1 Task 3 — install.sh sources lib/install-preflight.sh
and lib/install-deps.sh via _install_lib_source helper (lookup:
\$INSTALL_LIB_DIR -> /usr/local/lib/partner-edge -> \$(dirname \$0)/lib
-> \$REPO_RAW fetch). Inline Step 1/1b/1c/1b'/Step 2 blocks replaced
by preflight_run / deps_install function calls.

install.sh net: ~155 LoC removed, ~30 LoC helper added.
Phase 4 roadmap LoC ledger: 1991 -> ~1840."
```

---

## Task 4: Bundle `lib/` in release tarball

**Files:**
- Modify: `.github/workflows/release.yml` (find the tarball-pack step, add `lib/`)
- Modify: `tests/test_release_assets.sh` (assert `lib/install-*.sh` present in tarball)

- [ ] **Step 1: Modify `tests/test_release_assets.sh` — add lib/ assertions**

Append after existing assertions (look for the `@test` block that asserts `install.sh` in tarball):

```bash
@test "release tarball contains lib/install-preflight.sh" {
    skip_unless_release_assets_present
    tar -tzf "$RELEASE_TARBALL" | grep -qE '(^|/)lib/install-preflight\.sh$'
}

@test "release tarball contains lib/install-deps.sh" {
    skip_unless_release_assets_present
    tar -tzf "$RELEASE_TARBALL" | grep -qE '(^|/)lib/install-deps\.sh$'
}
```

(Helper `skip_unless_release_assets_present` already in the file; reuse.)

- [ ] **Step 2: Run test — 2 FAIL expected (tarball doesn't include lib/ yet)**

Run: `bats tests/test_release_assets.sh 2>&1 | tail -10`
Expected: 2 new FAIL (or SKIP if no local tarball — that's also acceptable; CI is the gate).

- [ ] **Step 3: Locate and modify release.yml tarball-pack step**

Read `.github/workflows/release.yml`. Find the step that creates the `partner-edge-vX.Y.Z.tar.gz` asset (likely a `run: tar -czf ...` line). Extend its file list:

```yaml
        run: |
          tar -czf "partner-edge-${TAG}.tar.gz" \
              install.sh bootstrap.sh update.sh \
              lib/ \
              channel-render-lib.sh \
              # ...preserve existing files
```

If a release-please / cargo-dist tool generates the tarball, find that tool's config (likely `release-plz.toml`, `cargo-dist.toml`, or `dist-workspace.toml`) and add `lib/` to its `include` list.

- [ ] **Step 4: Verify yaml syntax**

```bash
python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))" && echo "yaml ok"
```

Expected: `yaml ok`.

- [ ] **Step 5: Local dry-run of tarball build (if step is shell-runnable)**

If the release.yml tarball step is a plain `tar` invocation, replicate it locally:

```bash
TAG=dryrun bash -c "tar -czf /tmp/partner-edge-dryrun.tar.gz install.sh lib/ tests/"
tar -tzf /tmp/partner-edge-dryrun.tar.gz | grep '^lib/'
```

Expected: `lib/install-preflight.sh`, `lib/install-deps.sh` listed.

- [ ] **Step 6: Commit**

```bash
git add .github/workflows/release.yml tests/test_release_assets.sh
git commit -m "feat(release): bundle lib/ modules in release tarball

Phase 4.1 Task 4 — Phase 4 decomposition introduces sourced bash
modules under lib/. Release tarball must ship them so installs
landing on /usr/local/lib/partner-edge/ via the canonical path
(no REPO_RAW fallback needed for tarball flow)."
```

---

## Acceptance gate

After all 4 tasks merged:

- [ ] `bats tests/` full suite passes (existing + 3 new module/parity tests)
- [ ] `wc -l install.sh` reports 1840 ± 30 LoC
- [ ] `shellcheck install.sh lib/*.sh` — no NEW warnings vs `origin/main`
- [ ] Cheburator soak: install.sh tarball flow re-runs to convergence (idempotent) without `lib/` REPO_RAW fallback firing — log `[1/10] preflight checks` line still present + Phase 4.1 helper line `lib module install-preflight.sh resolved via /usr/local/lib/partner-edge` (debug log optional, can be one-line `log "  loaded $name from $candidate"` if useful)

## Risk register (Phase 4.1)

| Risk | Detection | Mitigation |
|------|-----------|------------|
| `set -euo pipefail` propagation across `source` breaks module | bats `assert_failure` on injected `false` | module functions use `local` for all vars; no `set -e` toggles inside |
| `OS_RELEASE_PATH` test hook leaks into prod | Code review | hook is `${OS_RELEASE_PATH:-/etc/os-release}` — default is canonical, override env-only |
| REPO_RAW fetch fails on Russian edges (Cloudflare path blocked) | install.sh log `die "lib module ... fetch failed"` | tarball flow is the prod default; fetch fallback is only for `curl|bash` |
| Module variable scope collides with install.sh globals | shellcheck + bats `OS_FAMILY` assertion | modules export via globals by design; documented at top of each module |

## Commit summary (4 commits, single PR)

```
feat(install): extract preflight into lib/install-preflight.sh
feat(install): extract deps_install into lib/install-deps.sh
feat(install): wire preflight + deps modules into install.sh
feat(release): bundle lib/ modules in release tarball
```

PR title: `feat(install): Phase 4.1 — extract preflight + deps into lib/ modules`
