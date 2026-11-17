"""Keep SDK/runtime selection shared by engine and standalone graphics checks."""
import json
import importlib.util
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


class RendererReceiptTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        path = HELPER.with_name('check_ios_preview_receipt.py')
        spec = importlib.util.spec_from_file_location('renderer_receipt', path)
        cls.module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.module)

    def receipt(self):
        return {'source': 'current-checkout', 'passed': True, 'completed': True,
                'tests': {name: True for name in self.module.EXPECTED_TESTS}}

    def test_accepts_all_required_checks_from_current_source(self):
        self.assertEqual(set(self.module.validate(self.receipt(), 'current-checkout')), self.module.EXPECTED_TESTS)

    def test_rejects_stale_missing_and_inconsistent_green_receipts(self):
        cases = []
        incomplete = self.receipt(); incomplete['completed'] = False; cases.append(incomplete)
        missing_completion = self.receipt(); del missing_completion['completed']; cases.append(missing_completion)
        stale = self.receipt(); stale['source'] = 'old-checkout'; cases.append(stale)
        missing = self.receipt(); del missing['tests']['progressive_gpu']; cases.append(missing)
        failed = self.receipt(); failed['tests']['progressive_gpu'] = False; cases.append(failed)
        wrong_type = self.receipt(); wrong_type['tests']['progressive_gpu'] = 1; cases.append(wrong_type)
        empty = self.receipt(); empty['tests'] = {}; cases.append(empty)
        green = self.receipt(); green['passed'] = False; cases.append(green)
        for receipt in cases:
            with self.subTest(receipt=receipt), self.assertRaises(ValueError):
                self.module.validate(receipt, 'current-checkout')
