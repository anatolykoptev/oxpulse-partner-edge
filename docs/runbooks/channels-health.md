# Runbook: channels-health-report (M2.6a)

## What it does

`oxpulse-channels-health-report` probes local channel listeners on the edge node
and reports per-channel liveness data to the central oxpulse-chat server via
`POST /api/partner/channel-health`. One POST per provisioned channel, every 60 seconds.

Channels are determined by `.channels[].id` in `/etc/oxpulse-partner-edge/node-config.json`.

### Probe method per channel

| Channel | Probe | Fields reported |
|---------|-------|-----------------|
| `ch1` (Reality/VLESS) | `curl` to `http://127.0.0.1:9080/canary/tunnel` (Caddy → xray-client:3080 → tunnel → backend `/api/health/live`) | `channel_rtt_ms` (HTTP RTT), `channel_handshake_ok` |
| `ch2` (AmneziaWG) | `ping -c 1 -W 2 ${OXPULSE_AWG_MOTHERLY_IP}` | `channel_handshake_ok` (no RTT — awg uses age-based freshness) |
| `ch3` (Hysteria2) | `nc -z 127.0.0.1 ${hy2-port}` | `channel_rtt_ms` (connect time; no `channel_handshake_ok` — UDP tunnel has no handshake concept) |
| `ch4/ch5/ch6` | Not wired — skipped with log message | — |

## Where to view reports on central

Central stores the latest report per node in `partner_nodes`:
```sql
SELECT node_id, channel_name, channel_rtt_ms, channel_handshake_ok,
       channel_probed_at, last_seen_at
FROM partner_nodes
ORDER BY last_seen_at DESC;
```

Prometheus: `partner_node_channel_heartbeat_total{node_id, channel_name, handshake_ok}` counter
increments on each successful report. Alert on stale counter = edge reporter stopped or lost auth.

## Timer status

```bash
systemctl status oxpulse-channels-health-report.timer
systemctl status oxpulse-channels-health-report.service   # last run
journalctl -u oxpulse-channels-health-report.service -n 50
```

## How to disable

```bash
sudo systemctl disable --now oxpulse-channels-health-report.timer
```

Re-enable:
```bash
sudo systemctl enable --now oxpulse-channels-health-report.timer
```

## Ad-hoc invocation

```bash
# Dry-run: print what would be reported without POSTing
sudo oxpulse-channels-health-report --dry-run

# Single run + actual POST
sudo oxpulse-channels-health-report --once
```

## Debugging a "down" status

1. **ch1 down** — xray tunnel not carrying traffic (container may be up but tunnel dead):
   ```bash
   # Probe the actual tunnel path (same as probe_ch1):
   curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:9080/canary/tunnel
   # Check container health (now probes the tunnel, not just the port):
   docker ps | grep oxpulse-partner-xray
   docker inspect --format '{{.State.Health.Status}}' oxpulse-partner-xray
   docker logs oxpulse-partner-xray --tail 50
   ```

2. **ch2 down** — AmneziaWG mesh not connected:
   ```bash
   ping -c 3 ${OXPULSE_AWG_MOTHERLY_IP:-10.9.0.2}
   sudo awg show   # check handshake age
   ```

3. **ch3 down** — Hysteria2 TCP forwarder not listening:
   ```bash
   ss -ltnH | grep 18443
   docker ps | grep oxpulse-partner-hy2
   docker logs oxpulse-partner-hy2 --tail 50
   ```

4. **Auth error (HTTP 401/403)** — service token revoked or mismatched:
   ```bash
   # Check token readable
   sudo cat /etc/oxpulse-partner-edge/token
   # Re-run with dry-run to confirm token is non-empty
   sudo oxpulse-channels-health-report --dry-run --curl-trace 2>&1 | grep Authorization
   # Rotate via partner-cli if needed (requires server-side access)
   ```

5. **No reports at all** — timer not running:
   ```bash
   systemctl is-active oxpulse-channels-health-report.timer
   # If inactive: re-enable
   sudo systemctl enable --now oxpulse-channels-health-report.timer
   ```

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All POSTs succeeded OR server 5xx/timeout (retry next tick) |
| 1 | At least one channel got HTTP 4xx (auth failure — check token) |
