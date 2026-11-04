# Relay-only node

A relay-only node runs coturn and nothing else: no Caddy, no Xray, no
Naive, no SFU, no AmneziaWG, no Docker. It holds exactly one TURN
credential, its **own per-node secret**, and reports liveness with a service
token. It never registers with the backend.

> **Service token reach (known gap).** On the central side the service token is
> not yet limited to heartbeats: the same token also authorises the node-config
> endpoint for its node id, which returns fleet Reality material. Treat
> `/etc/oxpulse-partner-edge/service-token` as sensitive as that material until
> the central fix lands (tracked in oxpulse-chat). The relay node never calls
> that endpoint.

> **Never run `install.sh`, `upgrade.sh` or anything that calls
> `/api/partner/register` on a relay-only host.** The full path writes
> registration material (`node-config.json`, signing/Reality keys, the shared
> TURN secret) that this profile exists to keep off the box. `install-relay.sh`
> refuses to run if any of it is already present.

## What the installer does

`relay/install-relay.sh` (Debian/Ubuntu, run as root from a checkout):

1. Refuses to continue if registration material is present: env vars
   (`SIGNALING_SFU_SECRET`, `TURN_PARTNER_LEGACY`, `TURN_CENTRAL_SECRET`,
   `ROOM_HMAC_KEY`, Reality keys, `OXPULSE_SERVICE_TOKEN`), the files the full
   install leaves behind (`node-config.json`, `token`, `.env`, `reality.priv`,
   `awg-private.key`, `sfu-signing-key`), or those secret names inside any file
   under `/etc/oxpulse-partner-edge`. It prints names, never values.
2. Masks the package's own `coturn.service` (before installing, so the package
   can never start it), then installs `coturn nftables openssl certbot jq curl
   python3 ufw chrony`. The profile runs `oxpulse-relay-coturn.service` instead.
3. Firewall (ufw/firewalld, default deny; `IPV6=yes` is required in
   `/etc/default/ufw`): the sshd port read from `sshd -T` (an existing,
   possibly source-restricted rule for it is kept; existing ufw rules are never
   reset), `80/tcp` (ACME HTTP-01), `443/tcp` (TURNS), `3478` tcp+udp, and the
   relay range `49152-65535/udp`, opened explicitly. Without the range, cross-TURN cascade traffic and RFC 7675
   consent packets die at INPUT.
4. Installs the coturn self-relay guard (nft OUTPUT: the `turnserver` user may
   send UDP to a local address only inside the relay range) and the matching
   reserved-ports sysctl. After the sysctl, chrony and systemd-resolved are
   restarted and the install fails if any non-`turnserver` socket is still
   bound in 49152-65535.
5. Issues a certificate with `certbot certonly --standalone` (only when DNS
   already resolves to `--public-ip`; otherwise it skips TLS and exits `3`) and
   installs a deploy hook that copies the certificate for coturn and restarts it.
