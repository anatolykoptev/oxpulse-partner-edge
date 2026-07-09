# Follow-ups

## Self-update convergence gate is scoped to upgrade.sh only (PR4 v0.14.5)

`_assert_self_update_converged` (PR4) fail-closes only on `upgrade.sh`'s own
convergence: it compares the running process's pre-sync bytes against the
post-sync installed `oxpulse-partner-edge-upgrade`. It does NOT assert that the
*other* host-scripts (`install-firewall.sh`, `host-scripts-lib.sh`, …) synced
successfully. There are two directions this can diverge in, and only one is benign:

- **Benign:** upgrade.sh converges (new bytes on disk, gate passes) but a sibling
  host-script independently 429s and stays stale. The orchestrator is up to date
  and (per its own version) knows how to drive whatever host-script version is
  present; degrades to the historical two-run convergence for that one file.
- **DANGEROUS (code-quality review, PR4 — this is the actual v0.14.4 incident
  reproduced, not just a corner case):** upgrade.sh's OWN sbin fetch specifically
  fails/skips (leaving OLD bytes, so the pre-sync fingerprint matches the
  post-sync installed sha → gate reads "converged") while a SIBLING host-script
  (fetched from a *different* origin — see `lib/host-scripts-lib.sh`'s
  `fetch_url` branch: upgrade.sh's own asset comes from `RELEASES_BASE`, every
  sibling from `REPO_RAW`) succeeds and installs NEW bytes. The gate is silent;
  an OLD orchestrator then drives a NEW host-script set it doesn't understand —
  exactly the `reconcile_firewall_surface` death that triggered this whole arc.

