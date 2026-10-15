#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Produce corresponding-source archive, never user data, binaries or credentials."""
import hashlib
import json
from pathlib import Path
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
ALLOWED_DIRS = {"Sources", "Tests", "scripts", "packaging", "docs"}
ALLOWED_FILES = {"Package.swift", "LICENSE", "NOTICE", "README.md", ".gitignore"}
EXCLUDE = {"__pycache__", ".build", ".verification", ".git", "dist"}


def main():
    target = Path(sys.argv[1]).resolve()
    files = sorted(p for p in ROOT.rglob("*") if p.is_file() and not p.is_symlink()
                   and not set(p.relative_to(ROOT).parts).intersection(EXCLUDE)
                   and (p.relative_to(ROOT).parts[0] in ALLOWED_DIRS or p.name in ALLOWED_FILES)
                   and (p.suffix in {".swift", ".c", ".h", ".py", ".sh", ".md", ".plist"} or p.name in ALLOWED_FILES)
                   and not p.name.startswith(".env")
                   and ROOT in p.resolve().parents
                   and p.resolve() != target)
    required = {"LICENSE", "NOTICE", "Package.swift", "Sources/ClipCore/core.c", "Sources/MemoriaLocal/App.swift"}
    paths = {p.relative_to(ROOT).as_posix() for p in files}
    if not required.issubset(paths):
        raise SystemExit("BLOCKED: missing source/license files")
    manifest = {p.relative_to(ROOT).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    with zipfile.ZipFile(target, "x", compression=zipfile.ZIP_DEFLATED) as archive:
        for file in files:
            archive.write(file, "MemoriaLocal-source/" + file.relative_to(ROOT).as_posix())
        archive.writestr("MemoriaLocal-source/SOURCE-SHA256.json", json.dumps(manifest, indent=2) + "\n")
    with zipfile.ZipFile(target) as archive:
        assert archive.testzip() is None
        for name, digest in manifest.items():
            assert hashlib.sha256(archive.read("MemoriaLocal-source/" + name)).hexdigest() == digest
    print(f"PASS corresponding source: {len(files)} files; manifest verified")


if __name__ == "__main__":
    main()
