use serde::{Deserialize, Serialize};

/// AmneziaWG obfuscation parameters — 11 fields matching the server's
/// `awg_params_epoch.params` JSONB schema and the orchestrator's `AwgParams`
/// struct in `cmd/orchestrator/awg_params.go`.
///
/// I1 (InitString) is a string value containing arbitrary bytes rendered as
/// angle-bracket tokens (e.g. `<r 2><b 0x0100>...`). Added in T1.3.x lockstep
/// with the Go orchestrator fix. Deserialization uses `default` so that
/// pre-I1 DB rows (where the field is absent from JSON) deserialize without
/// error — `i1` will be `None` and conf_merge skips the I1 line.
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
    /// InitString — arbitrary bytes as conf literal. `None` when absent from DB row.
    #[serde(rename = "I1", default)]
    pub i1: Option<String>,
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
///
/// Note: `node_id` is NOT in this payload — backend derives it from the
/// Bearer-token auth context (lookup partner_nodes by service_token_hash).
/// Backend struct AwgParamsAppliedRequest uses #[serde(deny_unknown_fields)],
/// so sending node_id here would 422. Security-correct: client can't spoof
/// which node it claims to be by passing a different node_id in the body.
#[derive(Debug, Serialize)]
pub struct AwgAppliedPayload {
    pub component: &'static str,
    pub epoch: i64,
}