**Mitigation shipped in PR4:** `RETRY_OPTS` was added to `host-scripts-lib.sh`'s
shared per-file fetch (previously unretried for every file in
`_HOST_SCRIPT_SBIN_FILES`, including upgrade.sh's own), narrowing how often a
transient 429 on ONE origin causes exactly one file to lag behind the rest. This
reduces the window but does not close it — a sustained/systemic outage on one
origin while the other stays healthy is still possible.

**Followup (MEDIUM — the dangerous direction is a real, if narrower, gap):**
extend the gate to assert every `_HOST_SCRIPT_SBIN_FILES` entry's installed sha
matches its `SHA256SUMS` expectation after sync (fail-closed), reusing
`_lookup_expected_hash`, instead of proxying whole-set convergence through
upgrade.sh's own file alone.

**File:line:** `upgrade.sh` `_assert_self_update_converged`; `lib/host-scripts-lib.sh`'s
`fetch_url`/`curl` site (the shared per-file fetch this followup would extend).

---

## Phase 5.5 fail-soft for hydrate/refresh/update (MAJOR 1 deferred)

`hydrate.sh`, `oxpulse-partner-edge-refresh.sh`, and `update.sh` do not use
`render_channel_soft` / `CHANNELS_FAILED` and lack the compose-strip
post-processor added to `install.sh` in PR #186.

A render failure in these scripts can tear down healthy channels via
`docker compose up -d [--force-recreate]` because the compose file still
contains the failed channel's service block referencing a missing config file.

**Followup:**
- Extract `render_channel_soft` and the compose-strip python3 block into
  `lib/channel-render-lib.sh` (or a new `lib/channel-fallback-lib.sh`) so
  `hydrate.sh`, `refresh.sh`, and `update.sh` can source it.
- Replace unconditional `docker compose up -d --force-recreate` in refresh with
  surgical per-channel restart: only recreate containers whose channel was
  re-rendered successfully.
- Mirror `channels-status.env` atomic write in all three scripts.

**Severity:** HIGH on refresh/hydrate paths (daily scheduled runs); MEDIUM on
update.sh (operator-explicit only).

**File:line:** `hydrate.sh:234–266`, `oxpulse-partner-edge-refresh.sh:185–238`,
`update.sh` (compose-up call). Warning comments + this entry added in PR #186.

---

## Phase 5.5: opec render xray reads node-config.json natively

Phase 5.4 (fix/install-bugs-3-4-live-edge) added env-export plumbing in
`install.sh` to feed `XRAY_XHTTP_*` into `opec render xray`. This duplicates
the responsibility of reading node-config that opec already owns for secrets
subcommands.

**Followup:** add `opec render xray --node-cfg <path>` that reads
`channels[0].xray.xhttp` natively (mirror `scripts/read-xhttp.py` logic in
Rust), then drop the `install.sh` env-export block (the six `python3 - ...`
heredocs + the `export XRAY_XHTTP_*` line before `render_with_opec xray`).

**Acceptance:** `install.sh` `render_with_opec xray` invocation needs no
ambient `XRAY_XHTTP_*` env vars; opec reads node-config directly.

**File:line:** `install.sh` (around the `render_with_opec xray` call),
`crates/opec/src/render/` (add `--node-cfg` flag to xray subcommand).

---

## BLOCKER 2 follow-up: lib/install-systemd.sh hardcodes /usr/local/bin for oxpulse-xray-update.sh (2026-05-18)

`lib/install-systemd.sh:_systemd_install_xray_update_script()` installs
`oxpulse-xray-update.sh` to hardcoded `/usr/local/bin/oxpulse-xray-update.sh`
instead of `${PREFIX_BIN:-/usr/local/bin}`. This means installations that
override `PREFIX_BIN` via `OXPULSE_PREFIX_BIN` will leave the file at the
wrong path.

**Suggested fix:** Change the function to use `${PREFIX_BIN:-/usr/local/bin}`
as the install destination. Requires `PREFIX_BIN` to be in scope when
`install-systemd.sh` is sourced (it already is — exported from install.sh).

**Severity:** LOW — `PREFIX_BIN` is only overridden in tests; prod defaults
to `/usr/local/bin`. Uninstall.sh Phase 5.7 review-fix already handles
removal of the hardcoded path.

**File:line:** `lib/install-systemd.sh:_systemd_install_xray_update_script()` (~L206-213).

---

## awg_extract silent failure swallows JSON / python3 errors during install (2026-05-18)

**Severity:** P1 — install completes "successfully" with empty `AWG_*` vars and a dead `awg-quick@awg0` service. No surfacing log; operator sees install OK but the edge is non-functional until they tail journalctl.

**Investigation report:** `/home/krolik/deploy/krolik-server/reports/oxpulse-chat/investigations/2026-05-18-mesh-bridge-online-drop.md` (item 6).

**Original code-quality-reviewer claim:** "`awg_extract` under `set -euo pipefail` aborts the install silently if JSON is malformed or python3 missing." → **REFUTED in letter, CONFIRMED in spirit.**

**Actual mechanism (worse than original claim):** Under `set -euo pipefail`, bash exempts assignment right-hand-side from `set -e`. So a failing `$(awg_extract /nonexistent jc)` does NOT abort the script. Instead three layers swallow:

1. `lib/install-awg.sh:137` — `python3 ... 2>/dev/null` discards python error output
2. Assignment captures empty string into local var (RHS-exempt from `set -e`)
3. Call sites at `install.sh:594-607` use `awg_extract` outputs to populate `AWG_*` env vars without checking for empty
4. `configure_amneziawg` (line 208+) renders `awg0.conf` with empty values, then `awg-quick up awg0` either fails-soft or starts a broken interface

Result: full install run reports OK exit, but `awg-quick@awg0.service` exits 1 silently. No `die` ever fires.

**Suggested fix:**
- Validate non-empty after each `awg_extract` call site (or batch-validate the 14 `AWG_*` vars before render)
- Surface python3-missing as `die` (not silent fallback) — python3 is a build-deps invariant on Debian/RHEL/Ubuntu
- Add a smoke-step after `configure_amneziawg` that checks `systemctl status awg-quick@awg0` exit 0 before declaring install success

**File:line:** `lib/install-awg.sh:137`, `install.sh:594-607`, `lib/install-awg.sh:208+` (configure_amneziawg).

---

## ~~GAUGE-LEAK: chat_relay_active_channels never decremented on disconnect~~

~~**Opened:** Phase 8 T10 review-fixes (commit following f6eb52d)~~
~~**Severity:** Medium — reconnect storm inflates gauge monotonically; no alert~~
~~  fires on churn that doesn't exceed a steady-state threshold.~~

**Closed:** `fix/chat-relay-gauge-leak` branch — commit TBD (SHA filled on merge).
Both `Registry::reap_dead` (`crates/sfu/src/registry/bwe.rs`) and
`Registry::evict_for_steal` (`crates/sfu/src/registry/mod.rs`) now decrement
`chat_relay_active_channels{dc="data"}` and `{dc="ctrl"}` guarded by
`chat_data_cid.is_some()` / `chat_ctrl_cid.is_some()`, mirroring the T10 voice fix.
Tests: `chat_relay_active_channels_gauge_decremented_on_reap` +
`chat_relay_active_channels_gauge_decremented_on_steal` added to
`crates/sfu/tests/relay_chat_e2e.rs`.

### ~~Open: voice_relay_dropped{buffered_amount_too_high} branch lacks unit test~~
**Closed.** T10 fix-loop (commit `f92c54a`) added a `ch.buffered_amount() > VOICE_BUFFERED_AMOUNT_MAX` backpressure check in `crates/sfu/src/client/voice.rs:~101`. The drop counter `voice_relay_dropped{reason="buffered_amount_too_high"}` increments correctly at runtime, but no integration test in `tests/voice_relay.rs` covers the branch. Test seam approach: drive a mock channel that returns a non-zero `buffered_amount()` via `client::test_seed::new_client` + relay flush. Without coverage the counter can silently regress (wrong label, wrong threshold, missing `.inc()`) — exactly the class of bug T10 cycle was designed to catch. Reviewer (final) flagged as MINOR, deferred to keep T10 boundary clean.

**Resolution:** Added `voice_relay_drops_when_subscriber_buffered_amount_too_high` in `crates/sfu/tests/voice_relay.rs` (10th test). Seam: `Client::set_buffered_amount_for_tests(usize)` in `test_seed.rs` + `buffered_amount_override: Option<usize>` field (cfg-gated). Override checked before `rtc.channel()` in voice.rs test path so the branch fires despite no live SCTP. Test asserts: `buffered_amount_too_high` counter +1 on overloaded subscriber; healthy subscriber still reaches relay attempt (`dc_closed` in test seam). <!-- closed: <!-- placeholder SHA --> -->

---

## ch4 coturn probe — hairpin/NAT caveat and allocation leak (PR #304)

### Hairpin / pure-NAT edge

On a **pure-NAT edge** where the public IP is NOT locally bound (e.g. AWS/GCP
instances where the public IP lives on the gateway, not the NIC), the probe
sends a TURN Allocate to `$probe_target` (the public IP).  Clouds that **drop
hairpin** traffic from the instance back to its own public address will silently
drop the packets; `timeout` kills `turnutils_uclient` with exit 124; the probe
reports `handshake_ok=false` on a perfectly healthy coturn.

**Remedy:** set `OXPULSE_COTURN_PROBE_TARGET` to an address that IS reachable
from the instance without hairpin — typically the instance's private/LAN IP if
coturn listens there, or a second IP on a peer box.  Example:

```bash
# In /etc/oxpulse-partner-edge.env or equivalent:
OXPULSE_COTURN_PROBE_TARGET=10.0.0.5   # LAN IP coturn actually binds
```

The script's `warn` on repeated timeout in `probe_ch4` (around the
`loopback-fallback` branch and the failure logger) references this env override;
the `loopback-fallback` warn text in `oxpulse-channels-health-report.sh` also
cites the env escape hatch.

