#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"
OUTPUT_DIR="${PROJECT_DIR}/build/migration/preview"
APP="${OUTPUT_DIR}/CangjieXPreview.app"
if [[ -x "${PROJECT_DIR}/.source/migration/cargo/bin/cargo" ]]; then
    export CARGO_HOME="${PROJECT_DIR}/.source/migration/cargo"
    export RUSTUP_HOME="${PROJECT_DIR}/.source/migration/rustup"
    export PATH="${CARGO_HOME}/bin:${PATH}"
fi
command -v cargo >/dev/null || { echo "Run make migration-toolchain first." >&2; exit 1; }
[[ "$(uname -s)" == Darwin ]] || { echo "Preview requires macOS." >&2; exit 1; }
export CARGO_TARGET_DIR="${PROJECT_DIR}/build/migration/rust"
export MACOSX_DEPLOYMENT_TARGET=11.0
(
    cd migration/core
    cargo build --release --locked --offline
)

mkdir -p "${APP}/Contents/MacOS" "${APP}/Contents/Resources"
cp assets/brand/CangjieX.icns "${APP}/Contents/Resources/Preview.icns"
cp assets/brand/CangjieXMenu.icns "${APP}/Contents/Resources/PreviewMenu.icns"
cp migration/preview/Info.plist "${APP}/Contents/Info.plist"
cp migration/data/LICENSE.HanConvert.txt "${APP}/Contents/Resources/LICENSE.HanConvert.txt"
cp migration/data/modules-manifest.json "${APP}/Contents/Resources/modules-manifest.json"
cp migration/data/compatibility-manifest.json "${APP}/Contents/Resources/compatibility-manifest.json"
cp migration/data/LICENSE.KeyKey.txt "${APP}/Contents/Resources/LICENSE.KeyKey.txt"
cp migration/data/manifest.json "${APP}/Contents/Resources/cangjie-manifest.json"
python3 - <<'PY'
import hashlib,json
from pathlib import Path
for family,license in [('Jigmo','CC0-1.0'),('CNS11643','OGDL-Taiwan-1.0')]:
    fonts=Path('assets/fonts')/family
    manifest=json.loads((fonts/'manifest.json').read_text())
    assert manifest['license']==license and manifest['modified'] is False
    for name,digest in manifest['files'].items():
        assert hashlib.sha256((fonts/name).read_bytes()).hexdigest()==digest, 'Font resource checksum mismatch: '+name
PY
mkdir -p "${APP}/Contents/Resources/Fonts"
ditto assets/fonts "${APP}/Contents/Resources/Fonts"
python3 - "${APP}/Contents/Info.plist" "${APP}/Contents/Resources/RuntimeBuild.json" "${OUTPUT_DIR}/CompiledRuntimeBuild.swift" <<'PY'
import json,plistlib,sys,uuid
version=plistlib.load(open(sys.argv[1],'rb'))['CFBundleShortVersionString']
identity={'version':version,'buildID':str(uuid.uuid4())}
with open(sys.argv[2],'w') as f: json.dump(identity,f);f.write('\n')
with open(sys.argv[3],'w') as f:
    f.write('enum CompiledRuntimeBuild { static let version = '+json.dumps(version)+'; static let buildID = '+json.dumps(identity['buildID'])+' }\n')
PY
maintenance_sources=(migration/preview/RuntimeDiagnostics.swift migration/preview/DiagnosticReport.swift migration/preview/DiagnosticsUI.swift migration/preview/RuntimeVersion.swift migration/preview/UpgradeActivation.swift migration/preview/InstallUI.swift migration/preview/InputSourceMaintenance.swift migration/preview/UninstallUI.swift)
sources=("${maintenance_sources[@]}" migration/preview/LegacySettings.swift migration/preview/PreviewSettings.swift migration/swift/EngineSession.swift migration/preview/CompositionSession.swift
         migration/preview/SystemCharacterCoverage.swift migration/preview/CandidateWindow.swift migration/preview/PreviewInputController.swift)
