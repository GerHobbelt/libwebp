#!/usr/bin/env bash
# Assembles and publishes the GitHub release of .github/workflows/release.yml (run from the repo root).
# Inputs (directories): natives/  natives.yml's 'natives-all' artifact (6 portable + 2 AVX2 tested libraries
#                                 + info-<id>.txt)
#                       avx2/     natives-windows-x64.yml's bin-<AVX2_BUILD> artifact (tested)
#                       webp4j/   webp4j checkout (WEBP4J_REF) used to build the drop-in jars
# Environment: TAG, AVX2_BUILD, WEBP4J_REF, PRERELEASE (--prerelease or empty), GH_TOKEN,
#              DRY_RUN=1 assembles rel/ + notes.md without publishing
set -euo pipefail

LIBWEBP=$(sed -nE 's/^AC_INIT\(\[libwebp\], \[([0-9.]+)\].*/\1/p' configure.ac)
W4J=${WEBP4J_REF#v}
SHORT=${GITHUB_SHA:0:8}
test -n "$LIBWEBP" && test -n "$W4J"
LIBS=(webp4j-windows-x64.dll webp4j-windows-aarch64.dll libwebp4j-linux-x64.so libwebp4j-linux-aarch64.so
      libwebp4j-mac-x64.dylib libwebp4j-mac-arm64.dylib)

rm -rf rel && mkdir rel
AVX2=(webp4j-windows-x64-avx2.dll libwebp4j-linux-x64-avx2.so libwebp4j-mac-x64-avx2.dylib)
for l in "${LIBS[@]}" libwebp4j-linux-x64-avx2.so libwebp4j-mac-x64-avx2.dylib; do cp "natives/$l" rel/; done
cp avx2/webp4j-windows-x64.dll rel/webp4j-windows-x64-avx2.dll
cp avx2/info.txt natives/info-windows-x64-avx2.txt
(cd natives && zip -q ../rel/build-info.zip info-*.txt)

# Drop-in replacements for dev.matrixlab.webp4j:webp4j-core:<W4J>: the same classes with these libraries.
mkdir -p webp4j/src/main/resources/native
for l in "${LIBS[@]}"; do cp "natives/$l" webp4j/src/main/resources/native/; done
(cd webp4j && mvn -B -ntp -q -DskipTests -Dgpg.skip=true -Dmaven.javadoc.skip=true -Dmaven.source.skip=true package)
JAR=webp4j-core-$W4J-all-platforms.jar
cp "webp4j/target/webp4j-core-$W4J.jar" "rel/$JAR"
cp "rel/$JAR" "rel/${JAR%.jar}-avx2.jar"
mkdir -p jarx/native   # the -avx2 jar: the three x64 libraries replaced by their AVX2 builds
for a in "${AVX2[@]}"; do cp "rel/$a" "jarx/native/${a/-avx2/}"; done
(cd jarx && jar uf "../rel/${JAR%.jar}-avx2.jar" native/webp4j-windows-x64.dll native/libwebp4j-linux-x64.so     native/libwebp4j-mac-x64.dylib)
for j in "rel/$JAR" "rel/${JAR%.jar}-avx2.jar"; do
    test "$(unzip -l "$j" | grep -cE ' native/(lib)?webp4j-')" = 6 || { echo "::error::$j: not 6 libraries"; exit 1; }
done
for a in "${AVX2[@]}"; do cmp <(unzip -p "rel/${JAR%.jar}-avx2.jar" "native/${a/-avx2/}") "rel/$a"; done

cp bench-results.md "rel/bench-results-$LIBWEBP-$W4J.md"
(cd rel && sha256sum -- * > SHA256SUMS.txt && cat SHA256SUMS.txt)

info() { sed -n "s/^$2: *//p" "natives/info-$1.txt" | head -1; }
row() {  # id label library [requirement]
    echo "| $2 | \`$3\` | $(info "$1" compiler | sed -E 's/ \(https?:[^)]*\)//') | ${4:-$(info "$1" requires)} |"
}
clean() { sed -E 's/-fprofile-use=[^ ]*/-fprofile-use/; s/ -W[^ ]*//g; s/ -fprofile-prefix-path=[^ ]*//'; }
{
    echo "webp4j $W4J native libraries with libwebp $LIBWEBP from this fork (commit \`$SHORT\`), built and tested by"
    echo "GitHub Actions ([run $GITHUB_RUN_ID]($GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID))."
    echo "Every library was built natively on a runner of its platform with Clang, LTO and PGO, and passed"
    echo "webp4j's JUnit suite there."
    echo
    echo "| Platform | Library | Compiler | Requires |"
    echo "|---|---|---|---|"
    row windows-x64 "Windows x64" webp4j-windows-x64.dll
    row windows-aarch64 "Windows ARM64" webp4j-windows-aarch64.dll
    row linux-x64 "Linux x64" libwebp4j-linux-x64.so
    row linux-aarch64 "Linux ARM64" libwebp4j-linux-aarch64.so
    row mac-x64 "macOS Intel" libwebp4j-mac-x64.dylib
    row mac-arm64 "macOS Apple Silicon" libwebp4j-mac-arm64.dylib
    row windows-x64-avx2 "Windows x64, **AVX2**" webp4j-windows-x64-avx2.dll         "Windows 10+ x64 (UCRT); x86-64-v3 CPU (AVX2/FMA/BMI2: Intel Haswell / AMD Zen 1 or newer)"
    row linux-x64-avx2 "Linux x64, **AVX2**" libwebp4j-linux-x64-avx2.so
    row mac-x64-avx2 "macOS Intel, **AVX2**" libwebp4j-mac-x64-avx2.dylib
    echo
    echo "* Portable libraries: \`$(info linux-x64 flags | clean)\` without \`-march\` (libwebp selects its SSE2/SSE4.1/"
    echo "  AVX2 or NEON code at run time). PGO profile: an instrumented build of \`webp_bench\` (same libwebp objects)"
    echo "  trained on each runner with the images of \`ci/compiler-bench/corpus.sh train\`."
    echo "* \`*-avx2\` libraries: \`-march=x86-64-v3\` in addition; on a CPU without AVX2 they fail with an illegal"
    echo "  instruction. The Windows one is \`$AVX2_BUILD\` (\`$(sed -n 's/^flags: *//p' avx2/info.txt | clean)\`), the"
    echo "  fastest of 16 GCC 16/17 and Clang 23/24 builds in \`bench-results-$LIBWEBP-$W4J.md\`."
    echo
    echo "**How to use**"
    echo "* \`$JAR\`: drop-in replacement for \`dev.matrixlab.webp4j:webp4j-core:$W4J\` (the same classes) with the"
    echo "  6 portable libraries inside. \`${JAR%.jar}-avx2.jar\`: the same with the AVX2 builds for the three x64 platforms."
    echo "* Or a single library: webp4j loads \`/native/<library>\` from the classpath, so a directory or jar with e.g."
    echo "  \`native/webp4j-windows-x64.dll\` (an \`-avx2\` file renamed) placed before webp4j-core on the classpath overrides it."
    echo
    echo "Build details of every library (compiler, flags, dependencies): \`build-info.zip\`. Checksums: \`SHA256SUMS.txt\`."
} > notes.md
cat notes.md

[ "${DRY_RUN:-}" = 1 ] && exit 0
gh release create "$TAG" rel/* --repo "$GITHUB_REPOSITORY" --target "$GITHUB_SHA" ${PRERELEASE:-} \
    --title "webp4j $W4J natives, libwebp $LIBWEBP ($TAG)" --notes-file notes.md
