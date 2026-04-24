//! Relay subsystem — JWT auth, HTTP handler, outbound WebRTC client.

pub mod client;
pub mod handler;
pub mod task;
pub mod types;

use hmac::{Hmac, Mac};
use sha2::Sha256;
use std::time::{SystemTime, UNIX_EPOCH};

type HmacSha256 = Hmac<Sha256>;

/// Short-lived relay grant token. Signed with HMAC-SHA256.
/// Wire format: `<base64url(json_payload)>.<base64url(hmac_tag)>`.
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct RelayJwt {
    pub room_id: String,
    pub upstream_url: String,
    pub upstream_room_token: String,
    pub issued_at: u64,
    pub expires_at: u64,
    /// Unique token ID for replay prevention.
    pub jti: String,
}

#[derive(Debug)]
pub enum RelayJwtError {
    Malformed,
    InvalidSignature,
    Expired,
}

impl RelayJwt {
    pub fn sign(&self, secret: &[u8]) -> String {
        let json = serde_json::to_string(self).expect("RelayJwt is always serializable");
        let payload_b64 = base64url_encode(json.as_bytes());
        let tag = hmac_sign(secret, payload_b64.as_bytes());
        let tag_b64 = base64url_encode(&tag);
        format!("{}.{}", payload_b64, tag_b64)
    }

    pub fn verify(token: &str, secret: &[u8], now_secs: u64) -> Result<Self, RelayJwtError> {
        let (payload_b64, tag_b64) = token.split_once('.').ok_or(RelayJwtError::Malformed)?;
        // MAC-first: reject forgeries before deserialising.
        let expected = hmac_sign(secret, payload_b64.as_bytes());
        let provided = base64url_decode(tag_b64).map_err(|_| RelayJwtError::Malformed)?;
        if !constant_time_eq(&expected, &provided) {
            return Err(RelayJwtError::InvalidSignature);
        }
        let payload = base64url_decode(payload_b64).map_err(|_| RelayJwtError::Malformed)?;
        let jwt: RelayJwt =
            serde_json::from_slice(&payload).map_err(|_| RelayJwtError::Malformed)?;
        if now_secs >= jwt.expires_at {
            return Err(RelayJwtError::Expired);
        }
        // Reject tokens issued improbably far in the future (clock skew > 30s).
        if jwt.issued_at > now_secs + 30 {
            return Err(RelayJwtError::Expired);
        }
        Ok(jwt)
    }
}

pub fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}

fn hmac_sign(secret: &[u8], data: &[u8]) -> Vec<u8> {
    let mut mac = HmacSha256::new_from_slice(secret).expect("HMAC accepts any key length");
    mac.update(data);
    mac.finalize().into_bytes().to_vec()
}

fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter()
        .zip(b.iter())
        .fold(0u8, |acc, (x, y)| acc | (x ^ y))
        == 0
}

fn base64url_encode(data: &[u8]) -> String {
    encode_b64(data)
        .replace('+', "-")
        .replace('/', "_")
        .trim_end_matches('=')
        .to_string()
}

fn base64url_decode(s: &str) -> Result<Vec<u8>, ()> {
    let mut p = s.replace('-', "+").replace('_', "/");
    match p.len() % 4 {
        2 => p.push_str("=="),
        3 => p.push('='),
        _ => {}
    }
    decode_b64(&p).map_err(|_| ())
}

