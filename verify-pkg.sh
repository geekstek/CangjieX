#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRODUCT_NAME="CangjieX"
APP_BUNDLE_ID="${APP_BUNDLE_ID:-io.github.geekstek.inputmethod.CangjieX}"
COMPONENT_ID="${COMPONENT_ID:-io.github.geekstek.cangjiex.inputmethod}"
PREFERENCES_BUNDLE_ID="${PREFERENCES_BUNDLE_ID:-io.github.geekstek.cangjiex.preferences}"
PHRASE_EDITOR_BUNDLE_ID="${PHRASE_EDITOR_BUNDLE_ID:-io.github.geekstek.cangjiex.phraseeditor}"
PKG_PATH="${1:-build/${PRODUCT_NAME}.pkg}"
BUILD_DIR="$(dirname "${PKG_PATH}")"
COMPONENT_PKG="${BUILD_DIR}/${PRODUCT_NAME}Component.pkg"
PROJECT_URL="${PROJECT_URL:-https://github.com/geekstek/CangjieX}"
PROJECT_URL_LABEL="${PROJECT_URL_LABEL:-github.com/geekstek/CangjieX}"

fail() {
    echo "verify-pkg: $*" >&2
    exit 1
}

pass() {
    echo "ok: $*"
}

binary_contains_text() {
    local file="$1"
    local text="$2"

    ruby -e '
        file = ARGV.fetch(0)
        text = ARGV.fetch(1).dup.force_encoding("UTF-8")
        data = File.binread(file)
        variants = [
          text.b,
          text.encode("UTF-16LE").b,
          text.encode("UTF-16BE").b,
        ]

        exit(variants.any? { |variant| data.include?(variant) } ? 0 : 1)
    ' "${file}" "${text}"
}

