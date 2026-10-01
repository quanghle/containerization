#!/bin/bash
# Copyright © 2026 Apple Inc. and the Containerization project authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#   https://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Builds a Linux deployment tarball for the HOST architecture (x86_64 or
# aarch64) natively — no apple/container CLI or cross toolchain required.
# Used by .github/workflows/linux-dist.yml; also runnable on any Linux host.
#
# Output: <out>/containerization-<arch>-<sha>.tar.gz (+ .sha256) containing
#
#   containerization-<arch>-<sha>/
#   ├── bin/{cctl,cloud-hypervisor,virtiofsd}
#   ├── kernel/vmlinux-<arch>
#   └── initfs.ext4
#
# cctl and vminitd/vmexec are static musl builds via the Swift Static Linux
# SDK (which already bundles libarchive/lzma/bz2/z/crypto). cloud-hypervisor
# and the guest kernel are pinned upstream release artifacts (sha256
# verified). virtiofsd is passed in via --virtiofsd because it is built
# separately against an older glibc for host portability.
#
# Requires: Swift toolchain matching .swift-version with the Static Linux SDK
# installed (`make -C vminitd linux-sdk`), curl, xz, tar, e2fsprogs, git.

set -euo pipefail

usage() {
    echo "usage: $0 --virtiofsd PATH [--out DIR]" >&2
    exit 1
}

VIRTIOFSD=""
OUT="bin"
while [ $# -gt 0 ]; do
    case "$1" in
        --virtiofsd) VIRTIOFSD=$2; shift 2 ;;
        --out)       OUT=$2;       shift 2 ;;
        *)           usage ;;
    esac
done
[ -n "${VIRTIOFSD}" ] && [ -f "${VIRTIOFSD}" ] || usage

ROOT=$(git rev-parse --show-toplevel)
cd "${ROOT}"
VIRTIOFSD=$(realpath "${VIRTIOFSD}")

CH_VERSION=v52.0
KATA_VERSION=3.17.0
case "$(uname -m)" in
    x86_64)
        ARCH=x86_64
        CH_ASSET=cloud-hypervisor-static
        CH_SHA256=829af01ff075bb96c4f183905134c453a88d68cbabdc6b87df21098842581ee9
        KATA_ARCH=amd64
        KATA_SHA256=1298e24922b03507e93563267c0049bc81a91666fda87f8632006828578e60e0
        ;;
    aarch64 | arm64)
        ARCH=aarch64
        CH_ASSET=cloud-hypervisor-static-aarch64
        CH_SHA256=bf004ddc1a148f47caa87ac49a783b8dbd6bf9bc27abe522ed197df7b982d3b1
        KATA_ARCH=arm64
        KATA_SHA256=647c7612e6edf789d5e14698c48c99d8bac15ad139ffaa1c8bb7d229f748d181
        ;;
    *)
        echo "ERROR: unsupported host architecture $(uname -m)" >&2
        exit 1
        ;;
esac

CACHE="${DIST_CACHE_DIR:-${ROOT}/.local/dist-cache}"
GIT_SHA=$(git rev-parse --short HEAD)
DIST_NAME="containerization-${ARCH}-${GIT_SHA}"
WORK="${ROOT}/${OUT}/dist-${ARCH}"
STAGE="${WORK}/${DIST_NAME}"
mkdir -p "${CACHE}" "${WORK}"

# fetch URL DEST SHA256 — download to DEST unless it already matches SHA256.
fetch() {
    local url=$1 dest=$2 sha=$3
    if [ -f "${dest}" ] && echo "${sha}  ${dest}" | sha256sum -c --status -; then
        return
    fi
    curl -fsSL -o "${dest}.tmp" "${url}"
    if ! echo "${sha}  ${dest}.tmp" | sha256sum -c --status -; then
        echo "ERROR: checksum mismatch for ${url}" >&2
        rm -f "${dest}.tmp"
        exit 1
    fi
    mv "${dest}.tmp" "${dest}"
}

SDK="${ARCH}-swift-linux-musl"

echo "==> Building cctl (${SDK})"
swift build -c release --swift-sdk "${SDK}" --product cctl \
    -Xswiftc -warnings-as-errors -Xlinker -s --disable-automatic-resolution
CCTL="$(swift build -c release --swift-sdk "${SDK}" --show-bin-path)/cctl"

echo "==> Building vminitd + vmexec (${SDK})"
make -C vminitd LIBC=musl MUSL_ARCH="${ARCH}" BUILD_CONFIGURATION=release INSTALL_DIR="${WORK}"

echo "==> Building initfs.ext4"
rm -f "${WORK}/initfs.ext4"
./scripts/build-initfs.sh --vminitd "${WORK}/vminitd" --vmexec "${WORK}/vmexec" --ext4 "${WORK}/initfs.ext4"

echo "==> Fetching cloud-hypervisor ${CH_VERSION}"
CH_BIN="${CACHE}/cloud-hypervisor-${CH_VERSION}-${ARCH}"
fetch "https://github.com/cloud-hypervisor/cloud-hypervisor/releases/download/${CH_VERSION}/${CH_ASSET}" \
    "${CH_BIN}" "${CH_SHA256}"

echo "==> Fetching Kata ${KATA_VERSION} guest kernel"
KERNEL="${CACHE}/vmlinux-${ARCH}-kata-${KATA_VERSION}"
if [ ! -f "${KERNEL}" ]; then
    KATA_TAR="${CACHE}/kata-static-${KATA_VERSION}-${KATA_ARCH}.tar.xz"
    fetch "https://github.com/kata-containers/kata-containers/releases/download/${KATA_VERSION}/kata-static-${KATA_VERSION}-${KATA_ARCH}.tar.xz" \
        "${KATA_TAR}" "${KATA_SHA256}"
    KATA_TMP=$(mktemp -d)
    tar -xJf "${KATA_TAR}" -C "${KATA_TMP}" --wildcards './opt/kata/share/kata-containers/vmlinux*'
    cp -L "${KATA_TMP}/opt/kata/share/kata-containers/vmlinux.container" "${KERNEL}"
    rm -rf "${KATA_TMP}" "${KATA_TAR}"
fi

echo "==> Staging ${DIST_NAME}"
rm -rf "${STAGE}"
mkdir -p "${STAGE}/bin" "${STAGE}/kernel"
install -m 755 "${CCTL}" "${STAGE}/bin/cctl"
install -m 755 "${CH_BIN}" "${STAGE}/bin/cloud-hypervisor"
install -m 755 "${VIRTIOFSD}" "${STAGE}/bin/virtiofsd"
install -m 644 "${KERNEL}" "${STAGE}/kernel/vmlinux-${ARCH}"
install -m 644 "${WORK}/initfs.ext4" "${STAGE}/initfs.ext4"

TGZ="${ROOT}/${OUT}/${DIST_NAME}.tar.gz"
tar -czf "${TGZ}" -C "${WORK}" "${DIST_NAME}"
(cd "$(dirname "${TGZ}")" && sha256sum "$(basename "${TGZ}")" > "$(basename "${TGZ}").sha256")
echo "==> Wrote ${TGZ}"
