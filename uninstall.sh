#!/usr/bin/env bash
set -euo pipefail

PRODUCT_NAME="CangjieX"
APP_PATH="/Library/Input Methods/${PRODUCT_NAME}.app"
PACKAGE_ID="io.github.geekstek.cangjiex.inputmethod"

if [[ "${EUID}" -ne 0 ]]; then
    exec sudo "$0" "$@"
fi

/usr/bin/killall "Yahoo! KeyKey" >/dev/null 2>&1 || true
/usr/bin/killall "${PRODUCT_NAME}" >/dev/null 2>&1 || true

if [[ -d "${APP_PATH}" ]]; then
    rm -rf "${APP_PATH}"
    echo "Removed ${APP_PATH}"
else
    echo "${APP_PATH} is not installed"
fi

if pkgutil --pkgs | grep -qx "${PACKAGE_ID}"; then
    pkgutil --forget "${PACKAGE_ID}" >/dev/null
    echo "Forgot package receipt ${PACKAGE_ID}"
fi

echo "Please log out and back in to refresh macOS input sources."
