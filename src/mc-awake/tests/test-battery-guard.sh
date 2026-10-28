#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
swiftc Sources/BatteryGuard.swift tests/test-battery-guard.swift -o "$WORK/test-battery-guard"
"$WORK/test-battery-guard"
