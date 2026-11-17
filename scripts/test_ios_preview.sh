#!/usr/bin/env bash
# Exercise the real renderer before the full slicing dependencies finish.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/ios_simulator_helpers.sh
source "$ROOT/scripts/ios_simulator_helpers.sh"
ARCH="$(uname -m)"
case "$ARCH" in arm64|x86_64) ;; *) echo "Unsupported simulator host: $ARCH" >&2; exit 1 ;; esac
SDK_PATH="$(xcrun --sdk iphonesimulator --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphonesimulator --show-sdk-version)"
TEST_DIR="$ROOT/build_logs/preview-renderer"
APP="$TEST_DIR/PreviewSmoke.app"
mkdir -p "$APP"
python3 - "$APP/Info.plist" <<'PYINFO'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'com.orcaslicer.preview-smoke',
    'CFBundleExecutable': 'PreviewSmoke', 'CFBundlePackageType': 'APPL',
    'CFBundleName': 'PreviewSmoke', 'CFBundleVersion': '1',
    'CFBundleShortVersionString': '1.0', 'MinimumOSVersion': '16.0',
    'LSRequiresIPhoneOS': True, 'UIDeviceFamily': [1, 2], 'UILaunchScreen': {},
}))
PYINFO
ios_test_run 240 xcrun --sdk iphonesimulator swiftc -parse-as-library -swift-version 5 \
  -sdk "$SDK_PATH" -target "$ARCH-apple-ios16.0-simulator" \
  "$ROOT/ios/OrcaSlicerApp/PlateSceneView.swift" "$ROOT/ios/tests/PreviewSmokeApp.swift" \
  -framework UIKit -framework SceneKit -framework Metal -o "$APP/PreviewSmoke" \
  2>&1 | tee "$TEST_DIR/build.log"
codesign --force --sign - "$APP"
RUNTIME="$(ios_test_runtime "$SDK_VERSION")"
DEVICE="$(ios_test_run 120 xcrun simctl create OrcaPreviewSmoke com.apple.CoreSimulator.SimDeviceType.iPhone-16 "$RUNTIME")"
cleanup() {
  test_exit=$?
  ios_test_run 20 xcrun simctl spawn "$DEVICE" log show --last 3m --style compact \
    --predicate 'process == "PreviewSmoke"' > "$TEST_DIR/app.log" 2>&1 || true
  if [[ "$test_exit" != 0 ]]; then
    ios_test_run 15 xcrun simctl io "$DEVICE" screenshot "$TEST_DIR/failure.png" >/dev/null 2>&1 || true
  fi
  ios_test_run 20 xcrun simctl shutdown "$DEVICE" >/dev/null 2>&1 || true
  ios_test_run 20 xcrun simctl delete "$DEVICE" >/dev/null 2>&1 || true
}
trap cleanup EXIT
ios_test_run 120 xcrun simctl boot "$DEVICE"
ios_test_run 360 xcrun simctl bootstatus "$DEVICE" -b 2>&1 | tee "$TEST_DIR/boot.log"
ios_test_run 240 xcrun simctl install "$DEVICE" "$APP" 2>&1 | tee "$TEST_DIR/install.log"
SOURCE_COMMIT="$(git -C "$ROOT" rev-parse HEAD)"
SIMCTL_CHILD_ORCA_GRAPHICS_SOURCE="$SOURCE_COMMIT" \
  ios_test_run 90 xcrun simctl launch "$DEVICE" com.orcaslicer.preview-smoke | tee "$TEST_DIR/launch.log"
APP_DATA="$(ios_test_run 30 xcrun simctl get_app_container "$DEVICE" com.orcaslicer.preview-smoke data)"
ios_test_run 75 python3 - "$APP_DATA" "$TEST_DIR" <<'PYRESULT'
from pathlib import Path
import json, shutil, sys, time
source = Path(sys.argv[1]) / 'tmp/preview-renderer.json'
deadline = time.monotonic() + 60
while True:
    try:
        completed = json.loads(source.read_text()).get('completed') is True
    except (FileNotFoundError, json.JSONDecodeError):
        completed = False
    if completed:
        break
    if time.monotonic() >= deadline:
        if source.is_file():
            shutil.copy2(source, Path(sys.argv[2]) / source.name)
        raise SystemExit('No completed renderer result within 60 seconds; any partial receipt was preserved')
    time.sleep(1)
shutil.copy2(source, Path(sys.argv[2]) / source.name)
PYRESULT
ios_test_run 20 python3 "$ROOT/scripts/check_ios_preview_receipt.py" \
  "$TEST_DIR/preview-renderer.json" "$SOURCE_COMMIT"
# A receipt must come from a still-running app, not a process that crashed later.
ios_test_run 20 xcrun simctl terminate "$DEVICE" com.orcaslicer.preview-smoke
