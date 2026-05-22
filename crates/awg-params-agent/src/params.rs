use serde::{Deserialize, Serialize};

/// AmneziaWG obfuscation parameters — 10 fields matching the server's
/// `awg_params_epoch.params` JSONB schema and the orchestrator's `AwgParams`
/// struct in `cmd/orchestrator/awg_params.go`.
///
/// I1 is intentionally absent: the orchestrator and installer both carry 10
/// params. When the server schema extends to I1, add the field and its regex
/// in `conf_merge.rs`.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct AwgParams {
    #[serde(rename = "Jc")]
    pub jc: i64,
    #[serde(rename = "Jmin")]
    pub jmin: i64,
    #[serde(rename = "Jmax")]
    pub jmax: i64,
    #[serde(rename = "S1")]
    pub s1: i64,
    #[serde(rename = "S2")]
    pub s2: i64,
    #[serde(rename = "S4")]
    pub s4: i64,
    #[serde(rename = "H1")]
    pub h1: i64,
    #[serde(rename = "H2")]
    pub h2: i64,
    #[serde(rename = "H3")]
    pub h3: i64,
    #[serde(rename = "H4")]
    pub h4: i64,
}

/// Response shape from `GET /api/partner/awg-params/latest?component=awg`.
/// The `params` field is the JSONB blob; `epoch` is a monotonically increasing
/// integer (Postgres BIGINT) identifying the rotation round.
#[derive(Debug, Deserialize)]
pub struct AwgParamsLatestResponse {
    pub epoch: i64,
    pub params: AwgParams,
}

/// Payload for `POST /api/partner/awg-params/applied` (T1.3.e receiver).
/// Sent best-effort; loop continues on failure.
#[derive(Debug, Serialize)]
pub struct AwgAppliedPayload {
    pub node_id: String,
    pub component: &'static str,
    pub epoch: i64,
}
