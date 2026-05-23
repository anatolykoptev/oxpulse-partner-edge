//! HTTP client for polling the central server and reporting applied epochs.

use crate::error::{Context, Result};
use crate::params::{AwgAppliedPayload, AwgParamsLatestResponse};
use reqwest::{Client, StatusCode};
use tracing::{debug, warn};

pub struct AgentClient {
    client: Client,
    central_url: String,
    token: String,
}

impl AgentClient {
    pub fn new(central_url: String, token: String) -> Result<Self> {
        let client = Client::builder()
            .use_rustls_tls()
            .timeout(std::time::Duration::from_secs(30))
            .build()
            .context("build HTTP client")?;
        Ok(Self {
            client,
            central_url,
            token,
        })
    }

    /// Poll `GET /api/partner/awg-params/latest?component=awg`.
    /// Returns `Ok(None)` on 4xx/5xx — loop logs and retries next interval.
    pub async fn poll_latest(&self) -> Result<Option<AwgParamsLatestResponse>> {
        let url = format!(
            "{}/api/partner/awg-params/latest?component=awg",
            self.central_url
        );
        debug!(%url, "polling awg-params");

        let resp = self
            .client
            .get(&url)
            .bearer_auth(&self.token)
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

        match self
            .client
            .post(&url)
            .bearer_auth(&self.token)
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
