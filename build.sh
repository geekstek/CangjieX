#!/usr/bin/env bash
set -euo pipefail
export COPYFILE_DISABLE=1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_NAME="CangjieX"
PRODUCT_DISPLAY_NAME="${PRODUCT_DISPLAY_NAME:-CangjieX}"
PRODUCT_CHINESE_NAME="${PRODUCT_CHINESE_NAME:-倉頡星}"
PRODUCT_SIMPLIFIED_NAME="${PRODUCT_SIMPLIFIED_NAME:-仓颉星}"
VERSION="${VERSION:-1.0.0}"
BRAND_ASSETS_DIR="${BRAND_ASSETS_DIR:-${SCRIPT_DIR}/assets/brand}"
PROJECT_URL="${PROJECT_URL:-https://github.com/geekstek/CangjieX}"
PROJECT_URL_LABEL="${PROJECT_URL_LABEL:-github.com/geekstek/CangjieX}"

if [[ ! "${VERSION}" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo "VERSION must use numeric x.y.z format, got: ${VERSION}" >&2
    exit 1
fi

APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.geekstek.inputmethod.CangjieX}"
COMPONENT_ID="${COMPONENT_ID:-io.github.geekstek.cangjiex.inputmethod}"
PREFERENCES_BUNDLE_ID="${PREFERENCES_BUNDLE_ID:-io.github.geekstek.cangjiex.preferences}"
PHRASE_EDITOR_BUNDLE_ID="${PHRASE_EDITOR_BUNDLE_ID:-io.github.geekstek.cangjiex.phraseeditor}"
INPUT_METHOD_CONNECTION_NAME="${INPUT_METHOD_CONNECTION_NAME:-}"

APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-${SIGN_IDENTITY:-}}"

BUILD_DIR="${BUILD_DIR:-build}"
STAGE_DIR="${BUILD_DIR}/stage"
SCRIPTS_STAGE_DIR="${BUILD_DIR}/scripts"
COMPONENT_PLIST="${BUILD_DIR}/components.plist"
COMPONENT_PKG="${BUILD_DIR}/${PRODUCT_NAME}Component.pkg"
OUTPUT_PKG="${BUILD_DIR}/${PRODUCT_NAME}.pkg"

SOURCE_APP="${SOURCE_APP:-root/Library/Input Methods/Yahoo! KeyKey.app}"
STAGED_INPUT_METHODS_DIR="${STAGE_DIR}/Library/Input Methods"
STAGED_APP="${STAGED_INPUT_METHODS_DIR}/${PRODUCT_NAME}.app"
STAGED_INFO_PLIST="${STAGED_APP}/Contents/Info.plist"

if [[ ! -d "${SOURCE_APP}" ]]; then
    echo "Missing source input method app: ${SOURCE_APP}" >&2
    exit 1
fi

prepare_build_dir() {
    if [[ -e "${BUILD_DIR}" ]]; then
        if ! rm -rf "${BUILD_DIR}" 2>/dev/null; then
            local stale_build_dir="/tmp/${PRODUCT_NAME}-stale-build-$(date +%Y%m%d%H%M%S)"

            echo "Unable to remove ${BUILD_DIR}; moving it to ${stale_build_dir}" >&2
            mv "${BUILD_DIR}" "${stale_build_dir}" || {
                echo "Unable to clear ${BUILD_DIR}. Please remove it manually." >&2
                exit 1
            }
        fi
    fi

    mkdir -p "${BUILD_DIR}"
}

prepare_build_dir

ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless Scripts "${SCRIPTS_STAGE_DIR}"
mkdir -p "${STAGED_INPUT_METHODS_DIR}"
ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless "${SOURCE_APP}" "${STAGED_APP}"
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

