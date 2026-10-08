# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.3.0"]
# ///
"""Generate the derived artifacts of a sprite pack from its frames, then validate it.

Usage: uv run tools/pack_build.py [--check] [--no-lune] PACK_DIR [PACK_DIR ...]

For every animation in PACK_DIR/pack.json this reads the listed frame PNGs and writes
  build/<anim>.apng        animated PNG; durations_ms exact, plays forever when "loop" is
                           true (num_plays 0), once otherwise (num_plays 1)
  build/<anim>.sheet.png   horizontal strip of the frames, canvas.width * frames wide
and sets the animation's "apng"/"sheet" fields to those paths. pack.json is rewritten with
2-space indentation and a trailing newline; key order and all other fields are kept (new
fields are appended to the animation object). Output bytes are deterministic: no PNG
metadata, fixed compression, so rebuilding unchanged frames reproduces identical files.
Finally the pack is checked with tools/validate_packs.py and, when `lune` is on PATH, with
`lune run tools/validate_pack.luau` (skip that with --no-lune).

Frames must be existing, single-image PNG files of exactly canvas.width x canvas.height,
referenced by safe pack-relative paths (same rules as the validators). Any 8-bit PNG
colour type is accepted and converted to RGBA losslessly; 16-bit images are rejected.
Two identical consecutive frames are an error: APNG encoders merge them into one frame,
which would no longer match the manifest. Delete the second frame and add its duration to
the first instead.

--check writes nothing and exits 1 when a derived file or a pack.json apng/sheet field is
missing or stale (byte comparison against a fresh build). Exit codes: 0 ok, 1 build,
check or validation failure, 2 usage error.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from PIL import Image

sys.path.insert(0, str(Path(__file__).resolve().parent))

import validate_packs as vp  # noqa: E402
from packlib import encode_apng, encode_sheet, first_duplicate  # noqa: E402

LOSSLESS_MODES = {"1", "L", "LA", "P", "PA", "RGB", "RGBA"}


class PackError(Exception):
    pass


def label(root: Path) -> str:
    return str(root.relative_to(vp.ROOT)) if root.is_relative_to(vp.ROOT) else str(root)


def load_frame(root: Path, rel: object, field: str, cw: int, ch: int) -> Image.Image:
    why = vp.check_path(rel, (".png", ".apng"))
    if why:
        raise PackError(f"{field}: unsafe path {rel!r}: {why}")
    assert isinstance(rel, str)
    path = vp.inside(root, rel)
    if path is None:
        raise PackError(f"{field} {rel!r}: resolves outside the pack directory")
    if not path.is_file():
        raise PackError(f"{field} {rel!r}: file not found")
    if not path.read_bytes()[: len(vp.PNG_SIG)] == vp.PNG_SIG:
        raise PackError(f"{field} {rel!r}: not a PNG (bad signature)")
    try:
        with Image.open(path) as im:
            if getattr(im, "n_frames", 1) != 1:
                raise PackError(f"{field} {rel!r}: is animated; frames must be single still images")
            if im.mode not in LOSSLESS_MODES:
                raise PackError(f"{field} {rel!r}: unsupported image mode {im.mode} (use an 8-bit RGBA PNG)")
            if im.size != (cw, ch):
                raise PackError(f"{field} {rel!r}: image is {im.width}x{im.height} but canvas is {cw}x{ch}")
            return im.convert("RGBA")
    except PackError:
        raise
    except Exception as e:  # noqa: BLE001 - surface any decoder failure with the frame name
        raise PackError(f"{field} {rel!r}: could not be decoded: {e}") from None


def derived_paths(name: str) -> dict[str, str]:
    """pack.json field -> pack-relative output path for animation `name`."""
    return {"apng": f"build/{name}.apng", "sheet": f"build/{name}.sheet.png"}


def plan(root: Path, raw: dict) -> dict[str, bytes]:
    """Returns {relative output path: bytes} for every derived file. Raises PackError."""
    canvas = raw.get("canvas")
    cw = canvas.get("width") if isinstance(canvas, dict) else None
    ch = canvas.get("height") if isinstance(canvas, dict) else None
    if not (vp.is_int(cw) and vp.is_int(ch) and cw > 0 and ch > 0):
        raise PackError("canvas: must be an object with positive integer width and height")
    anims = raw.get("animations")
    if not isinstance(anims, dict) or not anims:
        raise PackError("animations: must be a non-empty object keyed by animation name")
    outputs: dict[str, bytes] = {}
    for name, spec in anims.items():
        base = f"animations.{name}"
        apng_rel, sheet_rel = derived_paths(name).values()
        why = vp.check_path(apng_rel, (".apng",))
        if why:
            raise PackError(f"{base}: animation name cannot be used in a file name ({apng_rel!r}: {why})")
        if not isinstance(spec, dict):
            raise PackError(f"{base}: must be an object")
        frames = spec.get("frames")
        if not isinstance(frames, list) or not frames:
            raise PackError(f"{base}.frames: must be a non-empty list of file paths")
        durations = spec.get("durations_ms")
        if not isinstance(durations, list) or not all(vp.is_int(d) and d > 0 for d in durations):
            raise PackError(f"{base}.durations_ms: must be a list of positive integers (one per frame)")
        if len(durations) != len(frames):
            raise PackError(f"{base}.durations_ms: has {len(durations)} entries but there are {len(frames)} frames")
        loop = spec.get("loop")
        if not isinstance(loop, bool):
            raise PackError(f"{base}.loop: must be true or false (got {loop!r})")
        images = [load_frame(root, rel, f"{base}.frames[{i}]", cw, ch) for i, rel in enumerate(frames, start=1)]
        dup = first_duplicate(images)
        if dup is not None:
            a, b = dup + 1, dup + 2
            raise PackError(
                f"{base}.frames[{a}] {frames[a - 1]!r} and frames[{b}] {frames[b - 1]!r} are identical; "
                f"APNG merges identical consecutive frames, so remove frames[{b}] and give frames[{a}] "
                f"its combined duration ({durations[a - 1]} + {durations[b - 1]} = {durations[a - 1] + durations[b - 1]} ms)"
            )
        for rel in (apng_rel, sheet_rel):
            if vp.inside(root, rel) is None:
                raise PackError(f"{base}: output {rel!r} resolves outside the pack directory")
        try:
            outputs[apng_rel] = encode_apng(images, durations, loop)
        except ValueError as e:
            raise PackError(f"{base}: {e}") from None
        outputs[sheet_rel] = encode_sheet(images, cw, ch)
    return outputs


def process(root: Path, check: bool) -> bool:
    name = label(root)
    manifest_path = root / "pack.json"
    try:
        if not manifest_path.is_file():
            raise PackError("pack.json: not found")
        try:
            raw = json.loads(manifest_path.read_text(encoding="utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as e:
            raise PackError(f"pack.json: is not valid JSON: {e}") from None
        if not isinstance(raw, dict):
            raise PackError("pack.json: must contain a JSON object")
        outputs = plan(root, raw)
    except PackError as e:
        print(f"FAIL {name}: {e}", file=sys.stderr)
        return False

    fields = [(n, key, rel) for n in raw["animations"] for key, rel in derived_paths(n).items()]
    if check:
        stale: list[str] = []
        for n, key, rel in fields:
            if raw["animations"][n].get(key) != rel:
                stale.append(f"pack.json animations.{n}.{key} should be {rel!r}")
        for rel, data in outputs.items():
            path = root / rel
            if not path.is_file():
                stale.append(f"{rel} is missing")
            elif path.read_bytes() != data:
                stale.append(f"{rel} is stale")
        for s in stale:
            print(f"FAIL {name}: {s}", file=sys.stderr)
        if stale:
            print(f"FAIL {name}: derived files are out of date; run: uv run tools/pack_build.py {name}", file=sys.stderr)
            return False
        print(f"fresh {name}: {len(outputs)} derived files up to date")
        return True

    written = 0
    for rel, data in outputs.items():
        path = root / rel
        if path.is_file() and path.read_bytes() == data:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        written += 1
    for n, key, rel in fields:
        raw["animations"][n][key] = rel
    text = json.dumps(raw, indent=2, ensure_ascii=False) + "\n"
    if manifest_path.read_text(encoding="utf-8") != text:
        manifest_path.write_text(text, encoding="utf-8")
        written += 1
    print(f"built {name}: {len(raw['animations'])} animations, {written} files changed")
    return True


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="uv run tools/pack_build.py",
        description="Build build/<anim>.apng and build/<anim>.sheet.png for sprite packs, then validate them.",
    )
    parser.add_argument("packs", nargs="+", metavar="PACK_DIR", help="directory containing pack.json")
    parser.add_argument("--check", action="store_true", help="write nothing; exit 1 if derived files are missing or stale")
    parser.add_argument("--no-lune", action="store_true", help="skip the lune run tools/validate_pack.luau cross-check")
    args = parser.parse_args(argv)
    dirs = [Path(p).resolve() for p in args.packs]
    ok = True
    built: list[Path] = []
    for d in dirs:
        if process(d, args.check):
            built.append(d)
        else:
            ok = False
    for d in built:
        ok = vp.validate_sprite_pack(d, bundled=False) and ok
    if built and not args.no_lune:
        ok = vp.run_lune(built) and ok
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
