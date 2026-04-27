//! Client-facing WebSocket endpoint for browser peers.
//!
//! Phase 7 M4.A1: room-token-authenticated WS upgrade at
//! `/sfu/ws/{room_id}`. The actual SDP exchange and `Client` registration
//! into the [`Registry`] are M4.A2 — this module currently accepts the
//! upgrade, parks the connection, and serves as the auth seam.
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
//! [`Registry`]: crate::registry::Registry

mod handler;

pub use handler::{client_ws_upgrade, spawn_client_ws_api, ClientWsState};
