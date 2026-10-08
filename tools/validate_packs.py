# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow==12.3.0"]
# ///
"""Validate sprite packs, sound packs and the transition props (CI cross-check for cat/sprite/manifest.luau).

Usage: uv run tools/validate_packs.py [--no-lune] [PACK_DIR ...]

With no arguments, validates every directory under assets/packs/, every sound pack under
assets/sounds/ and assets/portals/portals.json. Sprite packs are checked here with Pillow
(structure, limits, path safety, PNG signatures, frame/APNG/sheet dimensions, APNG frame
counts) and then, when `lune` is on PATH, again with `lune run tools/validate_pack.luau` so
both implementations must agree. A directory argument containing portals.json is checked as
a transition-prop set. Exits 1 when anything is invalid.
"""

from __future__ import annotations

import json
import re
import shutil
import struct
import subprocess
import sys
import wave
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
PACKS_DIR = ROOT / "assets" / "packs"
SOUNDS_DIR = ROOT / "assets" / "sounds"
PORTALS_DIR = ROOT / "assets" / "portals"
LUAU_VALIDATOR = ROOT / "tools" / "validate_pack.luau"
DEFAULT_PACK = "orange-menace"

LIMITS = {
    "id_max": 32,
    "name_max": 64,
    "license_max": 64,
    "author_max": 64,
    "description_max": 512,
    "canvas_min": 8,
    "canvas_max": 256,
    "animations_max": 32,
    "frames_max": 64,
    "duration_min_ms": 40,
    "duration_max_ms": 10000,
    "path_max": 200,
    "file_max_bytes": 1024 * 1024,
    "files_max": 512,
    "pack_max_bytes": 16 * 1024 * 1024,
}
CANONICAL = [
    "idle",
    "walk",
    "sit",
    "sleep",
    "wake",
    "stretch",
    "groom",
    "blink",
    "look",
    "pet",
    "poke",
    "eat",
    "play",
    "happy",
    "disappointed",
    "swat",
    "startled",
    "flop",
    "stare",
    "hop",
    "dive",
    "emerge",
]
SOUND_IDS = ["meow", "purr", "surprise", "happy", "swat"]
SOUND_LIMITS = {"max_seconds": 1.5, "max_bytes": 80 * 1024, "rates": (8000, 48000)}
# Transition props (assets/portals/portals.json). The overlay steps exit timelines with a CSS
# transition, which can only step evenly, so exit frames must all last the same.
PORTAL_STYLES = ["portal", "vent", "box"]
PORTAL_FRAME = (48, 24)
PORTAL_TOTAL_MS = {"enter": 800, "exit": 640}
PORTAL_LAYERS = ["back", "front"]

ID_RE = re.compile(r"^[a-z][a-z0-9-]{0,31}$")
SEGMENT_RE = re.compile(r"^[A-Za-z0-9._-]+$")
PNG_SIG = b"\x89PNG\r\n\x1a\n"


class Report:
    def __init__(self, label: str) -> None:
        self.label = label
        self.errors: list[str] = []
        self.warnings: list[str] = []

    def err(self, field: str, msg: str) -> None:
        self.errors.append(f"{field}: {msg}")

    def warn(self, field: str, msg: str) -> None:
        self.warnings.append(f"{field}: {msg}")

    def emit(self) -> bool:
        for w in self.warnings:
            print(f"WARN {self.label}: {w}", file=sys.stderr)
        for e in self.errors:
            print(f"FAIL {self.label}: {e}", file=sys.stderr)
        if not self.errors:
            print(f"ok   {self.label}")
        return not self.errors


def is_int(v: object) -> bool:
    return isinstance(v, int) and not isinstance(v, bool)


