# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.3.0"]
# ///
"""Render the pane-transition props (portal, vent, box) from the code-authored art in tools/art.

Usage: uv run tools/build_portals.py

Writes:
  assets/portals/<style>/<enter|exit>-<back|front>.sheet.png   horizontal frame strips
  assets/portals/portals.json                                  manifest (schema_version 1)
  assets/portals/LICENSE.txt                                   attribution notice
and docs/images/portals-preview.png: every style's enter and exit timeline composited with
Orange Menace's emerge and dive at the anchor, on light and dark backgrounds.

Deterministic like tools/build_packs.py: images are only rewritten when their decoded
content changes, and files no longer produced are deleted.
"""

from __future__ import annotations

import io
import json
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))

from art import portals as PT  # noqa: E402
from art.animations import Anim, all_animations  # noqa: E402
from art.cat import SIZE, render  # noqa: E402
from art.palettes import rgba as cat_rgba  # noqa: E402
from art.raster import Canvas  # noqa: E402
from packlib import encode_sheet, prune, write_image  # noqa: E402

AUTHOR = "Ahmad Raaiyan"
PORTALS_DIR = ROOT / "assets" / "portals"
PREVIEW = ROOT / "docs" / "images" / "portals-preview.png"
PREVIEW_PACK = "orange-menace"
PREVIEW_SCALE = 4
LIGHT_BG = (246, 244, 239, 255)
DARK_BG = (30, 30, 36, 255)
# Cat timelines that start together with each prop timeline.
CAT_FOR = {"enter": "emerge", "exit": "dive"}
TOTAL_MS = {"enter": PT.ENTER_MS, "exit": PT.EXIT_MS}


def to_image(canvas: Canvas) -> Image.Image:
    im = Image.new("RGBA", (canvas.width, canvas.height))
    im.putdata([PT.rgba(c) for row in canvas.px for c in row])
    return im


def check_timeline(style: PT.Style, phase: str, frames: list[PT.Frame]) -> None:
    where = f"{style.id}.{phase}"
    durations = [f.ms for f in frames]
    if not 2 <= len(frames) <= 64:
        raise SystemExit(f"{where}: needs 2..64 frames (got {len(frames)})")
    if any(not 40 <= ms <= 10000 for ms in durations):
        raise SystemExit(f"{where}: durations must be 40..10000 ms (got {durations})")
    if sum(durations) != TOTAL_MS[phase]:
        raise SystemExit(f"{where}: durations total {sum(durations)} ms, expected {TOTAL_MS[phase]}")
    if phase == "exit" and len(set(durations)) != 1:
        raise SystemExit(f"{where}: exit frames must share one duration (CSS transitions step evenly)")
    last = frames[-1]
    if last.back.bbox() is not None or (last.front is not None and last.front.bbox() is not None):
        raise SystemExit(f"{where}: the last frame must be empty (it is the held end state)")
    fronts = {f.front is None for f in frames}
    if len(fronts) != 1:
        raise SystemExit(f"{where}: either every frame or no frame has a front layer")


def layer_entry(rel: str, frames: list[Canvas], durations: list[int]) -> dict:
    return {"sheet": rel, "frames": len(frames), "durations_ms": durations}


def build_assets(styles: list[PT.Style]) -> None:
    keep: set[Path] = set()
    manifest_styles: dict[str, dict] = {}
    for style in styles:
        entry: dict[str, object] = {"name": style.name}
        for phase, frames in (("enter", style.enter), ("exit", style.exit)):
            check_timeline(style, phase, frames)
            durations = [f.ms for f in frames]
            layers: dict[str, dict] = {}
            for layer in ("back", "front"):
                canvases = [getattr(f, layer) for f in frames]
                if canvases[0] is None:
                    continue
                rel = f"{style.id}/{phase}-{layer}.sheet.png"
                images = [to_image(c) for c in canvases]
                write_image(PORTALS_DIR / rel, encode_sheet(images, PT.FRAME_W, PT.FRAME_H), keep)
                layers[layer] = layer_entry(rel, canvases, durations)
            entry[phase] = layers
        manifest_styles[style.id] = entry
    for style in styles:
        prune(PORTALS_DIR / style.id, keep)
    for p in sorted(PORTALS_DIR.iterdir()):
        if p.is_dir() and p.name not in manifest_styles:
            prune(p, set())
            if p.is_dir() and not any(p.iterdir()):
                p.rmdir()
    manifest = {
        "schema_version": 1,
        "frame": {"width": PT.FRAME_W, "height": PT.FRAME_H},
        "anchor": list(PT.ANCHOR),
        "styles": manifest_styles,
    }
    (PORTALS_DIR / "portals.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    (PORTALS_DIR / "LICENSE.txt").write_text(
        "Pane-transition props (swirly portal, floor vent, cardboard box) for tern-cat\n"
        f"Copyright (c) {AUTHOR}\n\n"
        "Licensed under the Creative Commons Attribution 4.0 International License (CC BY 4.0).\n"
        "https://creativecommons.org/licenses/by/4.0/\n\n"
        f'Attribution: "Transition props by {AUTHOR} (tern-cat), CC BY 4.0".\n'
        "Generated from tools/art/portals.py by tools/build_portals.py; see assets/CREDITS.md.\n",
        encoding="utf-8",
    )


