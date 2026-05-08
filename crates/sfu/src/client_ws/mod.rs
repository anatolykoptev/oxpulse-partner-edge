//! Client-facing WebSocket endpoint for browser peers.
//!
//! Phase 7 M4.A1: room-token-authenticated WS upgrade at
//! `/sfu/ws/{room_id}`.
//! Phase 7 M4.A2: SDP offer/answer exchange + Registry insertion via
//! [`session::PendingClient`] channel into the main UDP loop.
//!
//! Authentication contract: browsers cannot send an `Authorization`
//! header on a WebSocket upgrade, so the room JWT is transported via the
//! `Sec-WebSocket-Protocol` header (the workaround used by Discord,
//! Slack-web, Zoom-web). The header value is a comma-separated list:
//!
//! ```text
//! Sec-WebSocket-Protocol: oxpulse-sfu-v1, Bearer <token>
//! ```
//!
//! The server negotiates back exactly `oxpulse-sfu-v1` (the second value
//! is *carried* in the Sec-WebSocket-Protocol envelope but is not a real
//! subprotocol — RFC 6455 requires the server pick one of the offered
//! values, but doesn't require all offered values be valid subprotocols).
//!
//! Wire format for post-upgrade frames is documented on
//! [`session`].
//!
//! [`Registry`]: crate::registry::Registry

mod handler;
pub mod session;
pub(crate) mod sdp_msid;

pub use handler::{client_ws_upgrade, spawn_client_ws_api, ClientWsState};
pub use session::PendingClient;
