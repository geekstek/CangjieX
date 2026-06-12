#!/usr/bin/env bash
set -euo pipefail

APP_PATH="/Library/Input Methods/CangjieX.app"
PACKAGE_ID="io.github.geekstek.inputmethod.CangjieX"

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
    print_check "Package receipt" "installed"
else
    print_check "Package receipt" "not found"
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
