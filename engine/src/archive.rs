//! Safe wrapper around libdwarfs-sys.
//!
//! libdwarfs-wr's mount state is process-global (`mount_root_memfs` /
//! `unmount_root_memfs`, not a per-archive handle -- see the design note
//! in proto/abyssal/engine/v1/engine.proto). `read_range` is therefore
//! deliberately self-contained per call: mmap the archive, mount it at
//! root, open+pread+close the entry, unmount, all serialized behind
//! MOUNT_LOCK. This is a known, temporary simplification for the
//! skeleton -- real multi-dataset concurrency would need `mount_memfs`
//! sub-mounts under one long-lived root instead of remounting root every
//! call.
use std::ffi::CString;
use std::os::raw::c_char;
use std::path::Path;
use std::sync::Mutex;

use memmap2::Mmap;

use crate::crypto;

static MOUNT_LOCK: Mutex<()> = Mutex::new(());

// `length` comes straight from an unauthenticated gRPC request with no
// other bound on it. `vec![0u8; length as usize]` below calls the global
// allocator directly -- on allocation failure that's `handle_alloc_error`,
// which *aborts the process*, not a catchable panic (so spawn_blocking's
// panic-capturing in service.rs would NOT save it). A single request with
// e.g. length = u64::MAX would take down the whole engine for every other
// in-flight and future request. 64 MiB is a generous cap for a range-read
// API -- large enough for any real chunked-read use, small enough to
// never risk an allocation failure in the first place.
const MAX_READ_LENGTH: u64 = 64 * 1024 * 1024;

#[derive(Debug)]
pub enum EngineError {
    Io(std::io::Error),
    InvalidPath,
    Mount(i32),
    Open(i32),
    Read(i32),
    MissingKey,
    InvalidKey,
    DecryptFailed,
    CorruptArchive,
    LengthTooLarge,
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Io(e) => write!(f, "io error: {e}"),
            EngineError::InvalidPath => write!(f, "entry path is not a valid C string"),
            EngineError::Mount(rc) => write!(f, "mount_root_memfs failed: {rc}"),
            EngineError::Open(rc) => write!(f, "tebako_open failed: {rc}"),
            EngineError::Read(rc) => write!(f, "tebako_pread failed: {rc}"),
            EngineError::MissingKey => write!(f, "archive is encrypted; key material required"),
            EngineError::InvalidKey => write!(f, "key must be exactly 32 bytes"),
            EngineError::DecryptFailed => {
                write!(f, "decryption failed: wrong key or corrupted archive")
            }
            EngineError::CorruptArchive => write!(f, "encrypted archive header is malformed"),
            EngineError::LengthTooLarge => {
                write!(
                    f,
                    "length exceeds the maximum of {MAX_READ_LENGTH} bytes per read"
                )
            }
        }
    }
}

impl std::error::Error for EngineError {}

pub struct RangeResult {
    pub data: Vec<u8>,
    pub eof: bool,
}