6. Installs the heartbeat timer (every 60 s), the upgrader and its daily timer
   (see [Auto-update](#auto-update)), and a `releases/0.0.0` + `current` baseline so
   the coturn unit always has a binary to start (the distro package until the first
   upgrade).

coturn is rendered **only** by `opec render coturn --secret-file`, from
`relay/coturn-relay.conf.tpl`, by the unit's root `ExecStartPre`
(`oxpulse-relay-prestart`) on every start and restart, so `coturn.conf` always
matches the current `node-secret`. The same step re-runs the registration-material
gate, requires the self-relay guard table to be loaded, and validates the secret
(`opec check-node-secret`: root-owned, mode `0600`, single hard link, opened
without following symlinks, one or two lines, each `^[A-Za-z0-9_-]{43}$`). The
unit also needs the secret, `relay.env` and the certificate and key to exist, is
rate-limited against restart loops, and runs sandboxed.

## Runbook

1. **DNS.** Create an A record for the relay hostname pointing at the node's
   public IPv4. Wait for it to resolve.
2. **Get the tree** on the node (`git clone` or a release source archive) and
   put a matching `opec` at `/usr/bin/opec`, or place `opec-amd64`/`opec-arm64`
   next to the checkout; otherwise the installer downloads the release asset
   and verifies it against `SHA256SUMS`.
3. **Install:**
   ```
   sudo bash relay/install-relay.sh --hostname relay.example.org \
        --public-ip 203.0.113.10 --node-id relay-node-1 --acme-email ops@example.org
   ```
   Re-run it after fixing DNS if it exited `3`.
4. **Write the node secret** (delivered out of band, never via argv or chat):
   ```
   sudo install -m 0600 -o root -g root /dev/stdin /etc/oxpulse-partner-edge/node-secret
   ```
   One secret per line. During a rotation overlap the file holds two lines (new
   and old); outside it, one.
5. **Write the service token.** Obtain it centrally with
   `partner-cli rotate-service-token --node-id <node-id>` and install it the
   same way at `/etc/oxpulse-partner-edge/service-token` (`0600`, root).
6. **Validate and start:** `sudo oxpulse-relay-apply`. It prints the line count
   and a sha256 prefix per secret line, never the secrets. **This restarts
   coturn and drops live allocations (calls reconnect)**: coturn has no safe hot
   reload of auth secrets, so run it in a quiet window.
7. **Verify:**
   - `systemctl is-active oxpulse-relay-coturn`
   - `sudo ss -lntu | grep -E ':(443|3478)\b'`
   - `sudo nft list table inet coturn_self_relay_guard`
   - `sudo oxpulse-relay-health-report.sh --dry-run` prints a `coturn` payload
     and a `coturn-tls` payload, both with `channel_handshake_ok: true`
   - `journalctl -u oxpulse-relay-health` shows `channel coturn reported OK`.

## Rotation

Rotation uses the overlap window: add the new secret as a second line and run
`oxpulse-relay-apply`; once the central side has switched, delete the old line
and run it again. Each run restarts coturn and drops live calls. The heartbeat always derives its credential from the first
line, so keep the **current** secret first. Central-side steps are in the
oxpulse-chat operator docs.

## Heartbeat

`oxpulse-relay-health-report.sh` reuses `lib/channel-health-lib.sh::_post_channel`
and posts two channels to `/api/partner/channel-health`, both from the central
allowlist. Each UPDATE refreshes `partner_nodes.last_seen_at` for the node, which
keeps it in the healthy pool.

- `coturn`: a TURN Allocate over **TCP** 3478 against the node's own public
  address. The guard drops coturn's UDP replies to a client on the same host, and
  the TCP control path avoids that while the UDP relay legs stay inside the
  allowed range.
- `coturn-tls`: a TLS handshake to 443 with SNI and hostname verification for the
  relay hostname and fatal chain errors (`openssl s_client -verify_return_error`).
  This is what proves TURNS/443 is serving a valid certificate.

The service token file must be `0600`, root-owned and shaped `stkn_<base64url>`,
or the heartbeat refuses to use it.

## Auto-update
A relay-only node follows the fleet release the same way an edge does, without
Docker and without registering. `oxpulse-relay-upgrade.timer` fires daily at
00:30 UTC (+ up to 1 h jitter; an upgrade restarts coturn and drops live calls, so
this is the quiet window). `oxpulse-relay-upgrade --check`:

1. Asks central for the node's `desired_release` with the unauthenticated
   `POST /api/partner/heartbeat {"node_id": ...}`. No token is sent, and the answer
   carries only convergence fields (`desired_release`, `keys_version`,
   `config_version`), never Reality material (that is the node-config endpoint,
   which the relay never calls). A node with no `desired_release` stays put.
2. Does nothing unless `desired` is a bare `MAJOR.MINOR.PATCH` strictly greater than
   the installed version in `/usr/local/share/oxpulse-partner-edge/VERSION` (the
   same file the heartbeat reports as `installer_version`). An equal version is a
   no-op, a lower one is refused (downgrade guard), a version that already failed its
   health gate is parked in `/usr/local/lib/oxpulse-relay/failed-version` and not
   retried (remove the file to retry).
3. Starts the real upgrade as its own transient unit, `oxpulse-relay-self-upgrade`
   (`systemd-run`, like edge #678), so the timer service's `TimeoutStartSec` can
   never kill it mid-swap. Follow it with `journalctl -u oxpulse-relay-self-upgrade`.

The target is the `desired_release` column of the node's `partner_nodes` row (the
same column an edge uses). To run it by hand: `sudo oxpulse-relay-upgrade --to X.Y.Z` (same guards, same detached
unit). It re-runs the registration-material gate first and refuses on any hit.

### Where the binary comes from
coturn is **not** the distro package (Ubuntu noble ships 4.6.1, exposed to the
pre-auth TCP/TLS DoS GHSA-m562, GHSA-5538 and the denied-peer canonicalisation
bypasses fixed through 4.13). Every release carries a fully **static musl** build of
coturn 4.18.0 (`turnserver`, `turnutils_uclient`) for amd64 and arm64, so it runs on
any Debian/Ubuntu whatever the glibc. `relay/coturn-static/Dockerfile` builds it in
Alpine from the upstream tag tarball, pinned by sha256 in
`relay/coturn-static/version.env` (the build fails on a mismatch). Attack surface
removed: no database drivers (sqlite, postgres, mysql, mongo, redis), no
libmicrohttpd and so no Prometheus exporter, no systemd, no OAuth token code
(`-DTURN_NO_OAUTH`); linked statically against libevent and OpenSSL, built with
stack protector and `_FORTIFY_SOURCE`. The release workflow smoke-tests the binary
with the real template before it can be published (starts without "Bad
configuration", Allocate succeeds, permissions to `127.0.0.1` and
`::ffff:127.0.0.1` are refused by the template's `denied-peer-ip` lines).

### What an upgrade does
Assets come from the GitHub release `vX.Y.Z` only (never from `main`). The upgrader
fetches `SHA256SUMS` and `relay-manifest.txt` (which lists exactly the files to
install; it carries file names, never paths), then every asset, and **fails closed**:
an asset that is not listed in `SHA256SUMS`, or does not match it, aborts the
upgrade before anything is touched. It also runs the new `turnserver --version` on
the host and makes sure `opec` can render the relay template (it fetches the
checksummed release `opec` otherwise). Then:

1. The binaries are laid out under `/usr/local/lib/oxpulse-relay/releases/<ver>/`.
2. Every file about to be replaced (libs, template, units, sbin scripts, the
   `current` symlink, VERSION) is copied to `.../snapshots/last`.
3. Files are installed atomically (temp + rename), the `current` symlink flips to
   the new release, `daemon-reload`, `systemctl restart oxpulse-relay-coturn`. The
   unit starts `/usr/local/lib/oxpulse-relay/current/turnserver`; the prestart re-renders
   `coturn.conf` from the new template.
4. **Health gate** (same probes as the heartbeat, `relay/relay-probe-lib.sh`): the
   unit is active, a TURN Allocate over TCP 3478 against the node's address
   succeeds, the TURNS handshake on 443 verifies, and `turnserver` holds a UDP
   socket on 3478 (retried for ~30 s after the restart). A UDP-transport allocate
   from the box itself cannot succeed by design (the self-relay guard drops
   coturn's UDP replies to a local client), so the UDP legs are covered by the
   probe's `-y` relay-to-relay traffic and the bound-socket check.
5. On success only, VERSION is written (the heartbeat then reports the new
   `installer_version`) and old releases are pruned (the two newest are kept).

### Rollback
If activation or the gate fails, the snapshot is restored (previous binary via the
`current` symlink, unit, template, scripts, libs), coturn is restarted and gated
again, and the failure is logged at `crit` priority (journal + syslog). Exit codes:
`11` rolled back and healthy, `12` the rollback itself did not come up healthy (page
a human: `journalctl -u oxpulse-relay-self-upgrade`). The failed version is parked
in `failed-version`. Manual rollback to the pre-upgrade state is the same restore;
the previous files are in `/usr/local/lib/oxpulse-relay/snapshots/last`.

The firewall, self-relay guard nft table and sysctl reservation are deliberately not
touched by an upgrade; they change only through `install-relay.sh`.

### Bootstrapping an existing relay node
A node installed before auto-update has no upgrader and no VERSION. One-time,
safe on a live node (touches no coturn file and never restarts coturn):
```
V=X.Y.Z   # the first release that ships relay-manifest.txt
cd "$(mktemp -d)"
curl -fsSLO "https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download/v$V/SHA256SUMS"
curl -fsSLO "https://github.com/anatolykoptev/oxpulse-partner-edge/releases/download/v$V/oxpulse-relay-upgrade.sh"
grep ' oxpulse-relay-upgrade.sh$' SHA256SUMS | sha256sum -c -
sudo bash oxpulse-relay-upgrade.sh --install-upgrader --version "$V"
```
It verifies and installs the upgrader, `relay-lib.sh`, `relay-probe-lib.sh` and the
upgrade service/timer, writes the `VERSION` baseline `0.0.0` (a pre-auto-update
relay) and creates `releases/0.0.0` + `current`. The node then reports
`installer_version=0.0.0` until its first upgrade. Run the first upgrade in a quiet
window: `sudo oxpulse-relay-upgrade --to "$V"`, or let central drive it.

**Known gap on a fresh install:** `install-relay.sh` still installs the distro coturn,
so until the first upgrade (within a day, from the timer) a new node runs 4.6.1 with
the 4.18-form template. That is functional (every key is valid on 4.6.1), but without
`no-dtls` 4.6.1 also opens a DTLS listener on udp/443, which the relay firewall does
not expose. The first upgrade replaces both.

`coturn-relay.conf.tpl` keeps `no-cli`: coturn 4.18 logs it as deprecated (the CLI is
off by default there) but 4.6.x, which a fresh install runs until its first
upgrade, has the CLI on by default.
