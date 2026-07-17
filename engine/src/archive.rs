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

static MOUNT_LOCK: Mutex<()> = Mutex::new(());

#[derive(Debug)]
pub enum EngineError {
    Io(std::io::Error),
    InvalidPath,
    Mount(i32),
    Open(i32),
    Read(i32),
}

impl std::fmt::Display for EngineError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            EngineError::Io(e) => write!(f, "io error: {e}"),
            EngineError::InvalidPath => write!(f, "entry path is not a valid C string"),
            EngineError::Mount(rc) => write!(f, "mount_root_memfs failed: {rc}"),
            EngineError::Open(rc) => write!(f, "tebako_open failed: {rc}"),
            EngineError::Read(rc) => write!(f, "tebako_pread failed: {rc}"),
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
pub fn read_range(
    archive_path: &Path,
    entry_path: &str,
    offset: u64,
    length: u64,
) -> Result<RangeResult, EngineError> {
    let _guard = MOUNT_LOCK.lock().expect("mount lock poisoned");

    let file = std::fs::File::open(archive_path).map_err(EngineError::Io)?;
    // SAFETY: the file is opened read-only above and outlives `mmap`; we
    // hold MOUNT_LOCK for the mmap's entire lifetime, and libdwarfs-wr
    // only reads through the pointer we hand it in mount_root_memfs.
    let mmap = unsafe { Mmap::map(&file) }.map_err(EngineError::Io)?;

    // SAFETY: mmap.as_ptr()/len() describe a valid, live mapping; the
    // remaining args are optional tuning knobs (null = library defaults).
    let rc = unsafe {
        libdwarfs_sys::mount_root_memfs(
            mmap.as_ptr() as *const _,
            mmap.len() as u32,
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
    fn read_range_matches_source_bytes_at_nonzero_offset() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };

        // testdata/hello/hello.txt is exactly "hello world" (11 bytes).
        // Read bytes [6, 11) -- "world" -- to prove range reads, not just
        // whole-file reads.
        let result = read_range(&archive_path, "hello.txt", 6, 5).expect("read_range");
        assert_eq!(result.data, b"world");
        assert!(result.eof);
    }

    #[test]
    fn read_range_whole_file_from_offset_zero() {
        let Some((_dir, archive_path)) = build_fixture() else {
            return;
        };

        let result = read_range(&archive_path, "hello.txt", 0, 11).expect("read_range");
        assert_eq!(result.data, b"hello world");
        assert!(result.eof);
    }
}
