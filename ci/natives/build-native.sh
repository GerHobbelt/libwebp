#!/usr/bin/env bash
# Native (Linux / macOS) build of the webp4j JNI library libwebp4j-<os>-<arch>.{so,dylib} (drop-in for
# dev.matrixlab.webp4j:webp4j-core) and webp_bench from this libwebp checkout, through the same
# superbuild as the Windows cross builds (ci/compiler-bench/CMakeLists.txt: webp4j's own CMakeLists.txt
# with its libwebp/ replaced by this repository). Used by .github/workflows/natives.yml.
#
# Usage: build-native.sh <out-dir>
# Environment:
#   WEBP4J_SRC   webp4j source tree whose libwebp/ points to this repository
#   GIFLIB_SRC   giflib 5.2.2 source tree (webp4j's FetchContent dependency)
#   JAVA_HOME    JDK of the build host (JNI headers)
#   CC, AR, RANLIB   compiler and LTO-aware archiver (default: cc and CMake's choice)
#   FLAGS        compile + link flags (default: -O3 -ffast-math -flto, no -march: libwebp dispatches its
#                SSE2/SSE4.1/AVX2 or NEON code at run time)
#   LINK_FLAGS   extra linker flags
#   OSX_TARGET   macOS deployment target
set -euo pipefail

OUT=$(mkdir -p "$1" && cd "$1" && pwd -P)
SB=$(cd "$(dirname "$0")/../compiler-bench" && pwd)
WORK=$(dirname "$OUT")/work-$(basename "$OUT")
SUPER=$(dirname "$OUT")/superbuild-src
FLAGS=${FLAGS--O3 -ffast-math -flto}
: "${WEBP4J_SRC:?}" "${GIFLIB_SRC:?}" "${JAVA_HOME:?}"

rm -rf "$WORK" "$SUPER" && mkdir -p "$SUPER"
cp "$SB/CMakeLists.txt" "$SB/webp_bench.c" "$SUPER/"
EXTRA=()
[ -z "${OSX_TARGET:-}" ] || EXTRA+=("-DCMAKE_OSX_DEPLOYMENT_TARGET=$OSX_TARGET")
[ -z "${AR:-}" ] || EXTRA+=("-DCMAKE_AR=$(command -v "$AR")")
[ -z "${RANLIB:-}" ] || EXTRA+=("-DCMAKE_RANLIB=$(command -v "$RANLIB")")

echo "::group::configure + build"
cmake -S "$SUPER" -B "$WORK" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER="${CC:-cc}" \
    -DCMAKE_C_FLAGS="$FLAGS" -DCMAKE_CXX_FLAGS="$FLAGS" \
    -DCMAKE_SHARED_LINKER_FLAGS="${LINK_FLAGS:-}" -DCMAKE_EXE_LINKER_FLAGS="${LINK_FLAGS:-}" \
    -DWEBP4J_DIR="$WEBP4J_SRC" \
    -DFETCHCONTENT_SOURCE_DIR_GIFLIB="$GIFLIB_SRC" -DFETCHCONTENT_FULLY_DISCONNECTED=ON \
    ${EXTRA[@]+"${EXTRA[@]}"} > "$OUT/configure.log" 2>&1 || { cat "$OUT/configure.log"; exit 1; }
cmake --build "$WORK" -j"$(getconf _NPROCESSORS_ONLN)" -v > "$OUT/build.log" 2>&1 || {
    awk '/^FAILED/{p=1} /^\[[0-9]+\/[0-9]+\]/{p=0} p' "$OUT/build.log" | cut -c1-600 | head -150; exit 1; }
echo "::endgroup::"

LIB=$(find "$WORK" -name 'libwebp4j-*.so' -o -name 'libwebp4j-*.dylib' | head -1)
NAME=$(basename "$LIB")
cp "$LIB" "$WORK/webp_bench" "$OUT/"
for f in src/enc/vp8l_enc.c src/main/c/webp4j.c; do grep -m1 -F "$f" "$OUT/build.log" || true; done > "$OUT/compile-cmds.txt"

# The library must depend on the C runtime only: a libjvm / libjawt reference (webp4j links
# ${JNI_LIBRARIES}) would fail to load in a JVM that has not loaded AWT.
if [ "$(uname)" = Darwin ]; then
    DEPS=$(otool -L "$OUT/$NAME" | tail -n +2 | awk '{print $1}' | grep -v "$NAME" | tr '\n' ' ')
    BAD=$(echo "$DEPS" | tr ' ' '\n' | grep -vE '^(/usr/lib/libSystem\.B\.dylib)?$' || true)
    MIN=$(otool -l "$OUT/$NAME" | awk '/minos/{print $2; exit}')
    EXPORTS=$(nm -gU "$OUT/$NAME" | grep -c 'Java_dev_matrixlab_webp4j_internal_NativeWebP_' || true)
    REQ="macOS $MIN+"
else
    DEPS=$(readelf -d "$OUT/$NAME" | sed -nE 's/.*\(NEEDED\).*\[(.*)\]/\1/p' | tr '\n' ' ')
    BAD=$(echo "$DEPS" | tr ' ' '\n' | grep -vE '^(lib(c|m|pthread|dl|rt)\.so\.[0-9]+|ld-linux[^ ]*)?$' || true)
    GLIBC=$(objdump -T "$OUT/$NAME" | grep -oE 'GLIBC_[0-9.]+' | sort -uV | tail -1)
    EXPORTS=$(nm -D --defined-only "$OUT/$NAME" | grep -c 'Java_dev_matrixlab_webp4j_internal_NativeWebP_' || true)
    REQ="${GLIBC/GLIBC_/glibc }+"
fi
[ -z "$BAD" ] || { echo "::error::$NAME depends on $BAD"; exit 1; }
[ "$EXPORTS" -ge 10 ] || { echo "::error::expected 10 JNI exports, found $EXPORTS"; exit 1; }
{
    echo "compiler: $(${CC:-cc} --version | head -1)"
    echo "variant:  portable"
    echo "flags:    $FLAGS ${LINK_FLAGS:-}"
    echo "libwebp:  $(git -C "$SB" rev-parse --short HEAD 2>/dev/null || echo '?')"
    echo "webp4j:   $(git -C "$WEBP4J_SRC" describe --tags --always 2>/dev/null || echo '?')"
    echo "exports:  $EXPORTS JNI functions"
    echo "requires: $REQ"
    echo "deps:     $DEPS"
} | tee "$OUT/info.txt"
ls -l "$OUT"
