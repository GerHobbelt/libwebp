#!/usr/bin/env bash
# Cross-build (Linux host -> Windows x64) the webp4j JNI library webp4j-windows-x64.dll (drop-in for
# dev.matrixlab.webp4j:webp4j-core) and webp_bench.exe from this libwebp checkout, with one compiler and
# one optimization variant. Used by .github/workflows/windows-x64-compilers.yml.
#
# Usage: build-variant.sh <gcc|clang> <base|avx2|avx2-lto> <out-dir>
#   x86_64-w64-mingw32-{gcc,g++|clang,clang++} must be on PATH. Environment:
#     WEBP4J_SRC  webp4j source tree whose libwebp/ points to this repository
#     GIFLIB_SRC  giflib 5.2.2 source tree (webp4j's FetchContent dependency)
#     JAVA_HOME   any JDK (only the platform-independent jni.h is used)
# Variants:
#   base      webp4j's release defaults: -O3, LTO for the JNI glue only, generic x86-64 (libwebp still
#             picks its SSE2/SSE4.1/AVX2 code at run time)
#   avx2      -O3 -march=x86-64-v3 (AVX2/FMA/BMI2: Intel Haswell+, AMD Zen+) -ffast-math (implies
#             -funsafe-math-optimizations -ffinite-math-only -fno-math-errno -fno-trapping-math ...)
#   avx2-lto  avx2 + whole-program LTO (libwebp + giflib + JNI glue)
set -euo pipefail

CC_KIND=$1
VARIANT=$2
OUT=$(mkdir -p "$3" && cd "$3" && pwd)
HERE=$(cd "$(dirname "$0")" && pwd)
WORK=$(dirname "$OUT")/work-$(basename "$OUT")   # build trees stay out of the uploaded OUT dir
T=x86_64-w64-mingw32
: "${WEBP4J_SRC:?}" "${GIFLIB_SRC:?}" "${JAVA_HOME:?}"

case $CC_KIND in
    # GCC LTO objects need the plugin-aware gcc-ar; llvm-mingw's ar is llvm-ar
    gcc)   CC=$T-gcc;   CXX=$T-g++;     AR=$T-gcc-ar; RANLIB=$T-gcc-ranlib; LTO=-flto=auto ;;
    clang) CC=$T-clang; CXX=$T-clang++; AR=$T-ar;     RANLIB=$T-ranlib;     LTO=-flto ;;
    *) echo "unknown compiler kind: $CC_KIND" >&2; exit 2 ;;
esac
case $VARIANT in
    base)     PERF="" ;;
    avx2)     PERF="-O3 -march=x86-64-v3 -ffast-math" ;;
    avx2-lto) PERF="-O3 -march=x86-64-v3 -ffast-math $LTO" ;;
    *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

# Windows JNI headers: jni.h is platform independent, jni_md.h must be the Windows one (LLP64: jlong is
# __int64; the Linux one makes jlong a 'long', which is 32-bit on Windows). FindJNI's library variables
# are satisfied with the kernel32 import library: webp4j links ${JNI_LIBRARIES} but uses nothing from
# jvm/jawt.
rm -rf "$WORK" && mkdir -p "$WORK/jni/include/win32" "$WORK/superbuild"
cp "$JAVA_HOME/include/jni.h" "$WORK/jni/include/"
cat > "$WORK/jni/include/win32/jni_md.h" <<'EOF'
#ifndef _JAVASOFT_JNI_MD_H_
#define _JAVASOFT_JNI_MD_H_
#define JNIEXPORT __declspec(dllexport)
#define JNIIMPORT __declspec(dllimport)
#define JNICALL __stdcall
typedef long jint;
typedef __int64 jlong;
typedef signed char jbyte;
#endif
EOF
# out-of-tree copy: webp4j's CMakeLists creates ${CMAKE_SOURCE_DIR}/src/main/resources/native
cp "$HERE/CMakeLists.txt" "$HERE/webp_bench.c" "$WORK/superbuild/"
tool() {  # absolute path of a PATH tool (Windows form when run from MSYS2 bash)
    local p; p=$(command -v "$1") || { echo "$1 not found" >&2; return 1; }
    if command -v cygpath > /dev/null; then cygpath -m "$p"; else echo "$p"; fi
}
SYSROOT=$(cd "$(dirname "$(command -v $CC)")/.." && pwd)   # toolchain prefix = find root
KERNEL32=$($CC -print-file-name=libkernel32.a)   # the target's own (llvm-mingw is multi-arch)
[ -f "$KERNEL32" ] || { echo "libkernel32.a not found" >&2; exit 1; }

