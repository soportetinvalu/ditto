#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise real NSPasteboard/SQLite/AppKit paths and reject isolated regressions.
No general/user pasteboard, profile, TCC changes, browser login, or network.
"""
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
    cases = [
        ("candidate", None, None, None, "ImageCaptureTests", 10),
        ("opening-before-poll", "HistoryController.swift", "        monitor.poll()\n", "", "testImmediateShortcutCapturesAndSelectsNewImageBeforeTimerTick", 1),
        ("fixed-image-whitelist", "Services.swift", " || Self.isImageType(type.rawValue) ||", " ||", "testNativeImageFormatsPreserveBytesAndRoundTripWithoutCustomTypes", 1),
        ("consume-unavailable-image", "Services.swift", "if attempts < 3 { pendingRead = (count, app, attempts) }", "if attempts < 3 { /* regression: already consumed */ }", "testUnavailableImageRetriesSameCountWithoutSavingURLOnlyFragment", 1),
        ("save-url-only-fragment", "Services.swift", "if Self.isImageType(type.rawValue) { retryRead(); return }", "if Self.isImageType(type.rawValue) { continue }", "testUnavailableImageRetriesSameCountWithoutSavingURLOnlyFragment", 1),
        ("keep-stale-opening-selection", "HistoryController.swift", "if selectPending, let row", "if false && selectPending, let row", "testDelayedOpeningCopyUpdatesSelectionButNotAfterUserChoosesAnotherRow", 1),
        ("ignore-concealed-marker", "Services.swift", "guard preferences.allowed(source: app, transient: concealed) else { return }", "guard preferences.allowed(source: app, transient: false) else { return }", "testPrivacyGuardsDoNotMaterializeImageOrRetryAfterPause", 1),
    ]
    records = []
    with tempfile.TemporaryDirectory(prefix="image-capture-", dir=output) as folder:
        checkout = Path(folder) / "source"
        files = subprocess.check_output(["git", "ls-files", "-z"], cwd=ROOT).decode().split("\0")
        for name in filter(None, files):
            source = ROOT / name
            if source.is_symlink():
                raise RuntimeError("Unexpected symlink")
            target = checkout / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        originals = {name: (checkout / "Sources/NexClip" / name).read_text()
                     for name in ["Services.swift", "HistoryController.swift"]}
        for name, filename, old, new, test, count in cases:
            for path, content in originals.items():
                (checkout / "Sources/NexClip" / path).write_text(content)
            if filename:
                assert originals[filename].count(old) == 1, name
                (checkout / "Sources/NexClip" / filename).write_text(originals[filename].replace(old, new))
            selection = test if not filename else "ImageCaptureTests." + test
            result = subprocess.run(["swift", "test", "--scratch-path", str(Path(folder) / "build"),
                                     "--filter", selection], cwd=checkout, text=True,
                                    stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            (output / (name + ".log")).write_text(result.stdout)
            good = (result.returncode == 0 and f"Executed {count} tests" in result.stdout) if not filename else (
                result.returncode != 0 and any(marker in result.stdout for marker in ("XCTAssert", "XCTUnwrap failed")) and
                any("Test Case" in line and test in line and "failed" in line for line in result.stdout.splitlines()))
            row = {"case": name, "exit_code": result.returncode,
                   "expected_assertion_failure": filename is not None, "pass": good}
            records.append(row)
            print(json.dumps(row), flush=True)
            if not good:
                print(result.stdout, flush=True)
                break
    (output / "result.json").write_text(json.dumps(records, indent=2) + "\n")
    return 0 if len(records) == len(cases) and all(row["pass"] for row in records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
