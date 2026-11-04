# CH3 (hysteria2) retired

## What and why

CH3 was a third, control-plane-only fallback tunnel (QUIC to a hysteria2 server on the central host). It never carried call media. Its server was stopped on purpose on 2026-10-09 after a secrets incident, but only on the central host: central kept advertising `hysteria2_server`, the edges kept their client, and a client that cannot connect exits and is restarted by docker forever. Edges ran for weeks in a crash loop that selfheal's start grace hid.

CH3 is retired. CH1 (Reality), CH2 (AmneziaWG) and naive stay. The edge decides this on its own: whether central still advertises `hysteria2_server` does not matter.

## What a node does

On every upgrade (before the pre-change baselines) and on every refresh cycle, `retire_hysteria2_ch3` (`channel-render-lib.sh`) runs. It is idempotent and silent on a node with no CH3 trace:

- removes the `oxpulse-partner-hysteria2` container (compose `--profile ch3 rm` from the project dir, `docker rm -f` as fallback);
- deletes `hysteria2-client.yaml`, its `.bak.*` copies and `hysteria2-config.sha`, only after the container is gone;
- drops `ch3` from `COMPOSE_PROFILES` in `.env`, keeping every other line;
- sets `hysteria2=retired` in `channels-status.env`;
- removes the leftover `oxpulse-partner-edge-enable-hy2` and `hydrate-hy2.sh` host scripts.

If docker is not answering it touches nothing and retries next cycle.

Port 18443 (the old forwarder, bound on all interfaces and open to the world in the firewall) is closed: it is no longer in the public allow lists, and firewalld nodes, which only ever added rules, get an explicit remove for tcp and udp, permanent and runtime.

selfheal now also alerts on any container docker restarts repeatedly (`partner_edge_container_restart_count` gauge; a rise in RestartCount bypasses the start grace and goes through the normal budget gate and Telegram alert).

## Ordering

1. Release this version and let every live node reach it (`desired_release`).
2. Only then stop advertising `hysteria2_server` on central and retire the credentials endpoint and server-side config.

Stopping the advertisement earlier is harmless to nodes already on this release, but a node still on an older release would keep its crash-looping client.

## Rollback caveat

An older release, on seeing `hysteria2_server` in node-config with no local yaml, re-provisions CH3. Rolling a node back while central still advertises the field brings the crash loop back. Do not roll back past this release before central stops advertising it.

## Verify on a node

```bash
grep '^hysteria2=' /var/lib/oxpulse-partner-edge/channels-status.env   # hysteria2=retired
docker ps -a --format '{{.Names}}' | grep -c oxpulse-partner-hysteria2  # 0
grep -c ch3 /etc/oxpulse-partner-edge/.env                              # 0 (or no .env)
ss -ltnu | grep -c ':18443'                                             # 0
sudo ufw status | grep -c 18443                                         # 0 (ufw nodes)
sudo firewall-cmd --zone=public --list-ports | grep -c 18443            # 0 (firewalld nodes)
```

A node that never had CH3 may show `hysteria2=skipped` until its first refresh after the upgrade, then `retired`.
