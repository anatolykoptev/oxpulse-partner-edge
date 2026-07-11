# Relay-x Topology Normalization Plan

## Current State (as of 2026-05-13)

Relay-x uses a **hybrid topology** where xray config is managed manually:

- `/opt/xray-config.json` — manually maintained xray server config. This file
  is the live config used by the xray container. It was set up before the
  partner-edge stack was deployed on relay-x and has never been migrated to the
  standard control plane.
- `/etc/oxpulse-partner-edge/node-config.json` — **stub only**. Contains
  only the node identity fields:

  ```json
  {
    "node_id": "<id>",
    "partner_id": "relay-x",
    "edge_id": "relay-x1",
    "public_ip": "<relay-x public IP>",
    "awg_ip": "<awg tunnel IP>"
  }
  ```

  **Missing**: `reality_uuid`, `reality_public_key`, `reality_encryption`,
  `reality_short_id`, `reality_server_name(s)`, `backend_endpoint`.

Because the `reality_*` fields are absent, `update.sh` cannot manage relay-x's
xray config and will exit with an error if run on relay-x without first
normalizing the node-config.json.

The daily refresh script (`oxpulse-partner-edge-refresh.sh`) and `update.sh`
both read secrets exclusively from `node-config.json`. The manual
`/opt/xray-config.json` file is invisible to both scripts.

This is what caused the 2026-05-12 incident: when the hub server switched
to `packet-up` + `xmux`, relay-x's manual config was not updated because the
control plane had no visibility into it.

## Target State (standard partner-edge topology)

After normalization, relay-x will work identically to edge-c and edge-a:

- `node-config.json` contains all `reality_*` fields sourced from the hub
  backend at registration time and kept current by the daily refresh script.
- `xray-client.json` is rendered by `update.sh` / `oxpulse-partner-edge-refresh.sh`
  from `xray-client.json.tpl` using the secrets in `node-config.json`.
- The manually maintained `/opt/xray-config.json` becomes the rendered artifact,
  not the source of truth.

This means running `update.sh` on any partner edge (including relay-x) will
self-heal xray config drift within minutes — no SSH required.

## Migration Steps

### Step 1: Gather current xray secrets from relay-x

SSH into relay-x and extract the current xray client parameters from
`/opt/xray-config.json`:

```bash
ssh relay-x
cat /opt/xray-config.json | python3 -m json.tool
```

Extract these values:
- `reality_uuid` — the VLESS user `id` in `outbounds[].settings.vnext[0].users[0].id`
- `reality_public_key` — `outbounds[].streamSettings.realitySettings.publicKey`
- `reality_short_id` — `outbounds[].streamSettings.realitySettings.shortId`
- `reality_server_name` — `outbounds[].streamSettings.realitySettings.serverName`
- `reality_server_names` — build from the serverName (single entry array)
- `reality_encryption` — the user `encryption` field (may be `none` or a PQ string)
- `backend_endpoint` — `outbounds[].settings.vnext[0].address + ":" + port`

Also verify the current mode in `outbounds[].streamSettings.xhttpSettings.mode`.
After normalization, `update.sh` will render the template (currently `packet-up`)
and override whatever mode was in the manual file.

### Step 2: Write full node-config.json on relay-x

```bash
ssh relay-x
# Backup the stub
cp /etc/oxpulse-partner-edge/node-config.json \
   /etc/oxpulse-partner-edge/node-config.json.bak.stub

# Write full config (substitute real values from Step 1)
cat > /etc/oxpulse-partner-edge/node-config.json <<'EOF'
{
  "node_id": "<existing node_id>",
  "partner_id": "relay-x",
  "edge_id": "relay-x1",
  "public_ip": "<relay-x public IP>",
  "awg_ip": "<awg tunnel IP>",
  "reality_uuid": "<uuid from /opt/xray-config.json>",
  "reality_public_key": "U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk",
  "reality_encryption": "<encryption or none>",
  "reality_short_id": "<shortId from /opt/xray-config.json>",
  "reality_server_name": "www.samsung.com",
  "reality_server_names": ["www.samsung.com"],
  "backend_endpoint": "hub.example.com:5349"
}
EOF
chmod 0600 /etc/oxpulse-partner-edge/node-config.json
```

