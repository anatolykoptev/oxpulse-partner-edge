//! AgentLoop: the main poll-apply-report loop.

use crate::{
    client::AgentClient,
    conf_merge::merge_obfuscation_params,
    error::{Context, Result},
    state::{load_state, save_state, AwgState},
};
use chrono::Utc;
use std::io::Write;
use std::{path::PathBuf, time::Duration};
use tempfile::NamedTempFile;
use tokio::{process::Command, time::sleep};
use tracing::{debug, error, info};

/// All configuration for the agent loop, parsed from env at startup.
pub struct AgentConfig {
    pub central_url: String,
    pub service_token_path: PathBuf,
    pub awg_conf_path: PathBuf,
    pub awg_iface: String,
    pub state_path: PathBuf,
    pub poll_interval: Duration,
    pub node_id: String,
}

pub struct AgentLoop {
    cfg: AgentConfig,
    client: AgentClient,
}

impl AgentLoop {
    pub fn new(cfg: AgentConfig) -> Result<Self> {
        let client = AgentClient::new(cfg.central_url.clone(), cfg.service_token_path.clone())?;
        Ok(Self { cfg, client })
    }

    /// Run forever. Each iteration: poll → compare → apply (if needed) → sleep.
    pub async fn run(self) -> Result<()> {
        info!(
            central_url = %self.cfg.central_url,
            iface = %self.cfg.awg_iface,
            conf = ?self.cfg.awg_conf_path,
            poll_interval = ?self.cfg.poll_interval,
            node_id = %self.cfg.node_id,
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

        // 3. Merge params into conf.
        let conf_text = tokio::fs::read_to_string(&self.cfg.awg_conf_path)
            .await
            .with_context(|| format!("read {:?}", self.cfg.awg_conf_path))?;

        let new_conf = merge_obfuscation_params(&conf_text, &response.params)
            .context("merge obfuscation params")?;

        // 4. Atomic write of new conf.
        self.write_conf_atomic(&new_conf)
            .await
            .context("atomic write conf")?;

        // 5. Apply to running kernel via awg-quick strip | awg syncconf.
        self.apply_to_kernel().await.context("apply to kernel")?;

        // 6. Update state file (only after successful kernel apply).
        let new_state = AwgState {
            last_applied_epoch: response.epoch,
            applied_at: Utc::now(),
        };
        save_state(&self.cfg.state_path, &new_state).context("save state")?;

        info!(epoch = response.epoch, "epoch applied successfully");

        // 7. Report to central (best-effort — failure does not affect the loop).
        self.client.report_applied(response.epoch).await;

        Ok(())
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
