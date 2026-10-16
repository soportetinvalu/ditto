#!/usr/bin/env python3
"""Offline integrity inspection of a ditto app ZIP (not a macOS trust verdict)."""
import hashlib
import io
import json
import plistlib
import stat
import struct
import sys
import zipfile


def inventory(z):
    return [{"path": i.filename, "size": i.file_size, "mode": oct(i.external_attr >> 16),
             "symlink": z.read(i).decode(errors="replace") if stat.S_ISLNK(i.external_attr >> 16) else None,
             "zip_extra_hex": i.extra.hex(), "appledouble": "/._" in i.filename or i.filename.startswith("__MACOSX/")}
            for i in z.infolist()]


def inspect(path):
    outer = zipfile.ZipFile(path)
    report = {"archive_sha256": hashlib.sha256(open(path, "rb").read()).hexdigest(), "outer_inventory": inventory(outer)}
    if "NexClip-arm64.zip" in outer.namelist():
        manifest = json.loads(outer.read("SHA256SUMS.json"))
        report["manifest_matches"] = {n: hashlib.sha256(outer.read(n)).hexdigest() == h for n, h in manifest.items()}
        report["source_inventory"] = inventory(zipfile.ZipFile(io.BytesIO(outer.read("NexClip-source.zip"))))
        z = zipfile.ZipFile(io.BytesIO(outer.read("NexClip-arm64.zip")))
    else:
        z = outer
    report["app_inventory"] = inventory(z)
    root = next(n for n in z.namelist() if n.endswith(".app/Contents/Info.plist"))[:-len("Info.plist")]
    files = {n[len(root):]: z.read(n) for n in z.namelist() if n.startswith(root) and not n.endswith("/")}
    info = plistlib.loads(files["Info.plist"])
    report["info"] = info
    seals = plistlib.loads(files["_CodeSignature/CodeResources"])
    report["resource_rules"] = {k: v for k, v in seals.items() if k.startswith("rules")}
    checks, sealed = [], set()
    for table in ("files", "files2"):
        for name, entry in seals.get(table, {}).items():
            sealed.add(name)
            if isinstance(entry, bytes):
                entry = {"hash": entry}
            for key, alg in (("hash", "sha1"), ("hash2", "sha256")):
                if key in entry:
                    actual = hashlib.new(alg, files.get(name, b"")).digest()
                    checks.append({"table": table, "path": name, "algorithm": alg, "present": name in files,
                                   "matches": name in files and actual == entry[key]})
    report["resource_checks"] = checks
    exe = "MacOS/" + info["CFBundleExecutable"]
    report["executable_mode_valid"] = bool((z.getinfo(root + exe).external_attr >> 16) & 0o111)
    report["missing_sealed_files"] = sorted(sealed - set(files))
    report["unsealed_files"] = sorted(set(files) - sealed - {"Info.plist", exe} - {n for n in files if n.startswith("_CodeSignature/")})
    data = files[exe]
    magic, cpu, subtype, filetype, count, commands_size, flags, reserved = struct.unpack_from("<8I", data)
    if magic != 0xfeedfacf:
        raise ValueError("Only thin little-endian Mach-O 64-bit supported")
    macho = {"cpu": hex(cpu), "architecture": "arm64" if cpu == 0x100000c else hex(cpu), "uuid": None}
    off, sig = 32, None
    version = lambda v: f"{v >> 16}.{(v >> 8) & 255}.{v & 255}"
    for _ in range(count):
        cmd, size = struct.unpack_from("<II", data, off)
        if cmd == 0x1b:
            macho["uuid"] = data[off+8:off+24].hex()
        if cmd == 0x32:
            platform, minimum, sdk, tools = struct.unpack_from("<4I", data, off+8)
            macho.update(platform=platform, minimum_os=version(minimum), sdk=version(sdk))
        if cmd == 0x24:
            macho["minimum_os"] = version(struct.unpack_from("<I", data, off+8)[0])
        if cmd == 0x1d:
            sig = struct.unpack_from("<II", data, off+8)
        off += size
    report["macho"] = macho
    if not sig:
        raise ValueError("LC_CODE_SIGNATURE absent")
    start, length = sig
    magic, bloblen, blobs = struct.unpack_from(">III", data, start)
    if magic != 0xfade0cc0:
        raise ValueError("Signature is not an embedded superblob")
    entries = {}
    for i in range(blobs):
        slot, offset = struct.unpack_from(">II", data, start+12+i*8)
        bmagic, blen = struct.unpack_from(">II", data, start+offset)
        entries[slot] = data[start+offset:start+offset+blen]
    report["signature_slots"] = {str(k): {"magic": hex(struct.unpack_from(">I", b)[0]), "size": len(b)} for k,b in entries.items()}
    report["requirements_hex"] = entries.get(2, b"").hex()
    report["entitlements"] = plistlib.loads(entries[5][8:]) if 5 in entries else None
    directories = []
    for slot, cd in entries.items():
        if struct.unpack_from(">I", cd)[0] != 0xfade0c02:
            continue
        _, size, version_cd, cdflags, hashoff, identoff, special, code, limit = struct.unpack_from(">9I", cd)
        hashsize, hashtype, platform, pageshift = struct.unpack_from(">4B", cd, 36)
        alg = {1: "sha1", 2: "sha256", 3: "sha256", 4: "sha384"}[hashtype]
        digest = lambda b: hashlib.new(alg, b).digest()[:hashsize]
        result = {"slot": slot, "version": hex(version_cd), "flags": hex(cdflags), "adhoc": bool(cdflags & 2),
                  "runtime": bool(cdflags & 0x10000), "linker_signed": bool(cdflags & 0x20000),
                  "identifier": cd[identoff:cd.index(0, identoff)].decode(), "cdhash": hashlib.new(alg, cd).digest()[:20].hex(),
                  "hash_type": hashtype, "code_limit": limit, "special_slots": [], "code_pages": code}
        payloads = {1: files["Info.plist"], 2: entries.get(2), 3: files["_CodeSignature/CodeResources"], 5: entries.get(5), 7: entries.get(7)}
        for n in range(1, special+1):
            expected = cd[hashoff-n*hashsize:hashoff-(n-1)*hashsize]
            payload = payloads.get(n)
            match = digest(payload) == expected if payload is not None else not any(expected)
            result["special_slots"].append({"slot": n, "expected": expected.hex(), "present": payload is not None, "matches": match})
        pagesize = 1 << pageshift
        bad_pages = [n for n in range(code) if digest(data[n*pagesize:min((n+1)*pagesize, limit)]) != cd[hashoff+n*hashsize:hashoff+(n+1)*hashsize]]
        result["bad_code_pages"] = bad_pages
        directories.append(result)
    report["code_directories"] = directories
    report["static_integrity_ok"] = bool(directories) and all(c["matches"] for c in checks) and not report["missing_sealed_files"] and not report["unsealed_files"] and all(not c["bad_code_pages"] and all(s["matches"] for s in c["special_slots"]) for c in directories)
    report["limits"] = "Hash consistency only; not SecCodeCheckValidity, TCC, notarization or trust on the recipient Mac. ZIP extra/AppleDouble inventoried; no xattrs in ZIP when both absent."
    return report


if __name__ == "__main__":
    result = inspect(sys.argv[1])
    encoded = json.dumps(result, ensure_ascii=False, indent=2) + "\n"
    if len(sys.argv) > 2:
        open(sys.argv[2], "w").write(encoded)
    else:
        print(encoded)
    sys.exit(0 if result["static_integrity_ok"] else 1)