def at(durations: list[int], t: int) -> int:
    """Index of the frame showing at `t` ms (the last frame holds after the end)."""
    acc = 0
    for i, ms in enumerate(durations):
        acc += ms
        if t < acc:
            return i
    return len(durations) - 1


def build_preview(styles: list[PT.Style], anims: dict[str, Anim]) -> None:
    s = PREVIEW_SCALE
    # Composite box in prop pixels: the cat frame stands on the anchor and may rise above the prop.
    cat_x = PT.ANCHOR[0] - SIZE // 2
    cat_y = PT.ANCHOR[1] - SIZE
    top = min(0, cat_y)
    box_w, box_h = PT.FRAME_W, PT.FRAME_H - top
    tile_w, tile_h = box_w * s, box_h * s
    pad = 8
    label_w = 150
    time_h = 18
    font = ImageFont.load_default(size=14)
    small = ImageFont.load_default(size=12)
    cat_frames = {name: [cat_image(render(pose)) for pose, _ in anims[name].frames] for name in CAT_FOR.values()}
    cat_durations = {name: [ms for _, ms in anims[name].frames] for name in CAT_FOR.values()}
    rows: list[tuple[PT.Style, str, list[int], tuple[int, int, int, int]]] = []
    for style in styles:
        for phase, frames in (("enter", style.enter), ("exit", style.exit)):
            cat = CAT_FOR[phase]
            times = sorted(set(starts([f.ms for f in frames])) | set(starts(cat_durations[cat])))
            for bg in (LIGHT_BG, DARK_BG):
                rows.append((style, phase, times, bg))
    cols = max(len(r[2]) for r in rows)
    width = label_w + cols * (tile_w + pad) + pad
    height = pad + len(rows) * (tile_h + time_h + pad)
    sheet = Image.new("RGBA", (width, height), (72, 72, 82, 255))
    draw = ImageDraw.Draw(sheet)
    for r, (style, phase, times, bg) in enumerate(rows):
        y = pad + r * (tile_h + time_h + pad)
        frames = style.enter if phase == "enter" else style.exit
        durations = [f.ms for f in frames]
        cat = CAT_FOR[phase]
        draw.text((pad, y + tile_h // 2 - 18), style.name, fill=(235, 235, 240, 255), font=font, anchor="lm")
        draw.text((pad, y + tile_h // 2), f"{phase} + {cat}", fill=(235, 235, 240, 255), font=font, anchor="lm")
        mode = "light theme" if bg == LIGHT_BG else "dark theme"
        draw.text((pad, y + tile_h // 2 + 18), mode, fill=(170, 170, 182, 255), font=font, anchor="lm")
        for col, t in enumerate(times):
            x = label_w + col * (tile_w + pad)
            frame = frames[at(durations, t)]
            tile = Image.new("RGBA", (box_w, box_h), bg)
            tile.alpha_composite(to_image(frame.back), (0, -top))
            tile.alpha_composite(cat_frames[cat][at(cat_durations[cat], t)], (cat_x, cat_y - top))
            if frame.front is not None:
                tile.alpha_composite(to_image(frame.front), (0, -top))
            sheet.alpha_composite(tile.resize((tile_w, tile_h), Image.NEAREST), (x, y))
            draw.text(
                (x + tile_w // 2, y + tile_h + time_h // 2),
                f"{t} ms",
                fill=(200, 200, 210, 255),
                font=small,
                anchor="mm",
            )
    PREVIEW.parent.mkdir(parents=True, exist_ok=True)
    buf = io.BytesIO()
    sheet.convert("RGB").save(buf, format="PNG", optimize=True)
    write_image(PREVIEW, buf.getvalue(), set())


def starts(durations: list[int]) -> list[int]:
    out, acc = [], 0
    for ms in durations:
        out.append(acc)
        acc += ms
    return out


def cat_image(canvas: Canvas) -> Image.Image:
    im = Image.new("RGBA", (canvas.width, canvas.height))
    im.putdata([cat_rgba(PREVIEW_PACK, c) for row in canvas.px for c in row])
    return im


def main() -> None:
    styles = PT.all_styles()
    build_assets(styles)
    print(f"built assets/portals: {', '.join(s.id for s in styles)}")
    build_preview(styles, {a.name: a for a in all_animations()})
    print(f"wrote {PREVIEW.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
