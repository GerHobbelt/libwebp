#!/usr/bin/env bash
# Build a Linux-hosted x86_64-w64-mingw32 cross GCC (UCRT, win32 thread model) from a GCC source
# tarball - used by .github/workflows/windows-x64-compilers.yml for GCC snapshots (e.g. GCC 17 trunk),
# which no Windows distribution (MSYS2, WinLibs) ships.
#
# Classic mingw-w64 cross order: binutils -> headers -> gcc (all-gcc) -> crt -> gcc (target libs).
# win32 threads: libwebp's thread_utils.c uses Win32 threads on _WIN32 (no pthread.h needed), and
# GCC >= 13 libstdc++ has std::thread/mutex on the win32 model, so winpthreads is not needed.
# (Shared with korvin2000/sevenzipjbinding scripts/compiler-bench/build-gcc-mingw-cross.sh.)
# Sysroot = PREFIX with PREFIX/mingw -> x86_64-w64-mingw32 (GCC's native header dir is /mingw/include).
#
# Usage: build-gcc-mingw-cross.sh <gcc-tarball-url> <install-prefix>
# Host deps (Ubuntu): build-essential bison flex texinfo libgmp-dev libmpfr-dev libmpc-dev libisl-dev
set -euo pipefail

GCC_URL=$1
PREFIX=$2
BINUTILS_VER=${BINUTILS_VER:-2.47}
# mingw-w64: a master commit - v14.0.0's CRT does not build with GCC 17 (ssp/stack_chk_guard.c type
# conflict with GCC's now-predeclared __stack_chk_guard; fixed on master by 5d04f8f791, 2026-05).
MINGW_VER=${MINGW_VER:-63ebe6cdb3ec4d5c586b7f0f0c03dd502e44c296}
TARGET=x86_64-w64-mingw32
JOBS=$(nproc)
WORK=${WORK:-$PWD/gcc-mingw-cross-work}

mkdir -p "$WORK" "$PREFIX"
cd "$WORK"
fetch() { curl -fsSL --retry 5 --retry-delay 15 -o "$2" "$1"; }
fetch "https://sourceware.org/pub/binutils/releases/binutils-$BINUTILS_VER.tar.xz" binutils.tar.xz
fetch "$GCC_URL" gcc.tar.xz
fetch "https://github.com/mingw-w64/mingw-w64/archive/$MINGW_VER.tar.gz" mingw-w64.tar.gz
mkdir src-binutils src-gcc src-mingw
tar -xf binutils.tar.xz  -C src-binutils --strip-components=1
tar -xf gcc.tar.xz       -C src-gcc      --strip-components=1
tar -xf mingw-w64.tar.gz -C src-mingw    --strip-components=1
export PATH="$PREFIX/bin:$PATH"

echo "::group::binutils $BINUTILS_VER"
mkdir b-binutils && cd b-binutils
../src-binutils/configure --target=$TARGET --prefix="$PREFIX" --with-sysroot="$PREFIX" \
    --disable-multilib --disable-nls --disable-werror --disable-gdb --disable-gprofng
make -j"$JOBS"
make install-strip
cd .. && echo "::endgroup::"

echo "::group::mingw-w64 headers $MINGW_VER (UCRT)"
mkdir b-headers && cd b-headers
../src-mingw/mingw-w64-headers/configure --host=$TARGET --prefix="$PREFIX/$TARGET" --with-default-msvcrt=ucrt
make install
ln -sfn "$TARGET" "$PREFIX/mingw"
cd .. && echo "::endgroup::"

echo "::group::gcc (compilers)"
mkdir b-gcc && cd b-gcc
../src-gcc/configure --target=$TARGET --prefix="$PREFIX" --with-sysroot="$PREFIX" \
    --enable-languages=c,c++,lto --enable-lto --disable-multilib --disable-nls --disable-werror \
    --enable-checking=release --enable-threads=win32 --enable-shared --enable-static \
    --disable-libstdcxx-pch --disable-libgomp --disable-libquadmath --disable-libssp --disable-libitm \
    --disable-libvtv --disable-libsanitizer \
    --with-pkgversion="libwebp CI cross, $(basename "$GCC_URL" .tar.xz)"
make -j"$JOBS" all-gcc
make install-strip-gcc
cd .. && echo "::endgroup::"

echo "::group::mingw-w64 crt $MINGW_VER (UCRT)"
mkdir b-crt && cd b-crt
../src-mingw/mingw-w64-crt/configure --host=$TARGET --prefix="$PREFIX/$TARGET" --with-sysroot="$PREFIX" \
    --with-default-msvcrt=ucrt --disable-lib32 --enable-lib64
make -j"$JOBS"
make install
cd .. && echo "::endgroup::"

echo "::group::gcc (libgcc, libstdc++)"
cd b-gcc
make -j"$JOBS"
make install-strip
cd .. && echo "::endgroup::"

# smoke test: a static C++ exe and DLL must link (a half-built toolchain must not get cached)
cd "$WORK"
printf '#include <string>
#include <cstdio>
int main(){std::string s("ok");std::puts(s.c_str());}
' > t.cpp
"$PREFIX/bin/$TARGET-g++" -O2 -static t.cpp -o t.exe
"$PREFIX/bin/$TARGET-g++" -O2 -shared -static t.cpp -o t.dll
"$PREFIX/bin/$TARGET-gcc" --version | head -1
