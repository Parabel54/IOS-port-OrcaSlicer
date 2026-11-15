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
  "$ROOT/ios/OrcaSlicerApp/StartupRecoveryView.swift" \
  "$ROOT/ios/OrcaSlicerApp/DocumentImport.swift" \
  "$ROOT/ios/OrcaSlicerApp/NativeDocumentPicker.swift" \
  "$ROOT/ios/OrcaSlicerApp/OrcaCloudAPI.swift" \
  "$ROOT/ios/OrcaSlicerApp/NativeCloudSignIn.swift" \
  "$ROOT/ios/OrcaSlicerApp/OrcaCloudAccount.swift" \
  "$ROOT/ios/OrcaSlicerApp/CloudAccountPanel.swift" \
  "$ROOT/ios/OrcaSlicerApp/FlashforgeClient.swift" \
  "$ROOT/ios/OrcaSlicerApp/NativePostProcessing.swift"

python3 -m unittest discover -s "$ROOT/scripts/tests" -p test_ios_settings_catalog.py -v

if [[ "$SDK" == iphonesimulator ]]; then
  PLATFORM_PATH="$(xcrun --sdk "$SDK" --show-sdk-platform-path)"
  xcrun --sdk "$SDK" swiftc -typecheck -parse-as-library -swift-version 5 \
    -sdk "$SDK_PATH" -target "$SWIFT_TARGET" \
    -F "$PLATFORM_PATH/Developer/Library/Frameworks" \
    -I "$PLATFORM_PATH/Developer/usr/lib" \
    "$ROOT/ios/tests/WorkspaceUITests.swift"
fi

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

xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/DocumentImport.swift" \
  "$ROOT/ios/tests/document_import_smoke.swift" -o "$TEST_DIR/document-import"
"$TEST_DIR/document-import"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/OrcaCloudAPI.swift" \
  "$ROOT/ios/tests/cloud_api_smoke.swift" -o "$TEST_DIR/cloud-api"
"$TEST_DIR/cloud-api"

xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/PrinterConnections.swift" \
  "$ROOT/ios/OrcaSlicerApp/FlashforgeClient.swift" \
  "$ROOT/ios/tests/flashforge_smoke.swift" -o "$TEST_DIR/flashforge"
"$TEST_DIR/flashforge"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/PrinterConnections.swift" \
  "$ROOT/ios/OrcaSlicerApp/OrcaCloudAPI.swift" \
  "$ROOT/ios/OrcaSlicerApp/OrcaCloudAccount.swift" \
  "$ROOT/ios/tests/cloud_account_smoke.swift" -o "$TEST_DIR/cloud-account"
"$TEST_DIR/cloud-account"

python3 "$ROOT/scripts/make_ios_postprocess_fixtures.py" "$TEST_DIR/zmod"
xcrun --sdk macosx swiftc -parse-as-library -swift-version 5 \
  "$ROOT/ios/OrcaSlicerApp/NativePostProcessing.swift" \
  "$ROOT/ios/tests/postprocessing_smoke.swift" -o "$TEST_DIR/post-processing"
"$TEST_DIR/post-processing" "$TEST_DIR/zmod"
