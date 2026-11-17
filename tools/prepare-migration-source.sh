#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMMIT="81e05f070c070af65cac21e8da28ca4ff2d58905"
ARCHIVE_SHA256="ceb512fdededfdddd395af8717ed762956cf56d7c2317ecd9b5f7561183c1a13"
CACHE_DIR="${PROJECT_DIR}/.source/migration"
ARCHIVE="${CACHE_DIR}/keykey.tar.gz"
mkdir -p "${CACHE_DIR}"

if [[ ! -f "${ARCHIVE}" ]]; then
    curl --fail --location --silent --show-error \
        "https://codeload.github.com/YahooArchive/KeyKey/tar.gz/${COMMIT}" \
        -o "${ARCHIVE}.download"
    mv "${ARCHIVE}.download" "${ARCHIVE}"
fi

actual_sha256="$(shasum -a 256 "${ARCHIVE}" | awk '{print $1}')"
if [[ "${actual_sha256}" != "${ARCHIVE_SHA256}" ]]; then
    echo "Migration source archive checksum mismatch: ${ARCHIVE}" >&2
    exit 1
fi

# This cache is separate from the legacy source-build checkout. Re-extraction
# ensures the reference harness always uses the pinned, unpatched source.
tar -xzf "${ARCHIVE}" -C "${CACHE_DIR}"
printf '%s\n' "${CACHE_DIR}/KeyKey-${COMMIT}/YahooKeyKey-Source-1.1.2528"
