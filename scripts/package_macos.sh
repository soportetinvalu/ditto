#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# For an authorized macOS executor. Does not install, publish, grant permissions or launch the app.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ "$(uname -s)" != "Darwin" ]]; then
  printf '%s\n' 'BLOCKED: macOS SDK/AppKit required; no .app was produced.' >&2
  exit 77
fi
if [[ "$(uname -m)" != "arm64" ]]; then
  printf '%s\n' 'BLOCKED: this acceptance path requires a native arm64 macOS executor.' >&2
  exit 77
fi
for tool in swift xcrun xcode-select codesign ditto plutil python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    printf 'BLOCKED: required existing tool missing: %s (nothing installed).\n' "$tool" >&2
    exit 77
  fi
done
if ! xcode-select -p >/dev/null 2>&1; then
  printf '%s\n' 'BLOCKED: no existing developer tools selected; nothing installed.' >&2
  exit 77
fi
OUT="${1:?Executor must supply an authorized output directory}"
mkdir -p "$OUT"
OUT="$(cd "$OUT" && pwd)"
BUILD="$OUT/build"
APP="$OUT/Memoria Local.app"
if [[ -e "$APP" || -e "$OUT/MemoriaLocal-source.zip" || -e "$OUT/MemoriaLocal-arm64.zip" ]]; then
  printf '%s\n' 'BLOCKED: output already exists; choose a fresh directory. No artifacts overwritten.' >&2
  exit 73
fi
cd "$ROOT"
xcrun --sdk macosx --show-sdk-path
swift --version
# Tests use synthetic records and a named pasteboard, never NSPasteboard.general.
swift test --scratch-path "$BUILD" -c debug
swift build --scratch-path "$BUILD" -c release --arch arm64
BIN="$(swift build --scratch-path "$BUILD" -c release --arch arm64 --show-bin-path)"
"$BIN/MemoriaLocal" --self-check
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/MemoriaLocal" "$APP/Contents/MacOS/MemoriaLocal"
cp "$ROOT/packaging/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$ROOT/README.md" "$APP/Contents/Resources/"
plutil -lint "$APP/Contents/Info.plist"
# Local ad-hoc signing only; not Developer ID, notarization or permission bypass.
codesign --force --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
# Corresponding source is always delivered alongside the binary, with exact file hashes.
python3 "$ROOT/scripts/source_archive.py" "$OUT/MemoriaLocal-source.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$OUT/MemoriaLocal-arm64.zip"
python3 -c 'import hashlib,json,pathlib,sys; p=pathlib.Path(sys.argv[1]); files=[p/"MemoriaLocal-source.zip",p/"MemoriaLocal-arm64.zip"]; (p/"SHA256SUMS.json").write_text(json.dumps({f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in files},indent=2)+"\n")' "$OUT"
printf '%s\n' 'PASS: compiled/tested, local ad-hoc .app + corresponding source. Not notarized or published. UI/TCC acceptance still required.'
