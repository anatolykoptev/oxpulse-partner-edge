//! AgentLoop: the main poll-apply-report loop.

use crate::{
    client::AgentClient,
    conf_merge::{merge_obfuscation_params, ClientDefaults},
    error::{Context, Result},
    metrics::{ConflictReason, Metrics},
    params::AwgParams,
    state::{load_state, save_state, AwgState},
};
use chrono::Utc;
use rustix::fs::{flock, FlockOperation};
use std::io::Write;
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
use std::sync::Arc;
use std::time::Instant;
use std::{
    path::{Path, PathBuf},
    time::Duration,
};
use tempfile::NamedTempFile;
use tokio::{process::Command, time::sleep};
use tracing::{debug, error, info, warn};

/// Poll interval while waiting for the shared awg0.conf lock (LOCK_EX|LOCK_NB
/// retry cadence). Mirrors the sub-second granularity of `flock -w`.
const LOCK_POLL_INTERVAL: Duration = Duration::from_millis(50);

/// All configuration for the agent loop, parsed from env at startup.
pub struct AgentConfig {
    pub central_url: String,
    pub service_token_path: PathBuf,
    pub awg_conf_path: PathBuf,
    pub awg_iface: String,
    pub state_path: PathBuf,
    pub poll_interval: Duration,
    pub node_id: String,
    /// Optional systemd unit to restart immediately after each successful kernel
    /// apply, before saving state.  Used by split-routing to re-assert the live
    /// AllowedIPs widening that awg syncconf just re-narrowed.
    ///
    /// Race-free guarantee: `restart_unit_after_apply` fires strictly AFTER
    /// `apply_to_kernel()` (i.e. after `awg syncconf` returns), so the widen
    /// always runs AFTER the re-narrow — not before.  A `.path` watcher on
    /// awg0.conf would fire at the rename step (step 4), BEFORE syncconf (step 5),
    /// and would therefore lose the race.  This hook is the correct solution.
    ///
    /// Set via `OXPULSE_RESTART_UNIT_AFTER_APPLY` env var.  Empty string → disabled.
    pub restart_unit_after_apply: Option<String>,

    /// Advisory lock file, shared **byte-for-byte** with the installer
    /// (`lib/install-awg.sh` flocks the same path). Both writers of
    /// `awg_conf_path` serialize on this file so a mid-install agent tick can no
    /// longer revert just-rotated identity fields (PrivateKey/Endpoint/Jc/S1-S4/
    /// H1-H4) — the awg0.conf lost-update race. Default `<awg_conf_path>.lock`,
    /// overridable via `OXPULSE_AWG_CONF_LOCK_PATH`.
    pub awg_conf_lock_path: PathBuf,

    /// Max wall time to wait for the shared conf lock before skipping the tick.
    /// Matches the installer's `flock -w 10`. Set via `OXPULSE_AWG_LOCK_TIMEOUT`.
    pub lock_acquire_timeout: Duration,

    /// node_exporter textfile-collector directory for every awg-params-agent
    /// metric (poll failures/success, conf-write conflicts, param rejections
    /// — see `metrics.rs`). Default matches `oxpulse-partner-edge-refresh.sh`'s
    /// textfile dir; set via `OXPULSE_TEXTFILE_DIR`.
    pub textfile_dir: PathBuf,

    /// **Test hook only.** Injected delay between the locked conf read and the
    /// atomic rename, used to deterministically reproduce the lost-update race
    /// in tests. Always `Duration::ZERO` in production (`load_config` never sets
    /// it non-zero).
    pub test_read_write_delay: Duration,
}

pub struct AgentLoop {
    cfg: AgentConfig,
    client: AgentClient,
    /// Task 12 shared metrics/textfile-writer state (poll failures/success,
    /// conf-write conflicts, param rejections, kernel-apply failures — see
    /// `metrics.rs`). `Arc` because `AgentClient` also records into it (poll
    /// failures/success) from its own async methods, independent of
    /// `AgentLoop`'s tick.
    metrics: Arc<Metrics>,
    /// Process-lifetime client-class defaults (I1/CPA/jc trio), drawn once
    /// from OS entropy at startup — the D2 sole generator. Each default only
    /// fires on a key absent from BOTH epoch and conf, so drawing fresh
    /// values per process start cannot re-randomize a written conf (the
    /// conf is the persistence).
    defaults: ClientDefaults,
}

impl AgentLoop {
    pub fn new(cfg: AgentConfig) -> Result<Self> {
        let metrics = Arc::new(Metrics::load(&cfg.textfile_dir));
        let client = AgentClient::new(
            cfg.central_url.clone(),
            cfg.service_token_path.clone(),
            metrics.clone(),
        )?;
        let defaults =
            ClientDefaults::generate().context("draw client-side AWG defaults from OS entropy")?;
        Ok(Self {
            cfg,
            client,
            metrics,
            defaults,
        })
    }

    /// Run forever. Each iteration: poll → compare → apply (if needed) → sleep.
    pub async fn run(self) -> Result<()> {
        info!(
            central_url = %self.cfg.central_url,
            iface = %self.cfg.awg_iface,
            conf = ?self.cfg.awg_conf_path,
            poll_interval = ?self.cfg.poll_interval,
            node_id = %self.cfg.node_id,
            restart_unit_after_apply = ?self.cfg.restart_unit_after_apply,
            "awg-params-agent starting"
        );

        // D3 startup top-up: merge(conf, None, &defaults) once per process
        // start, bypassing the epoch gate entirely. Lands the v3.1
        // client-side posture (I1/CPA/jc trio) at binary delivery instead of
        // waiting on a post-gate epoch the central writer deliberately
        // withholds. Client-class insert-if-absent only — must-match fields
        // can never be fabricated (params=None ⇒ no epoch source), the conf
        // file is the persistence (second run is a byte-identical no-op),
        // and NO state-file write happens so last_applied_epoch is never
        // advanced by a params-less merge. Best-effort: a failure here is
        // a warn, not a startup abort — the next epoch apply re-runs the
        // same insert-if-absent logic.
        self.startup_defaults_top_up().await;

        loop {
            if let Err(e) = self.tick().await {
                error!(error = %e, "tick failed — will retry next interval");
            }
            sleep(self.cfg.poll_interval).await;
        }
    }

