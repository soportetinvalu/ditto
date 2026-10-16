#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
# Firma el bundle recibido; no cambia su nombre ni su identificador.
set +x # Nunca heredar tracing al importar secretos.
set -euo pipefail
umask 077
APP="${1:?Supply the app bundle}"
PUBLIC_CERT="${2:?Supply the public DER certificate output path}"
IDENTITY="NexClip Developer"
TEMP=""
KEYCHAIN=""
ORIGINAL_KEYCHAINS=()
SEARCH_CHANGED=false
cleanup() {
  local rc=$?
  trap - EXIT
  set +e
  local cleanup_failed=false
  if [[ "$SEARCH_CHANGED" == true ]]; then
    security list-keychains -d user -s "${ORIGINAL_KEYCHAINS[@]}" || cleanup_failed=true
  fi
  if [[ -n "$KEYCHAIN" && -e "$KEYCHAIN" ]]; then
    security delete-keychain "$KEYCHAIN" || cleanup_failed=true
  fi
  if [[ -n "$TEMP" ]]; then rm -rf "$TEMP"; fi
  if [[ "$cleanup_failed" == true ]]; then
    printf '%s\n' 'ERROR: signing keychain cleanup failed.' >&2
    [[ "$rc" != 0 ]] || rc=1
  else
    printf '%s\n' 'PASS: temporary signing material and keychain removed; search list restored.'
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

STABLE=false
if [[ -n "${MACOS_CODESIGN_P12_BASE64:-}" && -n "${MACOS_CODESIGN_P12_PASSWORD:-}" ]]; then
  STABLE=true
  # Kept outside OUTPUT_DIR so artifact/source globs can never collect the identity.
  if [[ -n "${MACOS_CODESIGN_TEMP_DIR:-}" ]]; then
    mkdir -m 700 "$MACOS_CODESIGN_TEMP_DIR"
    TEMP="$MACOS_CODESIGN_TEMP_DIR"
  else
    TEMP="$(mktemp -d "${TMPDIR:-/tmp}/nexclip-sign.XXXXXX")"
  fi
  KEYCHAIN="$TEMP/signing.keychain-db"
  KEYCHAIN_PASSWORD="$(openssl rand -hex 32)"
  printf '::add-mask::%s\n' "$KEYCHAIN_PASSWORD"
  python3 - "$TEMP/identity.p12" <<'PY'
import base64, os, pathlib, sys
try:
    data = base64.b64decode(os.environ['MACOS_CODESIGN_P12_BASE64'], validate=True)
    if not data:
        raise ValueError()
    pathlib.Path(sys.argv[1]).write_bytes(data)
except Exception:
    raise SystemExit('ERROR: invalid or empty signing identity encoding (value withheld).')
PY
  security list-keychains -d user > "$TEMP/original-keychains.txt"
  while IFS= read -r item; do ORIGINAL_KEYCHAINS+=("$item"); done < <(
    python3 - "$TEMP/original-keychains.txt" <<'PY'
import pathlib, shlex, sys
for item in shlex.split(pathlib.Path(sys.argv[1]).read_text()):
    print(item)
PY
  )
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  security set-keychain-settings -lut 21600 "$KEYCHAIN"
  security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
  SEARCH_CHANGED=true
  security list-keychains -d user -s "$KEYCHAIN" "${ORIGINAL_KEYCHAINS[@]}"
  security import "$TEMP/identity.p12" -k "$KEYCHAIN" -P "$MACOS_CODESIGN_P12_PASSWORD" -T /usr/bin/codesign
  # No -A (arbitrary applications) and no permanent/system trust settings.
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
  rm -f "$TEMP/identity.p12"
  unset MACOS_CODESIGN_P12_BASE64 MACOS_CODESIGN_P12_PASSWORD
  security find-identity -p codesigning "$KEYCHAIN"
  security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" > "$TEMP/public.pem"
  openssl x509 -in "$TEMP/public.pem" -outform DER -out "$PUBLIC_CERT"
  openssl x509 -in "$TEMP/public.pem" -noout -sha256 -fingerprint -subject
  codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY" "$APP"
else
  printf '%s\n' '::warning::Signing secrets unavailable: using ad hoc signing. Stable TCC identity is NOT provided by this build.'
  codesign --force --timestamp=none --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"
DR="$(codesign -d -r- "$APP" 2>&1)"
DETAILS="$(codesign -dvv "$APP" 2>&1)"
printf '%s\n' "$DR" "$DETAILS"
if [[ "$STABLE" == true ]]; then
  # Check the designated requirement, not CDHash in the verbose signature metadata.
  DESIGNATED="$(printf '%s\n' "$DR" | grep '^designated =>')"
  if ! printf '%s\n' "$DESIGNATED" | grep -Eq 'anchor|certificate (leaf|0)'; then
    printf '%s\n' 'ERROR: designated requirement has no certificate anchor.' >&2
    exit 1
  fi
  if printf '%s\n' "$DESIGNATED" | grep -qi 'cdhash'; then
    printf '%s\n' 'ERROR: designated requirement depends on this build cdhash.' >&2
    exit 1
  fi
  printf '%s\n' "$DETAILS" | grep -Fx "Authority=$IDENTITY"
  printf '%s\n' 'PASS: stable certificate-based designated requirement; no hardened runtime or notarization.'
fi