echo "::group::configure + build ($CC_KIND $VARIANT)"
B=$WORK/build
cmake -S "$WORK/superbuild" -B "$B" -G Ninja \
    -DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=AMD64 \
    -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX -DCMAKE_RC_COMPILER=$T-windres \
    -DCMAKE_AR="$(tool $AR)" -DCMAKE_RANLIB="$(tool $RANLIB)" \
    -DCMAKE_FIND_ROOT_PATH="$SYSROOT" -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_FLAGS="$PERF" -DCMAKE_CXX_FLAGS="$PERF" \
    -DCMAKE_SHARED_LINKER_FLAGS="-static -s" -DCMAKE_EXE_LINKER_FLAGS="-static -s" \
    -DWEBP4J_DIR="$WEBP4J_SRC" \
    -DFETCHCONTENT_SOURCE_DIR_GIFLIB="$GIFLIB_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DJAVA_INCLUDE_PATH="$WORK/jni/include" -DJAVA_INCLUDE_PATH2="$WORK/jni/include/win32" \
    -DJAVA_AWT_INCLUDE_PATH="$WORK/jni/include" -DJAVA_AWT_LIBRARY="$KERNEL32" -DJAVA_JVM_LIBRARY="$KERNEL32" \
    > "$OUT/configure.log" 2>&1 || { cat "$OUT/configure.log"; exit 1; }
cmake --build "$B" -j"$(nproc)" -v > "$OUT/build.log" 2>&1 || {
    awk '/^FAILED/{p=1} /^\[[0-9]+\/[0-9]+\]/{p=0} p' "$OUT/build.log" | cut -c1-600 | head -150; exit 1; }
echo "::endgroup::"

DLL=$(find "$B" -name webp4j-windows-x64.dll | head -1)
EXE=$(find "$B" -name webp_bench.exe | head -1)
cp "$DLL" "$EXE" "$OUT/"
# effective compile lines (the last -O wins): a libwebp encoder file, an AVX2 file and the JNI glue
for f in src/enc/vp8l_enc.c src/dsp/lossless_avx2.c src/main/c/webp4j.c; do
    grep -m1 -F "$f" "$OUT/build.log" || true
done > "$OUT/compile-cmds.txt"

OBJDUMP=$(command -v $T-objdump || command -v llvm-objdump)
"$OBJDUMP" -p "$OUT/webp4j-windows-x64.dll" > "$WORK/dll-headers.txt"
grep -E 'file format|DLL Name' "$WORK/dll-headers.txt" || true
if grep -iE 'DLL Name: *lib' "$WORK/dll-headers.txt"; then
    echo "::error::webp4j-windows-x64.dll depends on a MinGW runtime DLL"; exit 1
fi
EXPORTS=$(grep -c 'Java_dev_matrixlab_webp4j_internal_NativeWebP_' "$WORK/dll-headers.txt" || true)
[ "$EXPORTS" -ge 10 ] || { echo "::error::expected 10 JNI exports, found $EXPORTS"; exit 1; }
YMM=$("$OBJDUMP" -d --no-show-raw-insn "$OUT/webp4j-windows-x64.dll" | grep -c ymm || true)
{
    echo "compiler: $($CC --version | head -1)"
    echo "variant:  $VARIANT"
    echo "flags:    ${PERF:-(webp4j defaults: -O3, generic x86-64)}"
    echo "libwebp:  $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo "webp4j:   $(git -C "$WEBP4J_SRC" describe --tags --always 2>/dev/null || echo '?')"
    echo "exports:  $EXPORTS JNI functions"
    echo "ymm:      $YMM instructions using ymm registers in the DLL"
    echo "imports:  $(grep 'DLL Name' "$WORK/dll-headers.txt" | awk '{print $NF}' | sort -u | tr '\n' ' ')"
} | tee "$OUT/info.txt"
ls -l "$OUT"