    async fn tick(&self) -> Result<()> {
        // 1. Poll central server.
        let response = match self.client.poll_latest().await? {
            Some(r) => r,
            None => return Ok(()), // non-2xx logged in client, skip this tick
        };

        // 2. Compare against local state.
        let state = load_state(&self.cfg.state_path).context("load state")?;
        let last_epoch = state.as_ref().map(|s| s.last_applied_epoch).unwrap_or(0);

        if response.epoch <= last_epoch {
            debug!(
                epoch = response.epoch,
                last_applied = last_epoch,
                "up to date — skipping"
            );
            return Ok(());
        }

        info!(
            current_epoch = last_epoch,
            new_epoch = response.epoch,
            "new epoch — applying"
        );

        // 3+4. Read → merge → atomic-write the conf, serialized against the
        // installer (lib/install-awg.sh) via the shared advisory lock. Holding
        // the lock across the whole read→rename span is what closes the
        // lost-update race: without it, this tick could read a pre-install conf
        // and rename its stale-identity merge over the installer's just-rotated
        // PrivateKey/Endpoint. The lock is released BEFORE apply_to_kernel so the
        // installer's `flock -w 10` never waits on the up-to-30s kernel apply.
        let written = match self
            .merge_and_write_conf_locked(Some(&response.params))
            .await
            .context("merge+write conf under lock")?
        {
            Some(id) => id,
            None => {
                // Another writer (the installer, or an overlapping tick) held the
                // lock past the timeout. Skip this tick WITHOUT saving state so the
                // next poll re-applies the same epoch; never partial-write unlocked.
                warn!(
                    lock = ?self.cfg.awg_conf_lock_path,
                    "awg0.conf lock held by another writer — skipping this tick, will retry next poll"
                );
                self.record_conf_write_conflict(ConflictReason::LockTimeout)
                    .await;
                return Ok(());
            }
        };

        // 4b. Supersede guard. The lock is released before apply_to_kernel so the
        // installer's `flock -w 10` never waits on the up-to-30s kernel apply — but
        // that opens a window where configure_amneziawg (which also takes the
        // shared lock, so it can only land AFTER our release) rewrites awg0.conf
        // between our locked write and this unlocked apply. Applying then would
        // push the INSTALLER's params to the kernel while we record OUR epoch — a
        // false "epoch live" state indistinguishable from a correct apply. Re-stat
        // the conf against the identity captured under the lock; if it changed,
        // skip the apply WITHOUT saving state — the next poll re-merges the central
        // params onto the installer's fresh conf and applies cleanly. (The
        // installer's write is atomic — temp+rename in lib/install-awg.sh — so
        // awg-quick strip can never observe a torn file; the only residual is a
        // microsecond-wide TOCTOU between this re-stat and awg-quick's open(),
        // which leaves the kernel running the installer's own valid conf,
        // self-healing on the next epoch bump.)
        match self.conf_changed_since(&written) {
            Ok(false) => {}
            Ok(true) => {
                warn!(
                    conf = ?self.cfg.awg_conf_path,
                    "awg0.conf superseded by another writer after our locked write — \
                     skipping kernel apply this tick, will re-merge next poll"
                );
                self.record_conf_write_conflict(ConflictReason::ApplySuperseded)
                    .await;
                return Ok(());
            }
            Err(e) => {
                warn!(
                    error = %e,
                    conf = ?self.cfg.awg_conf_path,
                    "could not re-stat awg0.conf before apply — skipping this tick"
                );
                return Ok(());
            }
        }

        // 5. Apply to running kernel via awg-quick strip | awg syncconf.
        self.apply_to_kernel().await.context("apply to kernel")?;

        // 6. Re-assert split-routing (if configured) — strictly AFTER syncconf.
        //
        // awg syncconf re-narrows the hub peer's AllowedIPs back to /32 (the value
        // in awg0.conf).  split-routing's live `awg set peer allowed-ips 0.0.0.0/0`
        // must run AFTER syncconf to re-widen it.  This hook fires here — after
        // apply_to_kernel() returned successfully — guaranteeing the correct order.
        //
        // Best-effort: a failure here is logged and does not fail the epoch update.
        // split-routing is re-asserted by the daily refresh timer as belt-and-suspenders.
        if let Some(unit) = should_restart(self.cfg.restart_unit_after_apply.as_deref(), true) {
            self.restart_unit(unit).await;
        }

        // 7. Update state file (only after successful kernel apply).
        let new_state = AwgState {
            last_applied_epoch: response.epoch,
            applied_at: Utc::now(),
        };
        save_state(&self.cfg.state_path, &new_state).context("save state")?;

        info!(epoch = response.epoch, "epoch applied successfully");

        // 8. Report to central (best-effort — failure does not affect the loop).
        self.client.report_applied(response.epoch).await;

        Ok(())
    }

    /// Restart a systemd unit via `systemctl restart <unit>`.
    /// Best-effort: logs warn on failure, never propagates the error.
    /// Bounded by 90s timeout to match split-routing.service's TimeoutStartSec=90s —
    /// the unit may legitimately take up to 90s to start (netlink socket setup);
    /// timing out earlier would log a misleading warning while systemd continues
    /// the unit lifecycle in the background.
    ///
    /// Note: this agent is a host binary
    /// (/usr/local/bin/oxpulse-awg-params-agent), not a container.  Updates are
    /// delivered by re-installing the release asset via install-awg-params-agent.sh,
    /// not via upgrade.sh image pull.
    async fn restart_unit(&self, unit: &str) {
        use tokio::time::timeout;

        info!(%unit, "restarting unit after kernel apply");

        let unit = unit.to_owned();
        let result = timeout(Duration::from_secs(90), async move {
            Command::new("systemctl")
                .arg("restart")
                .arg(&unit)
                .status()
                .await
        })
        .await;

        match result {
            Ok(Ok(status)) if status.success() => {
                info!("unit restart OK");
            }
            Ok(Ok(status)) => {
                warn!(%status, "unit restart exited non-zero (split-routing may be stale until next refresh)");
            }
            Ok(Err(e)) => {
                warn!(error = %e, "unit restart spawn failed (split-routing may be stale until next refresh)");
            }
            Err(_) => {
                warn!("unit restart timed out after 90s — unit may still be starting; systemd will continue the unit lifecycle");
            }
        }
    }

    /// One-shot client-side top-up, run once at process start before the
    /// poll loop (D3). `merge(conf, None, &defaults)` under the shared lock:
    /// only client-class insert-if-absent writes can fire — must-match
    /// params have no epoch source here and no edge default. Never touches
    /// the state file, so the epoch gate still decides the first real apply.
    /// Best-effort by contract: a lock-busy or merge rejection is a warn —
    /// the next epoch apply runs the identical insert-if-absent logic, so
    /// nothing stays missing forever.
    async fn startup_defaults_top_up(&self) {
        match self.merge_and_write_conf_locked(None).await {
            Ok(Some(_)) => info!("startup top-up: client-side AWG defaults ensured in awg0.conf"),
            Ok(None) => warn!(
                lock = ?self.cfg.awg_conf_lock_path,
                "startup top-up skipped — conf lock held by another writer (installer mid-flight); \
                 first epoch apply re-runs the same insert-if-absent merge"
            ),
            Err(e) => warn!(
                error = %e,
                "startup top-up failed (non-fatal) — continuing; first epoch apply re-runs it"
            ),
        }
    }

