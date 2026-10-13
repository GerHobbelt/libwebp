#!/usr/bin/env bash
# Native build (on the target platform itself) of the webp4j JNI library (drop-in for
# dev.matrixlab.webp4j:webp4j-core) and webp_bench from this libwebp checkout with Clang, through the
# superbuild in ci/compiler-bench (webp4j's CMakeLists.txt, libwebp/ = this repository).
# Used by .github/workflows/natives.yml.
#
# Usage: build-native.sh <platform> <lto|pgogen|pgo> <out-dir>
#   platform  linux-x64 | linux-aarch64 | mac-x64 | mac-arm64 | windows-x64 | windows-aarch64
#   Environment:
#     CPU         portable (default: no -march, libwebp picks SSE2/SSE4.1/AVX2 or NEON at run time) or
#                 x86-64-v3 (x64 only: -march=x86-64-v3, needs AVX2/FMA/BMI2)
#     WEBP4J_SRC  webp4j source tree whose libwebp/ points to this repository
#     GIFLIB_SRC  giflib 5.2.2 source tree (webp4j's FetchContent dependency)
#     JAVA_HOME   a JDK of the target OS (jni.h + its jni_md.h)
#     PGO_DIR     profile directory (default /tmp/pgo); pgo reads <PGO_DIR>/webp.profdata
#   Toolchain on PATH: clang, clang++, llvm-ar, llvm-ranlib, ld.lld (Linux, e.g. apt.llvm.org),
#     Xcode's clang (macOS), llvm-mingw's <arch>-w64-mingw32-clang (Windows); CMake, Ninja.
# Variants (the optimizations of the Windows x64 benchmark winner clang-*-avx2-lto-pgo):
#   lto     -O3 -ffast-math -flto (+ -march=x86-64-v3 with CPU=x86-64-v3)
#   pgogen  lto, instrumented for profile-guided optimization (training build, not shipped)
#   pgo     lto + profile-guided optimization with the profile of a pgogen training run
#           (pgogen and pgo must use the same out-dir parent: profiles are tied to source paths)
# Checks (the script fails otherwise): >= 10 JNI exports; for lto/pgo also Linux: NEEDED only
# libc/libm/libpthread/libdl (-static-libgcc); macOS: only /usr/lib + /System libraries, the expected
# minos, ad-hoc signed; Windows: x64/ARM64 PE importing only KERNEL32 + the UCRT (-static).
set -euo pipefail

PLATFORM=$1
VARIANT=$2
OUT=$(mkdir -p "$3" && cd "$3" && pwd -P)
HERE=$(cd "$(dirname "$0")/../compiler-bench" && pwd)   # superbuild CMakeLists.txt + webp_bench.c
CPU=${CPU:-portable}
WORK=$(dirname "$OUT")/work-$(basename "$OUT")   # build trees stay out of the uploaded OUT dir
B=$WORK/build
: "${WEBP4J_SRC:?}" "${GIFLIB_SRC:?}" "${JAVA_HOME:?}"
wp() {  # a path for native tools (Windows form under Git bash / MSYS2)
    if command -v cygpath > /dev/null; then cygpath -m "$1"; else printf '%s\n' "$1"; fi
}
tool() {  # absolute path of a PATH tool, for native tools
    local p; p=$(command -v "$1") || { echo "$1 not found" >&2; return 1; }
    if [ -f "$p.exe" ]; then p=$p.exe; fi
    wp "$p"
}
JH=$(wp "$JAVA_HOME")
PDIR=$(wp "${PGO_DIR:-/tmp/pgo}")

OPT="-O3 -ffast-math -flto"
case $CPU in
    portable) ;;
    x86-64-v3) [[ $PLATFORM == *-x64 ]] || { echo "CPU=$CPU needs an x64 platform" >&2; exit 2; }
               OPT="-O3 -march=x86-64-v3 -ffast-math -flto" ;;
    *) echo "unknown CPU level: $CPU" >&2; exit 2 ;;
