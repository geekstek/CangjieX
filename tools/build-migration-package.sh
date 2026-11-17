#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${PROJECT_DIR}"
export PREVIEW_ARCHS="${PREVIEW_ARCHS:-arm64 x86_64}"
bash tools/build-migration-preview.sh
APP="${PROJECT_DIR}/build/migration/preview/CangjieXPreview.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "${APP}/Contents/Info.plist")"
[[ "${VERSION}" =~ ^2\.[0-9]+\.[0-9]+$ ]] || { echo "Expected a 2.x.y Swift/Rust version." >&2; exit 1; }
[[ -z "${EXPECTED_VERSION:-}" || "${EXPECTED_VERSION}" == "${VERSION}" ]] || { echo "Tag and app version differ." >&2; exit 1; }
xcrun lipo "${APP}/Contents/MacOS/CangjieXPreview" -verify_arch arm64 x86_64
codesign --verify --strict "${APP}"
OUTPUT="${PROJECT_DIR}/build/migration/release"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/cangjiex-package.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
mkdir -p "${OUTPUT}" "${WORK}/root/Library/Input Methods"
ditto "${APP}" "${WORK}/root/Library/Input Methods/CangjieXPreview.app"
pkgbuild --analyze --root "${WORK}/root" "${WORK}/components.plist"
python3 - "${WORK}/components.plist" <<'PY'
import plistlib,sys
path=sys.argv[1]
with open(path,'rb') as f: components=plistlib.load(f)
assert len(components)==1
item=components[0]
assert item['RootRelativeBundlePath']=='Library/Input Methods/CangjieXPreview.app'
item.update(BundleIsRelocatable=False,BundleHasStrictIdentifier=True,BundleIsVersionChecked=True,BundleOverwriteAction='upgrade')
with open(path,'wb') as f: plistlib.dump(components,f)
PY
COMPONENT="io.github.geekstek.cangjiex.preview.pkg"
pkgbuild --root "${WORK}/root" --component-plist "${WORK}/components.plist" \
    --identifier "${COMPONENT}" --version "${VERSION}" --install-location / \
    "${WORK}/CangjieXPreview.pkg"
cat > "${WORK}/Distribution.xml" <<XML
<?xml version="1.0" encoding="UTF-8"?>
<installer-gui-script minSpecVersion="2">
  <title>倉頡星 CangjieX ${VERSION}</title>
  <options customize="never" require-scripts="false"/>
  <domains enable_anywhere="false" enable_currentUserHome="true" enable_localSystem="false"/>
  <volume-check script="true"><allowed-os-versions><os-version min="11.0"/></allowed-os-versions></volume-check>
  <readme file="README.html" mime-type="text/html"/>
  <conclusion file="CONCLUSION.html" mime-type="text/html"/>
  <choices-outline><line choice="preview"/></choices-outline>
  <choice id="preview" title="倉頡星" description="安裝倉頡星 ${VERSION}，保留舊版">
    <pkg-ref id="${COMPONENT}"/>
  </choice>
  <pkg-ref id="${COMPONENT}" version="${VERSION}">CangjieXPreview.pkg</pkg-ref>
</installer-gui-script>
XML
PACKAGE="CangjieX-${VERSION}-universal.pkg"
productbuild --distribution "${WORK}/Distribution.xml" --package-path "${WORK}" \
    --resources migration/release "${OUTPUT}/${PACKAGE}"
# Verify actual archived contents, including home-only domain and exact destination.
pkgutil --expand-full "${OUTPUT}/${PACKAGE}" "${WORK}/expanded"
python3 tools/verify-migration-package.py "${WORK}/expanded" "${APP}" "${VERSION}"
python3 - "${OUTPUT}/build-info.json" "${VERSION}" <<'PY'
import json,subprocess,sys
info={'version':sys.argv[2],'display_name':'倉頡星','source_commit':subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip(),
      'source_dirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()),
      'architectures':['arm64','x86_64'],'minimum_macos':'11.0',
      'bundle_identifier':'io.github.geekstek.inputmethod.CangjieXPreview',
      'install_location':'~/Library/Input Methods/CangjieXPreview.app',
      'developer_id_signed':False,'notarized':False,'legacy_app_replaced':False}
with open(sys.argv[1],'w') as f: json.dump(info,f,ensure_ascii=False,indent=2);f.write('\n')
PY
(cd "${OUTPUT}" && shasum -a 256 "${PACKAGE}" > "${PACKAGE}.sha256" && shasum -a 256 -c "${PACKAGE}.sha256")
echo "Verified per-user universal installer: ${OUTPUT}/${PACKAGE}"
