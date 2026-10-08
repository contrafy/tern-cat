# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.3.0"]
# ///
"""Render the bundled sprite packs from the code-authored art in tools/art.

Usage: uv run tools/build_packs.py

Writes, for every pack in tools/art/palettes.py:
  assets/packs/<id>/frames/<anim>/NN.png     one PNG per frame
  assets/packs/<id>/build/<anim>.apng        animated PNG (block renderer)
  assets/packs/<id>/build/<anim>.sheet.png   horizontal strip (overlay renderer)
  assets/packs/<id>/pack.json                manifest (schema_version 1)
  assets/packs/<id>/LICENSE.txt              attribution notice
and docs/images/packs-preview.png (contact sheet on light and dark backgrounds).

Output is deterministic: no PNG metadata, fixed compression, stable ordering. Compressed
bytes still depend on the platform's zlib, so an existing image is only rewritten when its
decoded content changes (packlib.same_image); files no longer produced are deleted.
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from art.animations import Anim, all_animations  # noqa: E402
from art.cat import SIZE, render  # noqa: E402
from art.palettes import CAT_INDICES, PACKS, rgba  # noqa: E402
from art.raster import Canvas  # noqa: E402
from packlib import encode_apng, encode_png, encode_sheet, same_image  # noqa: E402

AUTHOR = "Ahmad Raaiyan"
LICENSE = "CC-BY-4.0"
ANCHOR = [16, 31]
PACKS_DIR = ROOT / "assets" / "packs"
PREVIEW = ROOT / "docs" / "images" / "packs-preview.png"
PREVIEW_ANIMS = [
    ("idle", 0),
    ("walk", 0),
    ("sit", 0),
    ("sleep", 2),
    ("groom", 1),
    ("pet", 1),
    ("play", 3),
    ("swat", 2),
    ("startled", 1),
    ("flop", 3),
]
PREVIEW_SCALE = 4
LIGHT_BG = (246, 244, 239, 255)
DARK_BG = (30, 30, 36, 255)


def to_image(canvas: Canvas, pack_id: str) -> Image.Image:
    im = Image.new("RGBA", (canvas.width, canvas.height))
    im.putdata([rgba(pack_id, c) for row in canvas.px for c in row])
    return im


def write_image(path: Path, data: bytes, keep: set[Path]) -> None:
    """Writes `data` unless `path` already decodes to the same image.

    Compressed bytes depend on the platform's zlib, so rebuilding on another OS must not
    rewrite committed images whose content is unchanged.
    """
    keep.add(path)
    if path.is_file() and same_image(path.read_bytes(), data):
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


def prune(root: Path, keep: set[Path]) -> None:
    """Deletes files under `root` that this build did not produce, then empty directories."""
    if not root.is_dir():
        return
    for p in sorted(root.rglob("*"), reverse=True):
        if p.is_file() or p.is_symlink():
            if p not in keep:
                p.unlink()
        elif p.is_dir() and not any(p.iterdir()):
            p.rmdir()


def hitbox(canvases: list[Canvas]) -> list[int]:
    keep = CAT_INDICES + "o"
    boxes = [b for b in (c.bbox(keep) for c in canvases) if b]
    x0 = min(b[0] for b in boxes)
    y0 = min(b[1] for b in boxes)
    x1 = max(b[2] for b in boxes)
    y1 = max(b[3] for b in boxes)
    return [x0, y0, x1 - x0 + 1, y1 - y0 + 1]


def check_frames(anim: Anim, canvases: list[Canvas]) -> None:
    if len(canvases) < 2:
        raise SystemExit(f"{anim.name}: needs at least 2 frames")
    for i in range(1, len(canvases)):
        if canvases[i].px == canvases[i - 1].px:
            # Pillow merges identical consecutive APNG frames, which would break frame counts.
            raise SystemExit(f"{anim.name}: frames {i} and {i + 1} are identical")
    for _, ms in anim.frames:
        if not (isinstance(ms, int) and 40 <= ms <= 10000):
            raise SystemExit(f"{anim.name}: duration {ms} outside 40..10000 ms")


def build_pack(pack_id: str, anims: list[Anim], rendered: dict[str, list[Canvas]]) -> dict[str, list[Image.Image]]:
    out = PACKS_DIR / pack_id
    keep: set[Path] = set()
    images: dict[str, list[Image.Image]] = {}
    manifest_anims: dict[str, dict] = {}
    for anim in anims:
        canvases = rendered[anim.name]
        frames = [to_image(c, pack_id) for c in canvases]
        images[anim.name] = frames
        durations = [ms for _, ms in anim.frames]
        rel_frames = []
        for i, im in enumerate(frames, start=1):
            rel = f"frames/{anim.name}/{i:02d}.png"
            write_image(out / rel, encode_png(im), keep)
            rel_frames.append(rel)
        apng_rel = f"build/{anim.name}.apng"
        try:
            apng = encode_apng(frames, durations, anim.loop)
        except ValueError as e:
            raise SystemExit(f"{out / apng_rel}: {e}") from None
        write_image(out / apng_rel, apng, keep)
        sheet_rel = f"build/{anim.name}.sheet.png"
        write_image(out / sheet_rel, encode_sheet(frames, SIZE, SIZE), keep)
        manifest_anims[anim.name] = {
            "frames": rel_frames,
            "durations_ms": durations,
            "loop": anim.loop,
            "anchor": ANCHOR,
            "hitbox": hitbox(canvases),
            "apng": apng_rel,
            "sheet": sheet_rel,
        }
    for sub in ("frames", "build"):
        prune(out / sub, keep)
    info = PACKS[pack_id]
    manifest = {
        "schema_version": 1,
        "id": pack_id,
        "name": info["name"],
        "author": AUTHOR,
        "license": LICENSE,
        "description": info["description"],
        "canvas": {"width": SIZE, "height": SIZE},
        "animations": manifest_anims,
    }
    (out / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (out / "LICENSE.txt").write_text(
        f"{info['name']} sprite pack for tern-cat\n"
        f"Copyright (c) {AUTHOR}\n\n"
        "Licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0).\n"
        "https://creativecommons.org/licenses/by/4.0/\n\n"
        'Attribution: "' + info["name"] + " sprites by " + AUTHOR + ' (tern-cat), CC BY 4.0".\n'
        "Generated from tools/art by tools/build_packs.py; see assets/CREDITS.md.\n",
        encoding="utf-8",
    )
    return images


def build_preview(all_images: dict[str, dict[str, list[Image.Image]]]) -> None:
    tile = SIZE * PREVIEW_SCALE
    pad = 8
    label_w = 132
    header_h = 24
    font = ImageFont.load_default(size=14)
    rows = [(pack_id, bg) for pack_id in PACKS for bg in (LIGHT_BG, DARK_BG)]
    width = label_w + len(PREVIEW_ANIMS) * (tile + pad) + pad
    height = header_h + pad + len(rows) * (tile + pad)
    sheet = Image.new("RGBA", (width, height), (72, 72, 82, 255))
    draw = ImageDraw.Draw(sheet)
    for col, (name, _) in enumerate(PREVIEW_ANIMS):
        x = label_w + col * (tile + pad)
        draw.text((x + tile // 2, header_h // 2 + 2), name, fill=(235, 235, 240, 255), font=font, anchor="mm")
    for r, (pack_id, bg) in enumerate(rows):
        y = header_h + pad + r * (tile + pad)
        draw.text((pad, y + tile // 2 - 9), PACKS[pack_id]["name"], fill=(235, 235, 240, 255), font=font, anchor="lm")
        mode = "light theme" if bg == LIGHT_BG else "dark theme"
        draw.text((pad, y + tile // 2 + 9), mode, fill=(170, 170, 182, 255), font=font, anchor="lm")
        for col, (name, idx) in enumerate(PREVIEW_ANIMS):
            x = label_w + col * (tile + pad)
            draw.rectangle([x, y, x + tile - 1, y + tile - 1], fill=bg)
            frame = all_images[pack_id][name][idx].resize((tile, tile), Image.NEAREST)
            sheet.alpha_composite(frame, (x, y))
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    sheet.convert("RGB").save(buf, format="PNG", optimize=True)
    write_image(PREVIEW, buf.getvalue(), set())


def main() -> None:
    anims = all_animations()
    rendered: dict[str, list[Canvas]] = {}
    for anim in anims:
        canvases = [render(pose) for pose, _ in anim.frames]
        check_frames(anim, canvases)
        rendered[anim.name] = canvases
    all_images = {}
    for pack_id in PACKS:
        all_images[pack_id] = build_pack(pack_id, anims, rendered)
        print(f"built assets/packs/{pack_id}: {len(anims)} animations")
    build_preview(all_images)
    print(f"wrote {PREVIEW.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
