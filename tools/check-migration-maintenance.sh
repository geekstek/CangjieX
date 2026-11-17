#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "${PROJECT_DIR}/build/migration/maintenance"
common=("${PROJECT_DIR}/migration/preview/RuntimeVersion.swift" "${PROJECT_DIR}/migration/preview/UpgradeActivation.swift"
        "${PROJECT_DIR}/migration/preview/InstallUI.swift" "${PROJECT_DIR}/migration/preview/InputSourceMaintenance.swift"
        "${PROJECT_DIR}/migration/preview/UninstallUI.swift")
xcrun swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
    "${common[@]}" \
    "${PROJECT_DIR}/migration/tests/InputSourceMaintenanceTests.swift" \
    -framework AppKit -framework Carbon -framework CoreServices -o "${PROJECT_DIR}/build/migration/maintenance/maintenance-tests"
"${PROJECT_DIR}/build/migration/maintenance/maintenance-tests"
python3 "${PROJECT_DIR}/migration/tests/install_migration_test.py"
xcrun swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
    "${common[@]}" \
    "${PROJECT_DIR}/migration/tests/UninstallUITests.swift" \
    -framework AppKit -framework Carbon -framework CoreServices -o "${PROJECT_DIR}/build/migration/maintenance/uninstall-ui-tests"
"${PROJECT_DIR}/build/migration/maintenance/uninstall-ui-tests"
xcrun swiftc -swift-version 5 -O -warnings-as-errors -parse-as-library \
    "${common[@]}" "${PROJECT_DIR}/migration/tests/UpgradeActivationTests.swift" \
    -framework AppKit -framework Carbon -framework CoreServices -o "${PROJECT_DIR}/build/migration/maintenance/upgrade-tests"
"${PROJECT_DIR}/build/migration/maintenance/upgrade-tests"
