#!/usr/bin/env python3
"""Verify the production C/SQLite core. Only synthetic data, no user clipboard.
All binaries/fixtures stay under app-macos/.verification and are removed after use.
"""
import json
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".verification"
OUT.mkdir(exist_ok=True)
records = []


def run(name, command, expected=0):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (OUT / (name + ".log")).write_text("$ " + " ".join(map(str, command)) + "\n" + result.stdout + f"\nexit_code={result.returncode}\n")
    record = {"name": name, "exit_code": result.returncode, "expected": expected,
              "pass": result.returncode == expected, "log": str(OUT / (name + ".log"))}
    records.append(record)
    print(name, "PASS" if record["pass"] else "FAIL", "exit_code=" + str(result.returncode), result.stdout.strip())
    return record["pass"]


def main():
    cc = shutil.which("cc")
    if not cc:
        print("BLOCKED: no C compiler")
        return 77
    include = ["-I", str(ROOT / "Sources/ClipCore/include")]
    source = ROOT / "Sources/ClipCore/core.c"
    test = ROOT / "Tests/CoreTests/core_tests.c"
    common = [cc, "-std=c11", "-Wall", "-Wextra", "-Werror", "-pedantic", *include]
    with tempfile.TemporaryDirectory(prefix="fixtures-", dir=OUT) as temporary:
        temp = Path(temporary)
        binary = temp / "core-tests"
        link = ["-lsqlite3"]
        if not run("core-build-sdk", [*common, "-O2", str(source), str(test), *link, "-o", str(binary)]):
            # Header absence is a discovery blocker, not fabricated execution.
            # Use test-only ABI declarations and link to the actual installed SQLite runtime.
            failed_log = Path(records[-1]["log"]).read_text()
            if "sqlite3.h" not in failed_log or not any(message in failed_log for message in ["No such file or directory", "file not found"]):
                return 1
            records[-1]["nonfatal"] = True
            records[-1]["classification"] = "blocked_no_development_header; real runtime ABI fallback attempted"
            if platform.system() != "Linux":
                return 1
            common += ["-DCM_TEST_RUNTIME_ABI", "-I", str(ROOT / "Tests/Support")]
            link = ["-Wl,-l:libsqlite3.so.0"]
            if not run("core-build-runtime-abi", [*common, "-O2", str(source), str(test), *link, "-o", str(binary)]):
                return 1
        (temp / "normal").mkdir()
        if not run("core-tests", [str(binary), str(temp / "normal")]):
            return 1
        # Sanitizers are applied to exactly the shipped C source, not a duplicate implementation.
        sanitized = temp / "sanitized"
        if run("sanitizer-build", [*common, "-O1", "-g", "-fsanitize=address,undefined", "-fno-omit-frame-pointer", str(source), str(test), *link, "-o", str(sanitized)]):
            (temp / "sanitizer-data").mkdir()
            run("sanitizer-tests", [str(sanitized), str(temp / "sanitizer-data")])
        # Sensitivity checks compile altered copies in the temporary directory; production is unchanged.
        mutations = {
            "retention-guard": ("WHERE favorite=0 AND protected=0 AND sticky=0 AND", "WHERE favorite=0 AND sticky=0 AND"),
            "pause-guard": ("if(paused || transient || !source || !*source)", "if((paused && 0) || transient || !source || !*source)")
        }
        original = source.read_text()
        for name, (old, new) in mutations.items():
            assert original.count(old) == 1
            mutated = temp / (name + ".c"); mutated.write_text(original.replace(old, new))
            target = temp / name
            if run(name + "-build", [*common, "-O2", str(mutated), str(test), *link, "-o", str(target)]):
                data = temp / (name + "-data"); data.mkdir()
                run(name + "-sensitivity", [str(target), str(data)], expected=1)
    return 0 if all(r["pass"] or r.get("nonfatal", False) for r in records) else 1


if __name__ == "__main__":
    code = main()
    summary = {"platform": platform.system(), "python": platform.python_version(),
               "production_source_sha256": hashlib.sha256((ROOT / "Sources/ClipCore/core.c").read_bytes()).hexdigest(),
               "tests_source_sha256": hashlib.sha256((ROOT / "Tests/CoreTests/core_tests.c").read_bytes()).hexdigest(),
               "records": records, "exit_code": code,
               "claims": "C/SQLite only; Swift/AppKit are NOT compiled by this script"}
    (OUT / "portable-results.json").write_text(json.dumps(summary, ensure_ascii=False, indent=2) + "\n")
    sys.exit(code)
