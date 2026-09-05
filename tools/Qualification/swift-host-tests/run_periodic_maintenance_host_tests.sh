#!/bin/sh
# macOS host tests for the periodic maintenance core and mission store.
#
# The production sources are compiled directly into a command-line test
# binary. No Xcode project, UIKit dependency, simulator or device is needed,
# which keeps the state machine, recovery planner and atomic commit paths
# testable on any build machine.
#
# Usage: tools/Qualification/swift-host-tests/run_periodic_maintenance_host_tests.sh
set -eu

REPO_ROOT=$(cd "$(dirname "$0")/../../.." && pwd)
SOURCES_DIR="$REPO_ROOT/app/ios/RTABMapApp"
TESTS_DIR="$REPO_ROOT/tools/Qualification/swift-host-tests"
OUTPUT=${TMPDIR:-/tmp}/periodic-maintenance-host-tests

mkdir -p "$OUTPUT"
BINARY="$OUTPUT/PeriodicMaintenanceHostTests"

echo "Compiling periodic maintenance host tests..."
swiftc \
  -O \
  -target "$(uname -m)-apple-macosx13.0" \
  -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
  -o "$BINARY" \
  "$TESTS_DIR/main.swift" \
  "$SOURCES_DIR/PeriodicScanMaintenanceCore.swift" \
  "$SOURCES_DIR/PeriodicScanMaintenanceStore.swift"

echo "Running periodic maintenance host tests..."
"$BINARY"