if [[ -n "${INPUT_METHOD_CONNECTION_NAME}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :InputMethodConnectionName ${INPUT_METHOD_CONNECTION_NAME}" "${STAGED_INFO_PLIST}"
fi

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

set_localized_bundle_name "${STAGED_APP}/Contents/Resources/English.lproj/InfoPlist.strings" "${PRODUCT_CHINESE_NAME}"
set_localized_bundle_name "${STAGED_APP}/Contents/Resources/zh_TW.lproj/InfoPlist.strings" "${PRODUCT_CHINESE_NAME}"
set_localized_bundle_name "${STAGED_APP}/Contents/Resources/zh_CN.lproj/InfoPlist.strings" "${PRODUCT_CHINESE_NAME}"

plist_key_path() {
    local key="$1"

    key="${key//\\/\\\\}"
    key="${key//\"/\\\"}"
    printf ':"%s"' "${key}"
}

set_strings_value() {
    local strings_file="$1"
    local key="$2"
    local value="$3"
    local key_path

    if [[ ! -f "${strings_file}" ]]; then
        return
    fi

    key_path="$(plist_key_path "${key}")"

    if /usr/libexec/PlistBuddy -c "Print ${key_path}" "${strings_file}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set ${key_path} ${value}" "${strings_file}"
    else
        /usr/libexec/PlistBuddy -c "Add ${key_path} string ${value}" "${strings_file}"
    fi
}

set_info_plist_string() {
    local plist_file="$1"
    local key="$2"
    local value="$3"

    if [[ ! -f "${plist_file}" ]]; then
        return
    fi

    if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist_file}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist_file}"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist_file}"
    fi
}

brand_helper_app() {
    local app_dir="$1"
    local bundle_id="$2"
    local english_name="$3"
    local traditional_name="$4"
    local simplified_name="$5"
    local copyright_text="CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla."

    set_info_plist_string "${app_dir}/Contents/Info.plist" "CFBundleIdentifier" "${bundle_id}"
    set_info_plist_string "${app_dir}/Contents/Info.plist" "CFBundleName" "${english_name}"
    set_info_plist_string "${app_dir}/Contents/Info.plist" "CFBundleDisplayName" "${english_name}"
    set_info_plist_string "${app_dir}/Contents/Info.plist" "CFBundleVersion" "${VERSION}"
    set_info_plist_string "${app_dir}/Contents/Info.plist" "CFBundleShortVersionString" "${VERSION}"
    set_info_plist_string "${app_dir}/Contents/Info.plist" "NSHumanReadableCopyright" "${copyright_text}"

    set_strings_value "${app_dir}/Contents/Resources/English.lproj/InfoPlist.strings" "CFBundleName" "${english_name}"
    set_strings_value "${app_dir}/Contents/Resources/English.lproj/InfoPlist.strings" "CFBundleDisplayName" "${english_name}"
    set_strings_value "${app_dir}/Contents/Resources/English.lproj/InfoPlist.strings" "NSHumanReadableCopyright" "${copyright_text}"

    set_strings_value "${app_dir}/Contents/Resources/zh_TW.lproj/InfoPlist.strings" "CFBundleName" "${traditional_name}"
    set_strings_value "${app_dir}/Contents/Resources/zh_TW.lproj/InfoPlist.strings" "CFBundleDisplayName" "${traditional_name}"
    set_strings_value "${app_dir}/Contents/Resources/zh_TW.lproj/InfoPlist.strings" "NSHumanReadableCopyright" "${copyright_text}"

    set_strings_value "${app_dir}/Contents/Resources/zh_CN.lproj/InfoPlist.strings" "CFBundleName" "${simplified_name}"
    set_strings_value "${app_dir}/Contents/Resources/zh_CN.lproj/InfoPlist.strings" "CFBundleDisplayName" "${simplified_name}"
    set_strings_value "${app_dir}/Contents/Resources/zh_CN.lproj/InfoPlist.strings" "NSHumanReadableCopyright" "${copyright_text}"
}

