#!/bin/sh
# Builds vendor/libdwarfs-wr (github.com/tamatebako/libdwarfs) from source.
#
# This is a real, multi-minute native superbuild (it fetches and compiles
# its own pinned fork of dwarfs, plus zstd/glog/double-conversion/brotli/
# lz4/jemalloc from source) -- deliberately NOT run automatically by
# `cargo build`. Run it once; libdwarfs-sys/build.rs just looks for what
# this script already produced.
#
# Prerequisites (Arch/Artix package names shown; adjust for your distro):
#   pacman -S cmake gcc boost gflags google-glog libevent libarchive \
#             xxhash openssl fmt double-conversion brotli lz4 zstd pkgconf \
#             utf8cpp
#
# dwarfs's util.cpp does `#include <utf8.h>` (flat, no subdirectory) on
# non-MSVC, but dwarfs's CMakeLists.txt never find_package()s utf8cpp or
# adds its include dir -- it just assumes the header is already on the
# compiler's default search path. Arch's utf8cpp package namespaces it
# under /usr/include/utf8cpp/utf8.h instead, so that assumption doesn't
# hold here. Fixed below by adding utf8cpp's include dir via CPATH, which
# GCC/Clang both honor as an implicit -isystem for every compile.
#
# Verified working against libdwarfs-wr 0.11.0 + CMake 4.3.2: its vendored
# double-conversion CMakeLists.txt predates CMake's removal of
# cmake_minimum_required < 3.5 support, so CMAKE_POLICY_VERSION_MINIMUM
# must be set as an escape hatch -- see
# https://cmake.org/cmake/help/latest/policy/CMP0000.html
#
# libdwarfs-wr's own dwarfs fork (and its Folly/fsst dependencies) are
# fetched mid-build by ExternalProject_Add's download step (~68% in), not
# during configure -- so they don't exist on disk to patch until a build
# has been attempted at least once. Two source files in that fetched tree
# rely on transitive includes that newer GCC (15/16) no longer provides:
#   - fsst/libfsst.hpp uses uint8_t/uint32_t without including <cstdint>
#   - folly/debugging/symbolizer/Elf.cpp uses close/lseek/read/pread
#     without including <unistd.h>
# Both are real upstream bugs (GCC's own diagnostic names the missing
# header), not something to work around with a global -include flag --
# that was tried and rejected: it broke zstd's hand-written x86-64
# assembly (huf_decompress_amd64.S) by leaking C declarations into pure
# ASM compilation. Targeted per-file patches are safer in a mixed
# C/C++/ASM build. Applied automatically below, once the sources exist.
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ENGINE_DIR=$(dirname "$SCRIPT_DIR")
VENDOR_DIR="$ENGINE_DIR/vendor/libdwarfs-wr"
BUILD_DIR="$VENDOR_DIR/build"
DWARFS_SRC="$VENDOR_DIR/deps/src/_dwarfs"

if [ ! -e "$VENDOR_DIR/.git" ]; then
    echo "vendor/libdwarfs-wr is missing -- run 'git submodule update --init' first" >&2
    exit 1
fi

export CMAKE_POLICY_VERSION_MINIMUM=3.5

for utf8cpp_dir in /usr/include/utf8cpp /usr/local/include/utf8cpp; do
    if [ -f "$utf8cpp_dir/utf8.h" ]; then
        export CPATH="$utf8cpp_dir${CPATH:+:$CPATH}"
        break
    fi
done

apply_gcc15_patches() {
    fsst_header="$DWARFS_SRC/fsst/libfsst.hpp"
    if [ -f "$fsst_header" ] && ! grep -q '#include <cstdint>' "$fsst_header"; then
        echo "patching $fsst_header (missing <cstdint>)"
        sed -i '/#include <cstring>/a #include <cstdint>' "$fsst_header"
    fi

    folly_elf="$DWARFS_SRC/folly/folly/debugging/symbolizer/Elf.cpp"
    if [ -f "$folly_elf" ] && ! grep -q '#include <unistd.h>' "$folly_elf"; then
        echo "patching $folly_elf (missing <unistd.h>)"
        sed -i '/#include <sys\/types.h>/a #include <unistd.h>' "$folly_elf"
    fi
}

cmake -S "$VENDOR_DIR" -B "$BUILD_DIR" \
    -DWITH_TESTS=OFF \
    -DWITH_ASAN=OFF \
    -DWITH_COVERAGE=OFF

nproc_val=$(nproc 2>/dev/null || echo 4)

# First attempt fetches deps mid-build and will fail once it reaches the
# two known-bad files (they don't exist to patch before this point).
# Patch them and retry -- the retry is a cheap incremental build since
# ExternalProject_Add won't re-clone or recompile already-built objects.
if ! cmake --build "$BUILD_DIR" --parallel "$nproc_val"; then
    apply_gcc15_patches
    cmake --build "$BUILD_DIR" --parallel "$nproc_val"
fi

echo "libdwarfs-wr built at $BUILD_DIR"
echo "mkdwarfs byproduct: $(find "$VENDOR_DIR/deps/bin" "$BUILD_DIR" -name mkdwarfs -type f 2>/dev/null | head -1)"
echo "Set ABYSSAL_LIBDWARFS_PREFIX=$BUILD_DIR before 'cargo build', or rely on libdwarfs-sys/build.rs's default."
