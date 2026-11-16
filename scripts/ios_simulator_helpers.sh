#!/usr/bin/env bash
# Shared bounded CoreSimulator phases and SDK-matched runtime selection.
# CoreSimulator commands can stall without returning a diagnostic. Bound each
# phase so a failed install/launch cannot block subsequent validation builds.
ios_test_run() {
  # Keep the caller's stdin separate from the Python wrapper's own source.
  python3 - "$@" 3<&0 <<'PYRUN'
from pathlib import Path
import subprocess
import sys
import time
seconds = int(sys.argv[1])
command = sys.argv[2:]
print('Simulator phase: ' + ' '.join(command[:4]), file=sys.stderr, flush=True)
started = time.time()
try:
    subprocess.run(command, stdin=3, timeout=seconds, check=True)
except subprocess.TimeoutExpired:
    # CoreSimulator can lose a cold launch request before starting any process.
    # Never retry an app that is running, crashed, or returned an actual error.
    if command[:3] != ['xcrun', 'simctl', 'launch'] or command[4] != 'com.orcaslicer.ios':
        raise
    status = subprocess.run(['xcrun', 'simctl', 'spawn', command[3], 'launchctl', 'list'],
                            capture_output=True, text=True, timeout=20)
    reports = Path.home() / 'Library/Logs/DiagnosticReports'
    crashed = any(p.stat().st_mtime >= started for p in reports.glob('OrcaSlicer*.ips'))
    if status.returncode or command[4] in status.stdout or crashed:
        raise
    print('CoreSimulator did not start Orca; retrying its launch request once', file=sys.stderr, flush=True)
    subprocess.run(command, stdin=3, timeout=seconds, check=True)
PYRUN
}

ios_test_runtime() {
xcrun simctl list runtimes -j | python3 -c '
import json, sys
sdk = sys.argv[1].split(".")
rows = [r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"]
        and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")
        and r["version"].split(".")[0] == sdk[0]]
if not rows:
    raise SystemExit("No available simulator runtime matches selected iOS SDK " + sys.argv[1])
rows.sort(key=lambda r: (r["version"] == sys.argv[1], tuple(map(int, r["version"].split(".")))))
print(rows[-1]["identifier"])
' "$1"
}
