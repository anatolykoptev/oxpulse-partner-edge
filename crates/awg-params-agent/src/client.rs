//! HTTP client for polling the central server and reporting applied epochs.

use crate::error::{Context, Result};
use crate::metrics::Metrics;
use crate::params::{AwgAppliedPayload, AwgParamsLatestResponse};
use reqwest::{Client, StatusCode};
use std::path::PathBuf;
use std::sync::Arc;
use tracing::{debug, warn};

pub struct AgentClient {
    client: Client,
    central_url: String,
    token_path: PathBuf,
    /// Task 12 shared metrics/textfile-writer state. `poll_latest` records
    /// into it directly so `awg_params_agent_poll_failures_total` /
    /// `awg_params_agent_last_success_timestamp_seconds` reflect the REAL
    /// central-reachability signal, not a value derived after the fact.
    metrics: Arc<Metrics>,
}

impl AgentClient {
    pub fn new(central_url: String, token_path: PathBuf, metrics: Arc<Metrics>) -> Result<Self> {
        let client = Client::builder()
            .use_rustls_tls()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("build HTTP client")?;
        Ok(Self {
            client,
            central_url,
            token_path,
            metrics,
        })
    }

    /// Bump `poll_failures_total` and mirror it to the textfile collector.
    /// Non-fatal: a failed textfile write is logged at debug and does not
    /// affect the polling loop.
    async fn record_poll_failure(&self) {
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_poll_failure()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                debug!(error = %e, "poll-failure textfile metric write failed (non-fatal)")
            }
            Err(e) => {
                debug!(error = %e, "poll-failure textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }

    /// Advance `last_success_timestamp_seconds` to now and mirror it to the
    /// textfile collector. Non-fatal on write failure (see
    /// [`Self::record_poll_failure`]).
    async fn record_poll_success(&self) {
        let metrics = self.metrics.clone();
        match tokio::task::spawn_blocking(move || metrics.record_poll_success()).await {
            Ok(Ok(())) => {}
            Ok(Err(e)) => {
                debug!(error = %e, "poll-success textfile metric write failed (non-fatal)")
            }
            Err(e) => {
                debug!(error = %e, "poll-success textfile metric spawn_blocking join failed (non-fatal)")
            }
        }
    }

    /// Read the service token from `token_path` on every call, so a rotated
    /// token is picked up without a process restart. Err if missing or empty.
    fn read_token(&self) -> Result<String> {
        let token = std::fs::read_to_string(&self.token_path)
            .map(|s| s.trim().to_owned())
            .with_context(|| format!("read service token from {:?}", self.token_path))?;
        if token.is_empty() {
            return Err(crate::error::anyhow!(
                "service token file {:?} is empty",
                self.token_path
            ));
        }
        Ok(token)
    }

    /// Poll `GET /api/partner/awg-params/latest?component=awg`.
    /// Returns `Ok(None)` on 4xx/5xx — loop logs and retries next interval.
    ///
    /// Task 12: this is the sole detector for central-unreachable staleness —
    /// every path that fails to reach central (network error or non-2xx)
    /// bumps `poll_failures_total`; the sole 2xx-success path advances
    /// `last_success_timestamp_seconds`. A token-read failure (local
    /// misconfig, not a central-reachability signal) is deliberately NOT
    /// recorded here.
    pub async fn poll_latest(&self) -> Result<Option<AwgParamsLatestResponse>> {
        let url = format!(
            "{}/api/partner/awg-params/latest?component=awg",
            self.central_url
        );
        debug!(%url, "polling awg-params");

        let token = self.read_token()?;
        let resp = match self.client.get(&url).bearer_auth(token).send().await {
            Ok(r) => r,
            Err(e) => {
                self.record_poll_failure().await;
                return Err(e).context("GET awg-params/latest");
            }
        };

        let status = resp.status();
        if status.is_success() {
            let body = resp
                .json::<AwgParamsLatestResponse>()
                .await
                .context("decode awg-params response")?;
            self.record_poll_success().await;
            return Ok(Some(body));
        }

        // 4xx/5xx: log, record, and return None so the loop continues.
        let body = resp.text().await.unwrap_or_default();
        warn!(
            %status,
            %body,
            "poll_latest: non-2xx response — will retry next interval"
        );
        self.record_poll_failure().await;
        Ok(None)
    }

    /// POST `{central}/api/partner/awg-params/applied` (T1.3.e receiver).
    /// Best-effort: logs on failure but does NOT propagate the error.
    ///
    /// Note: `node_id` is NOT in the request body — backend derives it from
    /// the Bearer-token auth context. See AwgAppliedPayload doc-comment.
    pub async fn report_applied(&self, epoch: i64) {
        let url = format!("{}/api/partner/awg-params/applied", self.central_url);
        let payload = AwgAppliedPayload {
            component: "awg",
            epoch,
        };

        let token = match self.read_token() {
            Ok(t) => t,
            Err(e) => {
                warn!(error = %e, %epoch, "report_applied: token read failed — skipping (best-effort)");
                return;
            }
        };

        match self
            .client
            .post(&url)
            .bearer_auth(token)
            .json(&payload)
            .send()
            .await
        {
            Ok(resp) => {
                let status = resp.status();
                if !status.is_success() {
                    // T1.3.e endpoint may not exist yet — 404 is expected.
                    let body = resp.text().await.unwrap_or_default();
                    if status == StatusCode::NOT_FOUND {
                        debug!(%epoch, "report_applied: T1.3.e endpoint not yet live (404) — skipping");
                    } else {
                        warn!(%status, %body, %epoch, "report_applied: non-2xx — ignoring (best-effort)");
                    }
                } else {
                    debug!(%epoch, "report_applied: accepted");
                }
            }
            Err(e) => {
                warn!(error = %e, %epoch, "report_applied: request failed — ignoring (best-effort)");
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::metrics::Metrics;
    use std::io::{Read, Write};
    use std::sync::Arc;

    fn write_token(dir: &std::path::Path, contents: &str) -> PathBuf {
        let path = dir.join("token");
        std::fs::write(&path, contents).expect("write token fixture");
        path
    }

    /// Minimal one-shot raw-TCP HTTP server for testing `poll_latest` against
    /// a REAL socket. This crate has no HTTP-mock dependency (Cargo.toml is
    /// out of this task's scope) — a plain `TcpListener` speaking real
    /// HTTP/1.1 bytes exercises the REAL reqwest round-trip `poll_latest`
    /// makes, which is what the Task 12 wiring assertions need (not just
    /// that `Metrics::record_*` works in isolation). Binds an ephemeral
    /// port, accepts exactly one connection, drains the request headers,
    /// writes back `response` verbatim, then the thread exits.
    fn spawn_one_shot_http_server(response: String) -> String {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").expect("bind ephemeral port");
        let addr = listener.local_addr().expect("local addr");
        std::thread::spawn(move || {
            if let Ok((mut stream, _)) = listener.accept() {
                let mut buf = Vec::new();
                let mut chunk = [0u8; 1024];
                loop {
                    match stream.read(&mut chunk) {
                        Ok(0) => break,
                        Ok(n) => {
                            buf.extend_from_slice(&chunk[..n]);
                            if buf.windows(4).any(|w| w == b"\r\n\r\n") {
                                break;
                            }
                        }
                        Err(_) => break,
                    }
                }
                let _ = stream.write_all(response.as_bytes());
                let _ = stream.flush();
            }
        });
        format!("http://{addr}")
    }

    #[test]
    fn read_token_reads_current_file_contents() {
        let mut f = tempfile::NamedTempFile::new().expect("create tempfile");
        f.write_all(b"  stkn_aaa\n").expect("write token");
        f.flush().expect("flush");
        let path = f.path().to_path_buf();

        let metrics_dir = tempfile::tempdir().expect("metrics tempdir");
        let metrics = Arc::new(Metrics::load(metrics_dir.path()));
        let client =
            AgentClient::new("https://x".into(), path.clone(), metrics).expect("build client");

        // First read: trimmed current contents.
        assert_eq!(client.read_token().expect("read token"), "stkn_aaa");

        // Rotate the token on disk; the client must pick it up without rebuild.
        std::fs::write(&path, "stkn_bbb").expect("rotate token");
        assert_eq!(client.read_token().expect("read rotated token"), "stkn_bbb");
    }

    // Task 12 (finding repro): central returns 403 → poll_failures_total must
    // increment and last_success_timestamp_seconds must stay at the
    // never-succeeded sentinel (0). Drives the REAL poll_latest HTTP path
    // (not a direct call to Metrics::record_poll_failure) so reverting the
    // wiring inside poll_latest's non-2xx branch makes this go RED even
    // though Metrics itself still works standalone.
    #[tokio::test]
    async fn poll_latest_403_records_poll_failure_leaves_last_success_at_zero() {
        let dir = tempfile::tempdir().unwrap();
        let metrics = Arc::new(Metrics::load(dir.path()));
        let token_path = write_token(dir.path(), "stkn_test\n");
        let base_url = spawn_one_shot_http_server(
            "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".to_string(),
        );

        let client = AgentClient::new(base_url, token_path, metrics).expect("build client");
        let result = client
            .poll_latest()
            .await
            .expect("a 403 must not be a transport-level error");
        assert!(
            result.is_none(),
            "non-2xx must yield Ok(None), not Some(response)"
        );

        let prom = std::fs::read_to_string(dir.path().join(crate::metrics::PROM_FILE))
            .expect("metrics textfile must exist after a recorded poll failure");
        assert!(
            prom.contains(&format!("{} 1", crate::metrics::POLL_FAILURES_METRIC)),
            "a 403 poll must bump poll_failures_total via the REAL poll_latest path. Got:\n{prom}"
        );
        assert!(
            prom.contains(&format!("{} 0", crate::metrics::LAST_SUCCESS_METRIC)),
            "last_success_timestamp must remain at the never-succeeded sentinel after only a \
             failed poll. Got:\n{prom}"
        );
    }

    // Task 12: central returns 200 with a valid body → last_success_timestamp
    // must advance off the 0 sentinel. Same real-HTTP-roundtrip rationale as
    // the 403 test above.
    #[tokio::test]
    async fn poll_latest_200_records_poll_success_advances_timestamp() {
        let dir = tempfile::tempdir().unwrap();
        let metrics = Arc::new(Metrics::load(dir.path()));
        let token_path = write_token(dir.path(), "stkn_test\n");
        let body = r#"{"epoch":1,"params":{"Jc":4,"Jmin":3,"Jmax":500,"S1":10,"S2":20,"S4":30,"H1":1,"H2":2,"H3":3,"H4":4}}"#;
        let response = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
            body.len(),
            body
        );
        let base_url = spawn_one_shot_http_server(response);

        let client = AgentClient::new(base_url, token_path, metrics).expect("build client");
        let result = client
            .poll_latest()
            .await
            .expect("a 200 must decode cleanly");
        assert!(
            result.is_some(),
            "a 200 with a valid body must yield Some(response)"
        );

        let prom = std::fs::read_to_string(dir.path().join(crate::metrics::PROM_FILE))
            .expect("metrics textfile must exist after a recorded poll success");
        let ts_line = prom
            .lines()
            .find(|l| l.starts_with(crate::metrics::LAST_SUCCESS_METRIC))
            .expect("last_success series must be present");
        let ts: i64 = ts_line
            .rsplit(' ')
            .next()
            .and_then(|v| v.parse().ok())
            .expect("last_success value must parse as an integer");
        assert!(
            ts > 0,
            "a real 2xx poll must advance last_success_timestamp off the 0 sentinel via the \
             REAL poll_latest path. Got line: {ts_line:?}"
        );
    }
}