esac
MINOS=""
case $PLATFORM in
    linux-x64|linux-aarch64)
        CC=clang; CXX=clang++; LIB=libwebp4j-$PLATFORM.so; EXE=webp_bench; JNI_OS=linux; JNI_LIB=stub
        LDFLAGS="-fuse-ld=lld -static-libgcc"
        # -lm for webp_bench: with -ffast-math libwebp's pow() probe links without libm, so libwebp's
        # targets do not carry -lm (the JNI library links it itself)
        EXTRA=(-DCMAKE_AR="$(tool llvm-ar)" -DCMAKE_RANLIB="$(tool llvm-ranlib)" -DCMAKE_C_STANDARD_LIBRARIES=-lm) ;;
    mac-x64|mac-arm64)
        CC=clang; CXX=clang++; LIB=libwebp4j-$PLATFORM.dylib; EXE=webp_bench; JNI_OS=darwin; JNI_LIB=stub
        LDFLAGS=""
        if [ "$PLATFORM" = mac-x64 ]; then MINOS=10.13; OSXARCH=x86_64; else MINOS=11.0; OSXARCH=arm64; fi
        OPT="$OPT -mmacosx-version-min=$MINOS"
        EXTRA=(-DCMAKE_OSX_ARCHITECTURES=$OSXARCH -DCMAKE_OSX_DEPLOYMENT_TARGET=$MINOS) ;;
    windows-x64|windows-aarch64)
        # CMAKE_SYSTEM_*: explicit, so an emulated x64 shell or CMake cannot pick the wrong architecture
        if [ "$PLATFORM" = windows-x64 ]; then T=x86_64-w64-mingw32 PROC=AMD64 PE=AMD64
        else T=aarch64-w64-mingw32 PROC=ARM64 PE=ARM64; fi
        CC=$T-clang; CXX=$T-clang++; LIB=webp4j-$PLATFORM.dll
        EXE=webp_bench.exe; JNI_OS=win32
        JNI_LIB=$(wp "$($CC -print-file-name=libkernel32.a)")   # FindJNI: webp4j uses nothing of jvm/jawt
        [ -f "$JNI_LIB" ] || { echo "libkernel32.a not found" >&2; exit 1; }
        LDFLAGS="-static -s"
        EXTRA=(-DCMAKE_SYSTEM_NAME=Windows -DCMAKE_SYSTEM_PROCESSOR=$PROC -DCMAKE_RC_COMPILER=$T-windres
               -DCMAKE_AR="$(tool llvm-ar)" -DCMAKE_RANLIB="$(tool llvm-ranlib)") ;;
    *) echo "unknown platform: $PLATFORM" >&2; exit 2 ;;
esac
case $VARIANT in
    lto)    PERF="$OPT" ;;
    pgogen) PERF="$OPT -fprofile-generate" ;;   # the training run sets LLVM_PROFILE_FILE
    pgo)    [ -f "$PDIR/webp.profdata" ] || { echo "::error::$PDIR/webp.profdata not found"; exit 1; }
            PERF="$OPT -fprofile-use=$PDIR/webp.profdata -Wno-profile-instr-unprofiled -Wno-profile-instr-out-of-date" ;;
    *) echo "unknown variant: $VARIANT" >&2; exit 2 ;;
esac

# The superbuild copy lives at ONE path for all variants (PGO profiles are tied to source paths).
SUPER=$(dirname "$OUT")/superbuild-src
rm -rf "$WORK" "$SUPER" && mkdir -p "$WORK" "$SUPER"
cp "$HERE/CMakeLists.txt" "$HERE/webp_bench.c" "$SUPER/"
# Unix: FindJNI's library variables -> an archive whose only object is never pulled in (webp4j links
# ${JNI_LIBRARIES} but uses nothing from libjvm/libjawt, and NEEDED libjvm.so / @rpath/libjvm.dylib
# would not load outside a JDK). It must be an absolute path: CMake makes a relative FILEPATH absolute.
if [ "$JNI_LIB" = stub ]; then
    echo 'int webp4j_jni_stub(void) { return 0; }' > "$WORK/jnistub.c"   # (a function: macOS ranlib omits common symbols)
    $CC ${MINOS:+-mmacosx-version-min=$MINOS} -c "$WORK/jnistub.c" -o "$WORK/jnistub.o"
    ar rcs "$WORK/libjnistub.a" "$WORK/jnistub.o"
    JNI_LIB=$WORK/libjnistub.a
