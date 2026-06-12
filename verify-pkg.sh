#!/bin/bash
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
        executable_archs="$(lipo -archs "${executable_path}")"

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
        unigram_table_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = 'unigrams';" 2>/dev/null)" \
            || fail "KeyKey database cannot be inspected for unigrams"
        cangjiex_tail_count="$(sqlite3 "${database_path}" "SELECT instr(data, '頡') FROM associated_phrases WHERE headchar = '倉';" 2>/dev/null)" \
            || fail "KeyKey database cannot query CangjieX associated phrase seed"
        simplified_yi_tail_count="$(sqlite3 "${database_path}" "SELECT instr(data, '经') FROM associated_phrases WHERE headchar = '已';" 2>/dev/null)" \
            || fail "KeyKey database cannot query traditional associated phrase seed"
        simplified_zhe_head_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM associated_phrases WHERE headchar = '这';" 2>/dev/null)" \
            || fail "KeyKey database cannot inspect simplified associated phrase heads"

        [[ -n "${associated_phrase_count}" ]] && [[ "${associated_phrase_count}" != "0" ]] \
            || fail "KeyKey database does not contain associated phrases"
        [[ "${unigram_table_count}" == "1" ]] \
            || fail "KeyKey database does not contain unigrams table required by associated phrases"
        [[ -n "${cangjiex_tail_count}" ]] && [[ "${cangjiex_tail_count}" != "0" ]] \
            || fail "KeyKey database does not contain the CangjieX associated phrase seed"
        [[ -z "${simplified_yi_tail_count}" ]] || [[ "${simplified_yi_tail_count}" == "0" ]] \
            || fail "KeyKey database contains simplified 已 -> 经 associated phrase"
        [[ "${simplified_zhe_head_count}" == "0" ]] \
            || fail "KeyKey database contains simplified associated phrase head 这"

        pass "associated phrases (${associated_phrase_count} heads)"
    fi

    preferences_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/Preferences.app/Contents/Info.plist")"
    phrase_editor_name="$(/usr/libexec/PlistBuddy -c "Print :CFBundleName" "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Info.plist")"
    about_title="$(/usr/libexec/PlistBuddy -c 'Print :"About Yahoo! KeyKey"' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/Resources/English.lproj/Localizable.strings")"
    phrase_editor_warning="$(/usr/libexec/PlistBuddy -c 'Print :"Yahoo! KeyKey is not running."' "${BUILD_DIR}/stage/Library/Input Methods/${PRODUCT_NAME}.app/Contents/SharedSupport/PhraseEditor.app/Contents/Resources/English.lproj/Localizable.strings")"

    [[ "${preferences_name}" == "${PRODUCT_NAME} Preferences" ]] \
        || fail "preferences app name is ${preferences_name}"
    [[ "${phrase_editor_name}" == "${PRODUCT_NAME} Phrase Editor" ]] \
        || fail "phrase editor app name is ${phrase_editor_name}"
    [[ "${about_title}" == "About ${PRODUCT_NAME}" ]] \
        || fail "about title is ${about_title}"
    [[ "${phrase_editor_warning}" == "${PRODUCT_NAME} is not running." ]] \
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