    /// Merge obfuscation `params` into awg0.conf and atomically rewrite it,
    /// holding the installer-shared advisory lock across the entire read→rename
    /// span (the lost-update-critical section). The lock is released when `_lock`
    /// drops at the end of this method — i.e. BEFORE the caller runs
    /// `apply_to_kernel`, keeping the critical section sub-second so the
    /// installer's `flock -w 10` never times out on a concurrent kernel apply.
    ///
    /// `params` is `Some` on an epoch apply, `None` on the startup top-up —
    /// the `Option` wrapper sits at the params level, not per-field, so a
    /// params-less merge can only ever write client-class insert-if-absent
    /// defaults; must-match fields are unforgeable there (D3).
    ///
    /// A byte-identical merge result skips the rename entirely — pointless
    /// rewrites churn the inode (inode change = how `conf_changed_since`
    /// detects supersede, and rename is what a `.path` watcher fires on).
    ///
    /// Returns `Ok(Some(identity))` with the filesystem identity of the conf we
    /// just wrote (captured under the lock, for the caller's supersede guard); or
    /// `Ok(None)` if the lock could not be acquired within `lock_acquire_timeout`
    /// (caller skips this tick and retries on the next poll).
    async fn merge_and_write_conf_locked(
        &self,
        params: Option<&AwgParams>,
    ) -> Result<Option<ConfIdentity>> {
        let _lock = match self
            .acquire_conf_lock()
            .await
            .context("acquire conf lock")?
        {
            Some(lock) => lock,
            None => return Ok(None),
        };

        // Read the current conf — identity fields (PrivateKey/Endpoint/Address)
        // authored by the installer live here and are preserved verbatim by the
        // merge below.
        let conf_text = tokio::fs::read_to_string(&self.cfg.awg_conf_path)
            .await
            .with_context(|| format!("read {:?}", self.cfg.awg_conf_path))?;

        // Test hook: deterministically widen the read→rename window so the
        // lost-update race is reproducible in tests. Always ZERO in production.
        if !self.cfg.test_read_write_delay.is_zero() {
            sleep(self.cfg.test_read_write_delay).await;
        }

        let new_conf = match merge_obfuscation_params(&conf_text, params, &self.defaults) {
            Ok(c) => c,
            Err(e) => {
                // Task 12: a rejection here carries a `field=<name>` marker
                // (the FIELD_SPECS validators' named-field contract — charset
                // guard, S/H/range/HPK grammar, post-merge preconditions)
                // — surface it as param_rejected_total{field=...} BEFORE
                // propagating, so a hostile/MITM central is alert-visible,
                // not just logged. `extract_rejected_field` is a no-op for
                // any other error shape.
                self.record_param_rejection(&e).await;
                return Err(e).context("merge obfuscation params");
            }
        };

        if new_conf == conf_text {
            // No-op merge (e.g. a repeat top-up, or an epoch that changed
            // nothing on disk) — skip the rename so the inode stays stable
            // and no `.path` watcher fires on a nothing-changed write. The
            // identity the caller compares pre-apply is just the current file.
            let identity =
                conf_identity(&self.cfg.awg_conf_path).context("stat conf after no-op merge")?;
            debug!("merge produced a byte-identical conf — skipping atomic rewrite");
            return Ok(Some(identity));
        }

        self.write_conf_atomic(&new_conf)
            .await
            .context("atomic write conf")?;

        // Snapshot the on-disk identity of the file we just wrote, STILL under the
        // lock — no other writer can have touched it yet. The caller compares this
        // against a re-stat right before the unlocked kernel apply to catch a
        // concurrent installer supersede.
        let identity =
            conf_identity(&self.cfg.awg_conf_path).context("stat conf after atomic write")?;

        // `_lock` drops here → flock released before apply_to_kernel.
        Ok(Some(identity))
    }

    /// Re-stat `awg_conf_path` and report whether it differs from the identity
    /// captured under the lock right after our atomic write. `true` means another
    /// writer (the installer's `configure_amneziawg`, whose write also takes the
    /// shared lock and therefore lands only AFTER our release) superseded our
    /// merged conf in the window between the lock release and the kernel apply.
    /// `Err` = the file could not be stat'd; the caller treats that as a skip
    /// rather than pushing an unknown conf to the kernel.
    fn conf_changed_since(&self, written: &ConfIdentity) -> Result<bool> {
        Ok(conf_identity(&self.cfg.awg_conf_path)? != *written)
    }

    /// Acquire the shared conf advisory lock (LOCK_EX), polling until
    /// `lock_acquire_timeout`. `Ok(None)` = timed out (another writer holds it).
    /// Runs on the blocking pool because `flock(2)` and the retry sleeps block.
    async fn acquire_conf_lock(&self) -> Result<Option<ConfLock>> {
        let lock_path = self.cfg.awg_conf_lock_path.clone();
        let timeout = self.cfg.lock_acquire_timeout;
        tokio::task::spawn_blocking(move || acquire_conf_lock_blocking(&lock_path, timeout))
            .await
            .context("spawn_blocking for conf lock acquire")?
    }

