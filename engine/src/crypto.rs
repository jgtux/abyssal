//! Whole-archive AES-256-GCM decryption for Abyssal's encrypted-archive
//! format.
//!
//! Mirrors `Abyssal.Crypto.AesGcm.wrap/2` on the Elixir side byte-for-
//! byte -- this is the cross-language contract for the whole feature,
//! both sides must agree on it exactly:
//!
//!   offset 0..4    magic:   4 bytes, ASCII "ABY1"
//!   offset 4..16   nonce:   12 bytes (AES-GCM standard IV), random per publish
//!   offset 16..EOF ciphertext with its 16-byte GCM tag appended
//!
//! `mount_root_memfs` (see archive.rs) takes one pointer+length upfront,
//! not a stream, so encryption is whole-archive: the entire `.dwarfs`
//! file is one AEAD blob, decrypted into an owned buffer before the
//! engine ever mounts it.

use aes_gcm::aead::{Aead, KeyInit};
use aes_gcm::{Aes256Gcm, Key, Nonce};

use crate::archive::EngineError;

pub const MAGIC: &[u8; 4] = b"ABY1";
const NONCE_LEN: usize = 12;
const HEADER_LEN: usize = MAGIC.len() + NONCE_LEN;
const KEY_LEN: usize = 32;

/// Sniffs the first 4 bytes for the magic header -- this is how the
/// engine decides "is this encrypted?" with zero extra proto plumbing
/// beyond the key itself. Genuine DwarFS superblocks have their own
/// distinct magic, so there's no collision risk.
pub fn is_encrypted(data: &[u8]) -> bool {
    data.len() >= MAGIC.len() && &data[..MAGIC.len()] == MAGIC
}

/// Decrypts a whole archive file's bytes (as produced by
/// `Abyssal.Crypto.AesGcm.wrap/2`) into an owned buffer using `key` (must
/// be exactly 32 bytes). A wrong key and a tampered/corrupted ciphertext
/// are indistinguishable failures from AES-GCM's perspective -- both
/// surface as `EngineError::DecryptFailed`.
pub fn decrypt_archive(data: &[u8], key: &[u8]) -> Result<Vec<u8>, EngineError> {
    if key.len() != KEY_LEN {
        return Err(EngineError::InvalidKey);
    }
    if data.len() < HEADER_LEN {
        return Err(EngineError::CorruptArchive);
    }

    let nonce_bytes = &data[MAGIC.len()..HEADER_LEN];
    let ciphertext_with_tag = &data[HEADER_LEN..];

    let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
    let nonce = Nonce::from_slice(nonce_bytes);

    cipher
        .decrypt(nonce, ciphertext_with_tag)
        .map_err(|_| EngineError::DecryptFailed)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn encrypt_for_test(plaintext: &[u8], key: &[u8; 32]) -> Vec<u8> {
        use aes_gcm::aead::rand_core::RngCore;

        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
        let mut nonce_bytes = [0u8; NONCE_LEN];
        aes_gcm::aead::OsRng.fill_bytes(&mut nonce_bytes);
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext_with_tag = cipher.encrypt(nonce, plaintext).expect("encrypt");

        let mut out = Vec::with_capacity(HEADER_LEN + ciphertext_with_tag.len());
        out.extend_from_slice(MAGIC);
        out.extend_from_slice(&nonce_bytes);
        out.extend_from_slice(&ciphertext_with_tag);
        out
    }

    #[test]
    fn is_encrypted_detects_magic() {
        assert!(is_encrypted(b"ABY1rest of file"));
        assert!(!is_encrypted(b"DWRFS other format"));
        assert!(!is_encrypted(b"AB"));
    }

    #[test]
    fn decrypt_archive_round_trips_with_correct_key() {
        let key = [7u8; 32];
        let wrapped = encrypt_for_test(b"hello world", &key);

        let plaintext = decrypt_archive(&wrapped, &key).expect("decrypt");
        assert_eq!(plaintext, b"hello world");
    }

    #[test]
    fn decrypt_archive_fails_with_wrong_key() {
        let key = [7u8; 32];
        let wrong_key = [9u8; 32];
        let wrapped = encrypt_for_test(b"hello world", &key);

        let result = decrypt_archive(&wrapped, &wrong_key);
        assert!(matches!(result, Err(EngineError::DecryptFailed)));
    }

    #[test]
    fn decrypt_archive_rejects_wrong_key_length() {
        let key = [7u8; 32];
        let wrapped = encrypt_for_test(b"hello world", &key);

        let result = decrypt_archive(&wrapped, &[1, 2, 3]);
        assert!(matches!(result, Err(EngineError::InvalidKey)));
    }

    #[test]
    fn decrypt_archive_rejects_truncated_header() {
        let result = decrypt_archive(b"ABY1short", &[7u8; 32]);
        assert!(matches!(result, Err(EngineError::CorruptArchive)));
    }
}
