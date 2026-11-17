#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${PROJECT_DIR}/build/migration/preview/CangjieXPreview.app"
DESTINATION="${HOME}/Library/Input Methods/CangjieXPreview.app"
IDENTIFIER="io.github.geekstek.inputmethod.CangjieXPreview"

[[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "${SOURCE_APP}/Contents/Info.plist")" == "${IDENTIFIER}" ]] \
    || { echo "Refusing to install an app without the Preview identifier." >&2; exit 1; }
codesign --verify --strict "${SOURCE_APP}"
if [[ -e "${DESTINATION}" ]]; then
    [[ "$('/usr/libexec/PlistBuddy' -c 'Print :CFBundleIdentifier' "${DESTINATION}/Contents/Info.plist")" == "${IDENTIFIER}" ]] \
        || { echo "Refusing to replace an app with a different identifier." >&2; exit 1; }
fi

SELECTED_SOURCE="$(xcrun swift -e 'import Carbon; let source = TISCopyCurrentKeyboardInputSource().takeRetainedValue(); if let p = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) { print(Unmanaged<AnyObject>.fromOpaque(p).takeUnretainedValue()) }')"
[[ "${SELECTED_SOURCE}" != "${IDENTIFIER}" ]] \
    || { echo "Switch away from Preview before updating it, so pending composition is not lost." >&2; exit 1; }
mkdir -p "${HOME}/Library/Input Methods"
ditto "${SOURCE_APP}" "${DESTINATION}"
codesign --verify --strict "${DESTINATION}"
# Replace the bundle before stopping only the uniquely named Preview process.
/usr/bin/killall CangjieXPreview >/dev/null 2>&1 || true
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "${DESTINATION}"
"${DESTINATION}/Contents/MacOS/CangjieXPreview" --register-preview
echo "Installed only: ${DESTINATION}"