brand_visible_strings() {
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "Cangjie" \
        "倉頡"
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "Simplex" \
        "簡易"
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "Symbols" \
        "符號表"
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "Preferences..." \
        "偏好設定..."
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "About Yahoo! KeyKey" \
        "關於${PRODUCT_CHINESE_NAME}"
    set_strings_value "${STAGED_APP}/Contents/Resources/English.lproj/Localizable.strings" \
        "<p class=\"credit\">2008-2010 Yahoo! Taiwan All Rights Reserved.</p>" \
        "<p>CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla.</p>"
    set_strings_value "${STAGED_APP}/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "About Yahoo! KeyKey" \
        "關於${PRODUCT_CHINESE_NAME}"
    set_strings_value "${STAGED_APP}/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "<p class=\"credit\">2008-2010 Yahoo! Taiwan All Rights Reserved.</p>" \
        "<p>CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla.</p>"
    set_strings_value "${STAGED_APP}/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "About Yahoo! KeyKey" \
        "关于${PRODUCT_SIMPLIFIED_NAME}"
    set_strings_value "${STAGED_APP}/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "<p class=\"credit\">2008-2010 Yahoo! Taiwan All Rights Reserved.</p>" \
        "<p>CangjieX contributors. Based on Yahoo! KeyKey and OpenVanilla.</p>"

    brand_helper_app \
        "${STAGED_APP}/Contents/SharedSupport/Preferences.app" \
        "${PREFERENCES_BUNDLE_ID}" \
        "${PRODUCT_CHINESE_NAME}偏好設定" \
        "${PRODUCT_CHINESE_NAME}偏好設定" \
        "${PRODUCT_CHINESE_NAME}偏好設定"
    brand_helper_app \
        "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app" \
        "${PHRASE_EDITOR_BUNDLE_ID}" \
        "${PRODUCT_CHINESE_NAME}詞彙編輯程式" \
        "${PRODUCT_CHINESE_NAME}詞彙編輯程式" \
        "${PRODUCT_CHINESE_NAME}詞彙編輯程式"

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings" \
        "Yahoo! KeyKey is not running." \
        "${PRODUCT_DISPLAY_NAME} is not running."
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings" \
        "Since Yahoo! KeyKey is not running, you cannot use the Phrase Editor to alter your phrases." \
        "Since ${PRODUCT_DISPLAY_NAME} is not running, you cannot use the Phrase Editor to edit your phrases."
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "If ${PRODUCT_DISPLAY_NAME} is not running, you cannot export your database."
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to import your database." \
        "If ${PRODUCT_DISPLAY_NAME} is not running, you cannot import your database."

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "Yahoo! KeyKey is not running." \
        "${PRODUCT_CHINESE_NAME}並不在執行中"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "Since Yahoo! KeyKey is not running, you cannot use the Phrase Editor to alter your phrases." \
        "因為您沒有執行${PRODUCT_CHINESE_NAME}，因此無法使用詞彙編輯程式。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "如果${PRODUCT_CHINESE_NAME}不在使用中，您便無法匯出自訂詞資料庫。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to import your database." \
        "如果${PRODUCT_CHINESE_NAME}不在使用中，您便無法匯入自訂詞資料庫。"

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "Yahoo! KeyKey is not running." \
        "${PRODUCT_SIMPLIFIED_NAME}并不在执行中"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "Since Yahoo! KeyKey is not running, you cannot use the Phrase Editor to alter your phrases." \
        "因为您没有执行${PRODUCT_SIMPLIFIED_NAME}，因此无法使用词汇编辑工具。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "如果${PRODUCT_SIMPLIFIED_NAME}不在使用中，您便无法导出自订词数据库。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to import your database." \
        "如果${PRODUCT_SIMPLIFIED_NAME}不在使用中，您便无法导入自订词数据库。"

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/English.lproj/Localizable.strings" \
        "If you are nor running Yahoo! KeyKey, you are not able to check for update." \
        "If ${PRODUCT_DISPLAY_NAME} is not running, you cannot check for updates."
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/English.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "If ${PRODUCT_DISPLAY_NAME} is not running, you cannot export your database."
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/English.lproj/Localizable.strings" \
        "Yahoo! KeyKey user phrases database was not found on your iDisk." \
        "${PRODUCT_DISPLAY_NAME} user phrases database was not found on your iDisk."

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "If you are nor running Yahoo! KeyKey, you are not able to check for update." \
        "如果${PRODUCT_CHINESE_NAME}不在執行中，便無法執行更新檢查功能。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "如果${PRODUCT_CHINESE_NAME}不在使用中，您便無法匯出自訂詞資料庫。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to import your database." \
        "如果${PRODUCT_CHINESE_NAME}不在使用中，您便無法匯入自訂詞資料庫。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_TW.lproj/Localizable.strings" \
        "Yahoo! KeyKey user phrases database was not found on your iDisk." \
        "在您的 iDisk 上找不到${PRODUCT_CHINESE_NAME}的自訂詞資料庫備份。"

    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "If you are nor running Yahoo! KeyKey, you are not able to check for update." \
        "如果${PRODUCT_SIMPLIFIED_NAME}不在执行中，便无法执行更新检查功能。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to export your database." \
        "如果${PRODUCT_SIMPLIFIED_NAME}不在使用中，您便无法导出自订词数据库。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "If you are not runnung Yahoo! KeyKey, you are not able to import your database." \
        "如果${PRODUCT_SIMPLIFIED_NAME}不在使用中，您便无法导入自订词数据库。"
    set_strings_value "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources/zh_CN.lproj/Localizable.strings" \
        "Yahoo! KeyKey user phrases database was not found on your iDisk." \
        "在您的 iDisk 上找不到${PRODUCT_SIMPLIFIED_NAME}的自订词数据库备份。"
}

