//! AgentLoop: the main poll-apply-report loop.

use crate::{
    client::AgentClient,
    conf_merge::merge_obfuscation_params,
    error::{Context, Result},
    params::AwgParams,
    state::{load_state, save_state, AwgState},
};
use chrono::Utc;
use rustix::fs::{flock, FlockOperation};
use std::io::Write;
use std::os::unix::fs::OpenOptionsExt;
use std::sync::atomic::{AtomicU64, Ordering};
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

/// Interim node_exporter textfile-collector metric name for lock-acquire
/// conflicts. The durable counter lands in the Task 12 exporter; this textfile
/// line keeps the signal observable until then.
const CONF_CONFLICT_METRIC: &str = "awg_params_agent_conf_write_conflicts_total";

/// Filename written under `textfile_dir` for the interim conflict counter.
/// A dedicated file (not shared with partner_edge.prom) so the node_exporter
/// textfile collector accumulates both without either clobbering the other.
const CONF_CONFLICT_PROM_FILE: &str = "awg_params_agent.prom";

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

    /// node_exporter textfile-collector directory for the interim
    /// `awg_params_agent_conf_write_conflicts_total` counter. Default matches
    /// `oxpulse-partner-edge-refresh.sh`'s textfile dir; set via
    /// `OXPULSE_TEXTFILE_DIR`.
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
    /// Interim, process-lifetime conflict counter mirrored to the textfile
    /// collector. Seeded from the existing `.prom` file at startup so the
    /// exported value stays monotonic across daemon restarts.
    conf_write_conflicts: AtomicU64,
}

