#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLCHAIN="$(sed -n 's/^channel = "\([^"]*\)"/\1/p' "${PROJECT_DIR}/migration/rust-toolchain.toml")"
CACHE_DIR="${PROJECT_DIR}/.source/migration"
export CARGO_HOME="${CACHE_DIR}/cargo"
export RUSTUP_HOME="${CACHE_DIR}/rustup"

[[ "$(uname -s)" == Darwin ]] || { echo "This bootstrap targets macOS." >&2; exit 1; }
case "$(uname -m)" in
    arm64) host="aarch64-apple-darwin" ;;
    x86_64) host="x86_64-apple-darwin" ;;
    *) echo "Unsupported host architecture." >&2; exit 1 ;;
esac

mkdir -p "${CACHE_DIR}"
if [[ ! -x "${CARGO_HOME}/bin/rustup" ]]; then
    installer="${CACHE_DIR}/rustup-init-${host}"
    curl --fail --location --silent --show-error \
        "https://static.rust-lang.org/rustup/dist/${host}/rustup-init" -o "${installer}"
    expected_sha256="$(curl --fail --silent --show-error \
        "https://static.rust-lang.org/rustup/dist/${host}/rustup-init.sha256" | awk '{print $1}')"
    actual_sha256="$(shasum -a 256 "${installer}" | awk '{print $1}')"
    [[ "${actual_sha256}" == "${expected_sha256}" ]] || { echo "Rustup checksum mismatch." >&2; exit 1; }
    chmod +x "${installer}"
    "${installer}" -y --no-modify-path --profile minimal --default-toolchain none
fi

"${CARGO_HOME}/bin/rustup" toolchain install "${TOOLCHAIN}" --profile minimal --component rustfmt --component clippy
echo "Project-local Rust ${TOOLCHAIN} is ready; shell profiles and system PATH are unchanged."
