#!/usr/bin/env bash
# Type-check the linked Swift/C interface without waiting for C++ dependencies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="${1:-iphonesimulator}"
case "$SDK" in
  iphoneos) SWIFT_TARGET=arm64-apple-ios16.0 ;;
  iphonesimulator) SWIFT_TARGET=arm64-apple-ios16.0-simulator ;;
  *) echo "Expected iphoneos or iphonesimulator" >&2; exit 2 ;;
esac
SDK_PATH="$(xcrun --sdk "$SDK" --show-sdk-path)"
xcrun --sdk "$SDK" swiftc -typecheck -parse-as-library -swift-version 5 \
  -D ORCA_LINKED -sdk "$SDK_PATH" -target "$SWIFT_TARGET" \
  -I "$ROOT/src/ios" -import-objc-header "$ROOT/ios/OrcaSlicerApp/Bridging-Header.h" \
  "$ROOT/ios/OrcaSlicerApp/OrcaSlicerApp.swift" \
  "$ROOT/ios/OrcaSlicerApp/OrcaEngine.swift" \
  "$ROOT/ios/OrcaSlicerApp/PlateSceneView.swift" \
  "$ROOT/ios/OrcaSlicerApp/ProcessOptions.swift" \
  "$ROOT/ios/OrcaSlicerApp/PrinterConnections.swift" \
  "$ROOT/ios/OrcaSlicerApp/ConnectionsPanel.swift" \
  "$ROOT/ios/OrcaSlicerApp/StartupRecovery.swift" \
  "$ROOT/ios/OrcaSlicerApp/StartupRecoveryView.swift"

# Run storage and credential-isolation checks with injected secrets on the Mac host.
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/PrinterConnections.swift" \
  "$ROOT/ios/tests/printer_connections_smoke.swift" -o "$TEST_DIR/printer-connections"
"$TEST_DIR/printer-connections"

xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/StartupRecovery.swift" \
  "$ROOT/ios/tests/startup_recovery_smoke.swift" -o "$TEST_DIR/startup-recovery"
"$TEST_DIR/startup-recovery"
