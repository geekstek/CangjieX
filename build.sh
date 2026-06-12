#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

PRODUCT_NAME="CangjieX"
PRODUCT_DISPLAY_NAME="${PRODUCT_DISPLAY_NAME:-CangjieX}"
PRODUCT_CHINESE_NAME="${PRODUCT_CHINESE_NAME:-倉頡星}"
PRODUCT_SIMPLIFIED_NAME="${PRODUCT_SIMPLIFIED_NAME:-仓颉星}"
VERSION="${VERSION:-1.0.0}"

APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.geekstek.inputmethod.CangjieX}"
COMPONENT_ID="${COMPONENT_ID:-io.github.geekstek.cangjiex.inputmethod}"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}"

BUILD_DIR="${BUILD_DIR:-build}"
STAGE_DIR="${BUILD_DIR}/stage"
SCRIPTS_STAGE_DIR="${BUILD_DIR}/scripts"
COMPONENT_PLIST="${BUILD_DIR}/components.plist"
COMPONENT_PKG="${BUILD_DIR}/${PRODUCT_NAME}Component.pkg"
OUTPUT_PKG="${BUILD_DIR}/${PRODUCT_NAME}.pkg"

SOURCE_APP="root/Library/Input Methods/Yahoo! KeyKey.app"
STAGED_INPUT_METHODS_DIR="${STAGE_DIR}/Library/Input Methods"
STAGED_APP="${STAGED_INPUT_METHODS_DIR}/${PRODUCT_NAME}.app"
STAGED_INFO_PLIST="${STAGED_APP}/Contents/Info.plist"

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "Missing source input method app: ${SOURCE_APP}" >&2
    exit 1
fi

rm -rf "${BUILD_DIR}"
mkdir -p "${BUILD_DIR}"

ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless root "${STAGE_DIR}"
ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless Scripts "${SCRIPTS_STAGE_DIR}"
mv "${STAGED_INPUT_METHODS_DIR}/Yahoo! KeyKey.app" "${STAGED_APP}"
rm -rf \
    "${STAGED_APP}/Contents/SharedSupport/DownloadUpdate.app" \
    "${STAGED_APP}/Contents/SharedSupport/InstallerHelp.app"

/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier ${APP_BUNDLE_ID}" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleName ${PRODUCT_DISPLAY_NAME}" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${VERSION}" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :TISInputSourceID ${APP_BUNDLE_ID}" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLName ${PRODUCT_DISPLAY_NAME}" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 cangjiex" "${STAGED_INFO_PLIST}"
/usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla." "${STAGED_INFO_PLIST}"

if /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${STAGED_INFO_PLIST}" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION}" "${STAGED_INFO_PLIST}"
else
    /usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string ${VERSION}" "${STAGED_INFO_PLIST}"
fi

set_localized_bundle_name() {
    local strings_file="$1"
    local localized_name="$2"
    local copyright_text="CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla."

    if [[ -f "${strings_file}" ]]; then
        /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName ${localized_name}" "${strings_file}"
        /usr/libexec/PlistBuddy -c "Set :CFBundleName ${localized_name}" "${strings_file}"
        /usr/libexec/PlistBuddy -c "Set :NSHumanReadableCopyright ${copyright_text}" "${strings_file}"
        /usr/libexec/PlistBuddy -c "Delete :com.yahoo.inputmethod.KeyKey" "${strings_file}" >/dev/null 2>&1 || true

        if /usr/libexec/PlistBuddy -c "Print :${APP_BUNDLE_ID}" "${strings_file}" >/dev/null 2>&1; then
            /usr/libexec/PlistBuddy -c "Set :${APP_BUNDLE_ID} ${localized_name}" "${strings_file}"
        else
            /usr/libexec/PlistBuddy -c "Add :${APP_BUNDLE_ID} string ${localized_name}" "${strings_file}"
        fi
    fi
}

set_localized_bundle_name "${STAGED_APP}/Contents/Resources/English.lproj/InfoPlist.strings" "${PRODUCT_DISPLAY_NAME}"
set_localized_bundle_name "${STAGED_APP}/Contents/Resources/zh_TW.lproj/InfoPlist.strings" "${PRODUCT_CHINESE_NAME}"
set_localized_bundle_name "${STAGED_APP}/Contents/Resources/zh_CN.lproj/InfoPlist.strings" "${PRODUCT_SIMPLIFIED_NAME}"

set_bool_key() {
    local plist_file="$1"
    local key_path="$2"

    if /usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist_file}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set ${key_path} false" "${plist_file}"
    else
        /usr/libexec/PlistBuddy -c "Add ${key_path} bool false" "${plist_file}"
    fi
}

lock_component_install_path() {
    local plist_file="$1"
    local root_relative_bundle_path="Library/Input Methods/${PRODUCT_NAME}.app"
    local index=0
    local bundle_path
    local matched_index=""

    while bundle_path=$(/usr/libexec/PlistBuddy -c "Print :${index}:RootRelativeBundlePath" "${plist_file}" 2>/dev/null); do
        if [[ "${bundle_path}" == "${root_relative_bundle_path}" ]]; then
            matched_index="${index}"
            break
        fi

        index=$((index + 1))
    done

    if [[ -z "${matched_index}" ]]; then
        echo "Unable to find ${root_relative_bundle_path} in ${plist_file}" >&2
        exit 1
    fi

    set_bool_key "${plist_file}" ":${matched_index}:BundleIsRelocatable"
    set_bool_key "${plist_file}" ":${matched_index}:BundleIsVersionChecked"
    set_bool_key "${plist_file}" ":${matched_index}:BundleHasStrictIdentifier"
}

find "${STAGE_DIR}" -name ".DS_Store" -delete
find "${STAGE_DIR}" -name "._*" -delete
xattr -cr "${STAGE_DIR}" >/dev/null 2>&1 || true

if [[ -n "${APP_SIGN_IDENTITY}" ]]; then
    codesign --force --deep --timestamp --options runtime --sign "${APP_SIGN_IDENTITY}" "${STAGED_APP}"
fi

pkgbuild --analyze --root "${STAGE_DIR}" "${COMPONENT_PLIST}" >/dev/null
lock_component_install_path "${COMPONENT_PLIST}"

pkgbuild \
    --root "${STAGE_DIR}" \
    --component-plist "${COMPONENT_PLIST}" \
    --identifier "${COMPONENT_ID}" \
    --version "${VERSION}" \
    --scripts "${SCRIPTS_STAGE_DIR}" \
    --install-location / \
    --ownership recommended \
    "${COMPONENT_PKG}"

productbuild_args=(
    --product requirement.plist
    --distribution distribution.plist
    --resources Resources
    --package-path "${BUILD_DIR}"
)

if [[ -n "${INSTALLER_SIGN_IDENTITY}" ]]; then
    productbuild_args+=(--sign "${INSTALLER_SIGN_IDENTITY}")
fi

productbuild "${productbuild_args[@]}" "${OUTPUT_PKG}"

echo "Built ${OUTPUT_PKG}"
