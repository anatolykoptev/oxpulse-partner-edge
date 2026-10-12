//! SEC-CR-011 cross-repo contract: tokens minted by the REAL oxpulse-chat
//! signaling `RoomTokenSigner` (committed fixtures, 100-year TTL) must pass the
//! REAL SFU verifier under the matching policy and be rejected where they
//! should. The fixtures are not hand-encoded on this side.

use oxpulse_sfu::room_auth::{verify_room_token_ed25519_with, RoomAuthError, RoomTokenPolicy};

const PUB: &str = include_str!("fixtures/signaling_room_tokens/pub.pem");
const BOUND: &str = include_str!("fixtures/signaling_room_tokens/bound.jwt");
const ISS_ONLY: &str = include_str!("fixtures/signaling_room_tokens/iss_only.jwt");
const STAGING: &str = include_str!("fixtures/signaling_room_tokens/staging.jwt");
const ROOM: &str = "FIXTURE-ROOM";

fn strict() -> RoomTokenPolicy {
    RoomTokenPolicy::new(vec!["oxpulse-chat".into()], "oxpulse-sfu", true).unwrap()
}

fn verify(p: &RoomTokenPolicy, t: &str) -> Result<u64, RoomAuthError> {
    verify_room_token_ed25519_with(p, t.trim(), ROOM, PUB).map(|c| c.sub)
}

#[test]
fn signaling_minted_bound_token_passes_strict_sfu() {
    assert_eq!(verify(&strict(), BOUND).unwrap(), 42);
}

#[test]
fn issuer_only_token_passes_transition_but_not_strict() {
    // Rollout step 2 (signaling mints iss, not yet aud): accepted while the
    // flag is off, refused once binding is required.
    let transition =
        RoomTokenPolicy::new(vec!["oxpulse-chat".into()], "oxpulse-sfu", false).unwrap();
    assert!(verify(&transition, ISS_ONLY).is_ok());
    assert!(matches!(
        verify(&strict(), ISS_ONLY),
        Err(RoomAuthError::Malformed)
    ));
}

#[test]
fn foreign_instance_token_signed_with_the_same_key_is_rejected() {
    // Same key, valid signature, valid exp — only `iss` differs. This is the
    // SEC-CR-011 attack: public staging holding prod's key.
    assert!(matches!(
        verify(&strict(), STAGING),
        Err(RoomAuthError::Malformed)
    ));
    let transition =
        RoomTokenPolicy::new(vec!["oxpulse-chat".into()], "oxpulse-sfu", false).unwrap();
    assert!(matches!(
        verify(&transition, STAGING),
        Err(RoomAuthError::Malformed)
    ));
}
