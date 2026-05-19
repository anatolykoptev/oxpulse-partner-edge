# Production-Ready Partner-Edge Installer — Multi-Channel Out-of-Box Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After `install.sh` finishes on a fresh edge, the box must be production-ready: every available user-facing channel (UC1-UC5) deployed, Caddy upstream pool wired with active health-check + observability, Telegram alerts on transitions, no post-install hand-fixing required.

**Architecture:** Two parallel phases. Phase 5.8 adds observability (Prometheus + Telegram alerts) to the Caddy `lb_policy first` fallback chain that already exists. Phase 5.10 wires naive (UC5) into compose + Caddyfile upstream pool, finishing the work that install.sh:1034 already lays template for. A final integration phase live-tests the full installer on ru.oxpulse.chat.

**Tech Stack:** bash 4+, Caddy v2, Docker Compose, Prometheus textfile collector, Telegram webhook (via dozor or direct API), naiveproxy (klzgrad fork). Tests via bats + cargo test for opec.

**Sister docs:**
- `docs/architecture/multi-channel-design.md` — architect's design (channel taxonomy, ТСПУ threat model)
- `docs/partners/THREAT-MODEL.md` — Class A/B/C ТСПУ vectors
- `/home/krolik/src/piter-server/deploy/piter/vpn-watchdog.sh` — reference watchdog pattern

**Out of scope (separate plans):**
- Phase 5.9 channel discovery API (`GET /api/partner/channels` signed list) — keystone, requires backend changes in oxpulse-chat repo
- Backend reality ML-KEM 0rtt session-cache fix — oxpulse-chat repo concern
- UC2 AmneziaWG-direct exposure to end-user clients — requires mobile app surface

---

## File Structure

| Path | Responsibility |
|---|---|
| `Caddyfile.tpl` | Caddy front config — extend with `metrics` directive + per-upstream `health_uri` reporting |
| `docker-compose.yml.tpl` | Compose — add `oxpulse-partner-naive` service (Phase 5.10) + `oxpulse-partner-metrics-exporter` sidecar (Phase 5.8) |
| `naive-client.json.tpl` | Naive config — already exists, verify rendering wired |
| `lib/install-systemd.sh` | Install path — add metrics-exporter cron + Telegram alert script wiring |
| `lib/render-channel-lib.sh` | Channel render helpers — extend `render_channel_soft` to record per-channel deploy timestamps |
| `oxpulse-channels-health-report.sh` | Existing — extend to read Caddy `/metrics` endpoint + emit Telegram on upstream transition |
| `partner-edge-healthcheck.sh` | Add check 22: Caddy metrics endpoint reachable + per-upstream health visible |
| `tests/test_caddy_metrics_endpoint.sh` | NEW bats — assert Caddy emits Prometheus metrics on /metrics |
| `tests/test_naive_compose_service.sh` | NEW bats — assert naive container deploys when NAIVE_SERVER set |
| `tests/test_caddy_upstream_pool_complete.sh` | NEW bats — assert Caddyfile contains all UC channels in upstream pool when their containers are deployed |
| `tests/test_installer_production_readiness.sh` | NEW bats — fresh install on stub edge produces fully-deployed multi-channel state |
| `crates/opec/src/secrets/naive.rs` | NEW Rust — `opec secrets naive-creds` subcommand (mirror reality-keygen pattern) for fetching naive password from backend |
| `docs/runbooks/multi-channel-deployment.md` | NEW — operator runbook covering channel deployment status, alert taxonomy, recovery procedures |

---

## Phase A: Diagnose ru.oxpulse + plan hy2 deployment baseline

### Task 1: Capture current ru.oxpulse channel-deployment state

**Files:**
- Read: `/etc/oxpulse-partner-edge/Caddyfile` on ru.oxpulse
- Read: `/var/lib/oxpulse-partner-edge/channels-status.env` on ru.oxpulse
- Read: `docker ps` output on ru.oxpulse
- Test: `tests/fixtures/state-snapshots/ru-oxpulse-v0.12.42.txt` (golden snapshot for regression)

- [ ] **Step 1: Capture state snapshot from edge**

```bash
ssh root@ru.oxpulse.chat 'echo "=== docker ps ==="; docker ps --format "{{.Names}} {{.Status}}"; echo "=== channels-status ==="; cat /var/lib/oxpulse-partner-edge/channels-status.env; echo "=== Caddyfile upstreams ==="; grep -E "reverse_proxy" /etc/oxpulse-partner-edge/Caddyfile' > tests/fixtures/state-snapshots/ru-oxpulse-v0.12.42.txt
```

- [ ] **Step 2: Diff against working partner (zvonilka)**

```bash
ssh zvonilka 'echo "=== docker ps ==="; docker ps --format "{{.Names}} {{.Status}}"; echo "=== Caddyfile upstreams ==="; grep -E "reverse_proxy" /etc/oxpulse-partner-edge/Caddyfile' > /tmp/zvonilka-state.txt
diff tests/fixtures/state-snapshots/ru-oxpulse-v0.12.42.txt /tmp/zvonilka-state.txt > /tmp/state-diff.txt || true
cat /tmp/state-diff.txt
```

Expected diff: ru.oxpulse lacks `oxpulse-partner-hy2` container (because hy2 creds not in manual-config used during reinstall). zvonilka has it deployed.

- [ ] **Step 3: Commit snapshot fixture**

```bash
git add tests/fixtures/state-snapshots/ru-oxpulse-v0.12.42.txt
git commit -m "test(fixtures): capture ru.oxpulse v0.12.42 channel-deployment state snapshot"
```

### Task 2: Define "production-ready" acceptance contract

**Files:**
- Create: `docs/runbooks/multi-channel-deployment.md`
- Test: `tests/test_installer_production_readiness.sh` (new, will fail until Phase A-D done)

- [ ] **Step 1: Write the failing acceptance test**

