# Superbuild used by build-variant.sh (.github/workflows/windows-x64-compilers.yml):
#   webp4j JNI library - webp4j's own CMakeLists.txt, whose bundled libwebp/ is this repository
#   webp_bench         - encode/decode benchmark linked against the SAME libwebp objects, so it measures
#                        exactly the code that ships in the DLL
cmake_minimum_required(VERSION 3.16)
project(webp_compiler_bench C)

set(WEBP4J_DIR "" CACHE PATH "webp4j source tree (its libwebp/ must point to this repository)")
if(NOT EXISTS "${WEBP4J_DIR}/libwebp/src/webp/encode.h")
  message(FATAL_ERROR "WEBP4J_DIR=${WEBP4J_DIR} has no libwebp/src/webp/encode.h")
endif()
add_subdirectory(${WEBP4J_DIR} webp4j)

add_executable(webp_bench webp_bench.c)
target_link_libraries(webp_bench PRIVATE webp)
if(UNIX AND NOT APPLE)
  target_link_libraries(webp_bench PRIVATE m)  # libwebp's static targets do not carry -lm
endif()
