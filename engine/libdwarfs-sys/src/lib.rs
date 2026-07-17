//! Raw FFI bindings to libdwarfs-wr (github.com/tamatebako/libdwarfs).
//!
//! This crate is intentionally thin: it only exposes what `bindgen`
//! generates from `wrapper.h` (see build.rs). All safety invariants --
//! the process-global mount state in particular -- are enforced by the
//! safe wrapper in `abyssal-engine::archive`, not here.
#![allow(non_camel_case_types, non_snake_case, non_upper_case_globals)]

include!(concat!(env!("OUT_DIR"), "/bindings.rs"));

extern "C" {
    /// Fixed-arity wrapper around the variadic `tebako_open`, for the
    /// read-only case only. See shim.c.
    pub fn abyssal_tebako_open_rdonly(path: *const std::os::raw::c_char) -> std::os::raw::c_int;
}