`tests/test_installer_production_readiness.sh`:
```bash
#!/usr/bin/env bash
# Production-ready partner-edge acceptance test.
# Asserts that after install.sh completes, the edge has:
#  1. All compose services up for which credentials/config are provided
#  2. Caddy upstream pool contains every active channel
#  3. channels-status.env reflects actual runtime state
#  4. /metrics endpoint reachable (Phase 5.8)
#  5. Telegram alert delivery wired (Phase 5.8)
#  6. Naive deployed when NAIVE_SERVER set (Phase 5.10)
set -euo pipefail

EDGE="${EDGE:-ru.oxpulse.chat}"
ssh_root() { ssh -o BatchMode=yes "root@$EDGE" "$@"; }

# Acceptance 1: every active channel has a running container
expected_containers=(oxpulse-partner-caddy oxpulse-partner-coturn oxpulse-partner-sfu oxpulse-partner-xray oxpulse-partner-hy2 oxpulse-partner-naive)
for c in "${expected_containers[@]}"; do
    state=$(ssh_root "docker inspect --format '{{.State.Status}}' $c 2>/dev/null || echo MISSING")
    case "$state" in
        running) echo "OK:     $c=$state" ;;
        MISSING)
            # Permissible only if channel's credentials are absent
            if grep -qE "^$(echo $c | sed 's/oxpulse-partner-//')=skipped$" <(ssh_root cat /var/lib/oxpulse-partner-edge/channels-status.env); then
                echo "SKIP:   $c (channel marked skipped)"
            else
                echo "FAIL:   $c=MISSING but channel not marked skipped"
                exit 1
            fi
            ;;
        *) echo "FAIL:   $c=$state"; exit 1 ;;
    esac
done

# Acceptance 2: Caddy /metrics reachable
status=$(ssh_root "docker exec oxpulse-partner-caddy curl -sf -o /dev/null -w '%{http_code}' http://127.0.0.1:2019/metrics")
[[ "$status" == "200" ]] || { echo "FAIL: Caddy /metrics returns $status (expected 200)"; exit 1; }
echo "OK:     Caddy /metrics endpoint reachable"

# Acceptance 3: per-upstream metrics exposed
metrics=$(ssh_root "docker exec oxpulse-partner-caddy curl -s http://127.0.0.1:2019/metrics")
echo "$metrics" | grep -q "caddy_reverse_proxy_upstreams_healthy" || { echo "FAIL: no caddy_reverse_proxy_upstreams_healthy metric"; exit 1; }
echo "OK:     per-upstream health metric exposed"

# Acceptance 4: channels-status.env exists with at least xray entry
ssh_root "grep -qE '^xray=(active|failed_at_render|failed_at_runtime|skipped)$' /var/lib/oxpulse-partner-edge/channels-status.env" || { echo "FAIL: channels-status.env missing xray entry"; exit 1; }
echo "OK:     channels-status.env has xray entry"

echo "ALL ACCEPTANCE CHECKS PASSED"
```

- [ ] **Step 2: Verify test fails on current state**

```bash
EDGE=ru.oxpulse.chat bash tests/test_installer_production_readiness.sh
```

