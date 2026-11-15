#!/usr/bin/env python3
"""Reject desktop binaries/caches and non-Apple dylib dependencies in an iOS app."""
import argparse
from pathlib import Path
import re
import subprocess


def audit_resources(app):
    errors = []
    for path in app.rglob('*'):
        if not path.is_file():
            continue
        if path.suffix.lower() in {'.opc', '.dll', '.exe', '.so', '.pdb', '.lib', '.a'} or '.so.' in path.name.lower():
            errors.append(f'Desktop binary or cache: {path.relative_to(app)}')
        with path.open('rb') as stream:
            magic = stream.read(4)
        if magic == b'\x7fELF' or magic[:2] == b'MZ':
            errors.append(f'Linux/Windows executable: {path.relative_to(app)}')
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('app', type=Path)
    parser.add_argument('sdk', choices=['iphoneos', 'iphonesimulator'])
    args = parser.parse_args()
    if not args.app.is_dir():
        parser.error('App bundle does not exist')
    errors = audit_resources(args.app)
    if errors:
        raise SystemExit('\n'.join(errors))
    import plistlib
    with (args.app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    executable = args.app / info['CFBundleExecutable']
    binaries = [executable] + list((args.app / 'Frameworks').glob('*.dylib'))
    expected = 'IOS' if args.sdk == 'iphoneos' else 'IOSSIMULATOR'
    for binary in binaries:
        build = subprocess.check_output(['xcrun', 'vtool', '-show-build', str(binary)], text=True)
        platforms = re.findall(r'^\s*platform\s+(\S+)', build, flags=re.MULTILINE)
        if not platforms or any(platform != expected for platform in platforms):
            raise SystemExit(f'Wrong platform for {binary.name}: {platforms}, expected {expected}')
        linked = subprocess.check_output(['otool', '-L', str(binary)], text=True)
        for line in linked.splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/System/Library/', '/usr/lib/', '@rpath/libswift')):
                continue
            raise SystemExit(f'Unexpected dynamic dependency in {binary.name}: {dependency}')
    print(f'PASS: {args.sdk} bundle has no desktop executables/caches and uses iOS binaries and Apple runtime libraries')


if __name__ == '__main__':
    main()
