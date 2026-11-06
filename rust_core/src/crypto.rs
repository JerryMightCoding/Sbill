use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{Key, XChaCha20Poly1305, XNonce};
use ed25519_dalek::{Signature, Signer, SigningKey, VerifyingKey};
use flate2::read::ZlibDecoder;
use flate2::write::ZlibEncoder;
use flate2::Compression;
use rand::rngs::OsRng;
use rand::RngCore;
use serde::Serialize;
use serde_json::{Map, Value};
use std::io::{Read, Write};

use crate::error::{CoreError, CoreResult};
use zeroize::Zeroize;

pub const EVENT_MAX_BYTES: usize = 64 * 1024;
pub const SYNC_PACK_MAX_COMPRESSED_BYTES: usize = 20 * 1024 * 1024;
pub const SYNC_PACK_MAX_DECOMPRESSED_BYTES: usize = 64 * 1024 * 1024;
pub const SYNC_PACK_MAX_EVENTS: usize = 10_000;
pub const OPTICAL_PACK_RECOMMENDED_MAX_BYTES: usize = 256 * 1024;

/// Ed25519 signing keypair for a member device.
#[derive(Clone)]
pub struct DeviceKeypair {
    signing_key: SigningKey,
}

impl DeviceKeypair {
    pub fn generate() -> Self {
        let mut csprng = OsRng;
        let signing_key = SigningKey::generate(&mut csprng);
        Self { signing_key }
    }

    pub fn from_secret_bytes(bytes: &[u8; 32]) -> Self {
        Self {
            signing_key: SigningKey::from_bytes(bytes),
        }
    }

    pub fn secret_bytes(&self) -> [u8; 32] {
        self.signing_key.to_bytes()
    }

    pub fn public_key_b64(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.signing_key.verifying_key().as_bytes())
    }

    pub fn short_fingerprint(&self) -> String {
        let hash = blake3::hash(self.signing_key.verifying_key().as_bytes());
        hex::encode(&hash.as_bytes()[..6]).to_uppercase()
    }

    pub fn sign(&self, message: &[u8]) -> String {
        let sig: Signature = self.signing_key.sign(message);
        URL_SAFE_NO_PAD.encode(sig.to_bytes())
    }
}

pub fn verify_ed25519_signature(
    public_key_b64: &str,
    message: &[u8],
    signature_b64: &str,
) -> CoreResult<()> {
    let pk_bytes = URL_SAFE_NO_PAD
        .decode(public_key_b64)
        .map_err(|e| CoreError::Crypto(format!("invalid public key base64: {e}")))?;
    let pk_array: [u8; 32] = pk_bytes
        .try_into()
        .map_err(|_| CoreError::Crypto("Ed25519 public key must be 32 bytes".to_string()))?;
    let verifying_key = VerifyingKey::from_bytes(&pk_array)
        .map_err(|e| CoreError::Crypto(format!("invalid Ed25519 public key: {e}")))?;

    let sig_bytes = URL_SAFE_NO_PAD
        .decode(signature_b64)
        .map_err(|e| CoreError::Crypto(format!("invalid signature base64: {e}")))?;
    let sig_array: [u8; 64] = sig_bytes
        .try_into()
        .map_err(|_| CoreError::Crypto("Ed25519 signature must be 64 bytes".to_string()))?;
    let signature = Signature::from_bytes(&sig_array);

    verifying_key
        .verify_strict(message, &signature)
        .map_err(|e| CoreError::Crypto(format!("Ed25519 signature verification failed: {e}")))
}

/// 256-bit group symmetric key using XChaCha20-Poly1305 (192-bit random nonce).
#[derive(Clone)]
pub struct GroupCipher {
    key_bytes: [u8; 32],
    key_epoch: u32,
}

impl Drop for GroupCipher {
    fn drop(&mut self) { self.key_bytes.zeroize(); }
}

impl GroupCipher {
    pub fn generate(key_epoch: u32) -> Self {
        let mut key_bytes = [0u8; 32];
        OsRng.fill_bytes(&mut key_bytes);
        Self {
            key_bytes,
            key_epoch,
        }
    }

    pub fn from_raw(key_bytes: [u8; 32], key_epoch: u32) -> Self {
        Self {
            key_bytes,
            key_epoch,
        }
    }

    pub fn from_b64(key_b64: &str, key_epoch: u32) -> CoreResult<Self> {
        let decoded = URL_SAFE_NO_PAD
            .decode(key_b64)
            .map_err(|e| CoreError::Crypto(format!("invalid group key base64: {e}")))?;
        let key_bytes: [u8; 32] = decoded
            .try_into()
            .map_err(|_| CoreError::Crypto("group key must be 32 bytes".to_string()))?;
        Ok(Self {
            key_bytes,
            key_epoch,
        })
    }