PREVIEW_ARCHS="${PREVIEW_ARCHS:-$(uname -m)}"
binaries=()
maintenance_binaries=()
for architecture in ${PREVIEW_ARCHS}; do
    case "${architecture}" in
        arm64) rust_target="aarch64-apple-darwin" ;;
        x86_64) rust_target="x86_64-apple-darwin" ;;
        *) echo "Unsupported Preview architecture: ${architecture}" >&2; exit 1 ;;
    esac
    library_dir="${CARGO_TARGET_DIR}/release"
    if [[ "${architecture}" != "$(uname -m)" ]]; then
        (cd migration/core && cargo build --release --locked --offline --target "${rust_target}")
        library_dir="${CARGO_TARGET_DIR}/${rust_target}/release"
    fi
    binary="${OUTPUT_DIR}/CangjieXPreview-${architecture}"
    xcrun swiftc -target "${architecture}-apple-macosx11.0" -swift-version 5 -O -warnings-as-errors \
    -module-name CangjieXPreview \
    -import-objc-header migration/preview/PreviewBridge.h \
    "${sources[@]}" "${OUTPUT_DIR}/CompiledRuntimeBuild.swift" migration/preview/main.swift \
    -framework AppKit -framework InputMethodKit -framework Carbon \
    -L "${library_dir}" -lcangjiex_core -lsqlite3 \
    -o "${binary}"
    binaries+=("${binary}")
    maintenance_binary="${OUTPUT_DIR}/CangjieXMaintenance-${architecture}"
    xcrun swiftc -target "${architecture}-apple-macosx11.0" -swift-version 5 -O -warnings-as-errors \
        -D MAINTENANCE_TOOL -parse-as-library "${maintenance_sources[@]}" \
        -framework AppKit -framework Carbon -framework CoreServices -o "${maintenance_binary}"
    maintenance_binaries+=("${maintenance_binary}")
done
xcrun lipo -create "${binaries[@]}" -output "${APP}/Contents/MacOS/CangjieXPreview"
xcrun lipo -create "${maintenance_binaries[@]}" -output "${APP}/Contents/MacOS/CangjieXMaintenance"
codesign --force --sign - --timestamp=none "${APP}/Contents/MacOS/CangjieXMaintenance"
plutil -lint "${APP}/Contents/Info.plist"
codesign --force --sign - --timestamp=none "${APP}"
codesign --verify --strict "${APP}"
echo "Built independent Preview: ${APP}"

if [[ "${1:-}" == --test ]]; then
    bash tools/check-migration-maintenance.sh
    xcrun swiftc -swift-version 5 -O -warnings-as-errors \
        -import-objc-header migration/preview/PreviewBridge.h \
        "${sources[@]}" migration/tests/PreviewTests.swift \
        -framework AppKit -framework InputMethodKit \
        -L "${CARGO_TARGET_DIR}/release" -lcangjiex_core -lsqlite3 \
        -o "${OUTPUT_DIR}/preview-tests"
    "${OUTPUT_DIR}/preview-tests"
fi

if [[ "${1:-}" == --test-host ]]; then
    TEST_APP="${OUTPUT_DIR}/CangjieX Preview Test.app"
    mkdir -p "${TEST_APP}/Contents/MacOS"
    /usr/bin/plutil -create xml1 "${TEST_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleIdentifier string io.github.geekstek.cangjiex.preview-test" "${TEST_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string CangjieXPreviewTest" "${TEST_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundleName string CangjieX Preview Test" "${TEST_APP}/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Add :CFBundlePackageType string APPL" "${TEST_APP}/Contents/Info.plist"
    xcrun swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
        migration/tests/PreviewTestHost.swift -framework AppKit -framework Carbon \
        -o "${TEST_APP}/Contents/MacOS/CangjieXPreviewTest"
    codesign --force --sign - --timestamp=none "${TEST_APP}"
    echo "Built manual test host: ${TEST_APP}"
fi