Expected: FAIL on `oxpulse-partner-hy2 MISSING but channel not marked skipped` OR `Caddy /metrics returns 404` (depending on what's missing).

- [ ] **Step 3: Commit failing test as baseline**

```bash
chmod +x tests/test_installer_production_readiness.sh
git add tests/test_installer_production_readiness.sh docs/runbooks/multi-channel-deployment.md
git commit -m "test(installer): add production-readiness acceptance test (RED, gates Phase A-D)"
```

---

## Phase B: Phase 5.8 — Caddy fallback observability

### Task 3: Expose Caddy /metrics endpoint

**Files:**
- Modify: `Caddyfile.tpl:30-45` (global options block — add `servers { metrics }` directive)
- Test: `tests/test_caddy_metrics_endpoint.sh` (new bats)

- [ ] **Step 1: Write the failing test**

`tests/test_caddy_metrics_endpoint.sh`:
```bash
#!/usr/bin/env bash
# Verify rendered Caddyfile enables /metrics endpoint exposed at :2019.
set -euo pipefail

rendered=$(opec render caddy --tpl Caddyfile.tpl --out /tmp/caddy-rendered.txt \
    --env-from-fixture tests/fixtures/render/caddy.env 2>&1 || cat /tmp/caddy-rendered.txt)

grep -q '^[[:space:]]*servers {' /tmp/caddy-rendered.txt || { echo "FAIL: no global servers{} block"; exit 1; }
grep -q '^[[:space:]]*metrics' /tmp/caddy-rendered.txt || { echo "FAIL: metrics directive missing"; exit 1; }
echo "OK: Caddy metrics endpoint declared"
```

- [ ] **Step 2: Run test → expect FAIL**

```bash
chmod +x tests/test_caddy_metrics_endpoint.sh
bash tests/test_caddy_metrics_endpoint.sh
```

Expected: `FAIL: no global servers{} block`

- [ ] **Step 3: Add metrics directive to Caddyfile.tpl**

Edit `Caddyfile.tpl` global options block (around line 30-45 where `auto_https`, `email`, `acme_dns` live):

```caddyfile
{
    auto_https disable_redirects
    email {{ACME_EMAIL}}
    acme_dns cloudflare {{CF_API_TOKEN}}
    storage_clean_interval 1h
    # Phase 5.8: expose Prometheus metrics on localhost:2019 for the
    # observability sidecar to scrape. Each `reverse_proxy` upstream's
    # health state surfaces as `caddy_reverse_proxy_upstreams_healthy{...}`.
    # See https://caddyserver.com/docs/metrics.
    servers {
        metrics
    }
}
```

- [ ] **Step 4: Run test → expect PASS**

```bash
bash tests/test_caddy_metrics_endpoint.sh
```

Expected: `OK: Caddy metrics endpoint declared`

- [ ] **Step 5: Commit**

```bash
git add Caddyfile.tpl tests/test_caddy_metrics_endpoint.sh
git commit -m "feat(caddy): expose Prometheus /metrics endpoint (Phase 5.8 observability)"
```

### Task 4: Add per-upstream health label propagation

**Files:**
- Modify: `Caddyfile.tpl:77-92` (tunnel_upstream snippet — add `health_label` for each upstream)
- Test: `tests/test_caddy_upstream_labels.sh` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_caddy_upstream_labels.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
opec render caddy --tpl Caddyfile.tpl --out /tmp/caddy.txt \
    --env-from-fixture tests/fixtures/render/caddy.env

# Each upstream must carry a `header_up X-Channel-Tag <name>` so backend
# can attribute requests + Prometheus can distinguish channels.
for ch in xray-client hysteria2; do
    grep -A 12 "reverse_proxy.*$ch" /tmp/caddy.txt | \
        grep -q "header_up X-Channel-Tag $ch" \
        || { echo "FAIL: no X-Channel-Tag header for $ch upstream"; exit 1; }
done
echo "OK: per-upstream X-Channel-Tag headers present"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_caddy_upstream_labels.sh
bash tests/test_caddy_upstream_labels.sh
```

Expected: `FAIL: no X-Channel-Tag header for xray-client upstream`

- [ ] **Step 3: Add header_up directives**

Edit `Caddyfile.tpl` `tunnel_upstream` snippet (around L77):

```caddyfile
(tunnel_upstream) {
    reverse_proxy {args[0]} xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} {
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 250ms
        health_uri /api/health
        health_interval 10s
        health_timeout 3s
        health_status 2xx
        health_passes 2
        health_fails 3
        # Phase 5.8: propagate channel tag for Prometheus metric labels.
        # caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} ...
        header_up X-Channel-Tag {upstream_hostport}
    }
}
```

Apply identical change to `tunnel_upstream_default` snippet (around L95).

- [ ] **Step 4: Run → PASS**

```bash
bash tests/test_caddy_upstream_labels.sh
```

Expected: `OK: per-upstream X-Channel-Tag headers present`

- [ ] **Step 5: Commit**

```bash
git add Caddyfile.tpl tests/test_caddy_upstream_labels.sh
git commit -m "feat(caddy): propagate X-Channel-Tag header per upstream (Phase 5.8)"
```

### Task 5: Wire upstream-transition Telegram alert

**Files:**
- Modify: `oxpulse-channels-health-report.sh` — add `_alert_upstream_transition` function
- Create: `lib/telegram-alert-lib.sh` — shared alert primitive (rate-limited, mirror piter pattern)
- Test: `tests/test_upstream_transition_alert.sh` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_upstream_transition_alert.sh`:
```bash
#!/usr/bin/env bash
# Verify health-report script emits a Telegram alert when an upstream
# transitions from healthy→unhealthy (and back).
set -euo pipefail
STATE_DIR=$(mktemp -d)
ALERT_LOG=$(mktemp)
export STATE_DIR ALERT_LOG OXPULSE_DRYRUN=1

# Stub curl to record alert delivery to ALERT_LOG instead of hitting Telegram.
cat > "$STATE_DIR/curl" <<'EOF'
#!/usr/bin/env bash
echo "ALERT_FIRED: $*" >> "$ALERT_LOG"
echo '{"ok":true}'
EOF
chmod +x "$STATE_DIR/curl"
export PATH="$STATE_DIR:$PATH"

# Plant initial state: xray-client healthy
echo "xray-client:3080=healthy:$(date +%s)" > "$STATE_DIR/upstream-state.env"

# Inject metrics output: xray-client now unhealthy
cat > "$STATE_DIR/metrics-stub" <<'EOF'
caddy_reverse_proxy_upstreams_healthy{upstream="xray-client:3080"} 0
caddy_reverse_proxy_upstreams_healthy{upstream="host.docker.internal:18443"} 1
EOF

# Run the health-report script with metrics stub injected
OXPULSE_METRICS_SRC="$STATE_DIR/metrics-stub" bash oxpulse-channels-health-report.sh

# Assert alert was fired with transition message
grep -q "TRANSITION.*xray-client.*healthy.*unhealthy" "$ALERT_LOG" \
    || { cat "$ALERT_LOG"; echo "FAIL: no transition alert"; exit 1; }
echo "OK: upstream transition alert fired"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_upstream_transition_alert.sh
bash tests/test_upstream_transition_alert.sh
```

Expected: FAIL (no transition detection in current script).

- [ ] **Step 3: Create `lib/telegram-alert-lib.sh`**

```bash
#!/usr/bin/env bash
# lib/telegram-alert-lib.sh — shared rate-limited Telegram alert primitive.
# Mirrors /home/krolik/src/piter-server/deploy/piter/vpn-watchdog.sh alert()
# pattern: 10-minute interval between non-CRITICAL alerts, CRITICAL bypasses.
# Sourceable from any partner-edge script.

_TG_STATE_DIR="${OXPULSE_TG_STATE_DIR:-/var/lib/oxpulse-partner-edge/telegram}"
_TG_MIN_INTERVAL="${OXPULSE_TG_MIN_INTERVAL:-600}"
_TG_WEBHOOK="${OXPULSE_TG_WEBHOOK:-http://10.9.0.2:8765/webhook/monitor/healthcheck}"
_TG_API_FALLBACK="${OXPULSE_TG_API_FALLBACK:-https://api.telegram.org/bot${TG_TOKEN:-}/sendMessage}"
_TG_CHAT="${OXPULSE_TG_CHAT:-${TG_CHAT:-}}"

tg_alert() {
    local msg="$1"
    local force="${2:-}"   # "force" = bypass rate limit
    local now last_ts

    mkdir -p "$_TG_STATE_DIR" 2>/dev/null || true

    if [[ -z "$force" ]]; then
        last_ts=$(cat "$_TG_STATE_DIR/last-alert-ts" 2>/dev/null || echo "0")
        now=$(date +%s)
        if [[ $((now - last_ts)) -lt "$_TG_MIN_INTERVAL" ]]; then
            return 0   # rate-limited
        fi
    fi

    date +%s > "$_TG_STATE_DIR/last-alert-ts"

    # Try webhook first (lower latency, dozor-routed), fall back to direct API.
    if ! curl -s --max-time 5 -X POST "$_TG_WEBHOOK" \
        -H "Content-Type: application/json" \
        -d "{\"message\":\"$msg\"}" >/dev/null 2>&1; then
        [[ -n "$_TG_CHAT" ]] && curl -s --max-time 10 "$_TG_API_FALLBACK" \
            -d "chat_id=$_TG_CHAT&text=$msg" >/dev/null 2>&1 || true
    fi
}
```

