#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${PROJECT_DIR}/build/migration"
cd "${PROJECT_DIR}"

if [[ -x "${PROJECT_DIR}/.source/migration/cargo/bin/cargo" ]]; then
    export CARGO_HOME="${PROJECT_DIR}/.source/migration/cargo"
    export RUSTUP_HOME="${PROJECT_DIR}/.source/migration/rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
fi
command -v cargo >/dev/null || { echo "Rust is missing. Run: make migration-toolchain" >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "Swift bridge and legacy baseline checks require macOS." >&2; exit 1; }

source_root="$(bash tools/prepare-migration-source.sh)"
mkdir -p "${OUTPUT_DIR}/legacy-include"
ln -sfn "${source_root}/Frameworks/OpenVanilla/Headers" "${OUTPUT_DIR}/legacy-include/OpenVanilla"
ln -sfn "${source_root}/Frameworks/PlainVanilla/Headers" "${OUTPUT_DIR}/legacy-include/PlainVanilla"

# System includes isolate warnings from unchanged upstream headers. The forced
# unistd import is the same declaration fix used by the existing source build.
xcrun clang -c "${source_root}/ModulePackages/OVOFHanConvert/VXHCTC2SCTable.c" -o "${OUTPUT_DIR}/tc2sc.o"
xcrun clang -c "${source_root}/ModulePackages/OVOFHanConvert/VXHCSC2TCTable.c" -o "${OUTPUT_DIR}/sc2tc.o"
if ! xcrun clang++ -std=c++11 -include unistd.h \
    -Wno-dangling-else -Wno-deprecated-declarations -Wno-parentheses \
    -isystem "${OUTPUT_DIR}/legacy-include" \
    -I "${source_root}/ModulePackages/OVIMGeneric" \
    -I "${source_root}/ModulePackages/OVIMMandarin" \
    -I "${source_root}/ModulePackages/OVOFHanConvert" \
    -I "${source_root}/ModulePackages/OVAFBopomofoCorrection" \
    migration/baseline/legacy_probe.cpp \
    "${source_root}/ModulePackages/OVIMGeneric/OVIMGeneric.cpp" \
    "${source_root}/ModulePackages/OVIMMandarin/OVAFAssociatedPhrase.cpp" \
    "${source_root}/ModulePackages/OVOFHanConvert/OVOFHanConvert.cpp" \
    "${source_root}/ModulePackages/OVAFBopomofoCorrection/OVAFBopomofoCorrection.cpp" \
    "${OUTPUT_DIR}/tc2sc.o" "${OUTPUT_DIR}/sc2tc.o" \
    -lsqlite3 -o "${OUTPUT_DIR}/legacy-probe" >"${OUTPUT_DIR}/legacy-build.log" 2>&1; then
    cat "${OUTPUT_DIR}/legacy-build.log" >&2
    exit 1
fi

ruby migration/tests/extraction_test.rb "${source_root}"
ruby migration/tests/baseline_test.rb "${source_root}" "${OUTPUT_DIR}/legacy-probe"

export CARGO_TARGET_DIR="${OUTPUT_DIR}/rust"
(
    cd migration/core
    cargo fmt --check
    cargo test --locked --offline
    cargo clippy --locked --offline --all-targets -- -D warnings
    cargo build --release --locked --offline
)

xcrun swiftc -O -warnings-as-errors \
    -import-objc-header migration/bridge/CangjieCore.h \
    migration/swift/Probe.swift \
    -L "${CARGO_TARGET_DIR}/release" -lcangjiex_core \
    -o "${OUTPUT_DIR}/swift-rust-probe"
"${OUTPUT_DIR}/swift-rust-probe" migration/data/cangjie.tsv

xcrun swiftc -O -warnings-as-errors \
    -import-objc-header migration/bridge/CangjieCore.h \
    migration/swift/SessionProbe.swift \
    -L "${CARGO_TARGET_DIR}/release" -lcangjiex_core \
    -o "${OUTPUT_DIR}/swift-session-probe"
"${OUTPUT_DIR}/swift-session-probe" migration/baseline/cases.json migration/baseline/m2-cases.json migration/baseline/m3-live-cases.json migration/baseline/m3-full-cases.json migration/baseline/simplex-cases.json migration/baseline/correction-cases.json migration/baseline/simplex-full-cases.json
echo "PASS: migration checks complete. No input method was installed or replaced."