/// Mounts `archive_path` at the tebako memfs root, reads up to `length`
/// bytes of `entry_path` starting at `offset`, and unmounts -- all before
/// returning. Blocking; callers on an async runtime should run this via
/// `spawn_blocking`.
///
/// `key` is required (else `EngineError::MissingKey`) iff the archive is
/// in Abyssal's encrypted-archive format (magic-sniffed via
/// `crypto::is_encrypted`, see crypto.rs); ignored otherwise. When
/// present, the whole archive is decrypted into an owned buffer *before*
/// `mount_root_memfs` ever sees it -- that call takes one pointer+length
/// upfront, so there's no way to decrypt lazily/per-block.
pub fn read_range(
    archive_path: &Path,
    entry_path: &str,
    offset: u64,
    length: u64,
    key: Option<&[u8]>,
) -> Result<RangeResult, EngineError> {
    if length > MAX_READ_LENGTH {
        return Err(EngineError::LengthTooLarge);
    }

    let _guard = MOUNT_LOCK.lock().expect("mount lock poisoned");

    let file = std::fs::File::open(archive_path).map_err(EngineError::Io)?;
    // SAFETY: the file is opened read-only above and outlives `mmap`; we
    // hold MOUNT_LOCK for the mmap's entire lifetime, and libdwarfs-wr
    // only reads through the pointer we hand it in mount_root_memfs.
    let mmap = unsafe { Mmap::map(&file) }.map_err(EngineError::Io)?;

    // If encrypted, decrypt into an owned buffer up front and mount that
    // instead of the raw mmap. Both `mmap` and `decrypted` are ordinary
    // local bindings that live until this function returns, i.e. through
    // the whole mount/read/unmount sequence below -- same lifetime
    // guarantee the plain mmap already relied on.
    let decrypted: Option<Vec<u8>>;
    let (ptr, len): (*const u8, usize) = if crypto::is_encrypted(&mmap) {
        let key = key.ok_or(EngineError::MissingKey)?;
        let buf = crypto::decrypt_archive(&mmap, key)?;
        let ptr = buf.as_ptr();
        let len = buf.len();
        decrypted = Some(buf);
        (ptr, len)
    } else {
        decrypted = None;
        (mmap.as_ptr(), mmap.len())
    };
    let _decrypted = decrypted;

    // SAFETY: ptr/len describe a valid, live mapping (either the mmap or
    // the owned decrypted buffer above, both kept alive for this whole
    // scope); the remaining args are optional tuning knobs (null =
    // library defaults).
    let rc = unsafe {
        libdwarfs_sys::mount_root_memfs(
            ptr as *const _,
            len as u32,
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
            std::ptr::null(),
        )
    };
    if rc != 0 {
        return Err(EngineError::Mount(rc));
    }

    let result = read_entry(entry_path, offset, length);

    // SAFETY: matches the successful mount_root_memfs above; always run
    // regardless of read_entry's outcome, mirroring RAII-style cleanup.
    unsafe { libdwarfs_sys::unmount_root_memfs() };

    result
}

