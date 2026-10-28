#!/usr/bin/env bash
set -euo pipefail

# Called by Windows Python with Windows paths, inside an ARM64 MSVC developer environment.
export PATH="$(cygpath -u "$MSVC_BIN"):/usr/bin:$PATH"
source_dir=$(cygpath -u "$1")
build_dir=$(cygpath -u "$2")
prefix=$(cygpath -m "$3")
jobs=$4
shift 4
mkdir -p "$build_dir"
cd "$build_dir"
bash "$source_dir/configure" "$@" \
    --prefix="$prefix" --shlibdir="$prefix/bin" \
    --toolchain=msvc --arch=aarch64 --target-os=win64 --disable-asm --enable-cross-compile
make -j"$jobs"
make install
