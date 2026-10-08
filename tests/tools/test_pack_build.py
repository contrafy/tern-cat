"""Tests for tools/pack_build.py.

Run: uv run --with pytest --with pillow pytest tests/tools
"""

from __future__ import annotations

import json
import re
import shutil
import sys
from pathlib import Path

import PIL
import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import pack_build  # noqa: E402
import validate_packs  # noqa: E402

W, H = 16, 12


def frame(path: Path, color: tuple[int, int, int, int]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    im = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    for x in range(2, W - 2):
        for y in range(2, H - 2):
            im.putpixel((x, y), color)
    im.save(path, format="PNG")


def make_pack(root: Path) -> Path:
    frame(root / "frames/idle/01.png", (200, 100, 0, 255))
    frame(root / "frames/idle/02.png", (210, 110, 0, 255))
    frame(root / "frames/idle/03.png", (220, 120, 0, 255))
    frame(root / "frames/hop/01.png", (0, 0, 200, 255))
    frame(root / "frames/hop/02.png", (0, 0, 120, 128))
    manifest = {
        "schema_version": 1,
        "id": "tiny",
        "name": "Tiny",
        "author": "Tester",
        "license": "CC0-1.0",
        "description": "Fixture pack.",
        "canvas": {"width": W, "height": H},
        "animations": {
            "idle": {
                "frames": ["frames/idle/01.png", "frames/idle/02.png", "frames/idle/03.png"],
                "durations_ms": [400, 150, 275],
                "loop": True,
                "anchor": [8, 11],
                "hitbox": [2, 2, 12, 8],
            },
            "hop": {
                "frames": ["frames/hop/01.png", "frames/hop/02.png"],
                "durations_ms": [90, 1200],
                "loop": False,
                "anchor": [8, 11],
                "hitbox": [2, 2, 12, 8],
            },
        },
    }
    (root / "pack.json").write_text(json.dumps(manifest, indent=4), encoding="utf-8")
    return root


def run(*args: str | Path) -> int:
    return pack_build.main(["--no-lune", *map(str, args)])


def snapshot(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def apng_info(path: Path) -> tuple[int, int, list[int]]:
    data = path.read_bytes()
    pos = data.index(b"acTL")
    frames = int.from_bytes(data[pos + 4 : pos + 8], "big")
    plays = int.from_bytes(data[pos + 8 : pos + 12], "big")
    delays = []
    with Image.open(path) as im:
        for i in range(im.n_frames):
            im.seek(i)
            delays.append(im.info["duration"])
    return frames, plays, delays


def test_build_check_and_staleness(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    pack = make_pack(tmp_path / "tiny")
    assert run("--check", pack) == 1  # nothing built yet
    assert "build/idle.apng is missing" in capsys.readouterr().err

    assert run(pack) == 0
    assert apng_info(pack / "build/idle.apng") == (3, 0, [400, 150, 275])
    assert apng_info(pack / "build/hop.apng") == (2, 1, [90, 1200])
    with Image.open(pack / "build/idle.sheet.png") as sheet:
        assert sheet.size == (3 * W, H) and sheet.mode == "RGBA"
        with Image.open(pack / "frames/idle/02.png") as f2:
            assert sheet.crop((W, 0, 2 * W, H)).tobytes() == f2.convert("RGBA").tobytes()
    with Image.open(pack / "build/hop.sheet.png") as sheet:
        assert sheet.size == (2 * W, H)

    text = (pack / "pack.json").read_text(encoding="utf-8")
    assert text.endswith("}\n") and '\n  "id": "tiny"' in text
    manifest = json.loads(text)
    assert list(manifest) == ["schema_version", "id", "name", "author", "license", "description", "canvas", "animations"]
    assert list(manifest["animations"]) == ["idle", "hop"]
    idle = manifest["animations"]["idle"]
    assert list(idle) == ["frames", "durations_ms", "loop", "anchor", "hitbox", "apng", "sheet"]
    assert idle["apng"] == "build/idle.apng" and idle["sheet"] == "build/idle.sheet.png"
    assert validate_packs.validate_sprite_pack(pack, bundled=False)

    first = snapshot(pack)
    assert run(pack) == 0
    assert snapshot(pack) == first  # rebuild is byte-identical
    assert run("--check", pack) == 0
    assert snapshot(pack) == first

    frame(pack / "frames/hop/02.png", (0, 200, 0, 255))
    capsys.readouterr()
    assert run("--check", pack) == 1
    err = capsys.readouterr().err
    assert "build/hop.apng is stale" in err and "build/hop.sheet.png is stale" in err
    assert "build/idle" not in err
    assert snapshot(pack)["build/hop.apng"] == first["build/hop.apng"]  # --check wrote nothing

    assert run(pack) == 0
    assert run("--check", pack) == 0


def test_check_flags_missing_manifest_fields(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    pack = make_pack(tmp_path / "tiny")
    assert run(pack) == 0
    manifest = json.loads((pack / "pack.json").read_text(encoding="utf-8"))
    del manifest["animations"]["hop"]["sheet"]
    (pack / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    capsys.readouterr()
    assert run("--check", pack) == 1
    assert "animations.hop.sheet should be 'build/hop.sheet.png'" in capsys.readouterr().err


@pytest.mark.parametrize("bad", ["../outside.png", "/etc/passwd.png", "frames/../../x.png", "C:/x.png"])
def test_unsafe_frame_path_rejected(tmp_path: Path, capsys: pytest.CaptureFixture[str], bad: str) -> None:
    pack = make_pack(tmp_path / "tiny")
    frame(tmp_path / "outside.png", (1, 2, 3, 255))
    manifest = json.loads((pack / "pack.json").read_text(encoding="utf-8"))
    manifest["animations"]["idle"]["frames"][1] = bad
    (pack / "pack.json").write_text(json.dumps(manifest), encoding="utf-8")
    before = snapshot(pack)
    assert run(pack) == 1
    err = capsys.readouterr().err
    assert "animations.idle.frames[2]: unsafe path" in err
    assert snapshot(pack) == before
    assert not (pack / "build").exists()


def test_symlink_escape_rejected(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    pack = make_pack(tmp_path / "tiny")
    frame(tmp_path / "outside.png", (1, 2, 3, 255))
    (pack / "frames/idle/02.png").unlink()
    (pack / "frames/idle/02.png").symlink_to(tmp_path / "outside.png")
    assert run(pack) == 1
    assert "resolves outside the pack directory" in capsys.readouterr().err


def test_frame_errors_name_animation_and_frame(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    pack = make_pack(tmp_path / "tiny")
    Image.new("RGBA", (W + 1, H)).save(pack / "frames/hop/02.png")
    assert run(pack) == 1
    assert "animations.hop.frames[2] 'frames/hop/02.png': image is 17x12 but canvas is 16x12" in capsys.readouterr().err

    (pack / "frames/hop/02.png").unlink()
    assert run(pack) == 1
    assert "animations.hop.frames[2] 'frames/hop/02.png': file not found" in capsys.readouterr().err


def test_identical_consecutive_frames_rejected(tmp_path: Path, capsys: pytest.CaptureFixture[str]) -> None:
    pack = make_pack(tmp_path / "tiny")
    shutil.copy(pack / "frames/idle/02.png", pack / "frames/idle/03.png")
    assert run(pack) == 1
    err = capsys.readouterr().err
    assert "animations.idle.frames[2] 'frames/idle/02.png' and frames[3] 'frames/idle/03.png' are identical" in err
    assert "(150 + 275 = 425 ms)" in err
    assert not (pack / "build").exists()


def test_reproduces_bundled_pack(tmp_path: Path) -> None:
    header = (ROOT / "tools/pack_build.py").read_text(encoding="utf-8")
    pinned = re.search(r'"pillow==([^"]+)"', header)
    assert pinned
    if PIL.__version__ != pinned.group(1):
        pytest.skip(f"bundled bytes were encoded with Pillow {pinned.group(1)}, running {PIL.__version__}")
    src = ROOT / "assets/packs/orange-menace"
    pack = tmp_path / "orange-menace"
    shutil.copytree(src, pack, ignore=shutil.ignore_patterns("build"))
    manifest = json.loads((pack / "pack.json").read_text(encoding="utf-8"))
    for spec in manifest["animations"].values():
        del spec["apng"], spec["sheet"]
    (pack / "pack.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    assert run(pack) == 0
    assert snapshot(pack / "build") == snapshot(src / "build")
    assert (pack / "pack.json").read_bytes() == (src / "pack.json").read_bytes()