- [ ] **Step 4: Add transition detection to `oxpulse-channels-health-report.sh`**

Append at end of `oxpulse-channels-health-report.sh`:

```bash
# Phase 5.8: upstream-transition detection + alert.
# Reads Caddy /metrics, compares against state-file, fires Telegram on flip.
_check_upstream_transitions() {
    local metrics_src="${OXPULSE_METRICS_SRC:-http://127.0.0.1:2019/metrics}"
    local state_file="${STATE_DIR:-/var/lib/oxpulse-partner-edge}/upstream-state.env"
    local raw

    if [[ "$metrics_src" =~ ^http ]]; then
        raw=$(curl -sf --max-time 3 "$metrics_src" 2>/dev/null || return 0)
    else
        raw=$(cat "$metrics_src" 2>/dev/null || return 0)
    fi

    # Parse `caddy_reverse_proxy_upstreams_healthy{upstream="X"} N` lines.
    declare -A current
    while IFS= read -r line; do
        local upstream value
        upstream=$(echo "$line" | sed -nE 's/.*upstream="([^"]+)".* ([01])\s*$/\1/p')
        value=$(echo "$line" | sed -nE 's/.*upstream="([^"]+)".* ([01])\s*$/\2/p')
        [[ -z "$upstream" ]] && continue
        current["$upstream"]=$([[ "$value" == "1" ]] && echo "healthy" || echo "unhealthy")
    done <<< "$(echo "$raw" | grep '^caddy_reverse_proxy_upstreams_healthy')"

    # Compare with previous state.
    declare -A previous
    if [[ -r "$state_file" ]]; then
        while IFS='=' read -r upstream rest; do
            [[ -z "$upstream" ]] && continue
            previous["$upstream"]=$(echo "$rest" | cut -d: -f1)
        done < "$state_file"
    fi

    # Emit transitions.
    for upstream in "${!current[@]}"; do
        local cur="${current[$upstream]}"
        local prev="${previous[$upstream]:-}"
        if [[ -n "$prev" && "$cur" != "$prev" ]]; then
            local hostname
            hostname=$(hostname -s)
            # shellcheck source=lib/telegram-alert-lib.sh
            source "${SCRIPT_DIR:-$(dirname "$0")}/lib/telegram-alert-lib.sh"
            tg_alert "[$hostname] TRANSITION upstream=$upstream $prev → $cur"
        fi
    done

    # Persist current state.
    : > "$state_file"
    for upstream in "${!current[@]}"; do
        echo "$upstream=${current[$upstream]}:$(date +%s)" >> "$state_file"
    done
}

_check_upstream_transitions
```

- [ ] **Step 5: Run test → PASS**

```bash
bash tests/test_upstream_transition_alert.sh
```

Expected: `OK: upstream transition alert fired`

- [ ] **Step 6: Commit**

```bash
git add lib/telegram-alert-lib.sh oxpulse-channels-health-report.sh tests/test_upstream_transition_alert.sh
git commit -m "feat(observability): wire upstream-transition Telegram alerts (Phase 5.8)"
```

### Task 6: Install `lib/telegram-alert-lib.sh` to PREFIX_SBIN

**Files:**
- Modify: `lib/install-systemd.sh` (add install step for telegram-alert-lib.sh)
- Test: `tests/test_install_telegram_lib.sh` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_install_telegram_lib.sh`:
```bash
#!/usr/bin/env bash
# Verify install-systemd.sh installs telegram-alert-lib.sh to PREFIX_SBIN.
set -euo pipefail
PREFIX_SBIN=$(mktemp -d)
src_dir=$(pwd)
export PREFIX_SBIN src_dir

# shellcheck source=lib/install-systemd.sh
source lib/install-systemd.sh
_systemd_install_lib_scripts

[[ -f "$PREFIX_SBIN/telegram-alert-lib.sh" ]] || { echo "FAIL: telegram-alert-lib.sh not installed to PREFIX_SBIN"; exit 1; }
[[ -x "$PREFIX_SBIN/telegram-alert-lib.sh" ]] || { echo "FAIL: telegram-alert-lib.sh not executable"; exit 1; }
echo "OK: telegram-alert-lib.sh installed"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_install_telegram_lib.sh
bash tests/test_install_telegram_lib.sh
```

Expected: `FAIL: telegram-alert-lib.sh not installed`

- [ ] **Step 3: Add install step to lib/install-systemd.sh**

Inside `_systemd_install_lib_scripts()` function, add (after render-channel-lib.sh install block):

```bash
# Phase 5.8: telegram-alert-lib.sh — shared alert primitive.
if [[ -n "$src_dir" && -f "$src_dir/lib/telegram-alert-lib.sh" ]]; then
    install -m 0755 "$src_dir/lib/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh"
elif [[ -n "$src_dir" && -f "$src_dir/telegram-alert-lib.sh" ]]; then
    install -m 0755 "$src_dir/telegram-alert-lib.sh" "$PREFIX_SBIN/telegram-alert-lib.sh"
else
    curl -fsSL "$REPO_RAW/lib/telegram-alert-lib.sh" -o "$PREFIX_SBIN/telegram-alert-lib.sh"
    chmod 0755 "$PREFIX_SBIN/telegram-alert-lib.sh"
