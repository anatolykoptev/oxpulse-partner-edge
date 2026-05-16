# conf.d/ operator override slot

## What it is

`/etc/oxpulse-partner-edge/conf.d/` is a directory of Caddy config fragments
loaded **after** the auto-generated `Caddyfile` via a trailing
`import /etc/oxpulse-partner-edge/conf.d/*.caddy` directive.

Files inside conf.d/ survive every `install.sh`, `update.sh`, and
`upgrade.sh --with-templates` run. They are **never touched** by automation.

## When to use it

- Per-tenant vhosts not covered by the core partner-edge template (e.g.
  `cheburator.bot`, `www.cheburator.bot` with static file serving)
- Webhook proxy routes to internal services on the same host
- Emergency patches that must survive the next scheduled upgrade cycle
- Any hand-crafted Caddy config that previously lived in a `.bak` file

## File naming convention

```
<tenant>-<purpose>.caddy
```

Examples:
```
cheburator-vhosts.caddy     cheburator.bot + www.cheburator.bot vhosts
cheburator-webhook.caddy    webhook proxy to internal service
emergency-ratelimit.caddy   hotfix rate-limit rule
```

## Worked example: cheburator.bot vhosts

Create `/etc/oxpulse-partner-edge/conf.d/cheburator-vhosts.caddy`:

```caddyfile
cheburator.bot {
    root * /srv/cheburator-static
    file_server
    encode gzip

    handle_path /webhook/* {
        reverse_proxy localhost:9000
    }
}

www.cheburator.bot {
    redir https://cheburator.bot{uri} permanent
}
```

Reload Caddy (no restart needed if caddy admin API is running):

```bash
docker exec oxpulse-caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
# or restart the stack:
cd /etc/oxpulse-partner-edge && docker compose restart caddy
```

## Drift check with install.sh --check

```bash
sudo install.sh --check
```

Output:
```
[OK]    Caddyfile
[OK]    docker-compose.yml
[conf.d/] 1 files preserved
```

Exit codes:
- `0` — both Caddyfile and docker-compose.yml match fresh render (conf.d/ excluded)
- `1` — Caddyfile differs from fresh render (operator drifted the main Caddyfile)
- `2` — docker-compose.yml differs (image pinned differently, etc.)

conf.d/ files are always listed but never cause a non-zero exit.

## Migrating from a .bak file

If a previous operator edited the Caddyfile and a `.bak.pre-*` file exists:

```bash
# Dry-run first (shows what would be extracted)
sudo bash /usr/local/sbin/migrate-bak-to-confd.sh

# Apply if the extracted content looks correct
sudo bash /usr/local/sbin/migrate-bak-to-confd.sh --apply
```

The script:
1. Finds the operator-added section (content after the last auto-generated block)
2. Writes it to `conf.d/migrated-<epoch>.caddy`
3. Renames the `.bak` file to `.bak.migrated`

Always review the extracted file before relying on it in production.

## Empty directory behaviour

Caddy emits a log warning but exits 0 when `conf.d/` is empty:

```
No files matching import glob pattern: /etc/oxpulse-partner-edge/conf.d/*.caddy
```

This is expected and harmless.

## Security notes

- conf.d/ files are readable by any process running as the caddy container user.
  Do not place secrets (API keys, tokens) in these files.
- Secrets belong in docker-compose.yml environment blocks or dedicated secret
  files with mode 0600.