**Detection:** `COTURN_PROBE_TARGET_SOURCE=loopback-fallback` in
`/var/lib/oxpulse-partner-edge/coturn-probe-mode.env` (written every tick by
`_write_probe_mode_state`), or `channel_probe_reason=loopback-fallback` in the
central server POST payload (written when the fallback path is taken).

### Residual allocation leak on timeout

When `timeout` kills `turnutils_uclient` (exit 124) on a dead relay or
hairpin-drop edge, the client never sends a TURN Refresh(0) (graceful dealloc).
Coturn holds two dangling allocations per probe tick until its default
expiry (600 s).  At 60 s tick rate that is 2 leaks/60 s → **~10 leaked
allocations** outstanding at steady state.  The default user quota is 16, so a
probe username wedges into `486 Allocation Quota Reached` after roughly **8
minutes of continuous failure** on the default per-user quota.

`turnutils_uclient` has no `--lifetime` or allocation-duration flag (the `-l`
flag controls message length, not allocation lifetime; coturn-exporter confirms
no lifetime override exposed via the CLI).  The leak is therefore bounded only
by **coturn's `allocation-default-timeout` (default 600 s)** — the quota
recovers automatically once all timed-out allocations expire, but a
continuously-timing-out probe will keep the quota wedged.

**Mitigations:**
1. Fix the root cause: resolve hairpin via `OXPULSE_COTURN_PROBE_TARGET`
   (see above) so the probe succeeds and sends Refresh(0) gracefully.
