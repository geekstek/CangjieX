#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="CangjieX"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.geekstek.inputmethod.CangjieX}"
COMPONENT_ID="${COMPONENT_ID:-io.github.geekstek.cangjiex.inputmethod}"
PKG_PATH="${1:-build/${PRODUCT_NAME}.pkg}"
BUILD_DIR="$(dirname "${PKG_PATH}")"
COMPONENT_PKG="${BUILD_DIR}/${PRODUCT_NAME}Component.pkg"

fail() {
    echo "verify-pkg: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

[[ -f "${PKG_PATH}" ]] || fail "missing package: ${PKG_PATH}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if [[ ! -f "${COMPONENT_PKG}" ]]; then
    product_dir="${tmp_dir}/product"
    pkgutil --expand "${PKG_PATH}" "${product_dir}"
    COMPONENT_PKG="${product_dir}/${PRODUCT_NAME}Component.pkg"
fi

[[ -f "${COMPONENT_PKG}" ]] || fail "missing component package: ${COMPONENT_PKG}"

component_dir="${tmp_dir}/component"
pkgutil --expand "${COMPONENT_PKG}" "${component_dir}"
package_info="${component_dir}/PackageInfo"

grep -q "identifier=\"${COMPONENT_ID}\"" "${package_info}" \
    || fail "component identifier is not ${COMPONENT_ID}"
grep -q 'relocatable="false"' "${package_info}" \
    || fail "component package is relocatable; it may install outside /Library/Input Methods"
grep -q 'install-location="/"' "${package_info}" \
    || fail "component install location is not /"
grep -q "path=\"./Library/Input Methods/${PRODUCT_NAME}.app\"" "${package_info}" \
    || fail "CangjieX.app is not declared in the component package"
pass "component package metadata"

payload_files="${tmp_dir}/payload-files.txt"
pkgutil --payload-files "${COMPONENT_PKG}" >"${payload_files}"

grep -q "./Library/Input Methods/${PRODUCT_NAME}.app/Contents/Info.plist" "${payload_files}" \
    || fail "payload does not include CangjieX.app Info.plist"
grep -q "./Library/Input Methods/${PRODUCT_NAME}.app/Contents/MacOS/Yahoo! KeyKey" "${payload_files}" \
    || fail "payload does not include the input method executable"

if grep -q 'DownloadUpdate.app\|InstallerHelp.app' "${payload_files}"; then
    fail "payload still contains legacy Yahoo helper apps"
fi
pass "payload contents"

apple_double_count="$(grep -c '/\._' "${payload_files}" || true)"
if [[ "${apple_double_count}" != "0" ]]; then
    echo "warning: payload contains ${apple_double_count} AppleDouble metadata records from macOS provenance attributes"
fi

stage_info_plist="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Info.plist"
if [[ -f "${stage_info_plist}" ]]; then
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${stage_info_plist}")"
    actual_bundle_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${stage_info_plist}")"
    actual_input_source_id="$(/usr/libexec/PlistBuddy -c "Print :TISInputSourceID" "${stage_info_plist}")"

    [[ "${actual_bundle_id}" == "${APP_BUNDLE_ID}" ]] \
        || fail "bundle id is ${actual_bundle_id}, expected ${APP_BUNDLE_ID}"
    [[ "${actual_bundle_name}" == "${PRODUCT_NAME}" ]] \
        || fail "bundle name is ${actual_bundle_name}, expected ${PRODUCT_NAME}"
    [[ "${actual_input_source_id}" == "${APP_BUNDLE_ID}" ]] \
        || fail "input source id is ${actual_input_source_id}, expected ${APP_BUNDLE_ID}"
    pass "app Info.plist"
else
    echo "warning: ${stage_info_plist} is missing; skipping app Info.plist verification"
fi

choices_plist="${tmp_dir}/choices.plist"
installer -pkg "${PKG_PATH}" -target / -showChoicesXML >"${choices_plist}"
grep -q "<string>${PRODUCT_NAME}</string>" "${choices_plist}" \
    || fail "installer choices do not contain ${PRODUCT_NAME}"
grep -q "<string>${COMPONENT_ID}</string>" "${choices_plist}" \
    || fail "installer choices do not contain ${COMPONENT_ID}"
pass "installer choices"

if pkgutil --check-signature "${PKG_PATH}" >/dev/null 2>&1; then
    pass "package signature"
elif [[ "${REQUIRE_SIGNATURE:-0}" == "1" ]]; then
    fail "package is unsigned"
else
    echo "warning: package is unsigned"
fi

echo "verify-pkg: ${PKG_PATH} passed"
