#!/bin/bash -xe

# Copyright (c) 2024, NVIDIA CORPORATION. All rights reserved.
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

export ROOT_DIR=$(realpath "${ROOT_DIR:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/..}")
source "${ROOT_DIR}/build_scripts/validate_toolchain_env.sh"
: "${INSTALL_PREFIX:=${HOST_INSTALL_PREFIX:-/usr/local}}"

for flag_var in CPPFLAGS LDFLAGS; do
  if [[ -n ${!flag_var:-} && ! ${!flag_var} =~ ^[a-zA-Z0-9/_.+=,\ -]+$ ]]; then
    echo "ERROR: ${flag_var} contains invalid characters" >&2
    exit 1
  fi
done

mkdir -p ${ROOT_DIR}/third_party/aws-sdk-cpp/build

export TOOLCHAIN_FILE=${ROOT_DIR}/third_party/aws-sdk-cpp/toolchain.cmake

echo "set(CMAKE_SYSTEM_NAME Linux)" > ${TOOLCHAIN_FILE}
if [[ -n ${CMAKE_TARGET_ARCH:-} ]]; then
    echo "set(CMAKE_SYSTEM_PROCESSOR ${CMAKE_TARGET_ARCH})" >> ${TOOLCHAIN_FILE}
fi
if [[ -n ${CC_COMP:-} ]]; then
    echo "set(CMAKE_C_COMPILER ${CC_COMP})" >> ${TOOLCHAIN_FILE}
fi
if [[ -n ${CXX_COMP:-} ]]; then
    echo "set(CMAKE_CXX_COMPILER ${CXX_COMP})" >> ${TOOLCHAIN_FILE}
fi
# only when cross compiling
if [[ -n ${CC_COMP:-} && ${CC_COMP} != gcc ]]; then
    echo "set(CMAKE_FIND_ROOT_PATH \"${INSTALL_PREFIX}\")" >> ${TOOLCHAIN_FILE}
    echo "set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)" >> ${TOOLCHAIN_FILE}
    echo "set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)" >> ${TOOLCHAIN_FILE}
    echo "set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)" >> ${TOOLCHAIN_FILE}
fi
# use ' to avoid bash substitution for CMAKE_C* variables
echo 'set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -fPIC")' >> ${TOOLCHAIN_FILE}
echo 'set(CMAKE_CXX_FLAGS "${CMAKE_CXX_FLAGS} -fPIC")' >> ${TOOLCHAIN_FILE}

# Build AWS SDK libs, link statically with libcurl and OpenSSL. Both are built
# once, ahead of this script, by build_openssl.sh/build_curl.sh into the shared
# INSTALL_PREFIX - this used to build its own private copies of both, which
# just duplicated that work (and, for OpenSSL, reconfigured the same in-place
# source tree a second time).
pushd ${ROOT_DIR}/third_party/aws-sdk-cpp/build
cmake -DCMAKE_BUILD_TYPE=Release \
      -DLEGACY_MODE=OFF \
      -DCMAKE_DISABLE_FIND_PACKAGE_s2n=ON \
      -DCMAKE_SYSTEM_INCLUDE_PATH="${INSTALL_PREFIX}/include" \
      -DCMAKE_SYSTEM_PREFIX_PATH="${INSTALL_PREFIX}" \
      -DCURL_INCLUDE_DIR="${INSTALL_PREFIX}/include" \
      -DCURL_LIBRARY_RELEASE="${INSTALL_PREFIX}/lib/libcurl.a" \
      -DCURL_LIBRARIES="${INSTALL_PREFIX}/lib/libcurl.a" \
      -Dcrypto_INCLUDE_DIR="${INSTALL_PREFIX}/include" \
      -Dcrypto_SHARED_LIBRARY="${INSTALL_PREFIX}/lib/libcrypto.a" \
      -Dcrypto_STATIC_LIBRARY="${INSTALL_PREFIX}/lib/libcrypto.a" \
      -DOPENSSL_INCLUDE_DIR="${INSTALL_PREFIX}/include" \
      -DOPENSSL_SSL_LIBRARY="${INSTALL_PREFIX}/lib/libssl.a" \
      -DOPENSSL_CRYPTO_LIBRARY="${INSTALL_PREFIX}/lib/libcrypto.a" \
      -DOPENSSL_LIBRARIES="${INSTALL_PREFIX}/lib/libssl.a;${INSTALL_PREFIX}/lib/libcrypto.a" \
      -DCMAKE_TOOLCHAIN_FILE=${TOOLCHAIN_FILE} \
      -DCMAKE_INSTALL_PREFIX=${INSTALL_PREFIX} \
      -DBUILD_ONLY='s3;core' \
      -DCMAKE_POLICY_DEFAULT_CMP0075=NEW \
      -DENABLE_TESTING=OFF \
      ..
make -j"$(grep ^processor /proc/cpuinfo | wc -l)"
make install

popd
