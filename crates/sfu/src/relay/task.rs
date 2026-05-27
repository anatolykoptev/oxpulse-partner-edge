//! Background relay task description.

/// A relay connection task enqueued when `POST /relay/connect` is accepted.
#[derive(Debug)]
pub struct RelayTask {
    /// The room the relay connection is for.
    pub room_id: String,
    /// WebSocket URL of the primary (first allowed) upstream SFU.
    /// Kept for back-compat with the single-hub path; equals `upstream_candidates[0]`
    /// when the B0 candidate list is active.
    pub upstream_url: String,
    /// Room token for authenticating the relay join on the upstream edge.
    pub upstream_room_token: String,
    /// B0: Ordered list of allowed upstream hub URLs to attempt in sequence.
    /// Falls back to `[upstream_url]` when the signed JWT carried no candidates.
    pub upstream_candidates: Vec<String>,
}
