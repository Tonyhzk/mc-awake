#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
swiftc -D LOCALIZATION_TESTING -parse-as-library \
  Sources/main.swift Sources/BatteryGuard.swift Sources/Localization.swift \
  tests/test-localization.swift -o "$WORK/test-localization"
"$WORK/test-localization" "$WORK"
