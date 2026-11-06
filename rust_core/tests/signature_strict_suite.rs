use base64::{Engine, engine::general_purpose::URL_SAFE_NO_PAD};
use sbill_core::crypto::verify_ed25519_signature;

#[test]
fn small_order_public_key_and_signature_cannot_authorize_events() {
    let mut public = [0u8; 32];
    public[0] = 1;
    let mut signature = [0u8; 64];
    signature[0] = 1;
    assert!(verify_ed25519_signature(&URL_SAFE_NO_PAD.encode(public), b"untrusted claim",
        &URL_SAFE_NO_PAD.encode(signature)).is_err());
}
