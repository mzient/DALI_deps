#!/bin/bash -xe

# Copyright (c) 2026, NVIDIA CORPORATION. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Google Cloud C++ client libraries. DALI only uses Google Cloud Storage, so
# `storage` is the single entry in GOOGLE_CLOUD_CPP_ENABLE - the ~200 other GA
# libraries are left out. google_cloud_cpp_enable_deps() then adds monitoring,
# trace, opentelemetry and universe_domain on top of whatever was asked for, which
# is where the gRPC and opentelemetry-cpp dependencies come from. There is no
# storage-only-without-gRPC configuration: dropping monitoring/trace/opentelemetry
# still leaves an unconditional #include of an opentelemetry header in
# google_cloud_cpp_common, so the build fails rather than losing tracing support.
#
# The googleapis protobuf definitions are not vendored here: google-cloud-cpp
# downloads the pinned, checksummed tarball while configuring - the only
# dependency in this repo that reaches the network at build time, since
# everything else is a pinned submodule. Point
# GOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL at a local copy (a file:// URL
# works) to build offline; it is forwarded below when set in the environment.
#
# GOOGLE_CLOUD_CPP_WITH_MOCKS defaults to ON whenever BUILD_TESTING is OFF
# (CMakeLists.txt's cmake_dependent_option), which is exactly this build's
# configuration, and pulls in GTest/GMock (CMakeLists.txt:255, guarded by
# `if (BUILD_TESTING OR GOOGLE_CLOUD_CPP_WITH_MOCKS)`) purely to compile mocking
# libraries nothing here links against. Turning it off drops googletest and
# benchmark (GTest's build-time companion) from this dependency set entirely -
# verified with a from-scratch build: the default flags fail configure with
# "Could NOT find GTest" when googletest isn't installed, while adding this
# flag configures, builds, and installs cleanly without it.
#
# Shared, unlike everything built above it. This mirrors the AWS SDK: aws-sdk-cpp keeps its own
# CMake default of BUILD_SHARED_LIBS=ON and links its C runtime libraries statically, so DALI gets
# libaws-cpp-sdk-{core,s3}.so over static libaws-c-*.a. The same reasoning applies here - libdali.so
# and libdali_operators.so both use the GCS client, and a gcs::Client constructed by one and used
# by the other has to be the same object, which it is only if there is a single copy of the
# library in the process. Built statically instead, each of them ends up with a private copy, and
# passing a client across that boundary crashes. gRPC, protobuf, abseil, opentelemetry, curl and
# OpenSSL stay static and are linked into the three shared objects that come out of this:
# libgoogle_cloud_cpp_{storage,rest_internal,common}.so, which is the whole runtime closure.
export ROOT_DIR=$(realpath "${ROOT_DIR:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..}")
source "${ROOT_DIR}/build_scripts/validate_toolchain_env.sh"
source "${ROOT_DIR}/build_scripts/generate_toolchain_file.sh"
: "${HOST_INSTALL_PREFIX:=/usr/local}"
: "${INSTALL_PREFIX:=${HOST_INSTALL_PREFIX}}"

declare -a EXTRA_CMAKE_ARGS
# Cross compilation only: protoc and grpc_cpp_plugin have to be the host builds,
# the ones installed next to the target libraries cannot be executed here.
if [[ -n ${CC_COMP:-} && ${CC_COMP} != gcc ]]; then
  EXTRA_CMAKE_ARGS+=(-DProtobuf_PROTOC_EXECUTABLE=${HOST_INSTALL_PREFIX}/bin/protoc)
  EXTRA_CMAKE_ARGS+=(-DGOOGLE_CLOUD_CPP_GRPC_PLUGIN_EXECUTABLE=${HOST_INSTALL_PREFIX}/bin/grpc_cpp_plugin)
fi
if [[ -n ${GOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL:-} ]]; then
  EXTRA_CMAKE_ARGS+=(-DGOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL="${GOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL}")
fi
if [[ -n ${GOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL_HASH:-} ]]; then
  EXTRA_CMAKE_ARGS+=(-DGOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL_HASH="${GOOGLE_CLOUD_CPP_OVERRIDE_GOOGLEAPIS_URL_HASH}")
fi

pushd "${ROOT_DIR}/third_party/google-cloud-cpp"
mkdir -p build
cd build
generate_toolchain_file toolchain.cmake
cmake -DCMAKE_BUILD_TYPE=Release -DCMAKE_TOOLCHAIN_FILE=toolchain.cmake \
      -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
      -DCMAKE_PREFIX_PATH=${INSTALL_PREFIX} \
      -DCMAKE_CXX_STANDARD=17 \
      -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
      -DBUILD_SHARED_LIBS=ON \
      -DBUILD_TESTING=OFF \
      -DGOOGLE_CLOUD_CPP_WITH_MOCKS=OFF \
      -DGOOGLE_CLOUD_CPP_ENABLE=storage \
      -DGOOGLE_CLOUD_CPP_ENABLE_EXAMPLES=OFF \
      -DOPENSSL_ROOT_DIR=${INSTALL_PREFIX} \
      -DOPENSSL_USE_STATIC_LIBS=ON \
      "${EXTRA_CMAKE_ARGS[@]}" \
      ..
make -j"$(nproc)"
make install
popd
