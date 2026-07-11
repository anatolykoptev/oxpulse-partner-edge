# M4.A5 — Client-Facing SFU WebSocket Deploy Runbook

**Tag:** `partner-edge-v0.12.1` (M4.A6 fix on top of v0.12.0)
**Phase:** 7 / Track A / M4.A5 + M4.A6
**Adds:** `/sfu/ws/{room_id}` browser-facing WebSocket on the partner edge.
**M4.A6 fix:** `SFU_PUBLIC_IP` env override for host candidates — without this the SFU advertised `0.0.0.0:N` and off-box ICE failed.
**Rolls back to:** `partner-edge-v0.11.9` (no client_ws endpoint exposed).

---

## What this deploy changes per node

1. **SFU container** binds an extra TCP port (`SFU_CLIENT_WS_PORT=8920`)
   for browser SDP exchange. Endpoint is enabled iff
   `SIGNALING_SFU_SECRET` is set; otherwise it stays dark and Caddy
   returns 502 on `/sfu/ws/*` (safe default — no unauthenticated browser
   entry point).
2. **Caddy** gains a `handle /sfu/ws/* { reverse_proxy host.docker.internal:8920 }`
   block, mirroring the existing `/relay/*` handler. The SFU container
   runs `network_mode: host`, so this reaches the SFU through the bridge
   gateway alias.
3. **No new public ports.** Caddy already owns 443; the SFU's 8920 stays
   private to the host (loopback-only via the bridge gateway). No
   Oracle VCN security-list change required for partner-edge nodes —
   browsers never speak to 8920 directly.

---

## Pre-deploy checklist

- [ ] CI built `ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.0`
- [ ] `partner-edge-v0.12.0` tag visible at
      `git ls-remote --tags origin | grep v0.12.0`
- [ ] Signaling server side has `SIGNALING_SFU_SECRET` configured AND
      `/api/partner/keys` (or `node-config.json`) returns it. Without
      this the `/sfu/ws/*` endpoint stays disabled — feature ships dead.
- [ ] Confirm `SFU_PUBLIC_IP` is set in compose (M4.A6). Value comes
      from install.sh `$PUBLIC_IP` autodetect — the SFU advertises
      `Candidate::host(SFU_PUBLIC_IP, SFU_UDP_PORT)` so off-box browsers
      can complete ICE. Falls back to the bind address when unset, so
      v0.12.0 nodes that haven't been re-rendered keep working in their
      current (broken-for-off-box, fine-for-loopback) state until upgrade.
- [ ] `SFU_BIND_ADDRESS=0.0.0.0` is now SAFE for production — the host
      candidate IP is decoupled from the bind via `SFU_PUBLIC_IP`. Keep
      `0.0.0.0` for multi-NIC nodes; the bind controls *which* interfaces
      receive packets, the public IP controls *what address browsers see*.

---

## Deploy: per node (edge-c / relay-x / hub)

> The bundle install path (`install.sh`) handles this end-to-end if the
> backend `/api/partner/config` returns the new `signaling_sfu_secret`
> field. The recipe below is the **manual** container-only update for
> nodes that aren't ready for a full bundle reinstall.

```bash
# 0. SSH to the node
ssh <node>            # edge-c / relay-x / hub

# 1. Pull the new image (built by CI on tag push)
docker pull ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.1

# 2. Stop the running SFU
docker stop oxpulse-partner-sfu
docker rm   oxpulse-partner-sfu

# 3. Restart with the new env vars (SFU_CLIENT_WS_PORT + SIGNALING_SFU_SECRET).
#    Replace <relay-x|hub|edge-c>, the secrets, and the public IP.
docker run -d \
  --name oxpulse-partner-sfu \
  --restart unless-stopped \
  --network host \
  -e SFU_BIND_ADDRESS=<PUBLIC_IP> \
  -e SFU_UDP_PORT=7878 \
  -e SFU_METRICS_PORT=9317 \
  -e SFU_RELAY_API_PORT=8912 \
  -e SFU_CLIENT_WS_PORT=8920 \
  -e PARTNER_ID=<relay-x|hub|edge-c> \
  -e RUST_LOG=info \
  -e RELAY_JWT_SECRET=<32+ byte hex> \
  -e SFU_SIGNING_PUBLIC_KEY='-----BEGIN PUBLIC KEY-----...-----END PUBLIC KEY-----' \
  -e SIGNALING_SFU_SECRET=<HS256 secret matching oxpulse-chat> \
  -e SFU_PUBLIC_IP=<PUBLIC_IP> \
  ghcr.io/anatolykoptev/partner-edge-sfu:v0.12.1

# 4. Reload Caddy with the new template (only if running outside the
#    bundle's docker-compose; the bundle picks this up on `docker compose
#    up -d`).
sudo cp /path/to/Caddyfile /etc/oxpulse-partner-edge/Caddyfile
docker exec oxpulse-partner-caddy caddy reload \
  --config /etc/caddy/Caddyfile --adapter caddyfile