fi

echo "::group::configure + build ($PLATFORM $VARIANT)"
cmake -S "$(wp "$SUPER")" -B "$(wp "$B")" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=$CC -DCMAKE_CXX_COMPILER=$CXX \
    "${EXTRA[@]}" \
    -DCMAKE_C_FLAGS="$PERF" -DCMAKE_CXX_FLAGS="$PERF" \
    -DCMAKE_SHARED_LINKER_FLAGS="$LDFLAGS" -DCMAKE_EXE_LINKER_FLAGS="$LDFLAGS" \
    -DWEBP4J_DIR="$(wp "$WEBP4J_SRC")" \
    -DFETCHCONTENT_SOURCE_DIR_GIFLIB="$(wp "$GIFLIB_SRC")" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    -DJAVA_INCLUDE_PATH="$JH/include" -DJAVA_INCLUDE_PATH2="$JH/include/$JNI_OS" \
    -DJAVA_AWT_INCLUDE_PATH="$JH/include" -DJAVA_AWT_LIBRARY="$JNI_LIB" -DJAVA_JVM_LIBRARY="$JNI_LIB" \
    > "$OUT/configure.log" 2>&1 || { cat "$OUT/configure.log"; exit 1; }
cmake --build "$(wp "$B")" -v > "$OUT/build.log" 2>&1 || {
    awk '/^FAILED/{p=1} /^\[[0-9]+\/[0-9]+\]/{p=0} p' "$OUT/build.log" | cut -c1-600 | head -150
    tail -40 "$OUT/build.log"; exit 1; }
echo "::endgroup::"

F=$(find "$B" -name "$LIB" -type f | head -1)
X=$(find "$B" -name "$EXE" -type f | head -1)
[ -n "$F" ] && [ -n "$X" ] || { echo "::error::$LIB or $EXE not built"; ls -R "$B" | head -50; exit 1; }
cp "$F" "$X" "$OUT/"
F=$OUT/$LIB
# effective compile lines (the last -O wins): a libwebp encoder file, a SIMD file and the JNI glue
for f in src/enc/vp8l_enc.c src/dsp/lossless_avx2.c src/dsp/lossless_neon.c src/main/c/webp4j.c; do
    grep -m1 -F "$f" "$OUT/build.log" || true
done > "$OUT/compile-cmds.txt"

