# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""Regenerate the small sprite-pack fixtures under tests/fixtures/packs.

Usage (from the repo root): uv run tools/make_fixtures.py

Every pack is tiny (16x16 canvas) so the committed fixtures stay well under 100 KB.
Pathologically large inputs (oversized files, 20 MiB reads) are synthesized in the specs
with in-memory filesystem adapters instead of being committed.
"""

from __future__ import annotations

import json
import shutil
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent / "tests" / "fixtures" / "packs"
CANVAS = 16
ORANGE = (232, 128, 40, 255)
CREAM = (250, 225, 190, 255)


def frame(i: int, w: int = CANVAS, h: int = CANVAS) -> Image.Image:
    img = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    for y in range(h // 2, h):
        for x in range(2, w - 2):
            img.putpixel((x, y), ORANGE)
    img.putpixel(((3 + i) % w, h // 2), CREAM)
    return img


def save_png(path: Path, img: Image.Image) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, format="PNG", optimize=True)


def save_apng(path: Path, frames: list[Image.Image], durations: list[int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    frames[0].save(
        path,
        format="PNG",
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=1,
        blend=0,
        default_image=False,
    )


def save_sheet(path: Path, frames: list[Image.Image]) -> None:
    w, h = frames[0].size
    sheet = Image.new("RGBA", (w * len(frames), h), (0, 0, 0, 0))
    for i, f in enumerate(frames):
        sheet.paste(f, (i * w, 0))
    save_png(path, sheet)


def write_manifest(pack: Path, manifest: dict) -> None:
    pack.mkdir(parents=True, exist_ok=True)
    (pack / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n")


def base(pack_id: str, animations: dict, canvas: int = CANVAS) -> dict:
    return {
        "schema_version": 1,
        "id": pack_id,
        "name": pack_id.replace("-", " ").title(),
        "license": "CC0-1.0",
        "canvas": {"width": canvas, "height": canvas},
        "animations": animations,
    }


def idle_frames(pack: Path, count: int = 2) -> list[str]:
    names = []
    for i in range(count):
        name = f"idle_{i}.png"
        save_png(pack / name, frame(i))
        names.append(name)
    return names


def good_minimal() -> None:
    pack = ROOT / "good-minimal"
    names = idle_frames(pack)
    imgs = [frame(i) for i in range(2)]
    save_apng(pack / "idle.apng", imgs, [400, 200])
    save_sheet(pack / "idle_sheet.png", imgs)
    write_manifest(
        pack,
        base(
            "good-minimal",
            {
                "idle": {
                    "frames": names,
                    "durations_ms": [400, 200],
                    "loop": True,
                    "apng": "idle.apng",
                    "sheet": "idle_sheet.png",
                }
            },
        ),
    )


def good_full() -> None:
    pack = ROOT / "good-full"
    names = idle_frames(pack)
    walk = [frame(i + 4) for i in range(3)]
    walk_names = []
    for i, img in enumerate(walk):
        name = f"frames/walk_{i}.png"
        save_png(pack / name, img)
        walk_names.append(name)
    save_apng(pack / "walk.apng", walk, [100, 250, 100])
    save_sheet(pack / "walk_sheet.png", walk)
    manifest = base(
        "good-full",
        {
            "idle": {"frames": names, "durations_ms": [500, 500], "loop": True},
            "walk": {
                "frames": walk_names,
                "durations_ms": [100, 250, 100],
                "loop": True,
                "anchor": [8, 16],
                "hitbox": [2, 8, 12, 8],
                "apng": "walk.apng",
                "sheet": "walk_sheet.png",
            },
            "moonwalk": {"frames": names, "durations_ms": [100, 100], "loop": True},
        },
    )
    manifest["author"] = "tern-cat fixtures"
    manifest["description"] = "Fixture pack exercising optional fields."
    manifest["homepage"] = "https://example.invalid/ignored"
    write_manifest(pack, manifest)


def bad_traversal() -> None:
    pack = ROOT / "bad-traversal"
    idle_frames(pack)
    write_manifest(
        pack,
        base("bad-traversal", {"idle": {"frames": ["../../etc/passwd"], "durations_ms": [100], "loop": True}}),
    )


def bad_absolute() -> None:
    pack = ROOT / "bad-absolute"
    idle_frames(pack)
    write_manifest(
        pack,
        base("bad-absolute", {"idle": {"frames": ["/etc/hosts.png"], "durations_ms": [100], "loop": True}}),
    )


def bad_giant_canvas() -> None:
    pack = ROOT / "bad-giant-canvas"
    names = idle_frames(pack)
    write_manifest(
        pack,
        base(
            "bad-giant-canvas",
            {"idle": {"frames": names, "durations_ms": [100, 100], "loop": True}},
            canvas=4096,
        ),
    )


def bad_wrong_dims() -> None:
    pack = ROOT / "bad-wrong-dims"
    save_png(pack / "idle_0.png", frame(0))
    save_png(pack / "idle_1.png", frame(1, CANVAS + 1, CANVAS))
    write_manifest(
        pack,
        base(
            "bad-wrong-dims",
            {"idle": {"frames": ["idle_0.png", "idle_1.png"], "durations_ms": [100, 100], "loop": True}},
        ),
    )


def bad_not_png() -> None:
    pack = ROOT / "bad-not-png"
    pack.mkdir(parents=True, exist_ok=True)
    (pack / "idle_0.png").write_text("this is not a png, it is a text file\n")
    write_manifest(
        pack,
        base("bad-not-png", {"idle": {"frames": ["idle_0.png"], "durations_ms": [100], "loop": True}}),
    )


def bad_missing_idle() -> None:
    pack = ROOT / "bad-missing-idle"
    names = idle_frames(pack)
    write_manifest(
        pack,
        base("bad-missing-idle", {"walk": {"frames": names, "durations_ms": [100, 100], "loop": True}}),
    )


def bad_too_many_frames() -> None:
    pack = ROOT / "bad-too-many-frames"
    names = idle_frames(pack, 1)
    write_manifest(
        pack,
        base(
            "bad-too-many-frames",
            {"idle": {"frames": names * 65, "durations_ms": [100] * 65, "loop": True}},
        ),
    )


def bad_apng_frames() -> None:
    pack = ROOT / "bad-apng-frames"
    names = idle_frames(pack)
    save_apng(pack / "idle.apng", [frame(i) for i in range(3)], [100, 100, 100])
    write_manifest(
        pack,
        base(
            "bad-apng-frames",
            {"idle": {"frames": names, "durations_ms": [100, 100], "loop": True, "apng": "idle.apng"}},
        ),
    )


def bad_sheet_dims() -> None:
    pack = ROOT / "bad-sheet-dims"
    names = idle_frames(pack)
    save_sheet(pack / "idle_sheet.png", [frame(i) for i in range(3)])
    write_manifest(
        pack,
        base(
            "bad-sheet-dims",
            {"idle": {"frames": names, "durations_ms": [100, 100], "loop": True, "sheet": "idle_sheet.png"}},
        ),
    )


def bad_json() -> None:
    pack = ROOT / "bad-json"
    pack.mkdir(parents=True, exist_ok=True)
    (pack / "pack.json").write_text('{"schema_version": 1, "id": "bad-json", \n')


def main() -> None:
    if ROOT.exists():
        shutil.rmtree(ROOT)
    for build in (
        good_minimal,
        good_full,
        bad_traversal,
        bad_absolute,
        bad_giant_canvas,
        bad_wrong_dims,
        bad_not_png,
        bad_missing_idle,
        bad_too_many_frames,
        bad_apng_frames,
        bad_sheet_dims,
        bad_json,
    ):
        build()
    total = sum(p.stat().st_size for p in ROOT.rglob("*") if p.is_file())
    print(f"wrote fixtures to {ROOT} ({total} bytes)")


if __name__ == "__main__":
    main()
