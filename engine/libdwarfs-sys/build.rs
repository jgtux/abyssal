use std::env;
use std::path::{Path, PathBuf};

/// Locates a built+installed libdwarfs-wr tree.
///
/// libdwarfs-wr's own CMake superbuild (see engine/scripts/build-libdwarfs.sh)
/// is a separate, explicit, developer/CI-run step -- this build.rs never
/// invokes cmake/CMake itself. It only locates what that script already
/// produced and fails fast with an actionable message if it can't find it.
fn find_prefix() -> PathBuf {
    if let Ok(prefix) = env::var("ABYSSAL_LIBDWARFS_PREFIX") {
        return PathBuf::from(prefix);
    }

    // Default: engine/vendor/libdwarfs-wr/build (matches build-libdwarfs.sh).
    let default = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("libdwarfs-sys has a parent dir")
        .join("vendor/libdwarfs-wr/build");

    if include_dir(&default).is_some() {
        return default;
    }

    panic!(
        "libdwarfs-wr headers not found at {} (or $ABYSSAL_LIBDWARFS_PREFIX).\n\
         Run `engine/scripts/build-libdwarfs.sh` first, or set \
         ABYSSAL_LIBDWARFS_PREFIX to point at an existing build/install tree.",
        default.display()
    );
}

/// libdwarfs-wr's CMake build never installs a staged prefix -- its public
/// headers live in the checked-out source tree's own `include/` (a sibling
/// of `build/`, not inside it), while the compiled `.a` and `link.txt` live
/// under `build/`. So the header dir is `prefix/include` if `prefix` IS the
/// source tree, or `prefix/../include` if `prefix` is its `build/` subdir
/// (the default). Checked in that order so an explicit
/// ABYSSAL_LIBDWARFS_PREFIX pointing straight at a headers-in-prefix layout
/// still works too.
fn include_dir(prefix: &Path) -> Option<PathBuf> {
    let direct = prefix.join("include");
    if direct.join("tebako-io.h").exists() {
        return Some(direct);
    }
    let sibling = prefix.parent()?.join("include");
    if sibling.join("tebako-io.h").exists() {
        return Some(sibling);
    }
    None
}

/// libdwarfs-wr's own `dwarfs-wr` CMake target is a plain static archive
/// (`ar qc libdwarfs-wr.a ...`) -- CMake's `ar` step never captures
/// transitive dependency flags the way a real link step does, so there is
/// no `link.txt` anywhere that lists what `libdwarfs-wr.a` itself needs.
/// The one place that transitive chain *is* fully flattened and known-good
/// is the `mkdwarfs` executable's own link.txt: it links against the same
/// underlying dwarfs reader code (dwarfs.a, folly, fbthrift, compression
/// libs, boost, openssl, jemalloc, ...) that `dwarfs-wr.a` itself wraps.
/// So: reuse that link line verbatim, minus the two archives that are
/// specific to the `mkdwarfs` CLI binary (`mkdwarfs_main.a`,
/// `dwarfs_tool.a`), plus `dwarfs-wr.a` itself prepended (it's the one
/// archive nothing else in the chain references, so it must come first --
/// same position `mkdwarfs_main.a` held in the original line, right next
/// to the object code that actually calls into it).
///
/// One more thing preserved from the original line:
/// `libdwarfs_compression.a` is linked there with `--whole-archive`
/// (`-Wl,--push-state,--whole-archive libdwarfs_compression.a
/// -Wl,--pop-state`). Its codec backends (zstd, lzma, ...) self-register
/// via static initializers that nothing else in the archive graph calls
/// directly, so a normal archive link drops those object files as
/// "unused" and every read then fails with "unsupported compression
/// type" at runtime -- confirmed by hitting exactly that error before
/// this was added.
fn link_from_mkdwarfs_link_txt(prefix: &Path) -> bool {
    let Some(vendor_root) = prefix.parent() else {
        return false;
    };
    let dwarfs_build_dir = vendor_root.join("deps/src/_dwarfs-build");
    let link_txt = dwarfs_build_dir.join("CMakeFiles/mkdwarfs.dir/link.txt");

    let Ok(contents) = std::fs::read_to_string(&link_txt) else {
        return false;
    };

    const APP_SPECIFIC: &[&str] = &["libmkdwarfs_main.a", "libdwarfs_tool.a"];

    println!("cargo:rustc-link-search=native={}", prefix.display());
    println!("cargo:rustc-link-lib=static=dwarfs-wr");

    let mut found_any = false;
    for tok in contents.split_whitespace() {
        if let Some(lib) = tok.strip_prefix("-l") {
            println!("cargo:rustc-link-lib={lib}");
            found_any = true;
        } else if tok.ends_with(".a") || tok.contains(".so") {
            let file_name = Path::new(tok)
                .file_name()
                .map(|n| n.to_string_lossy().into_owned())
                .unwrap_or_default();
            if APP_SPECIFIC.contains(&file_name.as_str()) {
                continue;
            }

            let resolved = if Path::new(tok).is_absolute() {
                PathBuf::from(tok)
            } else {
                dwarfs_build_dir.join(tok)
            };
            if let Some(parent) = resolved.parent() {
                println!("cargo:rustc-link-search=native={}", parent.display());
            }

            if let Some(idx) = file_name.find(".so") {
                let name = file_name[..idx].strip_prefix("lib").unwrap_or(&file_name);
                println!("cargo:rustc-link-lib=dylib={name}");
            } else if let Some(name) = file_name.strip_suffix(".a") {
                let name = name.strip_prefix("lib").unwrap_or(name);
                if file_name == "libdwarfs_compression.a" {
                    println!("cargo:rustc-link-lib=static:+whole-archive={name}");
                } else {
                    println!("cargo:rustc-link-lib=static={name}");
                }
            }
            found_any = true;
        }
    }
    found_any
}

fn main() {
    let prefix = find_prefix();
    println!("cargo:rerun-if-env-changed=ABYSSAL_LIBDWARFS_PREFIX");

    if !link_from_mkdwarfs_link_txt(&prefix) {
        panic!(
            "could not find/parse deps/src/_dwarfs-build/CMakeFiles/mkdwarfs.dir/link.txt \
             under {} -- libdwarfs-wr's own dependency chain (folly, fbthrift, \
             compression libs, boost, ...) can't be linked without it. Re-run \
             engine/scripts/build-libdwarfs.sh.",
            prefix.display()
        );
    }

    println!("cargo:rustc-link-lib=stdc++");

    let include_dir = include_dir(&prefix).expect("include_dir already validated in find_prefix");
    let bindings = bindgen::Builder::default()
        .header("wrapper.h")
        .clang_arg(format!("-I{}", include_dir.display()))
        .allowlist_function("mount_root_memfs")
        .allowlist_function("mount_memfs.*")
        .allowlist_function("unmount_root_memfs")
        .allowlist_function("tebako_pread")
        .allowlist_function("tebako_close")
        .allowlist_function("tebako_stat")
        // NOTE: tebako_open itself is C-variadic and not callable from
        // stable Rust -- see shim.c's abyssal_tebako_open_rdonly, compiled
        // and linked below, and declared by hand in src/lib.rs.
        .parse_callbacks(Box::new(bindgen::CargoCallbacks::new()))
        .generate()
        .expect("bindgen failed to generate libdwarfs-wr bindings");

    let out_path = PathBuf::from(env::var("OUT_DIR").unwrap());
    bindings
        .write_to_file(out_path.join("bindings.rs"))
        .expect("failed to write bindings.rs");

    cc::Build::new()
        .file("shim.c")
        .include(&include_dir)
        .compile("abyssal_tebako_shim");
}