2. As a safety net, set `max-allocate-lifetime=120` and
   `allocation-default-timeout=120` in `coturn.conf.tpl` to halve the wedge
   window (not yet done — tracked here).
3. The probe username `<ts>:healthprobe` is fixed per-edge, so the wedge is
   per-username and does not pollute other users' quotas.

**Comment updated** in `oxpulse-channels-health-report.sh` (around line 215)
to state the residual leak honestly rather than claiming it is solved.

---

## `_restart_if_changed` passes container_name where `docker compose restart` needs the service key (pre-existing)

`oxpulse-partner-edge-refresh.sh`'s `_restart_if_changed` uses its 5th positional
arg (`container`) directly as the target of
`docker compose -f "$compose_file" restart "$container"`. But `docker compose
restart` addresses the compose **SERVICE key**, not `container_name`. The three
channel call sites pass the **container_name**:

- `_restart_if_changed xray … oxpulse-partner-xray`
- `_restart_if_changed naive … oxpulse-partner-naive`
- `_restart_if_changed hysteria2 … oxpulse-partner-hysteria2`

so `docker compose restart oxpulse-partner-xray` fails with `no such service`
(the service key is `xray`, not `oxpulse-partner-xray`). Surgical channel
restarts on config change are therefore a no-op today — the container keeps stale
config until the next full recreate.