def check_path(p: object, extensions: tuple[str, ...]) -> str | None:
    """Returns a reason when `p` is not a safe pack-relative path, else None."""
    if not isinstance(p, str):
        return "must be a string path"
    if p == "":
        return "must not be empty"
    if len(p) > LIMITS["path_max"]:
        return f"must be at most {LIMITS['path_max']} characters"
    if "\\" in p:
        return "must use forward slashes (no backslashes)"
    if ":" in p:
        return "must be a relative path inside the pack (no URL schemes or drive letters)"
    if p.startswith("/"):
        return "must be relative (no leading /)"
    for seg in p.split("/"):
        if seg == "":
            return "must not contain empty path segments"
        if seg in (".", ".."):
            return "must not contain . or .. segments"
        if not SEGMENT_RE.match(seg):
            return "may only contain letters, digits, '.', '_', '-' and '/'"
    if not p.endswith(extensions):
        if p.lower().endswith(extensions):
            return "extension must be lowercase " + " or ".join(extensions)
        return "must end in " + " or ".join(extensions)
    return None


def inside(root: Path, rel: str) -> Path | None:
    path = (root / rel).resolve()
    try:
        path.relative_to(root.resolve())
    except ValueError:
        return None
    return path


def apng_frames(data: bytes) -> int | None:
    """Frame count from the acTL chunk, or None when the PNG is not animated."""
    pos = len(PNG_SIG)
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos : pos + 8])
        if kind == b"acTL" and length >= 8:
            return struct.unpack(">I", data[pos + 8 : pos + 12])[0]
        if kind in (b"IDAT", b"IEND"):
            return None
        pos += 12 + length
    return None


def check_meta(r: Report, raw: dict, maxes: dict[str, int]) -> None:
    if raw.get("schema_version") != 1:
        r.err("schema_version", f"must be 1 (got {raw.get('schema_version')!r})")
    pid = raw.get("id")
    if not isinstance(pid, str) or not ID_RE.match(pid):
        r.err("id", f"must be 1..32 chars of a-z, 0-9 and '-', starting with a letter (got {pid!r})")
    for key in ("name", "license"):
        v = raw.get(key)
        if not isinstance(v, str) or not (1 <= len(v) <= maxes[key]):
            r.err(key, f"required string of 1..{maxes[key]} characters (got {v!r})")
    for key in ("author", "description"):
        v = raw.get(key)
        if v is not None and (not isinstance(v, str) or len(v) > maxes[key]):
            r.err(key, f"must be a string of at most {maxes[key]} characters")


def int_list(r: Report, field: str, v: object, arity: int) -> list[int] | None:
    if v is None:
        return None
    if not isinstance(v, list) or len(v) != arity or not all(is_int(x) for x in v):
        r.err(field, f"must be a list of {arity} integers")
        return None
    return v  # type: ignore[return-value]


