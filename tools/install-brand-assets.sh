#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: install-brand-assets.sh <CangjieX.app>" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
APP_DIR="$1"
ASSETS_DIR="${BRAND_ASSETS_DIR:-${PROJECT_DIR}/assets/brand}"
RESOURCES_DIR="${APP_DIR}/Contents/Resources"
PREFERENCES_DIR="${APP_DIR}/Contents/SharedSupport/Preferences.app"
PHRASE_EDITOR_DIR="${APP_DIR}/Contents/SharedSupport/PhraseEditor.app"

set_plist_string() {
    local plist_file="$1"
    local key="$2"
    local value="$3"

    [[ -f "${plist_file}" ]] || return 0

    if /usr/libexec/PlistBuddy -c "Print :${key}" "${plist_file}" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "${plist_file}"
    else
        /usr/libexec/PlistBuddy -c "Add :${key} string ${value}" "${plist_file}"
    fi
}

copy_asset() {
    local source="$1"
    local destination="$2"

    [[ -f "${source}" ]] || {
        echo "missing brand asset: ${source}" >&2
        exit 1
    }

    mkdir -p "$(dirname "${destination}")"
    cp "${source}" "${destination}"
}

[[ -d "${APP_DIR}" ]] || {
    echo "missing app bundle: ${APP_DIR}" >&2
    exit 1
}

[[ -d "${ASSETS_DIR}" ]] || {
    echo "missing brand assets directory: ${ASSETS_DIR}" >&2
    echo "Run: swift tools/generate-brand-assets.swift" >&2
    exit 1
}

copy_asset "${ASSETS_DIR}/CangjieX.icns" "${RESOURCES_DIR}/CangjieX.icns"
copy_asset "${ASSETS_DIR}/CangjieXMenu.icns" "${RESOURCES_DIR}/CangjieXMenu.icns"
copy_asset "${ASSETS_DIR}/About.jpg" "${RESOURCES_DIR}/About.jpg"
copy_asset "${ASSETS_DIR}/main/FontSmaller.tiff" "${RESOURCES_DIR}/FontSmaller.tiff"
copy_asset "${ASSETS_DIR}/main/FontBigger.tiff" "${RESOURCES_DIR}/FontBigger.tiff"

set_plist_string "${APP_DIR}/Contents/Info.plist" "CFBundleIconFile" "CangjieX"
set_plist_string "${APP_DIR}/Contents/Info.plist" "tsInputMethodIconFileKey" "CangjieXMenu.icns"

rm -f \
    "${RESOURCES_DIR}/Yahoo.icns" \
    "${RESOURCES_DIR}/Yahoo16.icns" \
    "${RESOURCES_DIR}/Yahoo32.icns"

if [[ -d "${PREFERENCES_DIR}" ]]; then
    preferences_resources="${PREFERENCES_DIR}/Contents/Resources"

    copy_asset "${ASSETS_DIR}/CangjieXPreferences.icns" "${preferences_resources}/CangjieXPreferences.icns"
    set_plist_string "${PREFERENCES_DIR}/Contents/Info.plist" "CFBundleIconFile" "CangjieXPreferences"
    rm -f "${preferences_resources}/Yahoo.icns"

    for asset_name in general cangjie phrase plugin generic phonetic simplex update playSound stopSound; do
        copy_asset "${ASSETS_DIR}/preferences/${asset_name}.tiff" "${preferences_resources}/${asset_name}.tiff"
    done
fi

if [[ -d "${PHRASE_EDITOR_DIR}" ]]; then
    phrase_editor_resources="${PHRASE_EDITOR_DIR}/Contents/Resources"

    copy_asset "${ASSETS_DIR}/CangjieXPhraseEditor.icns" "${phrase_editor_resources}/CangjieXPhraseEditor.icns"
    set_plist_string "${PHRASE_EDITOR_DIR}/Contents/Info.plist" "CFBundleIconFile" "CangjieXPhraseEditor"
    rm -f "${phrase_editor_resources}/PhraseEditor.icns"

    for asset_name in add addressBook editPhrase delete reload editReading; do
        copy_asset "${ASSETS_DIR}/phrase-editor/${asset_name}.png" "${phrase_editor_resources}/${asset_name}.png"
    done
fi

echo "Installed CangjieX brand assets into ${APP_DIR}"