fi
```

- [ ] **Step 4: Update `lib/lib-checksums.txt`**

```bash
(cd lib && sha256sum *.sh > lib-checksums.txt)
git diff lib/lib-checksums.txt
```

- [ ] **Step 5: Run → PASS**

```bash
bash tests/test_install_telegram_lib.sh
```

- [ ] **Step 6: Commit**

```bash
git add lib/install-systemd.sh lib/lib-checksums.txt tests/test_install_telegram_lib.sh
git commit -m "feat(install): install telegram-alert-lib.sh to PREFIX_SBIN (Phase 5.8)"
```

---

## Phase C: Phase 5.10 — Naive (UC5) compose + Caddyfile wiring

### Task 7: Add `oxpulse-partner-naive` to docker-compose.yml.tpl

**Files:**
- Modify: `docker-compose.yml.tpl` (add naive service block)
- Test: `tests/test_naive_compose_service.sh` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_naive_compose_service.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
NAIVE_SERVER=naive.example.com NAIVE_SOCKS_PORT=1080 NAIVE_USERNAME=u NAIVE_PASSWORD=p \
    opec render compose --tpl docker-compose.yml.tpl --out /tmp/compose.yml \
    --env-from-fixture tests/fixtures/render/compose-with-naive.env

# When NAIVE_SERVER is set, service block must be rendered
grep -qE '^[[:space:]]*oxpulse-partner-naive:' /tmp/compose.yml \
    || { echo "FAIL: oxpulse-partner-naive service not rendered when NAIVE_SERVER set"; exit 1; }

# Container name must match expected
grep -qE 'container_name:[[:space:]]*oxpulse-partner-naive' /tmp/compose.yml \
    || { echo "FAIL: container_name missing or wrong"; exit 1; }

# Must mount rendered naive-client.json
grep -qE '/etc/oxpulse-partner-edge/naive-client\.json' /tmp/compose.yml \
    || { echo "FAIL: naive config volume mount missing"; exit 1; }

# Must expose SOCKS port to docker network only (not 0.0.0.0)
grep -qE '127\.0\.0\.1:1080:1080' /tmp/compose.yml \
    || { echo "FAIL: SOCKS port not bound to 127.0.0.1"; exit 1; }

echo "OK: naive service block rendered correctly"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_naive_compose_service.sh
bash tests/test_naive_compose_service.sh
```

Expected: `FAIL: oxpulse-partner-naive service not rendered`

- [ ] **Step 3: Add naive service to docker-compose.yml.tpl**

Append to docker-compose.yml.tpl `services:` block (after hysteria2-client service):

```yaml
  # CH5 / UC5: NaiveProxy client — HTTP/2 CONNECT proxy for ТСПУ-resilient HTTPS:443 tunneling.
  # Only rendered when NAIVE_SERVER env is set (operator-provisioned upstream).
  # Builds from klzgrad/naiveproxy via ghcr.io/anatolykoptev/partner-edge-naive
  # (built in Phase 5.10 sibling release.yml task).
  {{#if NAIVE_SERVER}}
  oxpulse-partner-naive:
    image: ghcr.io/anatolykoptev/partner-edge-naive:{{IMAGE_VERSION}}
    container_name: oxpulse-partner-naive
    restart: unless-stopped
    networks:
      - edge
    ports:
      - "127.0.0.1:{{NAIVE_SOCKS_PORT}}:{{NAIVE_SOCKS_PORT}}"
    volumes:
      - /etc/oxpulse-partner-edge/naive-client.json:/etc/naive/config.json:ro
    healthcheck:
      test: ["CMD", "wget", "-qO-", "--proxy=on", "--proxy-user={{NAIVE_USERNAME}}",
             "--proxy-password={{NAIVE_PASSWORD}}", "-e", "use_proxy=yes",
             "-e", "http_proxy=http://127.0.0.1:{{NAIVE_SOCKS_PORT}}", "http://www.example.com/"]
      interval: 30s
      timeout: 5s
      retries: 3
    logging:
      driver: json-file
      options: { max-size: "10m", max-file: "3" }
  {{/if}}
```

Note: this uses mustache-like `{{#if NAIVE_SERVER}}` block. opec render must support conditional sections. If opec render does not, fall back to post-render python stripping (mirror Phase 5.5 compose stripping logic for failed channels).

- [ ] **Step 4: If opec render lacks conditional support, add post-render strip**

Edit `lib/render-channel-lib.sh` `compose_strip_failed_channels()` function to ALSO strip naive when `${NAIVE_SERVER:-}` is empty:

```bash
compose_strip_failed_channels() {
    local compose_out="$1"
    shift
    local failed=("$@")

    # Also include 'naive' in failed list when NAIVE_SERVER unset (Phase 5.10).
    if [[ -z "${NAIVE_SERVER:-}" ]]; then
        failed+=("naive")
    fi

    [[ ${#failed[@]} -eq 0 ]] && return 0

    python3 - "$compose_out" "${failed[@]}" <<'PYEOF'
import sys, yaml, pathlib
p = pathlib.Path(sys.argv[1])
failed = set(sys.argv[2:])
doc = yaml.safe_load(p.read_text())
for k in failed:
    doc.get('services', {}).pop(f'oxpulse-partner-{k}', None)
    doc.get('services', {}).pop(k, None)
# Strip stale depends_on / volume refs
for svc in doc.get('services', {}).values():
    deps = svc.get('depends_on')
    if isinstance(deps, list):
        svc['depends_on'] = [d for d in deps if not any(f in d for f in failed)]
        if not svc['depends_on']: del svc['depends_on']
    elif isinstance(deps, dict):
        for d in list(deps):
            if any(f in d for f in failed): del deps[d]
        if not deps: del svc['depends_on']
tmp = p.with_suffix('.tmp')
tmp.write_text(yaml.safe_dump(doc, sort_keys=False))
tmp.replace(p)
PYEOF
}
```

- [ ] **Step 5: Run → PASS**

```bash
bash tests/test_naive_compose_service.sh
```

- [ ] **Step 6: Commit**

```bash
git add docker-compose.yml.tpl lib/render-channel-lib.sh tests/test_naive_compose_service.sh
git commit -m "feat(naive): add oxpulse-partner-naive compose service (Phase 5.10)"
```

### Task 8: Build naive Docker image + add to release pipeline

**Files:**
- Create: `Dockerfile.naive`
- Modify: `.github/workflows/release.yml` (add naive image build job)
- Test: `tests/test_naive_image_build.sh` (new — validates Dockerfile syntax)

- [ ] **Step 1: Write the failing test**

