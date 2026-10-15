#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Static completeness/packaging checks. Not a substitute for Swift compilation."""
import ast
from collections import Counter
import hashlib
import json
from pathlib import Path
import plistlib
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / ".verification"
OUT.mkdir(exist_ok=True)
checks = []


def check(name, condition, detail=""):
    checks.append({"name": name, "pass": bool(condition), "detail": detail})
    if not condition:
        raise AssertionError(name + ": " + detail)


def main():
    source = ROOT / "Sources"
    files = sorted(p for p in ROOT.rglob("*") if p.is_file() and not set(p.relative_to(ROOT).parts).intersection({".verification", ".build", ".git", "__pycache__"}))
    matrix = (ROOT / "docs/MATRIZ-20.md").read_text()
    rows = [line.split("|") for line in matrix.splitlines() if re.match(r"\| F\d\d \|", line)]
    identifiers = [row[1].strip() for row in rows]
    check("matrix_20_exact", identifiers == [f"F{i:02d}" for i in range(1, 21)], repr(identifiers))
    states = Counter(row[3].strip() for row in rows)
    check("matrix_states", set(states).issubset({"Implementada", "Pendiente", "No aplicable"}), repr(states))
    for path in ROOT.joinpath("scripts").glob("*.py"):
        ast.parse(path.read_text(), filename=str(path))
    check("python_syntax", True)
    shell = subprocess.run(["bash", "-n", str(ROOT / "scripts/package_macos.sh")], capture_output=True, text=True)
    check("bash_syntax", shell.returncode == 0, shell.stderr)
    with (ROOT / "packaging/Info.plist").open("rb") as stream:
        plist = plistlib.load(stream)
    check("plist_minimum_and_identity", plist["LSUIElement"] is True and plist["CFBundleExecutable"] == "MemoriaLocal" and plist["LSMinimumSystemVersion"] == "13.0")
    license_hash = hashlib.sha256((ROOT / "LICENSE").read_bytes()).hexdigest()
    check("gpl_v3_exact_text", license_hash == "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986")
    swift_tests = (ROOT / "Tests/MemoriaLocalTests/MemoriaLocalTests.swift").read_text()
    check("tests_no_general_board", "NSPasteboard.general" not in swift_tests and "pasteboard: .general" not in swift_tests)
    native_source = "\n".join(p.read_text() for p in source.rglob("*.swift"))
    check("no_network_api_in_sources", not any(token in native_source for token in ["URLSession", "NWListener", "NWConnection", "import Network", "import WebKit", "WKWebView"]))
    check("no_placeholder_traps", not any(token in native_source for token in ["fatalError(", "preconditionFailure(", "TODO", "IMPLEMENT ME"]))
    package = (ROOT / "Package.swift").read_text()
    check("no_remote_packages", ".package(url:" not in package and "dependencies: [.package" not in package)
    inventory = {p.relative_to(ROOT).as_posix(): {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in files}
    result = {"checks": checks, "exit_code": 0, "matrix_states": dict(states),
              "swift_tests_prepared_not_run": len(re.findall(r"    func test\w+\(", swift_tests)),
              "inventory": inventory, "limitations": "Static checks only. No Swift/AppKit compilation or runtime acceptance."}
    (OUT / "source-checks.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({key: value for key, value in result.items() if key != "inventory"}, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