# 5. Verify
docker logs --tail 50 oxpulse-partner-sfu | grep -E "client_ws API listening|SIGNALING_SFU_SECRET"
# Expected: "client_ws API listening (Phase 7 M4.A1+M4.A2)" with addr=0.0.0.0:8920

ss -tln | grep ':8920 '
# Expected: LISTEN on 0.0.0.0:8920

curl -sS -o /dev/null -w '%{http_code}\n' \
  --header "Connection: Upgrade" --header "Upgrade: websocket" \
  --header "Sec-WebSocket-Key: $(openssl rand -base64 16)" \
  --header "Sec-WebSocket-Version: 13" \
  --header "Sec-WebSocket-Protocol: oxpulse-sfu-v1" \
  https://<node>/sfu/ws/test-room
# Expected: 401 (no JWT) — proves Caddy → SFU pathway is live.
```

---

## Bundle reinstall path (preferred)

If `/api/partner/config` returns `signaling_sfu_secret`, the operator
just runs the standard refresh. The new template chain plumbs the
secret through automatically:

```bash
ssh <node>
sudo /usr/local/sbin/oxpulse-partner-edge-refresh.sh
# or
sudo bash <(curl -fsSL https://<backend>/install.sh) --ref v0.12.0
```

---

## Rollback

If `/sfu/ws/*` misbehaves, drop the SFU image back to v0.11.9. The
Caddyfile change is **forward-compatible** — when the SFU isn't
listening on 8920, Caddy returns 502 for `/sfu/ws/*` and other routes
(`/api/*`, `/ws/*`, `/relay/*`) keep working unchanged.

```bash
docker pull ghcr.io/anatolykoptev/partner-edge-sfu:v0.11.9
docker stop oxpulse-partner-sfu && docker rm oxpulse-partner-sfu
docker run -d \
  --name oxpulse-partner-sfu \
  --restart unless-stopped \
  --network host \
  -e SFU_BIND_ADDRESS=<PUBLIC_IP> \
  -e SFU_UDP_PORT=7878 \
  -e SFU_METRICS_PORT=9317 \
  -e SFU_RELAY_API_PORT=8912 \
  -e PARTNER_ID=<relay-x|hub|edge-c> \
  -e RUST_LOG=info \
  -e RELAY_JWT_SECRET=<32+ byte hex> \
  -e SFU_SIGNING_PUBLIC_KEY='...' \
  ghcr.io/anatolykoptev/partner-edge-sfu:v0.11.9
```

(The new env vars `SFU_CLIENT_WS_PORT`, `SIGNALING_SFU_SECRET`, and
`SFU_PUBLIC_IP` are ignored by v0.11.9 — no manual cleanup needed.
For an in-place v0.12.1 → v0.12.0 rollback, simply unset `SFU_PUBLIC_IP`
and the SFU falls back to the historical bind-address candidate behavior.)

---

## Port-allocation note

8911 was the original choice for the client_ws endpoint. On hub
(arm-max-1768977332, San Jose), 8911 is squatted by an unrelated
go-imagine process and would require fleet-wide eviction to free up.
8920 was picked instead so the same Caddy template ships uniformly to
edge-c / relay-x / hub without per-node port juggling.