version_lte() {
    local actual="$1"
    local maximum="$2"
    local actual_parts=()
    local maximum_parts=()
    local width=0
    local actual_part
    local maximum_part
    local i

    IFS="." read -r -a actual_parts <<<"${actual}"
    IFS="." read -r -a maximum_parts <<<"${maximum}"

    if [[ "${#actual_parts[@]}" -gt "${#maximum_parts[@]}" ]]; then
        width="${#actual_parts[@]}"
    else
        width="${#maximum_parts[@]}"
    fi

    for ((i = 0; i < width; i++)); do
        actual_part="${actual_parts[i]:-0}"
        maximum_part="${maximum_parts[i]:-0}"

        if ((10#${actual_part} < 10#${maximum_part})); then
            return 0
        fi

        if ((10#${actual_part} > 10#${maximum_part})); then
            return 1
        fi
    done

    return 0
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

if grep -Eq '/(Yahoo|Yahoo16|Yahoo32|PhraseEditor)[.]icns$' "${payload_files}"; then
    fail "payload still contains legacy icon files"
fi

pass "payload contents"

apple_double_count="$(grep -c '/\._' "${payload_files}" || true)"
[[ "${apple_double_count}" == "0" ]] \
    || fail "payload contains ${apple_double_count} AppleDouble metadata records"

script_apple_double_count="$(find "${component_dir}/Scripts" -name '._*' -print 2>/dev/null | wc -l | tr -d '[:space:]')"
[[ "${script_apple_double_count}" == "0" ]] \
    || fail "scripts contain ${script_apple_double_count} AppleDouble metadata records"

if lsbom "${component_dir}/Bom" | grep -Eq '(^|/)\._'; then
    fail "bill of materials contains AppleDouble metadata records"
fi

stage_info_plist="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Info.plist"
if [[ -f "${stage_info_plist}" ]]; then
    actual_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${stage_info_plist}")"
    actual_bundle_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${stage_info_plist}")"
    actual_bundle_icon="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIconFile" "${stage_info_plist}")"
    actual_input_source_id="$(/usr/libexec/PlistBuddy -c "Print :TISInputSourceID" "${stage_info_plist}")"
    actual_input_icon="$(/usr/libexec/PlistBuddy -c "Print :tsInputMethodIconFileKey" "${stage_info_plist}")"

    [[ "${actual_bundle_id}" == "${APP_BUNDLE_ID}" ]] \
        || fail "bundle id is ${actual_bundle_id}, expected ${APP_BUNDLE_ID}"
    [[ "${actual_bundle_name}" == "${PRODUCT_NAME}" ]] \
        || fail "bundle name is ${actual_bundle_name}, expected ${PRODUCT_NAME}"
    [[ "${actual_bundle_icon}" == "CangjieX" ]] \
        || fail "bundle icon is ${actual_bundle_icon}, expected CangjieX"
    [[ "${actual_input_source_id}" == "${APP_BUNDLE_ID}" ]] \
        || fail "input source id is ${actual_input_source_id}, expected ${APP_BUNDLE_ID}"
    [[ "${actual_input_icon}" == "CangjieXMenu.icns" ]] \
        || fail "input method icon is ${actual_input_icon}, expected CangjieXMenu.icns"

    if [[ -n "${EXPECTED_VERSION:-}" ]]; then
        actual_bundle_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "${stage_info_plist}")"
        actual_short_version="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "${stage_info_plist}")"

        [[ "${actual_bundle_version}" == "${EXPECTED_VERSION}" ]] \
            || fail "bundle version is ${actual_bundle_version}, expected ${EXPECTED_VERSION}"
        [[ "${actual_short_version}" == "${EXPECTED_VERSION}" ]] \
            || fail "short version is ${actual_short_version}, expected ${EXPECTED_VERSION}"

        grep -q "version=\"${EXPECTED_VERSION}\"" "${package_info}" \
            || fail "component package version is not ${EXPECTED_VERSION}"
        pass "version (${EXPECTED_VERSION})"
    fi

    if [[ -n "${EXPECTED_INPUT_METHOD_CONNECTION_NAME:-}" ]]; then
        actual_connection_name="$(/usr/libexec/PlistBuddy -c "Print :InputMethodConnectionName" "${stage_info_plist}")"

        [[ "${actual_connection_name}" == "${EXPECTED_INPUT_METHOD_CONNECTION_NAME}" ]] \
            || fail "input method connection name is ${actual_connection_name}, expected ${EXPECTED_INPUT_METHOD_CONNECTION_NAME}"
    fi

    pass "app Info.plist"

    if [[ -n "${MAX_LS_MIN_SYSTEM_VERSION:-}" ]]; then
        actual_min_system_version="$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" "${stage_info_plist}")"

        version_lte "${actual_min_system_version}" "${MAX_LS_MIN_SYSTEM_VERSION}" \
            || fail "minimum system version is ${actual_min_system_version}, expected <= ${MAX_LS_MIN_SYSTEM_VERSION}"
        pass "minimum system version"
    fi

    executable_path="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/MacOS/Yahoo! KeyKey"
    if [[ -f "${executable_path}" ]]; then
        executable_file_info="$(file "${executable_path}")"
        executable_archs=""

        if [[ "${executable_file_info}" == *"x86_64"* ]]; then
            executable_archs="${executable_archs} x86_64"
        fi

        if [[ "${executable_file_info}" == *"arm64"* ]]; then
            executable_archs="${executable_archs} arm64"
        fi

        executable_archs="${executable_archs# }"

        if [[ "${REQUIRE_ARM64:-0}" == "1" ]] && [[ " ${executable_archs} " != *" arm64 "* ]]; then
            fail "input method executable is missing arm64 architecture: ${executable_archs}"
        fi

        if [[ -n "${EXPECTED_INPUT_METHOD_CONNECTION_NAME:-}" ]]; then
            executable_strings_file="${tmp_dir}/executable-strings.txt"
            strings -a "${executable_path}" >"${executable_strings_file}"

            grep -Fq "${EXPECTED_INPUT_METHOD_CONNECTION_NAME}" "${executable_strings_file}" \
                || fail "input method executable does not contain ${EXPECTED_INPUT_METHOD_CONNECTION_NAME}"

            if [[ "${EXPECTED_INPUT_METHOD_CONNECTION_NAME}" != "YahooKeyKey_1_Connection" ]]; then
                if grep -Fq "YahooKeyKey_1_Connection" "${executable_strings_file}"; then
                    fail "input method executable still contains YahooKeyKey_1_Connection"
                fi
            fi
        fi

        echo "ok: executable architectures: ${executable_archs}"
    fi

    if codesign --verify --deep --strict "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app" >/dev/null 2>&1; then
        pass "app code signature"
    else
        fail "app code signature is invalid"
    fi

    for helper_app in \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app" \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app"; do
        if codesign --verify --deep --strict "${helper_app}" >/dev/null 2>&1; then
            :
        else
            fail "$(basename "${helper_app}") code signature is invalid"
        fi
    done

    pass "helper app code signatures"

    preferences_executable="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app/Contents/MacOS/Preferences"
    if otool -L "${preferences_executable}" | grep -Fq '@rpath/DotMacKit.framework/DotMacKit'; then
        otool -l "${preferences_executable}" | grep -Fq '@executable_path/../Frameworks' \
            || fail "Preferences.app cannot resolve bundled DotMacKit.framework"
    fi

    pass "helper app runtime paths"

    for brand_asset in \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/CangjieX.icns" \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/CangjieXMenu.icns" \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/About.jpg" \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app/Contents/Resources/CangjieXPreferences.icns" \
        "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/CangjieXPhraseEditor.icns"; do
        [[ -f "${brand_asset}" ]] || fail "missing brand asset: ${brand_asset}"
    done

    pass "brand assets"

    if [[ "${REQUIRE_CANGJIE_DB:-0}" == "1" ]]; then
        database_path="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/Databases/KeyKey.db"
        [[ -f "${database_path}" ]] || fail "missing KeyKey database: ${database_path}"

        cangjie_entry_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM 'Generic-cj-cin';" 2>/dev/null)" \
            || fail "KeyKey database is not readable by sqlite3"

        [[ -n "${cangjie_entry_count}" ]] && [[ "${cangjie_entry_count}" != "0" ]] \
            || fail "KeyKey database does not contain Cangjie entries"

        pass "Cangjie database (${cangjie_entry_count} entries)"
    fi

    if [[ "${REQUIRE_ASSOCIATED_PHRASES:-0}" == "1" ]]; then
        database_path="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/Databases/KeyKey.db"
        [[ -f "${database_path}" ]] || fail "missing KeyKey database: ${database_path}"

        associated_phrase_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM associated_phrases;" 2>/dev/null)" \
            || fail "KeyKey database does not contain readable associated_phrases"

        [[ -n "${associated_phrase_count}" ]] && [[ "${associated_phrase_count}" != "0" ]] \
            || fail "KeyKey database does not contain associated phrases"

        ruby "${SCRIPT_DIR}/tools/validate-associated-phrases.rb" "${database_path}" \
            || fail "associated phrase quality validation failed"

        pass "associated phrases (${associated_phrase_count} heads)"
    fi

    database_path="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/Databases/KeyKey.db"
    [[ -f "${database_path}" ]] || fail "missing KeyKey database: ${database_path}"

    legacy_onekey_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM prepopulated_service_data WHERE key = 'onekey_services' OR value LIKE '%Yahoo! Search%' OR value LIKE '%Wretch.cc%' OR value LIKE '%Yahoo! Taiwan Auction%' OR value LIKE '%Yahoo! Taiwan Map%';" 2>/dev/null)" \
        || fail "unable to inspect database for legacy OneKey service data"

    [[ "${legacy_onekey_count}" == "0" ]] \
        || fail "database still contains legacy OneKey service data"

    if find "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app" \( -name '*OneKey*' -o -name 'OneKey.plist' \) | grep -q .; then
        fail "app bundle still contains legacy OneKey files"
    fi

    executable_path="${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/MacOS/Yahoo! KeyKey"
    if [[ -f "${executable_path}" ]]; then
        legacy_onekey_strings_file="${tmp_dir}/legacy-onekey-strings.txt"
        strings -a "${executable_path}" >"${legacy_onekey_strings_file}"

        if grep -Eq 'YKAFOneKey|OneKeyDataCopy|onekey_services|OneKey Services|Yahoo! Search|Wretch[.]cc|Yahoo! Taiwan Auction|Yahoo! Taiwan Map|One-Key' "${legacy_onekey_strings_file}"; then
            fail "input method executable still contains legacy OneKey service strings"
        fi
    fi

    pass "legacy OneKey service removed"

    if [[ -f "${executable_path}" ]]; then
        modern_menu_strings_file="${tmp_dir}/modern-menu-strings.txt"
        strings -a "${executable_path}" >"${modern_menu_strings_file}"

        grep -Fq "${PROJECT_URL}" "${modern_menu_strings_file}" \
            || fail "input method executable does not contain project GitHub URL"
        grep -Fq "${PROJECT_URL_LABEL}" "${modern_menu_strings_file}" \
            || fail "input method executable does not contain project GitHub link label"
        binary_contains_text "${executable_path}" "關於倉頡星" \
            || fail "input method executable does not contain the CangjieX About window title"
        binary_contains_text "${executable_path}" "移除輸入法" \
            || fail "input method executable does not contain the uninstall button title"
        grep -Fq "com.yahoo.KeyKey*.plist" "${modern_menu_strings_file}" \
            || fail "input method executable does not remove legacy KeyKey preference files"
        grep -Fq "Library/Caches/com.yahoo.KeyKey*" "${modern_menu_strings_file}" \
            || fail "input method executable does not remove legacy KeyKey cache files"
        grep -Fq "${PREFERENCES_BUNDLE_ID}" "${modern_menu_strings_file}" \
            || fail "input method executable does not contain the CangjieX Preferences bundle id"

        if grep -Eq 'Bopomofo Correction|Associated Phrase|Use Full-Width Characters|Traditional Chinese to Simpified Chinese|Traditional Chinese to Simplified Chinese|Simplified Chinese to Traditional Chinese|com[.]yahoo[.]inputmethod[.]KeyKey[.]Preferences|http://tw[.]help[.]cc[.]yahoo[.]com|http://tw[.]media[.]yahoo[.]com/keykey/help' "${modern_menu_strings_file}"; then
            fail "input method executable still contains legacy English menu or Yahoo help strings"
        fi

        pass "modernized menu strings"
    fi

    preferences_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app/Contents/Info.plist")"
    preferences_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app/Contents/Info.plist")"
    phrase_editor_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Info.plist")"
    phrase_editor_bundle_id="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Info.plist")"
    about_title="$(/usr/libexec/PlistBuddy -c 'Print :"About Yahoo! KeyKey"' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/English.lproj/Localizable.strings")"
    english_about_nib_title="$(/usr/libexec/PlistBuddy -c 'Print :$objects:35' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/English.lproj/AboutWindow.nib/keyedobjects.nib")"
    traditional_about_nib_title="$(/usr/libexec/PlistBuddy -c 'Print :$objects:35' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/zh_TW.lproj/AboutWindow.nib/keyedobjects.nib")"
    simplified_about_nib_title="$(/usr/libexec/PlistBuddy -c 'Print :$objects:35' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/zh_CN.lproj/AboutWindow.nib/keyedobjects.nib")"
    english_about_github="$(/usr/libexec/PlistBuddy -c 'Print :$objects:67' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/English.lproj/AboutWindow.nib/keyedobjects.nib")"
    traditional_about_github="$(/usr/libexec/PlistBuddy -c 'Print :$objects:67' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/zh_TW.lproj/AboutWindow.nib/keyedobjects.nib")"
    simplified_about_github="$(/usr/libexec/PlistBuddy -c 'Print :$objects:67' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/zh_CN.lproj/AboutWindow.nib/keyedobjects.nib")"
    phrase_editor_warning="$(/usr/libexec/PlistBuddy -c 'Print :"Yahoo! KeyKey is not running."' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings")"

    [[ "${preferences_name}" == "倉頡星偏好設定" ]] \
        || fail "preferences app name is ${preferences_name}"
    [[ "${preferences_bundle_id}" == "${PREFERENCES_BUNDLE_ID}" ]] \
        || fail "preferences app bundle id is ${preferences_bundle_id}"
    [[ "${phrase_editor_name}" == "倉頡星詞彙編輯程式" ]] \
        || fail "phrase editor app name is ${phrase_editor_name}"
    [[ "${phrase_editor_bundle_id}" == "${PHRASE_EDITOR_BUNDLE_ID}" ]] \
        || fail "phrase editor app bundle id is ${phrase_editor_bundle_id}"
    [[ "${about_title}" == "關於倉頡星" ]] \
        || fail "about title is ${about_title}"
    [[ "${english_about_nib_title}" == "關於倉頡星" ]] \
        || fail "English AboutWindow title is ${english_about_nib_title}"
    [[ "${traditional_about_nib_title}" == "關於倉頡星" ]] \
        || fail "Traditional Chinese AboutWindow title is ${traditional_about_nib_title}"
    [[ "${simplified_about_nib_title}" == "關於倉頡星" ]] \
        || fail "Simplified Chinese AboutWindow title is ${simplified_about_nib_title}"
    [[ "${english_about_github}" == "${PROJECT_URL_LABEL}" ]] \
        || fail "English AboutWindow GitHub link is ${english_about_github}"
    [[ "${traditional_about_github}" == "${PROJECT_URL_LABEL}" ]] \
        || fail "Traditional Chinese AboutWindow GitHub link is ${traditional_about_github}"
    [[ "${simplified_about_github}" == "${PROJECT_URL_LABEL}" ]] \
        || fail "Simplified Chinese AboutWindow GitHub link is ${simplified_about_github}"
    [[ "${phrase_editor_warning}" == "倉頡星並不在執行中" ]] \
        || fail "phrase editor warning is ${phrase_editor_warning}"
    pass "visible branding"
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
