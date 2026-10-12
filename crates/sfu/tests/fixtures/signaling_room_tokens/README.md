Room tokens minted by the REAL oxpulse-chat signaling code
(`RoomTokenSigner::from_signing_key(..).with_binding(..).issue_with_ttl(42, "FIXTURE-ROOM", 100y)`)
with a throwaway Ed25519 key (private half not committed). Used by
`tests/room_token_from_signaling.rs` to prove the minted claims pass the real SFU verifier.

- `bound.jwt`    iss=oxpulse-chat aud=oxpulse-sfu   (signaling rollout step 3+)
- `iss_only.jwt` iss=oxpulse-chat, no aud           (signaling rollout step 2)
- `staging.jwt`  iss=oxpulse-staging aud=oxpulse-sfu (a foreign instance, same key)
- `pub.pem`      verification key

Regenerate if the claim contract changes: mint with a new key from oxpulse-chat
`crates/signaling/src/room_token.rs` (see SEC-CR-011 PR) and replace all four files.
