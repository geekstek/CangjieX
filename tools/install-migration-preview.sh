#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${PROJECT_DIR}/build/migration/preview/CangjieXPreview.app"
DESTINATION="${HOME}/Library/Input Methods/CangjieXPreview.app"
IDENTIFIER="io.github.geekstek.inputmethod.CangjieXPreview"
[[ ! -L "${DESTINATION}" && ! -L "${HOME}/Library/Input Methods" ]] \
    || { echo "Refusing to update through a symbolic link." >&2; exit 1; }

[[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "${SOURCE_APP}/Contents/Info.plist")" == "${IDENTIFIER}" ]] \
    || { echo "Refusing to install an app without the Preview identifier." >&2; exit 1; }
codesign --verify --strict "${SOURCE_APP}"
if [[ -e "${DESTINATION}" ]]; then
    [[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "${DESTINATION}/Contents/Info.plist")" == "${IDENTIFIER}" ]] \
        || { echo "Refusing to replace an app with a different identifier." >&2; exit 1; }
fi

"${SOURCE_APP}/Contents/MacOS/CangjieXMaintenance" check
mkdir -p "${HOME}/Library/Input Methods"
# Stage a whole bundle so an older version's localized resources cannot survive.
WORK="$(mktemp -d "${HOME}/Library/Input Methods/.cangjiex-update.XXXXXX")"
cleanup() {
    if [[ -d "${WORK}/previous.app" && ! -e "${DESTINATION}" ]]; then
        mv "${WORK}/previous.app" "${DESTINATION}"
    fi
    rm -rf "${WORK}"
}
trap cleanup EXIT
ditto "${SOURCE_APP}" "${WORK}/CangjieXPreview.app"
codesign --verify --strict "${WORK}/CangjieXPreview.app"
"${SOURCE_APP}/Contents/MacOS/CangjieXMaintenance" check
if [[ -e "${DESTINATION}" ]]; then mv "${DESTINATION}" "${WORK}/previous.app"; fi
mv "${WORK}/CangjieXPreview.app" "${DESTINATION}"
codesign --verify --strict "${DESTINATION}"
# The helper stops only the installed V2 executable after checking the input source.
"${DESTINATION}/Contents/MacOS/CangjieXMaintenance" repair
echo "Installed only: ${DESTINATION}"