def validate_sprite_pack(root: Path, bundled: bool) -> bool:
    r = Report(str(root.relative_to(ROOT)) if root.is_relative_to(ROOT) else str(root))
    manifest_path = root / "pack.json"
    if not manifest_path.is_file():
        r.err("pack.json", "not found")
        return r.emit()
    try:
        raw = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        r.err("pack.json", f"is not valid JSON: {e}")
        return r.emit()
    if not isinstance(raw, dict):
        r.err("manifest", "pack.json must contain a JSON object")
        return r.emit()

    check_meta(
        r,
        raw,
        {
            "name": LIMITS["name_max"],
            "license": LIMITS["license_max"],
            "author": LIMITS["author_max"],
            "description": LIMITS["description_max"],
        },
    )
    if bundled and raw.get("id") != root.name:
        r.err("id", f"bundled pack id {raw.get('id')!r} must match its directory name {root.name!r}")

    canvas = raw.get("canvas")
    cw = ch = None
    if not isinstance(canvas, dict):
        r.err("canvas", "must be an object with width and height")
    else:
        for key in ("width", "height"):
            v = canvas.get(key)
            if not is_int(v) or not (LIMITS["canvas_min"] <= v <= LIMITS["canvas_max"]):
                r.err(
                    f"canvas.{key}",
                    f"must be an integer between {LIMITS['canvas_min']} and {LIMITS['canvas_max']} (got {v!r})",
                )
        if is_int(canvas.get("width")) and is_int(canvas.get("height")):
            cw, ch = canvas["width"], canvas["height"]

    anims = raw.get("animations")
    refs: list[tuple[str, str, str, int]] = []
    if not isinstance(anims, dict):
        r.err("animations", "must be an object keyed by animation name")
        anims = {}
    if len(anims) > LIMITS["animations_max"]:
        r.err("animations", f"has {len(anims)} entries; the limit is {LIMITS['animations_max']}")
    if "idle" not in anims:
        r.err("animations.idle", "is required")
    for name in anims:
        if name not in CANONICAL:
            r.warn(f"animations.{name}", "unknown animation name; it will be ignored")
    if bundled:
        missing = [n for n in CANONICAL if n not in anims]
        if missing:
            r.err("animations", "bundled packs must provide every canonical animation; missing " + ", ".join(missing))

    for name, spec in anims.items():
        base = f"animations.{name}"
        if not isinstance(spec, dict):
            r.err(base, "must be an object")
            continue
        frames = spec.get("frames")
        count = None
        if not isinstance(frames, list):
            r.err(f"{base}.frames", "must be a list of file paths")
        elif not (1 <= len(frames) <= LIMITS["frames_max"]):
            r.err(f"{base}.frames", f"must have between 1 and {LIMITS['frames_max']} frames (got {len(frames)})")
        else:
            count = len(frames)
            for i, p in enumerate(frames, start=1):
                why = check_path(p, (".png", ".apng"))
                if why:
                    r.err(f"{base}.frames[{i}]", f"unsafe path {p!r}: {why}")
                else:
                    refs.append((f"{base}.frames[{i}] {p!r}", p, "frame", 1))
        durations = spec.get("durations_ms")
        if not isinstance(durations, list):
            r.err(f"{base}.durations_ms", "must be a list of integers (one per frame)")
        else:
            if count is not None and len(durations) != count:
                r.err(f"{base}.durations_ms", f"has {len(durations)} entries but there are {count} frames")
            for i, d in enumerate(durations, start=1):
                if not is_int(d) or not (LIMITS["duration_min_ms"] <= d <= LIMITS["duration_max_ms"]):
                    r.err(
                        f"{base}.durations_ms[{i}]",
                        f"must be an integer between {LIMITS['duration_min_ms']} and {LIMITS['duration_max_ms']} (got {d!r})",
                    )
        if not isinstance(spec.get("loop"), bool):
            r.err(f"{base}.loop", f"must be true or false (got {spec.get('loop')!r})")
        w = cw if cw is not None else float("inf")
        h = ch if ch is not None else float("inf")
        anchor = int_list(r, f"{base}.anchor", spec.get("anchor"), 2)
        if anchor and not (0 <= anchor[0] <= w and 0 <= anchor[1] <= h):
            r.err(f"{base}.anchor", f"point ({anchor[0]}, {anchor[1]}) is outside the canvas")
        hb = int_list(r, f"{base}.hitbox", spec.get("hitbox"), 4)
        if hb and (hb[0] < 0 or hb[1] < 0 or hb[2] < 1 or hb[3] < 1 or hb[0] + hb[2] > w or hb[1] + hb[3] > h):
            r.err(f"{base}.hitbox", f"[x, y, w, h] = {hb} must have positive size and lie inside the canvas")
        for key in ("apng", "sheet"):
            p = spec.get(key)
            if p is None:
                continue
            why = check_path(p, (".png", ".apng"))
            if why:
                r.err(f"{base}.{key}", f"unsafe path {p!r}: {why}")
            else:
                refs.append((f"{base}.{key} {p!r}", p, key, count or 0))

    if cw is not None and ch is not None:
        check_files(r, root, cw, ch, refs)
    return r.emit()