fn encode_b64(data: &[u8]) -> String {
    const C: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(data.len().div_ceil(3) * 4);
    let mut i = 0;
    while i + 3 <= data.len() {
        let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8) | (data[i + 2] as u32);
        out.push(C[((n >> 18) & 63) as usize] as char);
        out.push(C[((n >> 12) & 63) as usize] as char);
        out.push(C[((n >> 6) & 63) as usize] as char);
        out.push(C[(n & 63) as usize] as char);
        i += 3;
    }
    match data.len() - i {
        1 => {
            let n = (data[i] as u32) << 16;
            out.push(C[((n >> 18) & 63) as usize] as char);
            out.push(C[((n >> 12) & 63) as usize] as char);
            out.push_str("==");
        }
        2 => {
            let n = ((data[i] as u32) << 16) | ((data[i + 1] as u32) << 8);
            out.push(C[((n >> 18) & 63) as usize] as char);
            out.push(C[((n >> 12) & 63) as usize] as char);
            out.push(C[((n >> 6) & 63) as usize] as char);
            out.push('=');
        }
        _ => {}
    }
    out
}

fn decode_b64(s: &str) -> Result<Vec<u8>, ()> {
    fn val(b: u8) -> Result<u8, ()> {
        match b {
            b'A'..=b'Z' => Ok(b - b'A'),
            b'a'..=b'z' => Ok(b - b'a' + 26),
            b'0'..=b'9' => Ok(b - b'0' + 52),
            b'+' => Ok(62),
            b'/' => Ok(63),
            b'=' => Ok(0),
            _ => Err(()),
        }
    }
    let bytes = s.as_bytes();
    if !bytes.len().is_multiple_of(4) {
        return Err(());
    }
    let mut out = Vec::with_capacity(bytes.len() * 3 / 4);
    let mut i = 0;
    while i < bytes.len() {
        let (a, b, c, d) = (
            val(bytes[i])?,
            val(bytes[i + 1])?,
            val(bytes[i + 2])?,
            val(bytes[i + 3])?,
        );
        let n = ((a as u32) << 18) | ((b as u32) << 12) | ((c as u32) << 6) | (d as u32);
        out.push((n >> 16) as u8);
        if bytes[i + 2] != b'=' {
            out.push(((n >> 8) & 0xff) as u8);
        }
        if bytes[i + 3] != b'=' {
            out.push((n & 0xff) as u8);
        }
        i += 4;
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sample(issued: u64, expires: u64) -> RelayJwt {
        RelayJwt {
            room_id: "abc123".to_string(),
            upstream_url: "wss://eu.example/ws/sfu/abc123".to_string(),
            upstream_room_token: "tok".to_string(),
            issued_at: issued,
            expires_at: expires,
            jti: "test-jti".to_string(),
        }
    }

    #[test]
    fn sign_and_verify_roundtrip() {
        let jwt = sample(1000, 1300);
        let token = jwt.sign(b"secret");
        let verified = RelayJwt::verify(&token, b"secret", 1100).unwrap();
        assert_eq!(verified.room_id, "abc123");
        assert_eq!(verified.upstream_url, "wss://eu.example/ws/sfu/abc123");
    }

    #[test]
    fn verify_rejects_expired() {
        let token = sample(1000, 1300).sign(b"s");
        assert!(matches!(
            RelayJwt::verify(&token, b"s", 1400),
            Err(RelayJwtError::Expired)
        ));
    }

    #[test]
    fn verify_rejects_wrong_secret() {
        let token = sample(1000, 1300).sign(b"correct");
        assert!(matches!(
            RelayJwt::verify(&token, b"wrong", 1100),
            Err(RelayJwtError::InvalidSignature)
        ));
    }

    #[test]
    fn verify_rejects_malformed_token() {
        assert!(matches!(
            RelayJwt::verify("not.valid.here", b"s", 1000),
            Err(RelayJwtError::Malformed)
        ));
    }

    #[test]
    fn verify_rejects_tampered_payload() {
        let token = sample(1000, 1300).sign(b"s");
        let (payload, sig) = token.split_once('.').unwrap();
        let mut p = payload.to_string();
        let last = p.pop().unwrap_or('A');
        p.push(if last == 'A' { 'B' } else { 'A' });
        let tampered = format!("{p}.{sig}");
        assert!(matches!(
            RelayJwt::verify(&tampered, b"s", 1100),
            Err(RelayJwtError::InvalidSignature)
        ));
    }
}