    pub fn to_b64(&self) -> String {
        URL_SAFE_NO_PAD.encode(self.key_bytes)
    }

    pub fn key_epoch(&self) -> u32 {
        self.key_epoch
    }

    /// Encrypts plaintext with a fresh 24-byte random nonce and associated data (AAD).
    /// Returns `nonce (24B) || ciphertext_with_tag`.
    pub fn encrypt(&self, plaintext: &[u8], aad: &[u8]) -> CoreResult<Vec<u8>> {
        let cipher = XChaCha20Poly1305::new(Key::from_slice(&self.key_bytes));
        let mut nonce_bytes = [0u8; 24];
        OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = XNonce::from_slice(&nonce_bytes);
        let ciphertext = cipher
            .encrypt(
                nonce,
                Payload {
                    msg: plaintext,
                    aad,
                },
            )
            .map_err(|e| CoreError::Crypto(format!("XChaCha20-Poly1305 encryption failed: {e}")))?;
        let mut out = Vec::with_capacity(24 + ciphertext.len());
        out.extend_from_slice(&nonce_bytes);
        out.extend_from_slice(&ciphertext);
        Ok(out)
    }

    /// Decrypts `nonce (24B) || ciphertext_with_tag` with associated data (AAD).
    pub fn decrypt(&self, nonce_and_ciphertext: &[u8], aad: &[u8]) -> CoreResult<Vec<u8>> {
        if nonce_and_ciphertext.len() < 24 + 16 {
            return Err(CoreError::Crypto(
                "ciphertext too short for XChaCha20-Poly1305 nonce and tag".to_string(),
            ));
        }
        let (nonce_bytes, ciphertext) = nonce_and_ciphertext.split_at(24);
        let cipher = XChaCha20Poly1305::new(Key::from_slice(&self.key_bytes));
        let nonce = XNonce::from_slice(nonce_bytes);
        cipher
            .decrypt(
                nonce,
                Payload {
                    msg: ciphertext,
                    aad,
                },
            )
            .map_err(|_| {
                CoreError::Crypto(
                    "XChaCha20-Poly1305 decryption failed (wrong key, wrong group AAD, or tampered payload)"
                        .to_string(),
                )
            })
    }
}

/// Recursively canonicalizes a JSON Value by sorting all object keys lexicographically
/// and serializing without whitespace.
pub fn canonicalize_json_value(value: &Value) -> Value {
    match value {
        Value::Object(map) => {
            let mut sorted_keys: Vec<&String> = map.keys().collect();
            sorted_keys.sort();
            let mut out = Map::with_capacity(map.len());
            for k in sorted_keys {
                if let Some(v) = map.get(k) {
                    out.insert(k.clone(), canonicalize_json_value(v));
                }
            }
            Value::Object(out)
        }
        Value::Array(items) => Value::Array(items.iter().map(canonicalize_json_value).collect()),
        other => other.clone(),
    }
}

pub fn canonical_json_bytes<T: Serialize>(value: &T) -> CoreResult<Vec<u8>> {
    let raw_val = serde_json::to_value(value)?;
    let canonical = canonicalize_json_value(&raw_val);
    Ok(serde_json::to_vec(&canonical)?)
}

pub fn blake3_hash_b64(bytes: &[u8]) -> String {
    let hash = blake3::hash(bytes);
    URL_SAFE_NO_PAD.encode(hash.as_bytes())
}

pub fn blake3_hash_hex(bytes: &[u8]) -> String {
    blake3::hash(bytes).to_hex().to_string()
}

pub fn compress_zlib(bytes: &[u8]) -> CoreResult<Vec<u8>> {
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    encoder
        .write_all(bytes)
        .map_err(|e| CoreError::SyncPackage(format!("zlib compression failed: {e}")))?;
    encoder
        .finish()
        .map_err(|e| CoreError::SyncPackage(format!("zlib finish failed: {e}")))
}

pub fn decompress_zlib_bounded(compressed: &[u8], max_bytes: usize) -> CoreResult<Vec<u8>> {
    let decoder = ZlibDecoder::new(compressed);
    let mut limited = decoder.take((max_bytes as u64) + 1);
    let mut out = Vec::new();
    limited
        .read_to_end(&mut out)
        .map_err(|e| CoreError::SyncPackage(format!("zlib decompression failed: {e}")))?;
    if out.len() > max_bytes {
        return Err(CoreError::LimitExceeded(format!(
            "decompressed payload exceeds limit of {max_bytes} bytes"
        )));
    }
    Ok(out)
}
