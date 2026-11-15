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
  "$ROOT/ios/OrcaSlicerApp/ProcessOptions.swift"
