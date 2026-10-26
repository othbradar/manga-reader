cmake_minimum_required(VERSION 3.22)
if(POLICY CMP0135)
  cmake_policy(SET CMP0135 NEW)
endif()
project(reader_jxl LANGUAGES C CXX)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
include(FetchContent)

# Pinned libjxl release and its exact submodule revisions. Downloaded sources
# and build products stay outside the repository; no host codec is required.
function(reader_fetch name url sha directory)
  FetchContent_Declare(${name} URL "${url}" URL_HASH "SHA256=${sha}"
    SOURCE_DIR "${directory}" SOURCE_SUBDIR unused)
  FetchContent_MakeAvailable(${name})
endfunction()
set(jxl_source "${CMAKE_CURRENT_BINARY_DIR}/sources/libjxl")
reader_fetch(reader_libjxl
  https://codeload.github.com/libjxl/libjxl/tar.gz/refs/tags/v0.12.0
  03e9be69a30be4011f559da75328b6d7cea8ad921fabfbd551ce10bf45cdc992 "${jxl_source}")
reader_fetch(reader_brotli
  https://codeload.github.com/google/brotli/tar.gz/028fb5a23661f123017c060daa546b55cf4bde29
  0afe09a53c8bad9861c8dd1fc1284308d54f19d2979ba3541cfdcc9b05fe360f "${jxl_source}/third_party/brotli")
reader_fetch(reader_highway
  https://codeload.github.com/google/highway/tar.gz/457c891775a7397bdb0376bb1031e6e027af1c48
  5124b0501c98d9930dbb065bfa1a5bbbd59ce0f12facb7e1e33aaef01a5f1f1a "${jxl_source}/third_party/highway")
reader_fetch(reader_skcms
  https://codeload.github.com/google/skcms/tar.gz/96d9171c94b937a1b5f0293de7309ac16311b722
  9bb4b5bba0b7c04f6c2bce9ff713d61e23c9a20c4945161ae16290498ad74627 "${jxl_source}/third_party/skcms")

set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
foreach(feature TOOLS DEVTOOLS DOXYGEN MANPAGES BENCHMARK EXAMPLES JNI SJPEG OPENEXR VIEWERS PLUGINS TCMALLOC)
  set(JPEGXL_ENABLE_${feature} OFF CACHE BOOL "" FORCE)
endforeach()
set(JPEGXL_ENABLE_SKCMS ON CACHE BOOL "" FORCE)
set(JPEGXL_ENABLE_TRANSCODE_JPEG ON CACHE BOOL "" FORCE)
add_subdirectory("${jxl_source}" libjxl EXCLUDE_FROM_ALL)
find_package(ZLIB REQUIRED)
add_library(reader_jxl SHARED reader_jxl.cpp)
target_link_libraries(reader_jxl PRIVATE jxl_dec jxl_cms ZLIB::ZLIB)
set_target_properties(reader_jxl PROPERTIES CXX_VISIBILITY_PRESET hidden)
if(ANDROID)
  target_link_options(reader_jxl PRIVATE "-Wl,-z,max-page-size=16384" "-Wl,--exclude-libs,ALL")
endif()