This predates the SFU key-apply work (PR #331). PR #331's own SFU call site is
**correct**: it passes the service key `sfu` as `container` (used by
`docker compose up -d --no-deps --force-recreate sfu`) and the `container_name`
`oxpulse-partner-sfu` only as the 7th `state_container` arg (for the
`docker inspect {{.State.Running}}` liveness probe). So the SFU path is not
affected — this row tracks only the pre-existing xray/naive/hysteria2 defect.

**Followup:** change the three channel call sites to pass the compose service key
(`xray` / `naive` / `hysteria2`) as `container`, and pass the container_name as
the (new) `state_container` arg for the liveness check — mirroring PR #331's SFU
call site. Add a test that greps the docker-spy log for
`compose … restart <service-key>` (not the container_name).

**Severity:** MEDIUM — channel config changes silently fail to apply on the daily
refresh until the next `channels_version`-driven full recreate.

**File:line:** `oxpulse-partner-edge-refresh.sh` — the `xray` / `naive` /
`hysteria2` `_restart_if_changed` call sites (channel surgical-restart block).

---

## Render-parity fixtures still snapshot the baked `{{SFU_SIGNING_PUBLIC_KEY}}` literal

PR #331 removed the `SFU_SIGNING_PUBLIC_KEY` `environment:` literal from
`docker-compose.yml.tpl` (the sfu service now reads the key via `env_file:
sfu-keys.env`) and dropped the now-dead `SFU_SIGNING_PUBLIC_KEY` export +
`. sfu-keys.env` sourcing from `install.sh`. The render-parity **fixtures** were
deliberately left untouched (out of scope for the SFU key-apply arc), so they
still model the OLD shape:

- `tests/fixtures/install-render/compose.tpl` + `.../expected/compose.txt` still
  bake `SFU_SIGNING_PUBLIC_KEY: "{{…}}"` under `environment:`.
- `tests/test_install_render_identical.sh` and `tests/test_install_opec_parity.sh`
  still list `SFU_SIGNING_PUBLIC_KEY` in their local `mirror_install_exports`.

These tests stay green (each is self-contained: its own mirror + its own
fixtures), but the fixture snapshot has drifted from the real template and
`install.sh`'s export list.

**Followup:** regenerate the `install-render` fixture snapshot from the current
`docker-compose.yml.tpl` (dropping the placeholder + golden line) and drop
`SFU_SIGNING_PUBLIC_KEY` from both parity tests' `mirror_install_exports`, as one
coordinated render-parity-suite change.

**Severity:** LOW — cosmetic fixture drift; no runtime effect, no test failure.

**File:line:** `tests/fixtures/install-render/compose.tpl`,
`tests/fixtures/install-render/expected/compose.txt`,
`tests/test_install_render_identical.sh`, `tests/test_install_opec_parity.sh`.

---

## install.sh / upgrade.sh still fetch the OLD `install-firewall.sh` name (Phase 6 firewall-lib cutover, deferred)

Phase 6's naming reclassification renamed `lib/install-firewall.sh` to
`lib/firewall-lib.sh` (it is sourced by BOTH `install.sh` and `lib/reconcile.sh`'s
converge loop, hence the `*-lib.sh` class) and left `lib/install-firewall.sh` in
place as a FROZEN byte-identical back-compat duplicate. `lib/reconcile.sh`'s new
`${FIREWALL_LIB:-.../firewall-lib.sh}` default is consequently unreachable in
production today: `install.sh:319`'s `_install_lib_source install-firewall.sh`
eagerly sources the OLD name first, so `declare -f firewall_apply` already
succeeds before reconcile's default would ever fire; `upgrade.sh:432`'s
`_stage_lib "install-firewall.sh" ...` (and its tier-3 `REPO_RAW` fetch) exports
`FIREWALL_LIB` pointing at the OLD staged file too. Updating `install.sh` /
`upgrade.sh` to reference `lib/firewall-lib.sh` directly was explicitly out of
the renaming task's edit scope — this entry makes that deferral trackable instead
of leaving it only in a code comment.

**Followup:** update `install.sh`'s `_install_lib_source` call and `upgrade.sh`'s
`_stage_lib` call + tier-3 `REPO_RAW` fetch to reference `lib/firewall-lib.sh`
directly, dropping every remaining `install-firewall.sh` literal (including the
`raw.githubusercontent.com` git-tree fetch tier, which serves a git SYMLINK's blob
as literal target-path text rather than dereferenced content — a real symlink here
would die-on-fetch on every fresh curl|bash install, per `lib/install-firewall.sh`'s
header). Kill criteria (from that same header): delete `lib/install-firewall.sh` +
its `lib/lib-checksums.txt` entry one release after `install.sh`/`upgrade.sh`
reference `lib/firewall-lib.sh` directly and all pinned partner edges have upgraded
past the Phase 6 rename tag; at that point the `.github/workflows/release.yml`
Phase-6 grep-guard step and `tests/test_firewall_lib_frozen_dup.sh` (parity gate
added alongside this entry) can also be deleted.

**Severity:** MEDIUM — not user-facing today (the frozen duplicate is kept in
lockstep by `tests/test_firewall_lib_frozen_dup.sh`), but every release this
cutover is deferred is another release where a firewall-rule edit has to
remember to touch two files by hand instead of one.

**File:line:** `install.sh:319` (`_install_lib_source install-firewall.sh`),
`upgrade.sh:432` (`_stage_lib "install-firewall.sh" ...`), `lib/reconcile.sh`
(`${FIREWALL_LIB:-...}` default — currently unreachable), `lib/install-firewall.sh`
(header — kill-criteria source of truth).

---

## settle-gate lacks an explicit "warming/starting" channel state (race-core comparison, 2026-07-04)

The upgrade settle-gate's cold-start hazard (a post-recreate COLD read on a not-yet-warm
container reporting a transient regression) is currently papered over by a re-poll-until-clear
heuristic rather than an explicit state. A code-research comparison against DARPA's RACE
framework (`tst-race/race-core` — otherwise not a fit for us: frozen since 2024, C++, built for
async covert-messaging over a mix-network, not our continuous-throughput relay) surfaced one
pattern worth taking as an IDEA, not code (wrong language, wrong shape everywhere else):
`racesdk/common/include/ChannelStatus.h:24` models channel state as 8 explicit values including
a distinct `CHANNEL_STARTING` vs `CHANNEL_FAILED` — "warming up" is a first-class state, not
inferred by retrying until a FAILED reading clears.