def check_files(r: Report, root: Path, cw: int, ch: int, refs: list[tuple[str, str, str, int]]) -> None:
    cache: dict[str, tuple[bytes | None, str | None]] = {}
    total = 0
    for field, rel, role, frames in refs:
        if rel not in cache:
            path = inside(root, rel)
            if path is None:
                cache[rel] = (None, "resolves outside the pack directory")
            elif not path.is_file():
                cache[rel] = (None, "file not found")
            else:
                size = path.stat().st_size
                if size > LIMITS["file_max_bytes"]:
                    cache[rel] = (None, f"file exceeds {LIMITS['file_max_bytes']} bytes")
                else:
                    data = path.read_bytes()
                    total += len(data)
                    cache[rel] = (data, None if data.startswith(PNG_SIG) else "not a PNG (bad signature)")
            if len(cache) > LIMITS["files_max"]:
                r.err("files", f"pack references more than {LIMITS['files_max']} files")
                return
            if total > LIMITS["pack_max_bytes"]:
                r.err("files", f"pack exceeds total size limit of {LIMITS['pack_max_bytes']} bytes")
                return
        data, problem = cache[rel]
        if problem or data is None:
            r.err(field, problem or "invalid")
            continue
        try:
            with Image.open(root / rel) as im:
                width, height = im.size
                pil_frames = getattr(im, "n_frames", 1)
        except Exception as e:  # noqa: BLE001 - report any decoder failure as invalid
            r.err(field, f"could not be decoded: {e}")
            continue
        if role == "frame":
            if (width, height) != (cw, ch):
                r.err(field, f"image is {width}x{height} but canvas is {cw}x{ch}")
        elif role == "apng":
            actl = apng_frames(data)
            if actl is None:
                r.err(field, "not an animated PNG (no acTL chunk before image data)")
            elif actl != frames or pil_frames != frames:
                r.err(field, f"has {actl} frames (acTL; Pillow decoded {pil_frames}) but the animation has {frames}")
            if (width, height) != (cw, ch):
                r.err(field, f"image is {width}x{height} but canvas is {cw}x{ch}")
        else:
            if (width, height) != (cw * frames, ch):
                r.err(
                    field, f"sheet is {width}x{height} but expected {cw * frames}x{ch} ({frames} frames of {cw}x{ch})"
                )


def validate_sound_pack(root: Path) -> bool:
    r = Report(str(root.relative_to(ROOT)) if root.is_relative_to(ROOT) else str(root))
    path = root / "sounds.json"
    if not path.is_file():
        r.err("sounds.json", "not found")
        return r.emit()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        r.err("sounds.json", f"is not valid JSON: {e}")
        return r.emit()
    if not isinstance(raw, dict):
        r.err("manifest", "sounds.json must contain a JSON object")
        return r.emit()
    check_meta(r, raw, {"name": 64, "license": 64, "author": 64, "description": 512})
    sounds = raw.get("sounds")
    if not isinstance(sounds, dict) or not sounds:
        r.err("sounds", "must be a non-empty object mapping sound ids to .wav files")
        return r.emit()
    for sid, rel in sounds.items():
        field = f"sounds.{sid}"
        if sid not in SOUND_IDS:
            r.warn(field, "unknown sound id; it will be ignored")
        why = check_path(rel, (".wav",))
        if why:
            r.err(field, f"unsafe path {rel!r}: {why}")
            continue
        file = inside(root, rel)
        if file is None or not file.is_file():
            r.err(field, f"{rel!r}: file not found")
            continue
        size = file.stat().st_size
        if size > SOUND_LIMITS["max_bytes"]:
            r.err(field, f"{rel!r} is {size} bytes; the limit is {SOUND_LIMITS['max_bytes']}")
        try:
            with wave.open(str(file), "rb") as w:
                rate, channels, width, n = w.getframerate(), w.getnchannels(), w.getsampwidth(), w.getnframes()
        except (wave.Error, EOFError) as e:
            r.err(field, f"{rel!r} is not a PCM WAV file: {e}")
            continue
        lo, hi = SOUND_LIMITS["rates"]
        if channels != 1 or width != 2 or not (lo <= rate <= hi):
            r.err(
                field,
                f"{rel!r} must be mono 16-bit PCM at {lo}..{hi} Hz (got {channels} ch, {width * 8}-bit, {rate} Hz)",
            )
        elif n / rate > SOUND_LIMITS["max_seconds"]:
            r.err(field, f"{rel!r} lasts {n / rate:.2f}s; the limit is {SOUND_LIMITS['max_seconds']}s")
    return r.emit()