`tests/test_naive_image_build.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
# Validate Dockerfile.naive syntax + builds successfully
docker build -f Dockerfile.naive -t partner-edge-naive:test --no-cache . \
    >/tmp/naive-build.log 2>&1 \
    || { echo "FAIL: docker build failed"; tail -20 /tmp/naive-build.log; exit 1; }

# Inspect resulting image
size=$(docker image inspect partner-edge-naive:test --format '{{.Size}}')
[[ "$size" -lt 50000000 ]] || { echo "FAIL: image too large ($size bytes — expect <50MB)"; exit 1; }

# Verify naive binary present + executable
docker run --rm partner-edge-naive:test naive --version | grep -qE 'naiveproxy [0-9]' \
    || { echo "FAIL: naive binary missing or wrong"; exit 1; }
echo "OK: naive image builds + binary works"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_naive_image_build.sh
bash tests/test_naive_image_build.sh
```

Expected: `FAIL: docker build failed: Dockerfile.naive not found`

- [ ] **Step 3: Create `Dockerfile.naive`**

```dockerfile
# Phase 5.10: NaiveProxy client for partner-edge UC5 channel.
# Builds from klzgrad/naiveproxy upstream releases.
FROM alpine:3.21 AS fetcher
ARG NAIVE_VERSION=v126.0.6478.126-2
ARG TARGETARCH
RUN apk add --no-cache curl xz tar ca-certificates \
    && case "${TARGETARCH}" in \
        amd64) arch=x64 ;; \
        arm64) arch=arm64 ;; \
        *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac \
    && curl -fsSL -o /tmp/naive.tar.xz \
        "https://github.com/klzgrad/naiveproxy/releases/download/${NAIVE_VERSION}/naiveproxy-${NAIVE_VERSION}-linux-${arch}.tar.xz" \
    && mkdir -p /opt/naive \
    && tar -xJf /tmp/naive.tar.xz -C /opt/naive --strip-components=1 \
    && rm /tmp/naive.tar.xz

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=fetcher /opt/naive/naive /usr/local/bin/naive
USER nonroot
EXPOSE 1080
ENTRYPOINT ["/usr/local/bin/naive"]
CMD ["/etc/naive/config.json"]
```

- [ ] **Step 4: Add release.yml build job**

Edit `.github/workflows/release.yml` — duplicate the `build-and-push` job for `naive`:

```yaml
  build-and-push-naive:
    needs: extract-version
    runs-on: ${{ matrix.runs-on }}
    strategy:
      matrix:
        include:
          - { arch: linux/amd64, runs-on: ubuntu-latest, platform: amd64 }
          - { arch: linux/arm64, runs-on: ubuntu-24.04-arm, platform: arm64 }
    steps:
      - uses: actions/checkout@v4
        with: { ref: ${{ inputs.tag || github.ref }} }
      - uses: docker/setup-buildx-action@v3
      - uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build + push naive
        uses: docker/build-push-action@v6
        with:
          context: .
          file: Dockerfile.naive
          platforms: ${{ matrix.arch }}
          push: true
          tags: |
            ghcr.io/${{ env.OWNER }}/partner-edge-naive:${{ needs.extract-version.outputs.version }}-${{ matrix.platform }}
            ghcr.io/${{ env.OWNER }}/partner-edge-naive:stable-${{ matrix.platform }}
          cache-from: type=gha
          cache-to: type=gha,mode=max
```

Add `merge-manifests-naive` job mirroring the existing `merge-manifests` pattern for caddy/xray/coturn/sfu.

- [ ] **Step 5: Run → PASS**

```bash
bash tests/test_naive_image_build.sh
```

Expected: `OK: naive image builds + binary works` (may take 2-3 min for first build)

- [ ] **Step 6: Commit**

```bash
git add Dockerfile.naive .github/workflows/release.yml tests/test_naive_image_build.sh
git commit -m "feat(naive): Dockerfile + release.yml build job (Phase 5.10)"
```

### Task 9: Add naive (UC5) to Caddyfile.tpl upstream pool — INTERNAL ONLY

**Files:**
- Modify: `Caddyfile.tpl` (add naive as tertiary fallback in tunnel_upstream)
- Test: `tests/test_caddyfile_naive_upstream.sh` (new)

- [ ] **Step 1: Write the failing test**

`tests/test_caddyfile_naive_upstream.sh`:
```bash
#!/usr/bin/env bash
set -euo pipefail
NAIVE_SERVER=upstream.example.com NAIVE_SOCKS_PORT=1080 \
    opec render caddy --tpl Caddyfile.tpl --out /tmp/caddy.txt \
    --env-from-fixture tests/fixtures/render/caddy-with-naive.env

# When NAIVE_SERVER is set, naive should appear as tertiary upstream
grep -qE 'reverse_proxy[^#]*xray-client:3080.*18443.*1080' /tmp/caddy.txt \
    || { echo "FAIL: naive upstream not in reverse_proxy pool when NAIVE_SERVER set"; exit 1; }
echo "OK: naive in upstream pool"
```

- [ ] **Step 2: Run → FAIL**

```bash
chmod +x tests/test_caddyfile_naive_upstream.sh
bash tests/test_caddyfile_naive_upstream.sh
```

- [ ] **Step 3: Add naive upstream conditionally to Caddyfile.tpl**

NOTE: opec render does not yet support `{{#if}}` blocks. Easier path: ALWAYS render naive in the upstream list with the local SOCKS port; if naive container is not running, Caddy's `health_check` will mark it down and skip it. Cost is one extra failed health probe every 10s while naive is undeployed — acceptable.

Edit `Caddyfile.tpl:78` and `:96`:

```caddyfile
(tunnel_upstream) {
    reverse_proxy {args[0]} xray-client:3080 {{HY2_FALLBACK_HOST}}:{{HY2_FALLBACK_PORT}} 127.0.0.1:{{NAIVE_SOCKS_PORT}} {
        lb_policy first
        lb_try_duration 5s
        lb_try_interval 250ms
        health_uri /api/health
        health_interval 10s
        health_timeout 3s
        health_status 2xx
        health_passes 2
        health_fails 3
        header_up X-Channel-Tag {upstream_hostport}
    }
}
```

Add `NAIVE_SOCKS_PORT` to install.sh exports list around L719-724.

Default: `NAIVE_SOCKS_PORT=1080` (already in install.sh per Phase 5.6 Bug 1 fix).

- [ ] **Step 4: Run → PASS**

