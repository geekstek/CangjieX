#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Use this checkout's implementation, including with an older installed app.
HELPER="${PROJECT_DIR}/build/migration/maintenance/CangjieXMaintenance"
mkdir -p "$(dirname "${HELPER}")"
xcrun swiftc -swift-version 5 -O -warnings-as-errors -D MAINTENANCE_TOOL -parse-as-library \
    "${PROJECT_DIR}/migration/preview/InputSourceMaintenance.swift" \
    "${PROJECT_DIR}/migration/preview/UninstallUI.swift" \
    -framework AppKit -framework Carbon -framework CoreServices -o "${HELPER}"
exec "${HELPER}" "$@"
