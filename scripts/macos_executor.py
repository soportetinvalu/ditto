#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""One entry point for an authorized executor, with persistent logs and exit codes.
No toolchain setup, credentials, remote CI, clipboard capture or publication.
"""
import argparse
import json
from pathlib import Path
import platform
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True, help="Fresh authorized artifact/log directory")
    args = parser.parse_args()
    if args.output.exists():
        print("BLOCKED: output directory exists; refusing overwrite")
        return 73
    args.output.mkdir(parents=True, mode=0o700)
    command = ["bash", str(ROOT / "scripts/package_macos.sh"), str(args.output.resolve())]
    result = subprocess.run(command, cwd=ROOT, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    (args.output / "macos-executor.log").write_text(result.stdout)
    summary = {"host": platform.system(), "architecture": platform.machine(), "exit_code": result.returncode,
               "compiled": result.returncode == 0, "published": False, "ui_tcc_acceptance": "pending",
               "log": "macos-executor.log", "command": command}
    (args.output / "result.json").write_text(json.dumps(summary, indent=2) + "\n")
    print(result.stdout, end=""); print(json.dumps(summary, indent=2))
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