    /// Bump the conf-write-conflict counter for `reason` and mirror it (along
    /// with every other series) to the node_exporter textfile collector via
    /// [`Metrics`]. Non-fatal: a failed textfile write is logged at debug and
    /// does not affect the loop. See [`ConflictReason`] for the two
    /// mechanics' semantics.
    async fn record_conf_write_conflict(&self, reason: ConflictReason) {
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_conf_write_conflict(reason)).await
        {
            Ok(Ok(())) => {}
            Ok(Err(e)) => debug!(error = %e, "conflict textfile metric write failed (non-fatal)"),
            Err(e) => {
                debug!(error = %e, "conflict textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }

    /// If `err`'s source chain carries a `field=<name>` marker (the
    /// named-field rejection contract of the FIELD_SPECS validators in
    /// `conf_merge.rs` / `params.rs`), bump `param_rejected_total{field}` and mirror
    /// it via [`Metrics`]. A no-op for every other error shape. Non-fatal on
    /// write failure, same as [`Self::record_conf_write_conflict`].
    async fn record_param_rejection(&self, err: &anyhow::Error) {
        let Some(field) = crate::metrics::extract_rejected_field(err) else {
            return;
        };
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_param_rejected(&field)).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                debug!(error = %e, "param-rejected textfile metric write failed (non-fatal)")
            }
            Err(e) => {
                debug!(error = %e, "param-rejected textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }

    /// Atomically overwrite `awg_conf_path` with `content`.
    /// Uses a temp file in the same directory + rename + dir-fsync for crash safety.
    async fn write_conf_atomic(&self, content: &str) -> Result<()> {
        let dir = self
            .cfg
            .awg_conf_path
            .parent()
            .unwrap_or(std::path::Path::new("."));

        // Blocking I/O on the write path — use spawn_blocking.
        let dir = dir.to_owned();
        let conf_path = self.cfg.awg_conf_path.clone();
        let content = content.to_owned();

        tokio::task::spawn_blocking(move || -> Result<()> {
            std::fs::create_dir_all(&dir).with_context(|| format!("create conf dir {:?}", dir))?;

            let mut tmp =
                NamedTempFile::new_in(&dir).with_context(|| format!("temp file in {:?}", dir))?;
            tmp.write_all(content.as_bytes())
                .context("write conf tmp")?;
            tmp.flush().context("flush conf tmp")?;
            tmp.as_file().sync_all().context("fsync conf tmp")?;
            tmp.persist(&conf_path)
                .with_context(|| format!("persist conf to {:?}", conf_path))?;

            // dir-fsync: durable across crash.
            if let Ok(d) = std::fs::File::open(&dir) {
                let _ = d.sync_all();
            }
            Ok(())
        })
        .await
        .context("spawn_blocking for conf write")??;

        Ok(())
    }

    /// Run `awg-quick strip <conf> | awg syncconf <iface> /dev/stdin`.
    /// Bounded by 30s timeout. Non-zero exit → Err (state file NOT updated).
    ///
    /// Every child-output byte that enters the error chain is scrubbed by
    /// [`scrub_key_material`] first: `awg-quick strip` echoes conf lines on
    /// parse errors, and the conf carries PrivateKey / PresharedKey /
    /// HeaderProtectionKey — an unscrubbed stderr string would land those
    /// keys in journald and (worse) in any error text the loop forwards.
    ///
    /// Outcome is mirrored to the apply metrics: any Err (spawn failure,
    /// non-zero exit, timeout) bumps `apply_failures_total`; success stamps
    /// `last_apply_success_timestamp_seconds`. Without the failure counter a
    /// permanently-failing apply loop is indistinguishable from a healthy
    /// one — polls stay green while epochs never reach the kernel (D9).
    async fn apply_to_kernel(&self) -> Result<()> {
        use tokio::time::timeout;

        let conf_path = self.cfg.awg_conf_path.display().to_string();
        let iface = self.cfg.awg_iface.clone();

        let apply = async {
            // Step 1: awg-quick strip <conf> → stripped bytes on stdout.
            let strip_out = Command::new("awg-quick")
                .arg("strip")
                .arg(&conf_path)
                .output()
                .await
                .context("awg-quick strip: spawn")?;

            if !strip_out.status.success() {
                let stderr = scrub_key_material(&String::from_utf8_lossy(&strip_out.stderr));
                return Err(crate::error::anyhow!(
                    "awg-quick strip failed (exit {}): {}",
                    strip_out.status,
                    stderr.trim()
                ));
            }

            // Step 2: awg syncconf <iface> /dev/stdin with stripped bytes.
            let mut syncconf = Command::new("awg")
                .arg("syncconf")
                .arg(&iface)
                .arg("/dev/stdin")
                .stdin(std::process::Stdio::piped())
                .stdout(std::process::Stdio::piped())
                .stderr(std::process::Stdio::piped())
                .spawn()
                .context("awg syncconf: spawn")?;

            // Feed stripped conf to stdin.
            if let Some(mut stdin) = syncconf.stdin.take() {
                use tokio::io::AsyncWriteExt;
                stdin
                    .write_all(&strip_out.stdout)
                    .await
                    .context("write to awg syncconf stdin")?;
                // stdin drops here, signalling EOF to the child.
            }

            let out = syncconf
                .wait_with_output()
                .await
                .context("awg syncconf: wait")?;

            if !out.status.success() {
                let stderr = scrub_key_material(&String::from_utf8_lossy(&out.stderr));
                let stdout = scrub_key_material(&String::from_utf8_lossy(&out.stdout));
                return Err(crate::error::anyhow!(
                    "awg syncconf failed (exit {}): {} {}",
                    out.status,
                    stderr.trim(),
                    stdout.trim()
                ));
            }

            info!(%iface, "awg syncconf applied");
            Ok(())
        };

        let outcome: Result<()> = match timeout(Duration::from_secs(30), apply).await {
            Ok(inner) => inner,
            Err(_) => Err(crate::error::anyhow!("awg apply timed out after 30s")),
        };
        match &outcome {
            Ok(()) => self.record_apply_success().await,
            Err(_) => self.record_apply_failure().await,
        }
        outcome
    }

    /// Bump `apply_failures_total` via [`Metrics`] — see
    /// [`Self::record_conf_write_conflict`] for the non-fatal spawn_blocking
    /// pattern this mirrors.
    async fn record_apply_failure(&self) {
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_apply_failure()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                debug!(error = %e, "apply-failure textfile metric write failed (non-fatal)")
            }
            Err(e) => {
                debug!(error = %e, "apply-failure textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }

    /// Stamp `last_apply_success_timestamp_seconds` via [`Metrics`].
    async fn record_apply_success(&self) {
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_apply_success()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                debug!(error = %e, "apply-success textfile metric write failed (non-fatal)")
            }
            Err(e) => {
                debug!(error = %e, "apply-success textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }
}

/// Redact `Key = <value>` assignments for the secret-bearing conf keys from
/// child-process output before it enters an error/log chain. Covers
/// `PrivateKey`, `PresharedKey`, and `HeaderProtectionKey` — the three
/// values whose presence in `awg-quick strip` / `awg syncconf` stderr or
/// stdout would otherwise leak key material into journald on a parse-error
/// path. Tolerates cosmetic whitespace around `=`; replaces only the value,
/// keeping the key name for diagnostic context.
fn scrub_key_material(text: &str) -> String {
    static KEY_RE: once_cell::sync::Lazy<regex::Regex> = once_cell::sync::Lazy::new(|| {
        regex::Regex::new(r"(?m)(PrivateKey|PresharedKey|HeaderProtectionKey)[ \t]*=[ \t]*[^\n]*")
            .expect("static regex is valid")
    });
    KEY_RE.replace_all(text, "$1 = [redacted]").into_owned()
}

/// Filesystem identity of awg0.conf, captured under the shared lock immediately
/// after the agent's atomic write. Compared against a re-stat before the unlocked
/// kernel apply to detect a concurrent installer supersede: the inode changes when
/// the other writer renames a fresh file over it (the installer's temp+rename and
/// the agent's own `write_conf_atomic`), and size/mtime change on any in-place
/// rewrite — so the tuple catches either shape.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
struct ConfIdentity {
    ino: u64,
    size: u64,
    mtime_sec: i64,
    mtime_nsec: i64,
}

/// Stat `path` into a `ConfIdentity`.
///
/// Deliberately a plain synchronous `stat(2)`, called directly from async code
/// (`merge_and_write_conf_locked` and `conf_changed_since`) — unlike the write
/// path (`write_conf_atomic` / `write_conflict_metric`), which is offloaded to
/// `spawn_blocking`. That offload exists because an `fsync` can stall under the
/// ARM box's disk/PSI pressure and must not block a tokio worker thread; a
/// metadata read has no writeback and cannot stall that way, so the
/// `spawn_blocking` hop is not warranted here.
fn conf_identity(path: &Path) -> Result<ConfIdentity> {
    let m = std::fs::metadata(path).with_context(|| format!("stat {:?}", path))?;
    Ok(ConfIdentity {
        ino: m.ino(),
        size: m.size(),
        mtime_sec: m.mtime(),
        mtime_nsec: m.mtime_nsec(),
    })
}

/// RAII guard for the shared awg0.conf advisory lock. Holds the open lock-file
/// descriptor; `flock(LOCK_UN)` on drop releases it deterministically (the
/// kernel also releases on fd close, but the explicit unlock documents intent).
struct ConfLock {
    file: std::fs::File,
}

impl Drop for ConfLock {
    fn drop(&mut self) {
        let _ = flock(&self.file, FlockOperation::Unlock);
    }
}

/// Blocking acquire of the shared conf lock. Opens (creating if absent) the lock
/// file, then retries `LOCK_EX|LOCK_NB` on `LOCK_POLL_INTERVAL` until `timeout`.
/// `Ok(None)` = another writer held the lock for the whole window.
fn acquire_conf_lock_blocking(lock_path: &Path, timeout: Duration) -> Result<Option<ConfLock>> {
    if let Some(parent) = lock_path.parent() {
        std::fs::create_dir_all(parent).with_context(|| format!("create lock dir {:?}", parent))?;
    }
    let file = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(false)
        .mode(0o600)
        .open(lock_path)
        .with_context(|| format!("open lock file {:?}", lock_path))?;

    let deadline = Instant::now() + timeout;
    loop {
        match flock(&file, FlockOperation::NonBlockingLockExclusive) {
            Ok(()) => return Ok(Some(ConfLock { file })),
            Err(e) if e == rustix::io::Errno::WOULDBLOCK || e == rustix::io::Errno::AGAIN => {
                if Instant::now() >= deadline {
                    return Ok(None);
                }
                std::thread::sleep(LOCK_POLL_INTERVAL);
            }
            Err(e) => {
                return Err(crate::error::anyhow!("flock {:?} failed: {}", lock_path, e));
            }
        }
    }
}

/// Decide whether to fire the post-apply unit restart hook.
///
/// Returns `Some(unit)` only when:
///   - `unit` is `Some` (hook is configured), AND
///   - `epoch_advanced` is true (an apply actually happened).
///
/// Returns `None` when the hook is disabled OR when no epoch advanced
/// (no-change tick — the hook must not fire on idle polls).
///
/// This is a pure function so it can be unit-tested without shelling out.
pub(crate) fn should_restart(unit: Option<&str>, epoch_advanced: bool) -> Option<&str> {
    match (unit, epoch_advanced) {
        (Some(u), true) => Some(u),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    // ── should_restart decision logic ────────────────────────────────────────

    #[test]
    fn hook_fires_when_configured_and_epoch_advanced() {
        assert_eq!(
            should_restart(Some("oxpulse-partner-edge-split-routing.service"), true),
            Some("oxpulse-partner-edge-split-routing.service"),
        );
    }

    #[test]
    fn hook_skipped_when_no_epoch_advanced() {
        // No-change tick: epoch did not advance → hook must NOT fire.
        assert_eq!(
            should_restart(Some("oxpulse-partner-edge-split-routing.service"), false),
            None,
        );
        // Regression: if this test passes when the epoch_advanced branch is removed,
        // the test is vacuous.  Verified: removing `epoch_advanced` arm makes it return
        // Some(u) unconditionally, causing this assertion to fail.
    }

    #[test]
    fn hook_skipped_when_not_configured() {
        // OXPULSE_RESTART_UNIT_AFTER_APPLY unset or empty → None.
        assert_eq!(should_restart(None, true), None);
        assert_eq!(should_restart(None, false), None);
    }

    #[test]
    fn hook_skipped_when_unit_empty_string_represented_as_none() {
        // Empty-string env var is converted to None in load_config (main.rs).
        // Verify should_restart also returns None for None regardless of epoch.
        assert_eq!(should_restart(None, true), None);
    }
}

// ── awg0.conf lost-update race: shared flock coordination ────────────────────
//
// These tests exercise the REAL locked write path (`merge_and_write_conf_locked`
// + `acquire_conf_lock`), not a hand-copy. Removing the flock from
// `merge_and_write_conf_locked` makes `agent_lock_prevents_identity_revert...`
// go RED — that is the falsification proof for the fix.
#[cfg(test)]
mod conf_lock_tests {
    use super::*;
    use crate::metrics::{CONF_CONFLICT_METRIC, PARAM_REJECTED_METRIC, PROM_FILE};

    const OLD_PRIV: &str = "OLDoldOLDoldOLDoldOLDoldOLDoldOLDoldOLDold0=";
    const NEW_PRIV: &str = "NEWnewNEWnewNEWnewNEWnewNEWnewNEWnewNEWnew1=";
    const OLD_ENDPOINT: &str = "1.1.1.1:51820";
    const NEW_ENDPOINT: &str = "2.2.2.2:51820";

    fn params(jc: i64) -> AwgParams {
        use crate::params::IntOrRange;
        // H tags must be >= 5 (1-4 are vanilla WG message types — the
        // FIELD_SPECS grammar now rejects them as must-match failures).
        // s1+56 != s2 holds: 10+56=66 != 20.
        AwgParams {
            jc: Some(jc),
            jmin: Some(3),
            jmax: Some(500),
            s1: 10,
            s2: 20,
            s3: None,
            s4: 30,
            h1: IntOrRange::Single(5),
            h2: IntOrRange::Single(6),
            h3: IntOrRange::Single(7),
            h4: IntOrRange::Single(8),
            i1: None,
            i2: None,
            i3: None,
            i4: None,
            i5: None,
            header_protection_key: None,
            content_padding_addition: None,
            rekey_after_time: None,
            rekey_timeout: None,
            reject_after_time: None,
            keepalive_timeout: None,
            max_handshake_attempts: None,
            random_trailers: None,
            disable_cookies: None,
        }
    }

    fn base_cfg(dir: &Path) -> AgentConfig {
        let conf = dir.join("awg0.conf");
        let mut lock = conf.clone().into_os_string();
        lock.push(".lock");
        AgentConfig {
            central_url: "http://127.0.0.1:1/unused".into(),
            service_token_path: dir.join("token"),
            awg_conf_path: conf,
            awg_iface: "awg0".into(),
            state_path: dir.join("state.json"),
            poll_interval: Duration::from_secs(30),
            node_id: "test-node".into(),
            restart_unit_after_apply: None,
            awg_conf_lock_path: PathBuf::from(lock),
            lock_acquire_timeout: Duration::from_secs(10),
            textfile_dir: dir.join("textfile"),
            test_read_write_delay: Duration::ZERO,
        }
    }

    fn seed_conf(path: &Path, priv_key: &str, endpoint: &str, jc: i64) {
        let body = format!(
            "[Interface]\n\
             PrivateKey = {priv_key}\n\
             Address = 10.0.0.9/32\n\
             ListenPort = 43811\n\
             Jc = {jc}\n\
             Jmin = 3\n\
             Jmax = 500\n\
             S1 = 10\n\
             S2 = 20\n\
             S4 = 30\n\
             H1 = 1\n\
             H2 = 2\n\
             H3 = 3\n\
             H4 = 4\n\
             Table = off\n\
             MTU = 1300\n\
             \n\
             [Peer]\n\
             PublicKey = SOMEPUBKEYbase64000000000000000000000000000=\n\
             Endpoint = {endpoint}\n\
             AllowedIPs = 10.0.0.1/32\n\
             PersistentKeepalive = 25\n"
        );
        std::fs::write(path, body).unwrap();
    }

    /// The installer's write, done under the SAME shared flock the agent uses
    /// (blocking `LOCK_EX`, mirroring `flock -w 10 9` in lib/install-awg.sh).
    /// Represents `configure_amneziawg` writing fresh identity mid-flight.
    fn installer_write_locked(
        lock_path: &Path,
        conf_path: &Path,
        priv_key: &str,
        endpoint: &str,
        jc: i64,
    ) {
        let lf = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .mode(0o600)
            .open(lock_path)
            .unwrap();
        loop {
            match flock(&lf, FlockOperation::NonBlockingLockExclusive) {
                Ok(()) => break,
                Err(e) if e == rustix::io::Errno::WOULDBLOCK || e == rustix::io::Errno::AGAIN => {
                    std::thread::sleep(Duration::from_millis(20));
                }
                Err(e) => panic!("installer flock failed: {e}"),
            }
        }
        seed_conf(conf_path, priv_key, endpoint, jc);
        let _ = flock(&lf, FlockOperation::Unlock);
    }

    // The agent reads OLD identity, then (mid its widened read→rename window) the
    // installer writes fresh NEW identity. With the shared flock the installer
    // blocks until the agent releases, so its NEW identity is the last write and
    // survives. Without the flock (regression) the agent's stale-read merge
    // renames OLD identity over NEW → this assertion fails.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_lock_prevents_identity_revert_under_concurrent_installer_write() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = base_cfg(dir.path());
        cfg.test_read_write_delay = Duration::from_millis(700);
        let conf_path = cfg.awg_conf_path.clone();
        let lock_path = cfg.awg_conf_lock_path.clone();

        seed_conf(&conf_path, OLD_PRIV, OLD_ENDPOINT, 4);
        let agent = AgentLoop::new(cfg).unwrap();

        // Give the agent's merge DISTINCT obfuscation params (Jc + S1/S2/S4) from
        // the installer's fixture so every identity field the spec names is
        // independently discriminable post-race: the installer seeds jc=9 +
        // S1=10/S2=20/S4=30 (seed_conf), the agent's losing merge would leave
        // jc=7 + S1=111/S2=122/S4=133. params()'s S-values equal seed_conf's, so
        // without this override S1-S4 could not tell winner from loser.
        let agent_params = AwgParams {
            s1: 111,
            s2: 122,
            s4: 133,
            ..params(7)
        };

        // Start the agent write; it acquires the lock, reads OLD, then holds the
        // lock through the 700ms delay.
        let agent_task =
            tokio::spawn(
                async move { agent.merge_and_write_conf_locked(Some(&agent_params)).await },
            );

        // Give the agent a head start so it is provably mid-delay (holding the
        // lock, having already read OLD) before the installer attempts its write.
        tokio::time::sleep(Duration::from_millis(200)).await;

        let inst_lock = lock_path.clone();
        let inst_conf = conf_path.clone();
        let installer_task = tokio::task::spawn_blocking(move || {
            installer_write_locked(&inst_lock, &inst_conf, NEW_PRIV, NEW_ENDPOINT, 9);
        });

        let wrote = agent_task.await.unwrap().expect("agent write ok");
        installer_task.await.unwrap();
        assert!(wrote.is_some(), "agent should have rewritten the conf");

        let final_conf = std::fs::read_to_string(&conf_path).unwrap();
        assert!(
            final_conf.contains(&format!("PrivateKey = {NEW_PRIV}")),
            "installer's fresh PrivateKey must survive the concurrent agent tick \
             (lost-update race). Final conf:\n{final_conf}"
        );
        assert!(
            final_conf.contains(&format!("Endpoint = {NEW_ENDPOINT}")),
            "installer's fresh Endpoint must survive the concurrent agent tick. \
             Final conf:\n{final_conf}"
        );
        // The spec names Jc/S1-S4 alongside PrivateKey/Endpoint: assert the FULL
        // named identity set survives, not just the two key fields. The installer's
        // jc=9 + S1=10/S2=20/S4=30 must win; the agent's stale-read merge (jc=7 +
        // S1=111/S2=122/S4=133) must NOT.
        assert!(
            final_conf.contains("Jc = 9") && !final_conf.contains("Jc = 7"),
            "installer's fresh Jc must survive the race, not the agent's stale merge. \
             Final conf:\n{final_conf}"
        );
        assert!(
            final_conf.contains("S1 = 10")
                && final_conf.contains("S2 = 20")
                && final_conf.contains("S4 = 30"),
            "installer's fresh S1/S2/S4 must survive the race. Final conf:\n{final_conf}"
        );
        assert!(
            !final_conf.contains("S1 = 111")
                && !final_conf.contains("S2 = 122")
                && !final_conf.contains("S4 = 133"),
            "the agent's stale-merge S1/S2/S4 must NOT win the race. Final conf:\n{final_conf}"
        );
    }

    // When the lock is held past the acquire timeout, the agent must NOT write
    // (returns false) and the conflict counter textfile must be emitted.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_skips_and_counts_when_lock_held_past_timeout() {
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = base_cfg(dir.path());
        cfg.lock_acquire_timeout = Duration::from_millis(200);
        let conf_path = cfg.awg_conf_path.clone();
        let lock_path = cfg.awg_conf_lock_path.clone();
        let textfile_dir = cfg.textfile_dir.clone();

        seed_conf(&conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        // A separate open-file-description holds LOCK_EX for the whole test.
        std::fs::create_dir_all(lock_path.parent().unwrap()).unwrap();
        let holder = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(false)
            .mode(0o600)
            .open(&lock_path)
            .unwrap();
        flock(&holder, FlockOperation::LockExclusive).unwrap();

        let agent = AgentLoop::new(cfg).unwrap();
        let wrote = agent
            .merge_and_write_conf_locked(Some(&params(7)))
            .await
            .expect("busy lock must not error");
        assert!(
            wrote.is_none(),
            "agent must skip (return None) when the lock is held beyond the timeout"
        );

        // The conf must be untouched (still OLD) — no partial unlocked write.
        let after = std::fs::read_to_string(&conf_path).unwrap();
        assert!(
            after.contains(&format!("PrivateKey = {OLD_PRIV}")),
            "conf must be untouched when the lock could not be acquired"
        );

        // tick() calls record_conf_write_conflict(LockTimeout) on this skip path.
        agent
            .record_conf_write_conflict(ConflictReason::LockTimeout)
            .await;
        let prom = std::fs::read_to_string(textfile_dir.join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!(
                "{CONF_CONFLICT_METRIC}{{reason=\"lock_timeout\"}} 1"
            )),
            "lock_timeout conflict series must be emitted with value 1. Got:\n{prom}"
        );
        // The other reason must exist as its own series, untouched (0) — a
        // lock-timeout skip must NOT bump apply_superseded.
        assert!(
            prom.contains(&format!(
                "{CONF_CONFLICT_METRIC}{{reason=\"apply_superseded\"}} 0"
            )),
            "apply_superseded series must be present and unbumped by a lock-timeout skip. Got:\n{prom}"
        );

        let _ = flock(&holder, FlockOperation::Unlock);
    }

    // Metric-conflation guard: the two skip mechanics keep DISTINCT reason-labeled
    // series. Record two lock_timeout skips + one apply_superseded skip via the
    // REAL record_conf_write_conflict path and assert each series carries only its
    // own count. Collapsing both reasons into one series (the conflation bug) makes
    // the 2-vs-1 assertions go RED — the falsification proof for the split.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn conflict_counter_keeps_lock_timeout_and_apply_superseded_distinct() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let textfile_dir = cfg.textfile_dir.clone();
        seed_conf(&cfg.awg_conf_path, OLD_PRIV, OLD_ENDPOINT, 4);
        let agent = AgentLoop::new(cfg).unwrap();

        agent
            .record_conf_write_conflict(ConflictReason::LockTimeout)
            .await;
        agent
            .record_conf_write_conflict(ConflictReason::ApplySuperseded)
            .await;
        agent
            .record_conf_write_conflict(ConflictReason::LockTimeout)
            .await;

        let prom = std::fs::read_to_string(textfile_dir.join(PROM_FILE)).unwrap();
        let lines: Vec<&str> = prom.lines().collect();
        // Each series must appear as a WHOLE line (not a substring) so a stray
        // newline in the multi-line HELP format string can never masquerade as a
        // valid series to the node_exporter parser.
        assert!(
            lines
                .contains(&format!("{CONF_CONFLICT_METRIC}{{reason=\"lock_timeout\"}} 2").as_str()),
            "lock_timeout must count ONLY its own two skips, as its own line. Got:\n{prom}"
        );
        assert!(
            lines.contains(
                &format!("{CONF_CONFLICT_METRIC}{{reason=\"apply_superseded\"}} 1").as_str()
            ),
            "apply_superseded must count ONLY its own one skip, as its own line. Got:\n{prom}"
        );
        // Exactly one HELP and one TYPE line for the metric (single-line HELP — a
        // raw newline in the HELP would produce a second, malformed line).
        assert_eq!(
            lines
                .iter()
                .filter(|l| l.starts_with(&format!("# HELP {CONF_CONFLICT_METRIC} ")))
                .count(),
            1,
            "exactly one single-line HELP for the metric. Got:\n{prom}"
        );
        assert_eq!(
            lines
                .iter()
                .filter(|l| l.starts_with(&format!("# TYPE {CONF_CONFLICT_METRIC} ")))
                .count(),
            1,
            "exactly one TYPE line for the metric. Got:\n{prom}"
        );
        // HELP text must describe BOTH reasons (not just lock_timeout — the round-3
        // conflation this split fixes).
        assert!(
            prom.contains("reason=\"apply_superseded\": wrote under the lock"),
            "HELP must document the apply_superseded reason. Got:\n{prom}"
        );
    }

    // Restart monotonicity per reason: a fresh AgentLoop seeded from an existing
    // textfile must resume each reason's count independently, then bump only the
    // recorded reason from its own seeded base.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn conflict_counter_reseeds_each_reason_independently_across_restart() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let textfile_dir = cfg.textfile_dir.clone();
        seed_conf(&cfg.awg_conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        // First process lifetime: 3 lock_timeout, 5 apply_superseded.
        {
            let agent = AgentLoop::new(base_cfg(dir.path())).unwrap();
            for _ in 0..3 {
                agent
                    .record_conf_write_conflict(ConflictReason::LockTimeout)
                    .await;
            }
            for _ in 0..5 {
                agent
                    .record_conf_write_conflict(ConflictReason::ApplySuperseded)
                    .await;
            }
        }

        // Second process lifetime: reseeds from the textfile, then one more
        // apply_superseded → 3 / 6, proving per-reason seeds are not conflated.
        let agent2 = AgentLoop::new(base_cfg(dir.path())).unwrap();
        agent2
            .record_conf_write_conflict(ConflictReason::ApplySuperseded)
            .await;

        let prom = std::fs::read_to_string(textfile_dir.join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!(
                "{CONF_CONFLICT_METRIC}{{reason=\"lock_timeout\"}} 3"
            )),
            "lock_timeout must resume at its seeded 3 across restart. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!(
                "{CONF_CONFLICT_METRIC}{{reason=\"apply_superseded\"}} 6"
            )),
            "apply_superseded must resume at seeded 5 then +1 = 6. Got:\n{prom}"
        );
    }

    // Positive control: with no competing writer, the agent acquires the lock,
    // merges the new obfuscation params, and rewrites the conf successfully.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_writes_merged_params_when_lock_free() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let conf_path = cfg.awg_conf_path.clone();
        seed_conf(&conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        let agent = AgentLoop::new(cfg).unwrap();
        let wrote = agent
            .merge_and_write_conf_locked(Some(&params(42)))
            .await
            .expect("write ok");
        assert!(wrote.is_some());

        let out = std::fs::read_to_string(&conf_path).unwrap();
        assert!(out.contains("Jc = 42"), "merged Jc must be applied:\n{out}");
        assert!(
            out.contains(&format!("PrivateKey = {OLD_PRIV}")),
            "identity preserved through the merge:\n{out}"
        );
    }

    // Task 12 (v2 class-split update): a malicious/MITM'd field on the
    // MUST-MATCH class path (here HeaderProtectionKey carrying an embedded
    // newline + `[Peer]` splice) is rejected by the merge AND must bump
    // param_rejected_total{field=...} via the REAL
    // merge_and_write_conf_locked path. Falsification: revert the
    // `record_param_rejection` call added to that function and this test
    // goes RED at the metric assertion while the merge still correctly
    // returns Err (the guard-level tests in params.rs / conf_merge.rs are
    // unaffected — this asserts the metric WIRING, not the guard).
    //
    // Under the v2 failure split a hostile CLIENT-side field (I1 etc.) is
    // omitted, not merge-rejected — so the metric-path assertion needs a
    // must-match field; the omit-without-render path is covered by
    // `agent_omits_malicious_client_side_field` below.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_records_param_rejected_metric_on_malicious_must_match_field() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let textfile_dir = cfg.textfile_dir.clone();
        seed_conf(&cfg.awg_conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        let agent = AgentLoop::new(cfg).unwrap();
        let malicious = AwgParams {
            header_protection_key: Some(
                "AAAA\n[Peer]\nPublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                 AllowedIPs = 0.0.0.0/0\nEndpoint = attacker.example.com:51820"
                    .to_string(),
            ),
            ..params(7)
        };

        let result = agent.merge_and_write_conf_locked(Some(&malicious)).await;
        assert!(
            result.is_err(),
            "malicious must-match HPK must be rejected by merge_and_write_conf_locked"
        );

        let prom = std::fs::read_to_string(textfile_dir.join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!(
                "{PARAM_REJECTED_METRIC}{{field=\"header_protection_key\"}} 1"
            )),
            "a malicious must-match rejection must bump param_rejected_total{{field=...}} via the \
             REAL merge_and_write_conf_locked path. Got:\n{prom}"
        );
    }

    // The client-side half of the D5 failure split, end-to-end: a hostile
    // I1 (newline + [Peer] splice) is OMITTED — merge_and_write_conf_locked
    // SUCCEEDS, the conf on disk carries none of the injected bytes, and the
    // rest of the epoch still lands. The conf file IS the assertion target
    // (this is where the splice would have reached the kernel from).
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_omits_malicious_client_side_field() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let conf_path = cfg.awg_conf_path.clone();
        seed_conf(&conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        let agent = AgentLoop::new(cfg).unwrap();
        let malicious = AwgParams {
            i1: Some(
                "<r 2>\n[Peer]\nPublicKey = ATTACKERAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n\
                 AllowedIPs = 0.0.0.0/0\nEndpoint = attacker.example.com:51820"
                    .to_string(),
            ),
            ..params(42)
        };

        let result = agent
            .merge_and_write_conf_locked(Some(&malicious))
            .await
            .expect("client-side omit must not fail the merge");
        assert!(result.is_some(), "the epoch merge must still write");

        let out = std::fs::read_to_string(&conf_path).unwrap();
        assert!(
            !out.contains("ATTACKER") && !out.contains("AllowedIPs = 0.0.0.0/0"),
            "injected bytes must never reach awg0.conf. Got:\n{out}"
        );
        assert!(
            out.contains("Jc = 42"),
            "the rest of the epoch must still apply:\n{out}"
        );
    }

    // Supersede guard (the exact residual apply_to_kernel race). After the agent's
    // locked write, an installer write — also under the shared lock, so it lands
    // only AFTER the agent's release — rewrites the conf before the kernel apply.
    // The identity captured under the lock must no longer match the on-disk conf,
    // so conf_changed_since() reports true and tick() skips the apply (which would
    // otherwise push the installer's params to the kernel while recording the
    // agent's epoch). Reverting the guard makes conf_changed_since always-false and
    // this test goes RED at the second assert.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn agent_detects_installer_supersede_between_write_and_apply() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let conf_path = cfg.awg_conf_path.clone();
        let lock_path = cfg.awg_conf_lock_path.clone();
        seed_conf(&conf_path, OLD_PRIV, OLD_ENDPOINT, 4);

        let agent = AgentLoop::new(cfg).unwrap();
        let written = agent
            .merge_and_write_conf_locked(Some(&params(7)))
            .await
            .expect("write ok")
            .expect("agent should have written the conf");

        // No supersede yet → the guard reads the conf as unchanged.
        assert!(
            !agent.conf_changed_since(&written).unwrap(),
            "conf must read as unchanged immediately after the locked write"
        );

        // Ensure a mtime delta beyond any coarse filesystem granularity, then let
        // the installer supersede the conf under the shared lock (its write lands
        // after the agent's release, mirroring configure_amneziawg mid-flight).
        tokio::time::sleep(Duration::from_millis(10)).await;
        installer_write_locked(&lock_path, &conf_path, NEW_PRIV, NEW_ENDPOINT, 9);

        // The guard now detects the supersede → tick() will skip the kernel apply
        // and re-merge next poll instead of applying the installer's params under
        // the agent's epoch.
        assert!(
            agent.conf_changed_since(&written).unwrap(),
            "conf_changed_since must detect the installer supersede so the apply is skipped"
        );
    }

    // ── v2: startup top-up, apply metrics, secret scrub ────────────────────

    // D3: `merge(conf, None, &defaults)` through the REAL locked write path.
    // Client-class insert-if-absent lands (I1/CPA on a bootstrap conf), the
    // state file is NEVER written (no epoch advance), and a second top-up is
    // a byte-identical no-op — the conf is the persistence.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn startup_top_up_inserts_client_defaults_without_epoch_advance_and_is_idempotent() {
        let dir = tempfile::tempdir().unwrap();
        let cfg = base_cfg(dir.path());
        let conf_path = cfg.awg_conf_path.clone();
        let state_path = cfg.state_path.clone();

        // Bootstrap-shape conf: no I1, no CPA, no jc trio — only the
        // must-match set + identity (what a pre-3.1 install leaves behind).
        std::fs::write(
            &conf_path,
            format!(
                "[Interface]\n\
                 PrivateKey = {OLD_PRIV}\n\
                 Address = 10.0.0.9/32\n\
                 S1 = 10\n\
                 S2 = 20\n\
                 S4 = 30\n\
                 H1 = 100\n\
                 H2 = 200\n\
                 H3 = 300\n\
                 H4 = 400\n\
                 \n\
                 [Peer]\n\
                 PublicKey = SOMEPUBKEYbase64000000000000000000000000000=\n\
                 Endpoint = {OLD_ENDPOINT}\n\
                 AllowedIPs = 10.0.0.1/32\n"
            ),
        )
        .unwrap();

        let agent = AgentLoop::new(cfg).unwrap();
        agent.startup_defaults_top_up().await;

        let out = std::fs::read_to_string(&conf_path).unwrap();
        // Client-class inserts landed — the actual drawn values come from the
        // agent's own defaults, so assert on the keys' presence and bands.
        assert!(out.contains("I1 = <r 32-256>"), "top-up I1:\n{out}");
        let cpa_line = out
            .lines()
            .find(|l| l.starts_with("ContentPaddingAddition = "))
            .expect("top-up must insert CPA");
        let cpa_val = &cpa_line["ContentPaddingAddition = ".len()..];
        assert!(
            crate::params::validate_range_string("content_padding_addition", cpa_val).is_ok(),
            "top-up CPA must satisfy its own grammar: {cpa_val:?}"
        );
        for key in ["Jc = ", "Jmin = ", "Jmax = "] {
            assert!(out.contains(key), "top-up must insert {key}:\n{out}");
        }
        // Must-match lines are never fabricated by a params-less merge.
        assert!(!out.contains("S3 =") && !out.contains("HeaderProtectionKey"));
        assert!(!out.contains("RandomTrailers") && !out.contains("DisableCookies"));
        // Identity preserved.
        assert!(out.contains(&format!("PrivateKey = {OLD_PRIV}")));
        // NO epoch advance: the state file must not exist at all.
        assert!(
            !state_path.exists(),
            "top-up must never write state (no epoch advance)"
        );

        // Idempotent: second top-up leaves the file byte-identical.
        let agent2 = AgentLoop::new(base_cfg(dir.path())).unwrap();
        agent2.startup_defaults_top_up().await;
        let out2 = std::fs::read_to_string(&conf_path).unwrap();
        assert_eq!(out, out2, "second top-up must be a byte-identical no-op");
    }