fn read_entry(entry_path: &str, offset: u64, length: u64) -> Result<RangeResult, EngineError> {
    let full_path = format!("/__tebako_memfs__/{}", entry_path.trim_start_matches('/'));
    let c_path = CString::new(full_path).map_err(|_| EngineError::InvalidPath)?;

    // SAFETY: c_path is a valid, NUL-terminated C string, live for the
    // duration of this call.
    let mut stat_buf: libdwarfs_sys::stat = unsafe { std::mem::zeroed() };
    let stat_rc =
        unsafe { libdwarfs_sys::tebako_stat(c_path.as_ptr() as *const c_char, &mut stat_buf) };
    if stat_rc != 0 {
        return Err(EngineError::Open(stat_rc));
    }
    let entry_size = stat_buf.st_size as u64;

    // SAFETY: c_path is a valid, NUL-terminated C string for the duration
    // of this call.
    let vfd =
        unsafe { libdwarfs_sys::abyssal_tebako_open_rdonly(c_path.as_ptr() as *const c_char) };
    if vfd < 0 {
        return Err(EngineError::Open(vfd));
    }

    let mut buf = vec![0u8; length as usize];
    // SAFETY: vfd is a valid virtual fd just opened above; buf is sized
    // to `length` and outlives the call.
    let n = unsafe {
        libdwarfs_sys::tebako_pread(
            vfd,
            buf.as_mut_ptr() as *mut _,
            length as usize,
            offset as libc::off_t,
        )
    };

    // SAFETY: vfd is still valid; closing it is required regardless of
    // whether the read above succeeded.
    unsafe {
        libdwarfs_sys::tebako_close(vfd);
    }

    if n < 0 {
        return Err(EngineError::Read(n as i32));
    }

    let n = n as usize;
    buf.truncate(n);
    let eof = offset + n as u64 >= entry_size;
    Ok(RangeResult { data: buf, eof })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::process::Command;

    /// Builds a tiny .dwarfs archive from ../testdata/hello via `mkdwarfs`
    /// (a byproduct of engine/scripts/build-libdwarfs.sh) into a temp dir.
    /// Skips (rather than fails) if mkdwarfs isn't on PATH, matching the
    /// plan's verification approach for environments without the full
    /// libdwarfs-wr build available.
    fn build_fixture() -> Option<(tempfile::TempDir, std::path::PathBuf)> {
        if Command::new("mkdwarfs").arg("--version").output().is_err() {
            eprintln!("skipping: mkdwarfs not on PATH");
            return None;
        }

        let dir = tempfile::tempdir().expect("tempdir");
        let archive_path = dir.path().join("hello.dwarfs");
        let source_dir = std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../testdata/hello");

        let status = Command::new("mkdwarfs")
            .arg("-i")
            .arg(&source_dir)
            .arg("-o")
            .arg(&archive_path)
            .status()
            .expect("failed to run mkdwarfs");
        assert!(status.success(), "mkdwarfs failed");

        Some((dir, archive_path))
    }

    #[test]
    fn read_range_rejects_length_over_the_cap_without_touching_the_filesystem() {
        // No fixture needed -- and deliberately not built, since the
        // whole point is that an oversized length is rejected before any
        // file I/O (an archive_path that doesn't exist would otherwise
        // surface as EngineError::Io, masking whether the length check
        // actually runs first).
        let result = read_range(
            Path::new("/nonexistent/does/not/matter.dwarfs"),
            "hello.txt",
            0,
            MAX_READ_LENGTH + 1,
            None,
        );
        assert!(matches!(result, Err(EngineError::LengthTooLarge)));
    }

    #[test]
    fn read_range_matches_source_bytes_at_nonzero_offset() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };

        // testdata/hello/hello.txt is exactly "hello world" (11 bytes).
        // Read bytes [6, 11) -- "world" -- to prove range reads, not just
        // whole-file reads.
        let result = read_range(&archive_path, "hello.txt", 6, 5, None).expect("read_range");
        assert_eq!(result.data, b"world");
        assert!(result.eof);
    }

    #[test]
    fn read_range_whole_file_from_offset_zero() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };

        let result = read_range(&archive_path, "hello.txt", 0, 11, None).expect("read_range");
        assert_eq!(result.data, b"hello world");
        assert!(result.eof);
    }

    /// Builds an encrypted fixture directly with the `aes-gcm` crate --
    /// independent of the (Elixir) writer, so this test doesn't depend on
    /// Publisher having been implemented/working. See crypto.rs's own
    /// tests for the format itself; this proves read_range's
    /// encrypt-aware branch end to end against a real mounted archive.
    fn encrypt_fixture(archive_path: &std::path::Path, key: &[u8; 32]) -> std::path::PathBuf {
        use aes_gcm::aead::{Aead, KeyInit};
        use aes_gcm::{Aes256Gcm, Key, Nonce};

        let plaintext = std::fs::read(archive_path).expect("read plaintext fixture");
        let cipher = Aes256Gcm::new(Key::<Aes256Gcm>::from_slice(key));
        let nonce_bytes = [42u8; 12];
        let nonce = Nonce::from_slice(&nonce_bytes);
        let ciphertext_with_tag = cipher
            .encrypt(nonce, plaintext.as_slice())
            .expect("encrypt");

        let mut wrapped = Vec::new();
        wrapped.extend_from_slice(crate::crypto::MAGIC);
        wrapped.extend_from_slice(&nonce_bytes);
        wrapped.extend_from_slice(&ciphertext_with_tag);

        let encrypted_path = archive_path.with_extension("dwarfs.enc");
        std::fs::write(&encrypted_path, wrapped).expect("write encrypted fixture");
        encrypted_path
    }

    #[test]
    fn read_range_requires_key_for_encrypted_archive() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };
        let key = [7u8; 32];
        let encrypted_path = encrypt_fixture(&archive_path, &key);

        let result = read_range(&encrypted_path, "hello.txt", 0, 11, None);
        assert!(matches!(result, Err(EngineError::MissingKey)));
    }

    #[test]
    fn read_range_fails_with_wrong_key_for_encrypted_archive() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };
        let key = [7u8; 32];
        let wrong_key = [9u8; 32];
        let encrypted_path = encrypt_fixture(&archive_path, &key);

        let result = read_range(&encrypted_path, "hello.txt", 0, 11, Some(&wrong_key));
        assert!(matches!(result, Err(EngineError::DecryptFailed)));
    }

    #[test]
    fn read_range_succeeds_with_correct_key_for_encrypted_archive() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };
        let key = [7u8; 32];
        let encrypted_path = encrypt_fixture(&archive_path, &key);

        let result =
            read_range(&encrypted_path, "hello.txt", 0, 11, Some(&key)).expect("read_range");
        assert_eq!(result.data, b"hello world");
        assert!(result.eof);
    }
}