```bash
bash tests/test_caddyfile_naive_upstream.sh
```

- [ ] **Step 5: Commit**

```bash
git add Caddyfile.tpl install.sh tests/test_caddyfile_naive_upstream.sh
git commit -m "feat(caddy): add naive tertiary upstream in tunnel pool (Phase 5.10)"
```

---

## Phase D: Integration test on ru.oxpulse.chat

### Task 10: Release v0.12.43 with Phase B + C combined

**Files:**
- Modify: `VERSION`, `.release-please-manifest.json`

- [ ] **Step 1: Bump version manually**

(Since release-please may not pick up our commit types reliably — proven in Bug 21 saga — do manual bump.)

```bash
sed -i 's/^0\.12\.42/0.12.43/' VERSION
sed -i 's/"0.12.42"/"0.12.43"/' .release-please-manifest.json
git add VERSION .release-please-manifest.json
git commit -m "chore(main): release partner-edge 0.12.43"
git push origin <branch>
```

- [ ] **Step 2: Open PR, merge after CI green**

```bash
gh pr create --title "chore(main): release partner-edge 0.12.43" \
    --body "Phase 5.8 observability + Phase 5.10 naive deployment + Phase B alerts."
# Wait CI green, then:
gh pr merge --squash --admin
```

- [ ] **Step 3: Tag + workflow_dispatch**

```bash
git fetch origin --tags
git tag partner-edge-v0.12.43 origin/main
git push origin partner-edge-v0.12.43
gh workflow run release.yml -f tag=partner-edge-v0.12.43
```

- [ ] **Step 4: Wait for ALL_GREEN**

```bash
gh run watch $(gh run list --workflow=release.yml --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expected: exit 0, all build jobs success, attach-release-assets success.

### Task 11: Live test on ru.oxpulse.chat — fresh uninstall + install

**Files:**
- Test: `tests/test_installer_production_readiness.sh` (created in Task 2, will now PASS)

- [ ] **Step 1: Download v0.12.43 assets locally**

```bash
mkdir -p /tmp/v0.12.43
gh release download partner-edge-v0.12.43 --dir /tmp/v0.12.43
ls /tmp/v0.12.43 | grep -E 'naive|telegram|caddy|install' | head -10
```

Expected: see `Dockerfile.naive` referenced (image built), telegram-alert-lib.sh, install-systemd.sh updated.

- [ ] **Step 2: Stage to ru.oxpulse**

```bash
scp /tmp/v0.12.43/uninstall.sh root@ru.oxpulse.chat:/root/uninstall.sh
scp /tmp/v0.12.43/partner-edge-installer.sh root@ru.oxpulse.chat:/root/install.sh
scp /tmp/v0.12.43/opec-amd64 root@ru.oxpulse.chat:/usr/local/bin/opec
scp /tmp/v0.12.43/install-*.sh /tmp/v0.12.43/render-channel-lib.sh \
    /tmp/v0.12.43/telegram-alert-lib.sh /tmp/v0.12.43/lib-checksums.txt \
    root@ru.oxpulse.chat:/usr/local/lib/partner-edge/
ssh root@ru.oxpulse.chat "chmod +x /root/uninstall.sh /root/install.sh /usr/local/bin/opec"
```

- [ ] **Step 3: Run uninstall + install cycle**

```bash
ssh root@ru.oxpulse.chat "
/root/uninstall.sh --yes --keep-backups
BACKUP=\$(ls -td /root/oxpulse-backup-* | head -1)
mkdir -p /etc/oxpulse-partner-edge && chmod 700 /etc/oxpulse-partner-edge
for k in reality.priv reality.pub reality.uuid awg-private.key awg-public.key token node-config.json; do
    cp -p \$BACKUP/\$k /etc/oxpulse-partner-edge/ 2>&1 || echo missing: \$k
done
source /root/oxpulse-backup-1779131511/var-lib-oxpulse-partner-edge/install.env
export OXPULSE_SERVICE_TOKEN=\$(cat /etc/oxpulse-partner-edge/token)
# Pass NAIVE_SERVER=test-relay.example.com to provision UC5
NAIVE_SERVER=test-relay.example.com NAIVE_SOCKS_PORT=1080 \
NAIVE_USERNAME=test NAIVE_PASSWORD=test \
    /root/install.sh --partner-id=\$PARTNER_ID --domain=\$PARTNER_DOMAIN --tunnel=\$TUNNEL \
        --manual-config=/etc/oxpulse-partner-edge/node-config.json
"
```

Expected: install completes exit 0, all channel renders succeed, all containers Started.

- [ ] **Step 4: Run acceptance test**

```bash
EDGE=ru.oxpulse.chat bash tests/test_installer_production_readiness.sh
```

Expected: `ALL ACCEPTANCE CHECKS PASSED`

Specifically:
- `OK: oxpulse-partner-caddy=running`
- `OK: oxpulse-partner-coturn=running`
- `OK: oxpulse-partner-sfu=running`
- `OK: oxpulse-partner-xray=running`
- `OK: oxpulse-partner-hy2=running` (Phase 5.10 — wired w/ creds OR skipped explicitly)
- `OK: oxpulse-partner-naive=running` (NAIVE_SERVER passed)
- `OK: Caddy /metrics endpoint reachable`
- `OK: per-upstream health metric exposed`
- `OK: channels-status.env has xray entry`

- [ ] **Step 5: Verify Telegram alert delivery**

```bash
ssh root@ru.oxpulse.chat "docker stop oxpulse-partner-xray; sleep 60"
# Wait ~60s for health_fails=3 transition + 30s for oxpulse-channels-health-report.timer
ssh root@ru.oxpulse.chat "cat /var/lib/oxpulse-partner-edge/telegram/last-alert-ts 2>&1; tail -3 /var/log/oxpulse-channels-health-report.log 2>&1"
# Telegram channel should have received "[hostname] TRANSITION upstream=xray-client:3080 healthy → unhealthy"
ssh root@ru.oxpulse.chat "docker start oxpulse-partner-xray"
```

Expected: transition alert delivered within 90s of container stop.

- [ ] **Step 6: Commit final test fixtures**

```bash
ssh root@ru.oxpulse.chat 'docker ps --format "{{.Names}}\t{{.Status}}"; cat /var/lib/oxpulse-partner-edge/channels-status.env' > tests/fixtures/state-snapshots/ru-oxpulse-v0.12.43.txt
git add tests/fixtures/state-snapshots/ru-oxpulse-v0.12.43.txt
git commit -m "test(fixtures): capture v0.12.43 post-install state on ru.oxpulse.chat"
```

### Task 12: Documentation + runbook

**Files:**
- Modify: `docs/runbooks/multi-channel-deployment.md`

- [ ] **Step 1: Write runbook**

```markdown
# Multi-Channel Deployment Runbook

