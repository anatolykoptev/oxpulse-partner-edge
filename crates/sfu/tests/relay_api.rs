//! Integration tests for the relay HTTP API.

use oxpulse_sfu::relay::handler::spawn_relay_api;
use oxpulse_sfu::relay::task::RelayTask;
use oxpulse_sfu::relay::types::{RelayConnectRequest, RelayConnectResponse};
use oxpulse_sfu::relay::{now_unix_secs, RelayJwt};
use reqwest::Client;
use std::sync::Arc;
use std::time::Duration;
use tokio::net::TcpListener;
use tokio::sync::mpsc;

async fn start_test_api(secret: Arc<[u8]>) -> (String, mpsc::Receiver<RelayTask>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let (tx, rx) = mpsc::channel::<RelayTask>(8);
    spawn_relay_api(listener, secret, tx).unwrap();
    (format!("http://{addr}"), rx)
}

fn make_token(secret: &[u8], room_id: &str) -> String {
    let now = now_unix_secs();
    RelayJwt {
        room_id: room_id.to_string(),
        upstream_url: "wss://us.example/ws/sfu/test".to_string(),
        upstream_room_token: "tok".to_string(),
        issued_at: now,
        expires_at: now + 60,
    }
    .sign(secret)
}

#[tokio::test]
async fn relay_connect_accepts_valid_jwt() {
    let secret: Arc<[u8]> = Arc::from(b"test-secret".as_slice());
    let (base, mut rx) = start_test_api(Arc::clone(&secret)).await;
    let token = make_token(&secret, "room-abc");
    let resp: RelayConnectResponse = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest {
            relay_token: token,
            upstream_url: "wss://us.example/ws/sfu/room-abc".to_string(),
            upstream_room_token: "tok".to_string(),
        })
        .send()
        .await
        .unwrap()
        .json()
        .await
        .unwrap();
    assert_eq!(resp.status, "ok");
    assert!(resp.relay_id.is_some());
    let task = tokio::time::timeout(Duration::from_secs(1), rx.recv())
        .await
        .expect("task within 1s")
        .expect("channel open");
    assert_eq!(task.room_id, "room-abc");
}

#[tokio::test]
async fn relay_connect_rejects_invalid_jwt() {
    let secret: Arc<[u8]> = Arc::from(b"correct".as_slice());
    let (base, _rx) = start_test_api(Arc::clone(&secret)).await;
    let status = Client::new()
        .post(format!("{base}/relay/connect"))
        .json(&RelayConnectRequest {
            relay_token: "completely.invalid".to_string(),
            upstream_url: "wss://x.example/ws/sfu/x".to_string(),
            upstream_room_token: "tok".to_string(),
        })
        .send()
        .await
        .unwrap()
        .status();
    assert!(status.is_client_error(), "expected 4xx, got {status}");
}
