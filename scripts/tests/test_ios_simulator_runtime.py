"""Keep SDK/runtime selection shared by engine and standalone graphics checks."""
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

HELPER = Path(__file__).resolve().parents[2] / 'scripts/ios_simulator_helpers.sh'


class SimulatorRuntimeTests(unittest.TestCase):
    def test_bounded_command_preserves_stdin_and_failure_status(self):
        for code, status, marker in (("print('child-script-ran')", 0, 'child-script-ran'),
                                     ("raise SystemExit(7)", 1, '')):
            with self.subTest(code=code):
                result = subprocess.run(['bash', '-c', 'source "$1"; ios_test_run 5 python3 -',
                                         'stdin-test', str(HELPER)], input=code, capture_output=True, text=True)
                if status == 0:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertIn(marker, result.stdout)
                else:
                    self.assertNotEqual(result.returncode, 0, 'Child validation failure must fail the phase')

    def select(self, sdk, runtimes):
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory) / 'runtimes.json'
            fixture.write_text(json.dumps({'runtimes': runtimes}))
            return subprocess.run(['bash', '-c',
                                   'source "$1"; RUNTIME_FIXTURE="$2"; '
                                   'xcrun() { cat "$RUNTIME_FIXTURE"; }; ios_test_runtime "$3"',
                                   'runtime-test', str(HELPER), str(fixture), sdk],
                                  capture_output=True, text=True)

    @staticmethod
    def runtime(version, available=True):
        return {'version': version, 'isAvailable': available,
                'identifier': 'com.apple.CoreSimulator.SimRuntime.iOS-' + version.replace('.', '-')}

    def test_prefers_exact_sdk_then_available_version_in_same_family(self):
        rows = [self.runtime('26.2'), self.runtime('18.6'), self.runtime('18.5'), self.runtime('18.7', False)]
        exact = self.select('18.5', rows)
        self.assertEqual(exact.returncode, 0, exact.stderr)
        self.assertEqual(exact.stdout.strip(), self.runtime('18.5')['identifier'])
        fallback = self.select('18.4', rows)
        self.assertEqual(fallback.returncode, 0, fallback.stderr)
        self.assertEqual(fallback.stdout.strip(), self.runtime('18.6')['identifier'])

    def test_rejects_other_family_and_unavailable_runtime(self):
        result = self.select('18.5', [self.runtime('26.2'), self.runtime('18.5', False)])
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('No available simulator runtime matches selected iOS SDK 18.5', result.stderr)