def validate_portals(root: Path, bundled: bool) -> bool:
    """Checks a transition-prop set: portals.json plus its frame-strip sheets."""
    r = Report(str(root.relative_to(ROOT)) if root.is_relative_to(ROOT) else str(root))
    path = root / "portals.json"
    if not path.is_file():
        r.err("portals.json", "not found")
        return r.emit()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as e:
        r.err("portals.json", f"is not valid JSON: {e}")
        return r.emit()
    if not isinstance(raw, dict):
        r.err("manifest", "portals.json must contain a JSON object")
        return r.emit()
    if raw.get("schema_version") != 1:
        r.err("schema_version", f"must be 1 (got {raw.get('schema_version')!r})")
    for key in raw:
        if key not in ("schema_version", "frame", "anchor", "styles"):
            r.warn(key, "unknown key; it will be ignored")
    fw, fh = PORTAL_FRAME
    frame = raw.get("frame")
    if not isinstance(frame, dict) or frame.get("width") != fw or frame.get("height") != fh:
        r.err("frame", f'must be {{"width": {fw}, "height": {fh}}} (got {frame!r})')
    anchor = int_list(r, "anchor", raw.get("anchor"), 2)
    if anchor is None and "anchor" not in raw:
        r.err("anchor", "is required")
    elif anchor and not (0 <= anchor[0] <= fw and 0 <= anchor[1] <= fh):
        r.err("anchor", f"point ({anchor[0]}, {anchor[1]}) is outside the {fw}x{fh} frame")
    styles = raw.get("styles")
    if not isinstance(styles, dict) or not styles:
        r.err("styles", "must be a non-empty object keyed by style id")
        return r.emit()
    if bundled:
        missing = [s for s in PORTAL_STYLES if s not in styles]
        if missing:
            r.err("styles", "bundled props must provide every style; missing " + ", ".join(missing))
    for sid, style in styles.items():
        base = f"styles.{sid}"
        if sid not in PORTAL_STYLES:
            r.warn(base, "unknown style id; it will be ignored")
        if not isinstance(style, dict):
            r.err(base, "must be an object")
            continue
        name = style.get("name")
        if not isinstance(name, str) or not (1 <= len(name) <= LIMITS["name_max"]):
            r.err(f"{base}.name", f"required string of 1..{LIMITS['name_max']} characters (got {name!r})")
        for phase, total in PORTAL_TOTAL_MS.items():
            timeline = style.get(phase)
            if not isinstance(timeline, dict):
                r.err(f"{base}.{phase}", "must be an object with a back layer (and optionally front)")
                continue
            for key in timeline:
                if key not in PORTAL_LAYERS:
                    r.warn(f"{base}.{phase}.{key}", "unknown layer; it will be ignored")
            if "back" not in timeline:
                r.err(f"{base}.{phase}.back", "is required")
            timings: dict[str, list[int]] = {}
            for layer in PORTAL_LAYERS:
                if layer not in timeline:
                    continue
                durations = check_portal_layer(r, root, f"{base}.{phase}.{layer}", timeline[layer], phase, total)
                if durations is not None:
                    timings[layer] = durations
            if len(timings) == 2 and timings["back"] != timings["front"]:
                r.err(f"{base}.{phase}.front.durations_ms", "must equal the back layer's durations_ms")
    return r.emit()


