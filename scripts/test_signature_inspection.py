#!/usr/bin/env python3
"""Negative controls against a real supplied artifact; never runs its executable."""
import copy
import io
import json
from pathlib import Path
import sys
import tempfile
import zipfile
from inspect_macos_signature import inspect

outer = zipfile.ZipFile(sys.argv[1])
inner = zipfile.ZipFile(io.BytesIO(outer.read("NexClip-arm64.zip")))
root = "NexClip.app/Contents/"
controls = {"resource": root + "Resources/README.md", "plist": root + "Info.plist",
            "code": root + "MacOS/NexClip", "missing": root + "Resources/NOTICE",
            "unsealed": root + "checksums.txt"}
results = {}
with tempfile.TemporaryDirectory(dir=Path(__file__).resolve().parents[1] / ".verification") as tmp:
    for label, target in controls.items():
        path = Path(tmp) / (label + ".zip")
        with zipfile.ZipFile(path, "w") as z:
            for entry in inner.infolist():
                if label == "missing" and entry.filename == target:
                    continue
                data = inner.read(entry)
                if entry.filename == target:
                    if label == "code":
                        data = data[:4096] + bytes([data[4096] ^ 1]) + data[4097:]
                    else:
                        data += b"\n"
                z.writestr(copy.copy(entry), data)
            if label == "unsealed":
                z.writestr(target, b"test-only unsigned file")
        report = inspect(path)
        results[label] = not report["static_integrity_ok"]
assert all(results.values()), results
print(json.dumps({"negative_controls_rejected": results, "pass": True}, indent=2))
