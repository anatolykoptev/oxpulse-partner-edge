//! Background relay task description.

/// A relay connection task enqueued when `POST /relay/connect` is accepted.
#[derive(Debug)]
pub struct RelayTask {
    /// The room the relay connection is for.
    pub room_id: String,
    /// WebSocket URL of the upstream SFU (e.g. `wss://eu.example/ws/sfu/ROOM`).
    pub upstream_url: String,
    /// Room token for authenticating the relay join on the upstream edge.
    pub upstream_room_token: String,
}