BAD=""
YMM=""
case $PLATFORM in
    linux-*)
        readelf -d "$F" > "$WORK/dynamic.txt"
        cat "$WORK/dynamic.txt"
        DEPS=$(awk '/\(NEEDED\)/{gsub(/\[|\]/, "", $NF); print $NF}' "$WORK/dynamic.txt" | tr '\n' ' ')
        for d in $DEPS; do
            case $d in libc.so.6|libm.so.6|libpthread.so.0|libdl.so.2) ;; *) BAD="$BAD $d" ;; esac
        done
        objdump -T "$F" > "$WORK/dynsym.txt"
        GLIBC=$(grep -oE 'GLIBC_[0-9]+(\.[0-9]+)+' "$WORK/dynsym.txt" | sort -uV | tail -1 || true)
        [ -z "$GLIBC" ] || echo "symbols that need $GLIBC: $(grep -w "$GLIBC" "$WORK/dynsym.txt" | awk '{print $NF}' | tr '\n' ' ')"
        REQ="glibc >= ${GLIBC#GLIBC_}"
        EXPORTS=$(nm -D --defined-only "$F" | grep -c ' T Java_dev_matrixlab_webp4j_internal_NativeWebP_' || true)
        [ "$PLATFORM" != linux-x64 ] || YMM=$(objdump -d --no-show-raw-insn "$F" | grep -c ymm || true) ;;
    mac-*)
        strip -x "$F"                       # local symbols only (Linux/Windows builds are stripped too)
        codesign --force -s - "$F"          # ad-hoc (strip invalidates the linker's signature)
        codesign -dv "$F" 2>&1 | grep -E '^(Identifier|Format|CodeDirectory|Signature)' || true
        otool -L "$F"
        ID=$(otool -D "$F" | tail -n +2)
        DEPS=$(otool -L "$F" | tail -n +2 | awk '{print $1}' | grep -vxF "$ID" | tr '\n' ' ' || true)
        for d in $DEPS; do
            case $d in /usr/lib/*|/System/*) ;; *) BAD="$BAD $d" ;; esac
        done
        otool -l "$F" | grep -E -A4 'LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX' || true
        GOT=$(otool -l "$F" | awk '/LC_BUILD_VERSION|LC_VERSION_MIN_MACOSX/{f=1} f && ($1=="minos" || $1=="version"){print $2; exit}')
        [ "$GOT" = "$MINOS" ] || BAD="$BAD minos=$GOT(expected $MINOS)"
        codesign -v "$F" || BAD="$BAD unsigned"
        REQ="macOS >= $GOT"
        EXPORTS=$(nm -gU "$F" | grep -c ' T _Java_dev_matrixlab_webp4j_internal_NativeWebP_' || true)
        [ "$PLATFORM" != mac-x64 ] || YMM=$(otool -tv "$F" | grep -c ymm || true) ;;
    windows-*)
        llvm-readobj --file-headers "$F" > "$WORK/headers.txt"
        grep -E 'Format|Arch|Machine' "$WORK/headers.txt" || true
        grep -q "IMAGE_FILE_MACHINE_$PE" "$WORK/headers.txt" || BAD="$BAD not-an-$PE-PE"
        DEPS=$(llvm-readobj --coff-imports "$F" | awk '$1=="Name:"{print $2}' | sort -u | tr '\n' ' ')
        for d in $DEPS; do
            case $(printf '%s' "$d" | tr 'A-Z' 'a-z') in kernel32.dll|ucrtbase.dll|api-ms-win-crt-*.dll) ;; *) BAD="$BAD $d" ;; esac
        done
        if [ "$PE" = AMD64 ]; then REQ="Windows 10+ x64 (UCRT)"; else REQ="Windows 10+ on ARM64 (UCRT)"; fi
        [ "$PE" != AMD64 ] || YMM=$(llvm-objdump -d --no-show-raw-insn "$F" | grep -c ymm || true)
        EXPORTS=$(llvm-readobj --coff-exports "$F" | grep -c 'Name: Java_dev_matrixlab_webp4j_internal_NativeWebP_' || true) ;;
esac
[ "$CPU" = portable ] || REQ="$REQ; x86-64-v3 CPU (AVX2/FMA/BMI2: Intel Haswell / AMD Zen 1 or newer)"
if [ -n "$BAD" ]; then
    if [ "$VARIANT" = pgogen ]; then echo "::warning::$LIB ($VARIANT, not shipped):$BAD"
    else echo "::error::$LIB has unexpected dependencies/properties:$BAD"; exit 1; fi
fi
[ "$EXPORTS" -ge 10 ] || { echo "::error::expected 10 JNI exports, found $EXPORTS"; exit 1; }
{
    echo "platform: $PLATFORM"
    echo "file:     $LIB"
    echo "compiler: $($CC --version | head -1)"
    echo "variant:  $VARIANT, CPU $CPU"
    echo "pgo:      $([ "$VARIANT" = pgo ] && echo yes || echo no)"
    echo "flags:    $PERF"
    echo "ldflags:  ${LDFLAGS:-(defaults)}"
    echo "libwebp:  $(git -C "$HERE" rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo "webp4j:   $(git -C "$WEBP4J_SRC" describe --tags --always 2>/dev/null || echo '?')"
    echo "exports:  $EXPORTS JNI functions"
    [ -z "$YMM" ] || echo "ymm:      $YMM instructions using ymm registers"
    echo "deps:     $DEPS"
    echo "requires: $REQ"
} | tee "$OUT/info.txt"
ls -l "$OUT"
