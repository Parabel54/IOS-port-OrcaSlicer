#!/usr/bin/env python3
"""Accept actual production-renderer results only for the requested checkout."""
import json
import sys
from pathlib import Path

EXPECTED_TESTS = {"camera", "painted_filaments_gpu", "progressive_ranges", "progressive_gpu", "preview_geometry"}


def validate(result, source):
    if result.get("source") != source:
        raise ValueError("Renderer receipt belongs to a different source checkout")
    if result.get("completed") is not True:
        raise ValueError("Renderer receipt is incomplete")
    tests = result.get("tests")
    if not isinstance(tests, dict) or not EXPECTED_TESTS.issubset(tests):
        raise ValueError("Renderer receipt is missing required tests")
    if result.get("passed") is not True or any(value is not True for value in tests.values()):
        raise ValueError("Renderer tests failed")
    return tests


def main():
    try:
        tests = validate(json.loads(Path(sys.argv[1]).read_text()), sys.argv[2])
    except (OSError, ValueError, TypeError, AttributeError) as error:
        raise SystemExit(str(error)) from error
    for name in sorted(tests):
        print("PASS: " + name)


if __name__ == "__main__":
    main()