**Followup:** consider replacing (or complementing) the settle-gate's cold-start re-poll
(`upgrade.sh` cold-start retry logic, ~line 1439, and its twin in `lib/healthcheck-lib.sh`) with
an explicit STARTING status per channel/check, so a not-yet-warm container reports STARTING
rather than a transient RED that has to be waited out. Subsumed in large part by the
serve-ability-aware settle-gate rework (this same file, tracked separately, in flight as of this
writing) — revisit only if the re-poll heuristic causes a real incident after that lands.

**Severity:** LOW — the existing re-poll heuristic already covers the practical case; this is a
robustness/clarity improvement, not a live bug.

**File:line:** `upgrade.sh` (cold-start retry logic, ~line 1439), `lib/healthcheck-lib.sh`
(twin copy). Full comparison: agent memory `race-core-vs-oxpulse-channels.md`.

---

## `_patch_compose_sfu_healthcheck_cidr` live-box migration shim — remove once fleet is >= v0.14.5 (2026-07-08)

PR1 of the v0.14.5 installer/upgrade robustness arc fixed
`docker-compose.yml.tpl`'s SFU healthcheck to reference the container's own
`${SFU_METRICS_BIND}`/`${SFU_RELAY_API_BIND}` runtime env vars instead of the
raw `{{AWG_ALLOCATED_IP}}` template placeholder (which kept its `/CIDR`
suffix, breaking the wget/nc probes and causing a permanent false
"unhealthy" — confirmed on ruoxp, failingstreak=19471+). Because
`upgrade.sh` never re-renders `docker-compose.yml` from the template on an
existing box (only `image_tags` are sed-patched in place per
`manifest.yaml`'s `compose` surface `patch_only` list), the template fix
alone does not reach already-deployed boxes. `upgrade.sh` gained a second,
narrowly-anchored sed helper — `_patch_compose_sfu_healthcheck_cidr()`,
called from both compose-patch sites (`--with-templates` and plain apply
paths) — that strips the `/CIDR` suffix from the two SFU healthcheck host
tokens on every upgrade, idempotently, until the box's compose file is
eventually re-rendered fresh by v0.14.5+ install.sh.

**Followup:** delete `_patch_compose_sfu_healthcheck_cidr()`, its two call
sites, and the `sfu_healthcheck_cidr` entry in `manifest.yaml`'s `compose`
surface `patch_only` list once fleet telemetry confirms 100% of nodes are on
`>= v0.14.5` (the shim becomes a permanent no-op at that point — safe to
leave, but it is dead weight once no live box can still carry the pre-fix
template).

**Severity:** LOW — the shim itself is safe (idempotent, narrowly anchored,
covered by `tests/test_upgrade_sfu_healthcheck_heal.sh`); this entry exists
so the shim doesn't outlive its purpose.

**File:line:** `upgrade.sh` (`_patch_compose_sfu_healthcheck_cidr()` +
its two call sites in the `--with-templates` and plain-apply compose-patch
steps), `manifest.yaml:69` (`compose` surface `patch_only` list),
`docker-compose.yml.tpl` (the fixed healthcheck `test:` line — the source of
truth going forward). Cites: v0.14.5 installer/upgrade robustness arc, PR1.
## reconcile.sh's own top-level `source` still double-fetches across a self-update reexec (PR2 finding 4, acknowledged out of scope)

PR2 (finding 4a) deferred the 5-file `_stage_lib` transitive-dep staging block to a
lazy, stage-once `_stage_reconcile_transitive_deps()` so it no longer re-fetches
across `_maybe_self_update_reexec`'s re-exec boundary. `upgrade.sh`'s OWN
`_source_lib "reconcile.sh" ...` call (upgrade.sh:~500, inside the eager
`_source_lib "channel-render-lib.sh"` / `"ghcr-auth-lib.sh"` / `"reconcile.sh"`
trio near the top of the script) was deliberately left as-is: it still runs
unconditionally at top level, before `_maybe_self_update_reexec` is ever called,
so a pre-reexec parent fetches `lib/reconcile.sh` once, and the re-exec'd child
fetches it again — a single extra request per self-update, not the 5-file (10
request) double-fetch this PR fixed.

**Followup:** apply the same "defer past the self-update-reexec decision" treatment
to the `reconcile.sh` source call as `_stage_reconcile_transitive_deps` — either
fold it into that same lazy function (it is already the thing that consumes
`reconcile.sh`'s definitions) or give it its own lazy-source wrapper called from
the same 4 call sites. Left out of this PR to keep the diff to the specific
5-file staging bug this PR's live-rollout evidence covered; the `channel-render-
lib.sh` / `ghcr-auth-lib.sh` eager sources are unaffected (their consumers run
before any self-update-reexec call site, so they are not part of this class of
double-fetch).

**Severity:** LOW — 1 extra request per self-update-triggering upgrade run
(compare: the 5-file bug was 5 extra requests), and `reconcile.sh` itself is a
committed repo file with a stable size, so it is a smaller rate-limit contributor
than the 5-file block this PR already fixed.

**File:line:** `upgrade.sh:~500` (`_source_lib "reconcile.sh" ...`), `upgrade.sh`
(`_stage_reconcile_transitive_deps()` — the pattern to mirror).

---

## Single-tarball/bundle fetch for upgrade.sh's transitive deps (PR2 finding 4c, explicitly out of scope)

PR2 hardened the existing per-file fetch model (curl-native retry via
`RETRY_OPTS`, finding 4b; stage-once across self-update reexec, finding 4a) but
deliberately did NOT replace the N-separate-requests shape itself with a single
bundled tarball/archive fetch (e.g. one `tar.gz` containing all 5 transitive-dep
libs + their checksums, fetched and verified as one request instead of 5+1).
A bundle fetch would cut GitHub raw/release request volume further (helps both
the rate-limit and the Fastly/Varnish cached-429 case `RETRY_OPTS`'s header
comment notes it cannot fix) but is a materially larger, riskier change: it
touches the release pipeline (what gets built/published), the verification
model (one tarball checksum vs. per-file `lib-checksums.txt` entries), and the
resolution order (`_source_lib`/`_stage_lib`'s tier-1/2/3 fallback chain).

**Followup:** if GitHub rate-limiting on the per-file fetch model recurs after
this PR's mitigations (429-aware retry + stage-once), design a single-request
bundle fetch for the transitive-dep set as a separate, dedicated arc — NOT a
quick addition to this PR. `tests/test_release_assets.sh` documents this repo's
own history with exactly this class of change: a prior `bootstrap.sh` incident
spanned 39 releases before being fully resolved, which is the concrete precedent
for treating a release-asset-shape change as high-risk and worth its own
council-vetted plan rather than folding into a resilience PR.

**Severity:** LOW (mitigations already shipped materially reduce the exposure);
tracked here so the option is not silently forgotten if the mitigations turn out
insufficient at higher fleet scale.

**File:line:** `upgrade.sh` (`_source_lib`/`_stage_lib` — the fetch model a bundle
would replace), `tests/test_release_assets.sh` (the 39-release precedent for
release-asset-shape-change risk), `.github/workflows/release.yml` (where a bundle
would need to be built/published).

---

## Backport the 429/408 transient carve-out into xprb_curl_get_with_retry() (PR2 finding 4b, nice-to-have consistency)

`lib/channel-health-lib.sh:620` and `lib/cross-probe-lib.sh:389` both carve
HTTP 429/408 out of the general 4xx-is-terminal bucket as transient-not-fatal
(RFC 6585) — a rate-limited or timed-out channel-health/cross-probe POST retries
next tick instead of tripping the systemd-timer failure path. `lib/xprb-refresh-
lib.sh:88`'s `xprb_curl_get_with_retry()` does not: it treats EVERY 4xx
(including a 429) as terminal, on the stated rationale that "auth/permission
errors are deterministic, and burning the retry budget on one just delays
surfacing a real misconfiguration." A rate-limited xprb refresh call today
surfaces as an immediate non-retried failure instead of getting the same
2s/5s-backoff retry a transport failure or 5xx gets.

**Followup:** decide whether xprb refresh calls are frequent/bursty enough
(daily-tick re-mint, per this file's own header comment) to plausibly hit a
central-side rate limiter, and if so, add the same `429/408 → transient, treat
like a 5xx (retry within the existing 3-attempt/2s-5s budget)` carve-out inside
`xprb_curl_get_with_retry()`'s status-code branch, keeping every OTHER 4xx
terminal. This is a consistency improvement raised while cross-referencing this
repo's 3 deliberately-different retry policies for PR2 (finding 4b) — not a
reported live incident on the xprb path, so it is a nice-to-have, not urgent.

**Severity:** LOW — no observed live incident on this path; xprb's own daily-tick
cadence gives ample natural retry via the next scheduled run even without this.

**File:line:** `lib/xprb-refresh-lib.sh:88` (`xprb_curl_get_with_retry()`),
`lib/channel-health-lib.sh:620`, `lib/cross-probe-lib.sh:389` (the carve-out
pattern to mirror).

---

## `_source_lib` fallthrough does not rescue a PRESENT-but-stale tier-2 entry (PR3, v0.14.5 arc)

PR3 fixed `_source_lib`'s tier-2 permanent fail-closed on a *missing* manifest
entry (a stale `lib-checksums.txt` that predates a newly-introduced lib): the
resolver now walks candidates in tier order and falls through past any
candidate that resolves but has no opinion on the file, terminating only at a
candidate that actually contains an entry. That fix does NOT — and by design
cannot — help the sibling case: a lib whose CONTENT changed while its tier-2
entry is still PRESENT in the manifest, just now WRONG (stale hash, not a
missing line). Per this PR's own security-critical invariant (a found entry,
right or wrong, terminates the search immediately — a mismatch is never
"rescued" by trying another tier), that case correctly stays fail-closed today:
the stale-but-present tier-2 entry wins the search and dies on mismatch before
the correct tier-3 remote entry is ever consulted. There is no fix for this
inside `_source_lib`'s current resolution model — loosening "mismatch is
terminal" to "mismatch also falls through" would reopen exactly the downgrade
attack the invariant defends against (an attacker able to plant one bad
manifest entry could force fallthrough to a source they also control).

**Followup:** the real fix is keeping tier-2 current, not making the resolver
more permissive. Two options, both operator/architecture decisions out of this
PR's scope: (1) tier-2-refresh-post-sync — have `reconcile.sh`/`upgrade.sh`
overwrite `${INSTALL_LIB_DIR}/lib-checksums.txt` with the freshly-verified
manifest after every successful sync, so a staged tier-2 anchor is never more
than one run stale; or (2) a GPG-signed `SHA256SUMS.asc` for genuine
cross-origin authentication, which would let the resolver safely prefer a newer
signed manifest over an older one instead of relying on tier order alone. Note
per the THREAT MODEL header that nothing in the current release pipeline
actually populates `INSTALL_LIB_DIR` automatically today — this gap is real
only for the subset of operators who manually stage tier-2, but it is worth
tracking before that staging path becomes more common.

**Severity:** LOW — requires an operator who manually staged tier-2 in the
first place, AND that lib's content changing upstream without the operator
re-staging; the far more common "just never staged tier-2 at all" and "staged
once, new lib added later" cases are both fixed by this PR's fallthrough.

**File:line:** `upgrade.sh:_source_lib` (the mismatch-is-terminal invariant
that correctly refuses to fall through here), `upgrade.sh:_source_lib` THREAT
MODEL header (RESIDUAL bullet documents this exact gap).