impl AgentLoop {
    pub fn new(cfg: AgentConfig) -> Result<Self> {
        let client = AgentClient::new(cfg.central_url.clone(), cfg.service_token_path.clone())?;
        let seed = seed_conflict_counter(&cfg.textfile_dir);
        Ok(Self {
            cfg,
            client,
            conf_write_conflicts: AtomicU64::new(seed),
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
        if !self
            .merge_and_write_conf_locked(&response.params)
            .await
            .context("merge+write conf under lock")?
        {
            // Another writer (the installer, or an overlapping tick) held the
            // lock past the timeout. Skip this tick WITHOUT saving state so the
            // next poll re-applies the same epoch; never partial-write unlocked.
            warn!(
                lock = ?self.cfg.awg_conf_lock_path,
                "awg0.conf lock held by another writer — skipping this tick, will retry next poll"
            );
            self.record_conf_write_conflict();
            return Ok(());
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

    /// Merge new obfuscation `params` into awg0.conf and atomically rewrite it,
    /// holding the installer-shared advisory lock across the entire read→rename
    /// span (the lost-update-critical section). The lock is released when `_lock`
    /// drops at the end of this method — i.e. BEFORE the caller runs
    /// `apply_to_kernel`, keeping the critical section sub-second so the
    /// installer's `flock -w 10` never times out on a concurrent kernel apply.
    ///
    /// Returns `Ok(true)` if the conf was rewritten; `Ok(false)` if the lock
    /// could not be acquired within `lock_acquire_timeout` (caller skips this
    /// tick and retries on the next poll).
    async fn merge_and_write_conf_locked(&self, params: &AwgParams) -> Result<bool> {
        let _lock = match self.acquire_conf_lock().await.context("acquire conf lock")? {
            Some(lock) => lock,
            None => return Ok(false),
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

        let new_conf =
            merge_obfuscation_params(&conf_text, params).context("merge obfuscation params")?;

        self.write_conf_atomic(&new_conf)
            .await
            .context("atomic write conf")?;

        // `_lock` drops here → flock released before apply_to_kernel.
        Ok(true)
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

    /// Bump the interim conflict counter and best-effort mirror it to the
    /// node_exporter textfile collector. Non-fatal: a failed textfile write is
    /// logged at debug and does not affect the loop.
    fn record_conf_write_conflict(&self) {
        let value = self.conf_write_conflicts.fetch_add(1, Ordering::Relaxed) + 1;
        if let Err(e) = write_conflict_metric(&self.cfg.textfile_dir, value) {
            debug!(error = %e, "conflict textfile metric write failed (non-fatal)");
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
                let stderr = String::from_utf8_lossy(&strip_out.stderr);
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
                let stderr = String::from_utf8_lossy(&out.stderr);
                let stdout = String::from_utf8_lossy(&out.stdout);
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

        timeout(Duration::from_secs(30), apply)
            .await
            .context("awg apply timed out after 30s")?
    }
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
        std::fs::create_dir_all(parent)
            .with_context(|| format!("create lock dir {:?}", parent))?;
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

/// Best-effort write of the interim conflict counter as a node_exporter
/// textfile-collector line. Atomic replace (temp + rename) so the collector
/// never scrapes a partially written file.
fn write_conflict_metric(dir: &Path, value: u64) -> Result<()> {
    std::fs::create_dir_all(dir).with_context(|| format!("create textfile dir {:?}", dir))?;
    let body = format!(
        "# HELP {name} Ticks where the agent could not acquire the awg0.conf lock within the timeout and skipped.\n\
         # TYPE {name} counter\n\
         {name} {value}\n",
        name = CONF_CONFLICT_METRIC,
        value = value,
    );
    let mut tmp =
        NamedTempFile::new_in(dir).with_context(|| format!("temp textfile in {:?}", dir))?;
    tmp.write_all(body.as_bytes())
        .context("write conflict textfile")?;
    tmp.flush().context("flush conflict textfile")?;
    tmp.persist(dir.join(CONF_CONFLICT_PROM_FILE))
        .context("persist conflict textfile")?;
    Ok(())
}

/// Seed the process-lifetime conflict counter from the existing textfile so the
/// exported value stays monotonic across daemon restarts. Best-effort: any
/// read/parse failure yields 0 (fresh start).
fn seed_conflict_counter(dir: &Path) -> u64 {
    let path = dir.join(CONF_CONFLICT_PROM_FILE);
    let Ok(text) = std::fs::read_to_string(&path) else {
        return 0;
    };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix(CONF_CONFLICT_METRIC) {
            if let Some(tok) = rest.split_whitespace().next() {
                if let Ok(n) = tok.parse::<u64>() {
                    return n;
                }
            }
        }
    }
    0
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

    const OLD_PRIV: &str = "OLDoldOLDoldOLDoldOLDoldOLDoldOLDoldOLDold0=";
    const NEW_PRIV: &str = "NEWnewNEWnewNEWnewNEWnewNEWnewNEWnewNEWnew1=";
    const OLD_ENDPOINT: &str = "1.1.1.1:51820";
    const NEW_ENDPOINT: &str = "2.2.2.2:51820";

    fn params(jc: i64) -> AwgParams {
        AwgParams {
            jc,
            jmin: 3,
            jmax: 500,
            s1: 10,
            s2: 20,
            s4: 30,
            h1: 1,
            h2: 2,
            h3: 3,
            h4: 4,
            i1: None,
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

        // Start the agent write; it acquires the lock, reads OLD, then holds the
        // lock through the 700ms delay.
        let agent_task =
            tokio::spawn(async move { agent.merge_and_write_conf_locked(&params(7)).await });

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
        assert!(wrote, "agent should have rewritten the conf");

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
            .merge_and_write_conf_locked(&params(7))
            .await
            .expect("busy lock must not error");
        assert!(
            !wrote,
            "agent must skip (return false) when the lock is held beyond the timeout"
        );

        // The conf must be untouched (still OLD) — no partial unlocked write.
        let after = std::fs::read_to_string(&conf_path).unwrap();
        assert!(
            after.contains(&format!("PrivateKey = {OLD_PRIV}")),
            "conf must be untouched when the lock could not be acquired"
        );

        // tick() calls record_conf_write_conflict on the skip path.
        agent.record_conf_write_conflict();
        let prom = std::fs::read_to_string(textfile_dir.join(CONF_CONFLICT_PROM_FILE)).unwrap();
        assert!(
            prom.contains(&format!("{CONF_CONFLICT_METRIC} 1")),
            "conflict counter textfile must be emitted. Got:\n{prom}"
        );

        let _ = flock(&holder, FlockOperation::Unlock);
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
            .merge_and_write_conf_locked(&params(42))
            .await
            .expect("write ok");
        assert!(wrote);

        let out = std::fs::read_to_string(&conf_path).unwrap();
        assert!(out.contains("Jc = 42"), "merged Jc must be applied:\n{out}");
        assert!(
            out.contains(&format!("PrivateKey = {OLD_PRIV}")),
            "identity preserved through the merge:\n{out}"
        );
    }
}