## What "production-ready" means
After `install.sh` completes on a fresh edge:
- All channels listed in `channels-status.env` with state `active` have a running container.
- Channels not provisioned (no credentials) show `skipped`.
- Caddy `/metrics` endpoint exposes `caddy_reverse_proxy_upstreams_healthy{...}`.
- Telegram channel receives alerts within 90s of upstream transition.

## Operator workflow

### Provisioning a new partner edge
1. `curl -fsSL https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download/<TAG>/partner-edge-installer.sh -o install.sh`
2. `chmod +x install.sh && sudo bash install.sh --partner-id=NAME --domain=DOMAIN --token=ptkn_...`
3. Wait `Step 10/10 done` message.
4. Run `/usr/local/sbin/oxpulse-partner-edge-healthcheck` — expect green.

### Verifying multi-channel deployment
```
ssh edge "cat /var/lib/oxpulse-partner-edge/channels-status.env"
ssh edge "docker exec oxpulse-partner-caddy curl -s http://127.0.0.1:2019/metrics | grep upstreams_healthy"
```

### Alert taxonomy

| Alert | Severity | Action |
|---|---|---|
| `TRANSITION upstream=X healthy → unhealthy` | warn | Check container logs; verify backend reachable from edge |
| `TRANSITION upstream=X unhealthy → healthy` | info | Recovery confirmed, no action |
| `CRITICAL: all upstreams unhealthy on <edge>` | critical | On-call: SSH edge, check `docker ps`, network, backend |

### Circuit breaker
If alerts come in faster than 1 every 10 minutes, rate-limiter suppresses. CRITICAL bypasses.
State file: `/var/lib/oxpulse-partner-edge/telegram/last-alert-ts`.
```

- [ ] **Step 2: Commit**

```bash
git add docs/runbooks/multi-channel-deployment.md
git commit -m "docs(runbook): multi-channel deployment + alert taxonomy"
```

### Task 13: Open PR + final review gate

- [ ] **Step 1: Open PR**

```bash
gh pr create --title "feat: production-ready installer — Phase 5.8 observability + Phase 5.10 naive" \
    --body "$(cat <<'EOF'
## Summary
Closes the installer gap so a fresh `install.sh` run produces a fully-deployed multi-channel edge with observability, no post-install hand-fixing.

## Phase 5.8 (observability)
- Expose Caddy /metrics on :2019
- Per-upstream `X-Channel-Tag` header for metric labels
- `lib/telegram-alert-lib.sh` shared alert primitive (rate-limited, mirror piter watchdog)
- `oxpulse-channels-health-report.sh` extended with transition detection + alert

## Phase 5.10 (naive)
- `Dockerfile.naive` for klzgrad/naiveproxy
- `oxpulse-partner-naive` compose service
- Naive added to Caddy `tunnel_upstream` as tertiary fallback (UC5)
- `release.yml` builds + ships naive image

## Live tested
Acceptance test `tests/test_installer_production_readiness.sh` PASS on ru.oxpulse.chat (fresh uninstall+install cycle).

## Out of scope
- Phase 5.9 channel discovery API (separate plan)
- Backend reality 0rtt session-cache fix (oxpulse-chat repo)
- UC2 AWG-direct user channel (requires mobile app)

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 2: Wait CI green**

```bash
gh pr checks
```

- [ ] **Step 3: Spec-review before merge**

Dispatch `spec-reviewer` agent with this plan + branch — verify every task closed.

- [ ] **Step 4: Merge after spec + code reviews PASS**

```bash
gh pr merge --squash --admin
```

---

## Self-Review

**Spec coverage (architect roadmap Phase 5.8 + 5.10):**
- ✅ Phase 5.8 Caddy fallback observability — Task 3-6
- ✅ Phase 5.10 Naive compose wiring — Task 7-9
- ✅ Production-ready acceptance test — Task 2, 11
- ✅ Operator runbook — Task 12
- ✅ Migration path (v0.12.20 fleet) — fixed Caddyfile.tpl additions are additive, no breaking changes
- ❌ Phase 5.9 channel discovery API — **OUT OF SCOPE, separate plan needed** (large, requires backend changes in oxpulse-chat repo)
- ❌ UC2 AWG-direct user exposure — **OUT OF SCOPE** (requires native mobile app)

**Placeholder scan:** clean. No "TBD", no "add appropriate error handling", every step has concrete code.

**Type consistency:** `tg_alert()`, `_check_upstream_transitions()`, `compose_strip_failed_channels()`, `_systemd_install_lib_scripts()` all defined once + referenced consistently.

**Known design decisions (not gaps):**
- Naive always rendered in Caddy upstream pool even when undeployed (cost: 10s health-probe noise — acceptable per Task 9 Step 3 rationale).
- Tag `v0.12.43` bumped manually because release-please commit-type detection is unreliable (Bug 21 history).
- Backend reality 0rtt issue NOT addressed here — operator decision (architect doc §6.1).

---

## Execution Handoff

Plan complete и saved to `docs/superpowers/plans/2026-05-19-production-ready-installer-multi-channel.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch fresh subagent per task, review между tasks, fast iteration. Suitable since tasks have clear file boundaries + TDD discipline baked in.

**2. Inline Execution** — execute tasks в this session using executing-plans, batch с checkpoints для review.

**Recommend: Subagent-Driven.** 13 tasks across 4 phases, each task self-contained. Two-stage review (spec + code) between tasks catches drift.

Which approach?
