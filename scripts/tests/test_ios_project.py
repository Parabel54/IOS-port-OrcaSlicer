"""Generator checks without Xcode, SDKs, or real engine archives."""
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[2] / 'ios/generate_xcodeproj.py'


class ProjectGenerationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'ios').mkdir()
        shutil.copy(SOURCE, self.root / 'ios/generate_xcodeproj.py')
        profiles = self.root / 'resources/profiles'
        profiles.mkdir(parents=True)
        (profiles / 'vendor.json').write_text('{}')

    def generate(self, sdk):
        return subprocess.run([sys.executable, str(self.root / 'ios/generate_xcodeproj.py'),
                               '--require-engine', sdk], capture_output=True, text=True)

    def engine(self, sdk):
        archive = self.root / f'build-ios-{sdk}-arm64/engine_bundle/lib/liborca_engine.a'
        archive.parent.mkdir(parents=True, exist_ok=True)
        archive.write_bytes(b'!<arch>\n')
        return archive

    def test_rejects_missing_empty_and_wrong_sdk_archives(self):
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)
        self.engine('iphonesimulator')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)
        self.engine('iphoneos').write_bytes(b'')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)

    def test_linked_project_is_stable_and_refreshes_profiles(self):
        self.engine('iphoneos')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        project = self.root / 'ios/OrcaSlicer.xcodeproj/project.pbxproj'
        first = project.read_bytes()
        self.assertIn(b'ORCA_LINKED', first)
        self.assertIn(b'iphoneos*', first)
        stale = self.root / 'ios/OrcaSlicerApp/Resources/profiles/stale.json'
        stale.write_text('{}')
        result = self.generate('iphoneos')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(first, project.read_bytes())
        self.assertFalse(stale.exists())

    def test_requires_profiles(self):
        self.engine('iphoneos')
        shutil.rmtree(self.root / 'resources/profiles')
        self.assertNotEqual(self.generate('iphoneos').returncode, 0)


if __name__ == '__main__':
    unittest.main()
