#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: write-source-build-info.sh <source-pkg> <output-file>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_PKG="$1"
OUTPUT_FILE="$2"
SOURCE_PATCH_MANIFEST="${SOURCE_PATCH_MANIFEST:-${SCRIPT_DIR}/source-patches/manifest.tsv}"
UPSTREAM_REPO="${UPSTREAM_REPO:-https://github.com/YahooArchive/KeyKey.git}"
VERSION="${VERSION:-unknown}"
GIT_CMD="${GIT:-git}"

relative_path() {
    local path="$1"

    case "${path}" in
        "${PROJECT_DIR}"/*)
            printf '%s\n' "${path#"${PROJECT_DIR}/"}"
            ;;
        *)
            printf '%s\n' "${path}"
            ;;
    esac
}

[[ -f "${SOURCE_PKG}" ]] || {
    echo "source package is missing: ${SOURCE_PKG}" >&2
    exit 1
}

[[ -f "${SOURCE_PATCH_MANIFEST}" ]] || {
    echo "source patch manifest is missing: ${SOURCE_PATCH_MANIFEST}" >&2
    exit 1
}

mkdir -p "$(dirname "${OUTPUT_FILE}")"

source_pkg_path="$(cd "$(dirname "${SOURCE_PKG}")" && pwd)/$(basename "${SOURCE_PKG}")"
manifest_path="$(cd "$(dirname "${SOURCE_PATCH_MANIFEST}")" && pwd)/$(basename "${SOURCE_PATCH_MANIFEST}")"
package_sha256="$(shasum -a 256 "${source_pkg_path}" | awk '{ print $1 }')"
manifest_sha256="$(shasum -a 256 "${manifest_path}" | awk '{ print $1 }')"
upstream_commit="$(awk '$1 == "#" && $2 == "upstream" { print $3; exit }' "${manifest_path}")"
patch_count="$(awk 'NF && $1 !~ /^#/ { count += 1 } END { print count + 0 }' "${manifest_path}")"
project_revision="$("${GIT_CMD}" -C "${PROJECT_DIR}" rev-parse HEAD 2>/dev/null || true)"
project_dirty="unknown"

if "${GIT_CMD}" -C "${PROJECT_DIR}" rev-parse --git-dir >/dev/null 2>&1; then
    if [[ -n "$("${GIT_CMD}" -C "${PROJECT_DIR}" status --short)" ]]; then
        project_dirty="yes"
    else
        project_dirty="no"
    fi
fi

{
    echo "CangjieX source build info"
    echo "version: ${VERSION}"
    echo "built_at_utc: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    echo "package: $(relative_path "${source_pkg_path}")"
    echo "package_sha256: ${package_sha256}"
    echo "upstream_repo: ${UPSTREAM_REPO}"
    echo "upstream_commit: ${upstream_commit}"
    echo "patch_manifest: $(relative_path "${manifest_path}")"
    echo "patch_manifest_sha256: ${manifest_sha256}"
    echo "patch_count: ${patch_count}"
    echo "project_revision: ${project_revision:-unknown}"
    echo "project_dirty: ${project_dirty}"
    echo "xcode:"
    if command -v xcodebuild >/dev/null 2>&1; then
        xcodebuild -version 2>/dev/null | sed 's/^/  /'
    else
        echo "  unavailable"
    fi
} >"${OUTPUT_FILE}"

echo "Wrote $(relative_path "${OUTPUT_FILE}")"
