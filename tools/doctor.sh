#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
PRODUCT_NAME="CangjieX"
APP_PATH="/Library/Input Methods/${PRODUCT_NAME}.app"
APP_BUNDLE_ID="io.github.geekstek.inputmethod.CangjieX"
PACKAGE_ID="io.github.geekstek.cangjiex.inputmethod"
EXPECTED_CONNECTION_NAME="CangjieX_1_Connection"

xcrun_policy_error() {
    local output="$1"

    [[ "${output}" == *"unable to load libxcrun"* ]] \
        || [[ "${output}" == *"library load denied by system policy"* ]]
}

print_check() {
    local label="$1"
    local value="$2"

    printf '%-28s %s\n' "${label}" "${value}"
}

check_command() {
    local command_name="$1"

    if command -v "${command_name}" >/dev/null 2>&1; then
        print_check "${command_name}" "ok"
    else
        print_check "${command_name}" "missing"
    fi
}

check_runnable() {
    local label="$1"
    shift

    local output
    if output="$("$@" 2>&1)"; then
        print_check "${label}" "ok"
        printf '%s\n' "${output}" | sed 's/^/  /'
        return 0
    fi

    if xcrun_policy_error "${output}"; then
        print_check "${label}" "blocked by macOS system policy"
        printf '%s\n' "${output}" | sed 's/^/  /'
        return 0
    fi

    print_check "${label}" "failed"
    printf '%s\n' "${output}" | sed 's/^/  /'
}

plist_value() {
    local plist_file="$1"
    local key_path="$2"

    if [[ ! -f "${plist_file}" ]]; then
        return 1
    fi

    /usr/libexec/PlistBuddy -c "Print ${key_path}" "${plist_file}" 2>/dev/null
}

echo "CangjieX doctor"
echo

developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ -n "${developer_dir}" ]]; then
    print_check "Developer directory" "${developer_dir}"
else
    print_check "Developer directory" "not selected"
fi

echo
echo "Build tools"
check_command pkgbuild
check_command productbuild
check_command plutil
check_command ruby
check_command git

echo
echo "Tool health"
check_runnable "git --version" git --version
check_runnable "xcodebuild -version" xcodebuild -version

echo
echo "Installed input method"
if [[ -d "${APP_PATH}" ]]; then
    print_check "App bundle" "${APP_PATH}"
else
    print_check "App bundle" "not installed"
fi

if pkgutil --pkg-info "${PACKAGE_ID}" >/dev/null 2>&1; then
    print_check "Package receipt" "${PACKAGE_ID}"
else
    print_check "Package receipt" "not found"
fi

if [[ -d "${APP_PATH}" ]]; then
    info_plist="${APP_PATH}/Contents/Info.plist"
    database_path="${APP_PATH}/Contents/Resources/Databases/KeyKey.db"
    executable_path="${APP_PATH}/Contents/MacOS/Yahoo! KeyKey"

    bundle_id="$(plist_value "${info_plist}" ":CFBundleIdentifier" || true)"
    input_source_id="$(plist_value "${info_plist}" ":TISInputSourceID" || true)"
    connection_name="$(plist_value "${info_plist}" ":InputMethodConnectionName" || true)"

    if [[ "${bundle_id}" == "${APP_BUNDLE_ID}" ]]; then
        print_check "Bundle id" "${bundle_id}"
    else
        print_check "Bundle id" "${bundle_id:-missing} (expected ${APP_BUNDLE_ID})"
    fi

    if [[ "${input_source_id}" == "${APP_BUNDLE_ID}" ]]; then
        print_check "Input source id" "${input_source_id}"
    else
        print_check "Input source id" "${input_source_id:-missing} (expected ${APP_BUNDLE_ID})"
    fi

    if [[ "${connection_name}" == "${EXPECTED_CONNECTION_NAME}" ]]; then
        print_check "Connection name" "${connection_name}"
    else
        print_check "Connection name" "${connection_name:-missing} (expected ${EXPECTED_CONNECTION_NAME})"
    fi

    if [[ -f "${executable_path}" ]] && command -v lipo >/dev/null 2>&1; then
        print_check "Executable archs" "$(lipo -archs "${executable_path}")"
    fi

    if [[ -f "${database_path}" ]] && command -v sqlite3 >/dev/null 2>&1; then
        cangjie_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM 'Generic-cj-cin';" 2>/dev/null || true)"
        associated_count="$(sqlite3 "${database_path}" "SELECT COUNT(*) FROM associated_phrases;" 2>/dev/null || true)"

        print_check "Cangjie entries" "${cangjie_count:-unreadable}"
        print_check "Associated heads" "${associated_count:-unreadable}"

        if ruby -e 'require "sqlite3"' >/dev/null 2>&1; then
            if ruby "${PROJECT_DIR}/tools/validate-associated-phrases.rb" "${database_path}" >/dev/null 2>&1; then
                print_check "Associated quality" "ok"
            else
                print_check "Associated quality" "failed"
            fi
        fi
    fi
fi

echo
if xcodebuild_output="$(xcodebuild -version 2>&1)" && git_output="$(git --version 2>&1)"; then
    echo "Environment looks ready for source probing."
else
    combined_output="${xcodebuild_output:-}${git_output:-}"
    if xcrun_policy_error "${combined_output}"; then
        echo "Xcode's command line bridge is currently blocked by macOS."
        echo "Open Xcode once, restart macOS, then run: ./tools/doctor.sh"
        echo "If it still fails after restart, reinstall Xcode."
        if [[ -d /Library/Developer/CommandLineTools ]]; then
            echo "For package-only work, you can switch back with:"
            echo "  sudo xcode-select -s /Library/Developer/CommandLineTools"
        fi
    else
        echo "Some developer tools are not ready yet. Review the failed checks above."
    fi
fi
