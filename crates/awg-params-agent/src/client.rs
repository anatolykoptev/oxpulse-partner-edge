//! HTTP client for polling the central server and reporting applied epochs.

use crate::error::{Context, Result};
use crate::params::{AwgAppliedPayload, AwgParamsLatestResponse};
use reqwest::{Client, StatusCode};
use std::path::PathBuf;
use tracing::{debug, warn};

pub struct AgentClient {
    client: Client,
    central_url: String,
    token_path: PathBuf,
}

impl AgentClient {
    pub fn new(central_url: String, token_path: PathBuf) -> Result<Self> {
        let client = Client::builder()
            .use_rustls_tls()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("build HTTP client")?;
        Ok(Self {
            client,
            central_url,
            token_path,
        })
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
    pub async fn poll_latest(&self) -> Result<Option<AwgParamsLatestResponse>> {
        let url = format!(
            "{}/api/partner/awg-params/latest?component=awg",
            self.central_url
        );
        debug!(%url, "polling awg-params");

        let token = self.read_token()?;
        let resp = self
            .client
            .get(&url)
            .bearer_auth(token)
            .send()
            .await
            .context("GET awg-params/latest")?;

        let status = resp.status();
        if status.is_success() {
            let body = resp
                .json::<AwgParamsLatestResponse>()
                .await
                .context("decode awg-params response")?;
            return Ok(Some(body));
        }

        // 4xx/5xx: log and return None so the loop continues.
        let body = resp.text().await.unwrap_or_default();
        warn!(
            %status,
            %body,
            "poll_latest: non-2xx response — will retry next interval"
        );
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
    use std::io::Write;

    #[test]
    fn read_token_reads_current_file_contents() {
        let mut f = tempfile::NamedTempFile::new().expect("create tempfile");
        f.write_all(b"  stkn_aaa\n").expect("write token");
        f.flush().expect("flush");
        let path = f.path().to_path_buf();

        let client =
            AgentClient::new("https://x".into(), path.clone()).expect("build client");

        // First read: trimmed current contents.
        assert_eq!(client.read_token().expect("read token"), "stkn_aaa");

        // Rotate the token on disk; the client must pick it up without rebuild.
        std::fs::write(&path, "stkn_bbb").expect("rotate token");
        assert_eq!(client.read_token().expect("read rotated token"), "stkn_bbb");
    }
}