force_traditional_localizations() {
    local resources_dir="$1"
    local source_lproj="${resources_dir}/zh_TW.lproj"
    local target_lproj

    if [[ ! -d "${source_lproj}" ]]; then
        return
    fi

    for target_lproj in English.lproj zh_CN.lproj; do
        rm -rf "${resources_dir}/${target_lproj}"
        ditto --norsrc --noextattr --noqtn --noacl --nopersistRootless \
            "${source_lproj}" \
            "${resources_dir}/${target_lproj}"
    done
}

force_all_traditional_localizations() {
    force_traditional_localizations "${STAGED_APP}/Contents/Resources"
    force_traditional_localizations "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/Resources"
    force_traditional_localizations "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app/Contents/Resources"
}

set_about_window_nib_strings() {
    local nib_dir="$1"
    local title="$2"
    local contributors="$3"
    local tagline="$4"
    local nib_file="${nib_dir}/keyedobjects.nib"

    if [[ ! -f "${nib_file}" ]]; then
        return
    fi

    plutil -lint "${nib_file}" >/dev/null
    /usr/libexec/PlistBuddy -c "Set :\$objects:13 ${contributors}" "${nib_file}"
    /usr/libexec/PlistBuddy -c "Set :\$objects:35 ${title}" "${nib_file}"
    /usr/libexec/PlistBuddy -c "Set :\$objects:63 ${tagline}" "${nib_file}"
    /usr/libexec/PlistBuddy -c "Set :\$objects:67 ${PROJECT_URL_LABEL}" "${nib_file}"
    plutil -convert binary1 "${nib_file}"
}