    // D9: a failed kernel apply must bump apply_failures_total and leave
    // last_apply_success_timestamp_seconds at the never-applied 0 sentinel.
    // Deterministic on every host: pointing awg_conf_path at a DIRECTORY
    // makes `awg-quick strip` fail (spawn error where the binary is absent;
    // non-zero exit where present) — either way the failure path runs.
    #[tokio::test(flavor = "multi_thread", worker_threads = 2)]
    async fn apply_failure_records_apply_failures_metric() {
        use crate::metrics::{APPLY_FAILURES_METRIC, LAST_APPLY_SUCCESS_METRIC};
        let dir = tempfile::tempdir().unwrap();
        let mut cfg = base_cfg(dir.path());
        let textfile_dir = cfg.textfile_dir.clone();
        cfg.awg_conf_path = dir.path().join("not-a-file-dir");
        std::fs::create_dir_all(&cfg.awg_conf_path).unwrap();

        let agent = AgentLoop::new(cfg).unwrap();
        let res = agent.apply_to_kernel().await;
        assert!(res.is_err(), "apply against a directory must fail");

        let prom = std::fs::read_to_string(textfile_dir.join(PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!("{APPLY_FAILURES_METRIC} 1")),
            "failed apply must bump apply_failures_total. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!("{LAST_APPLY_SUCCESS_METRIC} 0")),
            "last_apply_success must stay at the 0 sentinel. Got:\n{prom}"
        );
    }

