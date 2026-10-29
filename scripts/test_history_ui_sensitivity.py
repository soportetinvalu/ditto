#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Run real AppKit regression tests against reversible, isolated UI mutants."""
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    output = Path(sys.argv[1]).resolve()
    output.mkdir(parents=True, exist_ok=True)
    records = []
    with tempfile.TemporaryDirectory(prefix="history-ui-", dir=output) as folder:
        checkout = Path(folder) / "source"
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        for name in filter(None, files):
            source = ROOT / name
            if source.is_symlink():
                raise RuntimeError("Unexpected symlink in tracked source")
            target = checkout / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        history = checkout / "Sources/NexClip/HistoryController.swift"
        original = history.read_text()
        cases = [
            ("candidate", None, None, "NexClipTests.testHistory|NexClipTests.testNumberingDoesNotExtend", False, None),
            ("dots-after-nine", 'labelWithString: "\\(row + 1)"',
             'labelWithString: row < 9 ? "\\(row + 1)" : "·"',
             "NexClipTests.testHistoryNumberingContinuesPastNineAndRestartsAfterFiltering", True,
             "testHistoryNumberingContinuesPastNineAndRestartsAfterFiltering"),
            ("fixed-narrow-column", "max(33, ceil((String(max(1, count)) as NSString).size(withAttributes: [.font: numberFont]).width) + 16)",
             "33", "NexClipTests.testHistoryNumberColumnFitsLargePositionsAndShrinksAfterFiltering", True,
             "testHistoryNumberColumnFitsLargePositionsAndShrinksAfterFiltering"),
            ("notice-restored", "NSStackView(views: [top, scroll, bottom, information])",
             'NSStackView(views: [top, NSTextField(labelWithString: "macOS está protegiendo el teclado"), scroll, bottom, information])',
             "NexClipTests.testHistoryHasNoKeyboardProtectionNoticeWithSecureInputOnOrOff", True,
             "testHistoryHasNoKeyboardProtectionNoticeWithSecureInputOnOrOff"),
        ]
        try:
            for name, old, new, test, expect_failure, marker in cases:
                if old is not None:
                    assert original.count(old) == 1, name
                    history.write_text(original.replace(old, new))
                else:
                    history.write_text(original)
                result = subprocess.run(["swift", "test", "--scratch-path", str(Path(folder) / "build"),
                                         "--filter", test], cwd=checkout, text=True,
                                        stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
                (output / (name + ".log")).write_text(result.stdout)
                # Require an XCTest assertion failure, never accept compile/host errors as sensitivity.
                passed = (result.returncode == 0 and "Executed 4 tests" in result.stdout) if not expect_failure else (
                    result.returncode != 0 and any("Test Case" in line and marker in line and "failed" in line
                                                   for line in result.stdout.splitlines())
                    and "XCTAssert" in result.stdout)
                records.append({"case": name, "exit_code": result.returncode,
                                "expected_assertion_failure": expect_failure, "pass": passed})
                print(json.dumps(records[-1]), flush=True)
                if not passed:
                    print(result.stdout, flush=True)
                    break
        finally:
            history.write_text(original)
    (output / "result.json").write_text(json.dumps(records, indent=2) + "\n")
    return 0 if len(records) == len(cases) and all(row["pass"] for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