def check_portal_layer(r: Report, root: Path, field: str, spec: object, phase: str, total: int) -> list[int] | None:
    """Validates one prop layer; returns its durations when they are well-formed."""
    if not isinstance(spec, dict):
        r.err(field, "must be an object with sheet, frames and durations_ms")
        return None
    frames = spec.get("frames")
    if not is_int(frames) or not (1 <= frames <= LIMITS["frames_max"]):
        r.err(f"{field}.frames", f"must be an integer between 1 and {LIMITS['frames_max']} (got {frames!r})")
        frames = None
    durations = spec.get("durations_ms")
    ok = isinstance(durations, list) and all(
        is_int(d) and LIMITS["duration_min_ms"] <= d <= LIMITS["duration_max_ms"] for d in durations
    )
    if not ok:
        r.err(
            f"{field}.durations_ms",
            f"must be a list of integers between {LIMITS['duration_min_ms']} and {LIMITS['duration_max_ms']}",
        )
        durations = None
    else:
        if frames is not None and len(durations) != frames:
            r.err(f"{field}.durations_ms", f"has {len(durations)} entries but there are {frames} frames")
        if sum(durations) != total:
            r.err(f"{field}.durations_ms", f"total {sum(durations)} ms; {phase} timelines must total {total} ms")
        if phase == "exit" and len(set(durations)) > 1:
            r.err(f"{field}.durations_ms", "exit frames must all share one duration (the overlay steps them evenly)")
    rel = spec.get("sheet")
    why = check_path(rel, (".png",))
    if why:
        r.err(f"{field}.sheet", f"unsafe path {rel!r}: {why}")
        return durations
    path = inside(root, rel)
    if path is None:
        r.err(f"{field}.sheet", f"{rel!r} resolves outside {root.name}/")
        return durations
    if not path.is_file():
        r.err(f"{field}.sheet", f"{rel!r}: file not found")
        return durations
    if path.stat().st_size > LIMITS["file_max_bytes"]:
        r.err(f"{field}.sheet", f"{rel!r} exceeds {LIMITS['file_max_bytes']} bytes")
        return durations
    if not path.read_bytes().startswith(PNG_SIG):
        r.err(f"{field}.sheet", f"{rel!r} is not a PNG (bad signature)")
        return durations
    try:
        with Image.open(path) as im:
            size, mode = im.size, im.mode
    except Exception as e:  # noqa: BLE001 - report any decoder failure as invalid
        r.err(f"{field}.sheet", f"{rel!r} could not be decoded: {e}")
        return durations
    if mode != "RGBA":
        r.err(f"{field}.sheet", f"{rel!r} must be an RGBA PNG (got mode {mode})")
    fw, fh = PORTAL_FRAME
    if frames is not None and size != (fw * frames, fh):
        r.err(
            f"{field}.sheet",
            f"{rel!r} is {size[0]}x{size[1]} but expected {fw * frames}x{fh} ({frames} frames of {fw}x{fh})",
        )
    return durations


def run_lune(dirs: list[Path]) -> bool:
    lune = shutil.which("lune")
    if not lune:
        print("note: lune not on PATH; skipped the Luau validator cross-check", file=sys.stderr)
        return True
    if not LUAU_VALIDATOR.is_file():
        print(f"note: {LUAU_VALIDATOR.relative_to(ROOT)} not found; skipped the Luau cross-check", file=sys.stderr)
        return True
    args = [str(d.relative_to(ROOT)) if d.is_relative_to(ROOT) else str(d) for d in dirs]
    print("==> lune run tools/validate_pack.luau " + " ".join(args))
    result = subprocess.run([lune, "run", "tools/validate_pack.luau", *args], cwd=ROOT)
    return result.returncode == 0


def main(argv: list[str]) -> int:
    use_lune = "--no-lune" not in argv
    targets = [Path(a).resolve() for a in argv if a != "--no-lune"]
    sprite_dirs: list[Path]
    sound_dirs: list[Path]
    portal_dirs: list[Path]
    if targets:
        portal_dirs = [t for t in targets if (t / "portals.json").exists()]
        sound_dirs = [t for t in targets if (t / "sounds.json").exists()]
        sprite_dirs = [
            t for t in targets if (t / "pack.json").exists() or (t not in sound_dirs and t not in portal_dirs)
        ]
        bundled = False
    else:
        sprite_dirs = sorted(p for p in PACKS_DIR.iterdir() if p.is_dir()) if PACKS_DIR.is_dir() else []
        sound_dirs = sorted(p for p in SOUNDS_DIR.iterdir() if p.is_dir()) if SOUNDS_DIR.is_dir() else []
        portal_dirs = [PORTALS_DIR]
        bundled = True
        if not (PACKS_DIR / DEFAULT_PACK).is_dir():
            print(f"FAIL assets/packs: default pack {DEFAULT_PACK!r} is missing", file=sys.stderr)
            return 1
    if not sprite_dirs and not sound_dirs and not portal_dirs:
        print("FAIL: no packs found", file=sys.stderr)
        return 1
    ok = True
    for d in sprite_dirs:
        ok = validate_sprite_pack(d, bundled) and ok
    for d in sound_dirs:
        ok = validate_sound_pack(d) and ok
    for d in portal_dirs:
        ok = validate_portals(d, bundled) and ok
    if use_lune and sprite_dirs:
        ok = run_lune(sprite_dirs) and ok
    print("packs: passed" if ok else "packs: FAILED", file=sys.stderr if not ok else sys.stdout)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