    // Secret scrub: a child stderr echoing conf lines must lose the key
    // VALUES (PrivateKey/PresharedKey/HeaderProtectionKey) while keeping
    // the key names and non-secret content for diagnostics.
    #[test]
    fn scrub_key_material_redacts_secrets_and_keeps_context() {
        let raw = "line one\n\
                   PrivateKey = SECRETPRIVATEKEYAAAAAAAAAAAAAAAAAAAAAAA=\n\
                   PresharedKey= SECRETPSKBBBBBBBBBBBBBBBBBBBBBBBBBB=\n\
                   HeaderProtectionKey  =  SECRETHPKCCCCCCCCCCCCCCCCCCCCC=\n\
                   AllowedIPs = 0.0.0.0/0\n";
        let out = scrub_key_material(raw);
        for secret in ["SECRETPRIVATEKEY", "SECRETPSK", "SECRETHPK"] {
            assert!(
                !out.contains(secret),
                "secret {secret} must be redacted:\n{out}"
            );
        }
        assert!(out.contains("PrivateKey = [redacted]"));
        assert!(out.contains("PresharedKey = [redacted]"));
        assert!(out.contains("HeaderProtectionKey = [redacted]"));
        assert!(
            out.contains("AllowedIPs = 0.0.0.0/0"),
            "non-secret lines pass through"
        );
        assert!(out.contains("line one"));
    }
}