brand_about_window_nibs() {
    set_about_window_nib_strings \
        "${STAGED_APP}/Contents/Resources/English.lproj/AboutWindow.nib" \
        "關於${PRODUCT_CHINESE_NAME}" \
        "${PRODUCT_DISPLAY_NAME} contributors" \
        "Open Cangjie for macOS"
    set_about_window_nib_strings \
        "${STAGED_APP}/Contents/Resources/zh_TW.lproj/AboutWindow.nib" \
        "關於${PRODUCT_CHINESE_NAME}" \
        "${PRODUCT_DISPLAY_NAME} contributors" \
        "為現代 macOS 而生的開源倉頡輸入法"
    set_about_window_nib_strings \
        "${STAGED_APP}/Contents/Resources/zh_CN.lproj/AboutWindow.nib" \
        "關於${PRODUCT_CHINESE_NAME}" \
        "${PRODUCT_DISPLAY_NAME} contributors" \
        "為現代 macOS 而生的開源倉頡輸入法"
}

brand_visible_strings
force_all_traditional_localizations
brand_about_window_nibs

BRAND_ASSETS_DIR="${BRAND_ASSETS_DIR}" "${SCRIPT_DIR}/tools/install-brand-assets.sh" "${STAGED_APP}"

add_rpath_if_needed() {
    local executable_path="$1"
    local runtime_path="$2"

    if [[ ! -f "${executable_path}" ]]; then
        return
    fi

    if otool -l "${executable_path}" | grep -Fq "${runtime_path}"; then
        return
    fi

    install_name_tool -add_rpath "${runtime_path}" "${executable_path}"
}

fix_helper_app_runtime_paths() {
    add_rpath_if_needed \
        "${STAGED_APP}/Contents/SharedSupport/Preferences.app/Contents/MacOS/Preferences" \
        "@executable_path/../Frameworks"
}

fix_helper_app_runtime_paths

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

scrub_component_package_metadata() {
    local component_pkg="$1"
    local payload_root="$2"
    local tmp_dir
    local expanded_dir
    local bom_list
    local cpio_log

    tmp_dir="$(mktemp -d)"
    expanded_dir="${tmp_dir}/component"
    bom_list="${tmp_dir}/bom.txt"
    cpio_log="${tmp_dir}/payload-cpio.log"

    pkgutil --expand "${component_pkg}" "${expanded_dir}"

    lsbom "${expanded_dir}/Bom" | ruby -ne 'print unless $_ =~ %r{(^|/)\._}' >"${bom_list}"
    mkbom -i "${bom_list}" "${expanded_dir}/Bom"

    if [[ -d "${expanded_dir}/Scripts" ]]; then
        rm -f "${expanded_dir}/Scripts"/._*
    fi

    if ! (
        cd "${payload_root}"
        find . ! -name "._*" -print | cpio -o -H odc -R root:wheel 2>"${cpio_log}" | gzip -c >"${expanded_dir}/Payload"
    ); then
        echo "Unable to rebuild package payload without AppleDouble metadata." >&2
        cat "${cpio_log}" >&2
        rm -rf "${tmp_dir}"
        exit 1
    fi

    rm -f "${component_pkg}"
    pkgutil --flatten "${expanded_dir}" "${component_pkg}" >/dev/null
    rm -rf "${tmp_dir}"
}

find "${STAGE_DIR}" -name ".DS_Store" -delete
find "${STAGE_DIR}" -name "._*" -delete
xattr -cr "${STAGE_DIR}" >/dev/null 2>&1 || true

codesign_bundle() {
    local bundle_path="$1"

    if [[ ! -e "${bundle_path}" ]]; then
        return
    fi

    if [[ -n "${APP_SIGN_IDENTITY}" ]]; then
        codesign --force --deep --timestamp --options runtime --sign "${APP_SIGN_IDENTITY}" "${bundle_path}"
    else
        codesign --force --deep --timestamp=none --sign - "${bundle_path}"
    fi
}

codesign_bundle "${STAGED_APP}/Contents/SharedSupport/Preferences.app"
codesign_bundle "${STAGED_APP}/Contents/SharedSupport/PhraseEditor.app"
codesign_bundle "${STAGED_APP}"

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

scrub_component_package_metadata "${COMPONENT_PKG}" "${STAGE_DIR}"

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