**Note on publicKey**: use the current hub server public key
`U6ea044JJjgiCjQAnYEBqBBlkeSqrQaLq3lcjnN2EFk` (the 2026-05-12 key). This is
the correct key even if the old `/opt/xray-config.json` has the pre-rotation
key `gV5XA0q27mWGyJxRID0P88Sn0jVap7yO-pfe4pLlA3w` — that key is what caused
the 2026-05-12 incident.

### Step 3: Dry-run render (non-destructive verification)

Before running `update.sh`, verify that `node-config.json` will produce a
valid `xray-client.json` by running the render in a temp location:

```bash
ssh relay-x
# Copy the template locally if not present
cp /usr/local/sbin/channel-render-lib.sh /tmp/  # or from the repo

# Dry-run: render to a temp file instead of overwriting live config
NODE_CFG=/etc/oxpulse-partner-edge/node-config.json \
XRAY_CFG=/tmp/xray-client.json.test \
PREFIX_ETC=/etc/oxpulse-partner-edge \
bash -c '
    source /usr/local/sbin/channel-render-lib.sh
    REPO_RAW=https://raw.githubusercontent.com/anatolykoptev/oxpulse-partner-edge/main
    re_render_xray
'

# Inspect the rendered output
python3 -m json.tool /tmp/xray-client.json.test

# Verify mode = packet-up and xmux block present
python3 -c "
import json
d = json.load(open(\"/tmp/xray-client.json.test\"))
for ob in d[\"outbounds\"]:
    s = ob.get(\"streamSettings\", {}).get(\"xhttpSettings\", {})
    if s:
        print(\"mode:\", s.get(\"mode\"))
        print(\"xmux:\", s.get(\"xmux\"))
"
```

Expected output:
```
mode: packet-up
xmux: {'maxConcurrency': 1, 'cMaxReuseTimes': 64, 'cMaxLifetimeMs': 15000}
```

### Step 4: Run update.sh

Once dry-run looks correct, run `update.sh` on relay-x:

```bash
ssh relay-x
# Place a token file if one exists for API re-fetch (optional)
# echo 'ptkn_...' > /etc/oxpulse-partner-edge/token
# chmod 0600 /etc/oxpulse-partner-edge/token

# Run the update — this will render xray-client.json and restart the container
bash /usr/local/sbin/oxpulse-partner-edge-update
```

Or if deploying from git directly:

```bash
cd /usr/local/sbin  # or wherever the repo is deployed
bash /path/to/update.sh
```

If update.sh exits 0 with "smoke test PASSED", relay-x is normalized and the
xray tunnel is working with the new `packet-up` + xmux config.

### Step 5: Verify traffic

After `update.sh` exits 0:

```bash
# Check xray-client logs for recent activity
docker logs --tail 20 xray-client

# Check port 3080 is listening (tunnel inbound)
ss -tlnH | grep 3080

# Optional: check a web request routes through the tunnel
# (from a browser client pointed at relay-x, verify oxpulse.chat loads)
```

### Step 6: Update the daily refresh cron entry

Ensure `oxpulse-partner-edge-refresh.sh` is scheduled on relay-x so future
key rotations are applied automatically without manual intervention:

```bash
systemctl status oxpulse-partner-edge-refresh.timer
```

If the timer is absent, install it from the partner-edge systemd units.

## Rollback Plan

If `update.sh` fails or the smoke test reports Reality handshake failure:

```bash
# Restore the pre-update backup (update.sh creates one before writing)
ls /etc/oxpulse-partner-edge/xray-client.json.bak.*
cp /etc/oxpulse-partner-edge/xray-client.json.bak.<timestamp> \
   /etc/oxpulse-partner-edge/xray-client.json
cd /etc/oxpulse-partner-edge && docker compose restart xray-client

# If the backup is missing or also broken, restore the original manual config
cp /opt/xray-config.json /etc/oxpulse-partner-edge/xray-client.json
cd /etc/oxpulse-partner-edge && docker compose restart xray-client
```

Check logs for the failure reason:
```bash
docker logs --tail 50 xray-client | grep -i "error\|real certificate\|failed"
tail -50 /var/log/oxpulse-partner-edge-update.log
```

## Why This Normalization Matters

The daily refresh script only acts on `channels_version` hash changes — a
manual server config edit that doesn't bump the version leaves all partners
silently broken (see the 2026-05-12 incident above). After normalization,
`update.sh` can heal drift on any partner edge in under 30 seconds, without
knowing which fields changed on the server.
