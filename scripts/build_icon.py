#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build/validate PNG-backed ICNS. Pillow is only needed to regenerate assets."""
import argparse
import io
import json
from pathlib import Path
import struct
from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
CHUNKS = {b"icp4": 16, b"icp5": 32, b"icp6": 64, b"ic07": 128, b"ic08": 256,
          b"ic09": 512, b"ic10": 1024, b"ic11": 32, b"ic12": 64, b"ic13": 256, b"ic14": 512}


def validate(data):
    assert data[:4] == b"icns" and struct.unpack(">I", data[4:8])[0] == len(data)
    position = 8
    found = {}
    while position < len(data):
        tag, size = struct.unpack(">4sI", data[position:position + 8])
        assert size > 8 and position + size <= len(data) and tag not in found
        png = data[position + 8:position + size]
        assert png[:8] == b"\x89PNG\r\n\x1a\n"
        image = Image.open(io.BytesIO(png)); image.load()
        assert image.size == (CHUNKS[tag], CHUNKS[tag]) and image.mode == "RGBA"
        assert image.getpixel((0, 0))[3] == 0
        found[tag] = image.width
        position += size
    assert position == len(data) and found == CHUNKS
    return {tag.decode(): pixels for tag, pixels in found.items()}


def extract(original):
    rgb = original.convert("RGB")
    # The bright continuous rim is a barrier. Flood only the exterior; retain dark artwork inside.
    r, g, b = rgb.split()
    barrier = ImageChops.lighter(ImageChops.lighter(r, g), b).point(lambda value: 255 if value > 70 else 0)
    ImageDraw.floodfill(barrier, (0, 0), 128, thresh=0)
    solid = barrier.point(lambda value: 0 if value == 128 else 255)
    # Retain only the enclosed central squircle, not compression specks in the black exterior.
    ImageDraw.floodfill(solid, (rgb.width // 2, rgb.height // 2), 128, thresh=0)
    mask = solid.point(lambda value: 255 if value == 128 else 0).filter(ImageFilter.MedianFilter(7))
    box = mask.getbbox()
    assert box is not None and box[2] - box[0] > rgb.width * 0.7
    image = rgb.convert("RGBA"); image.putalpha(mask)
    image = image.crop(box)
    side = max(image.size)
    square = Image.new("RGBA", (side, side))
    square.paste(image, ((side - image.width) // 2, (side - image.height) // 2))
    canvas = Image.new("RGBA", (1024, 1024))
    graphic = square.resize((820, 820), Image.Resampling.LANCZOS)
    canvas.paste(graphic, (102, 102))
    return canvas, box


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("--master", action="store_true", help="input is the existing transparent 1024px master")
    parser.add_argument("--preview", type=Path)
    args = parser.parse_args()
    original = Image.open(args.input)
    master, box = (original.convert("RGBA"), None) if args.master else extract(original)
    assert master.size == (1024, 1024)
    packaging = ROOT / "packaging"
    master.save(packaging / "AppIcon.png")
    iconset = packaging / "AppIcon.iconset"; iconset.mkdir(exist_ok=True)
    for points in (16, 32, 64, 128, 256, 512):
        for scale in (1, 2):
            master.resize((points * scale, points * scale), Image.Resampling.LANCZOS).save(
                iconset / (f"icon_{points}x{points}" + ("@2x" if scale == 2 else "") + ".png"))
    chunks = []
    for tag, pixels in CHUNKS.items():
        stream = io.BytesIO()
        master.resize((pixels, pixels), Image.Resampling.LANCZOS).save(stream, format="PNG")
        payload = stream.getvalue()
        chunks.append(tag + struct.pack(">I", len(payload) + 8) + payload)
    body = b"".join(chunks)
    path = packaging / "AppIcon.icns"
    path.write_bytes(b"icns" + struct.pack(">I", len(body) + 8) + body)
    sizes = validate(path.read_bytes())
    if args.preview:
        args.preview.parent.mkdir(parents=True, exist_ok=True)
        master.resize((512, 512), Image.Resampling.LANCZOS).save(args.preview)
    print(json.dumps({"detected_rim_bbox": box, "alpha_bbox": master.getchannel("A").getbbox(),
                      "graphic_canvas_fraction": 820 / 1024, "chunks": sizes, "bytes": path.stat().st_size}))


if __name__ == "__main__":
    main()
