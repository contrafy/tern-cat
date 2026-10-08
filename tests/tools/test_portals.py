"""Tests for the transition props (assets/portals) and their validator in tools/validate_packs.py.

Run: uv run --with pytest --with pillow pytest tests/tools
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import validate_packs  # noqa: E402

FW, FH = validate_packs.PORTAL_FRAME


def strip(path: Path, frames: int, mode: str = "RGBA", size: tuple[int, int] | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    Image.new(mode, size or (FW * frames, FH)).save(path)


def layer(sheet: str, durations: list[int]) -> dict:
    return {"sheet": sheet, "frames": len(durations), "durations_ms": durations}


def props(root: Path, manifest_edit=None) -> Path:
    """A minimal valid prop set: one `portal` style with enter (back+front) and exit (back)."""
    strip(root / "portal/enter-back.sheet.png", 2)
    strip(root / "portal/enter-front.sheet.png", 2)
    strip(root / "portal/exit-back.sheet.png", 4)
    manifest = {
        "schema_version": 1,
        "frame": {"width": FW, "height": FH},
        "anchor": [24, 12],
        "styles": {
            "portal": {
                "name": "Swirly portal",
                "enter": {
                    "back": layer("portal/enter-back.sheet.png", [300, 500]),
                    "front": layer("portal/enter-front.sheet.png", [300, 500]),
                },
                "exit": {"back": layer("portal/exit-back.sheet.png", [160, 160, 160, 160])},
            }
        },
    }
    if manifest_edit:
        manifest_edit(manifest)
    (root / "portals.json").write_text(json.dumps(manifest), encoding="utf-8")
    return root


def errors(root: Path, capsys, bundled: bool = False) -> str:
    assert not validate_packs.validate_portals(root, bundled)
    return capsys.readouterr().err


def test_bundled_props_are_valid(capsys):
    assert validate_packs.validate_portals(ROOT / "assets/portals", bundled=True), capsys.readouterr().err


def test_minimal_props_pass_unbundled_but_bundled_needs_every_style(tmp_path, capsys):
    root = props(tmp_path)
    assert validate_packs.validate_portals(root, bundled=False)
    assert "styles: bundled props must provide every style; missing vent, box" in errors(root, capsys, bundled=True)


def test_default_run_and_directory_argument_include_props(tmp_path, capsys):
    assert validate_packs.main(["--no-lune", str(props(tmp_path))]) == 0
    assert f"ok   {tmp_path}" in capsys.readouterr().out
    assert validate_packs.main(["--no-lune"]) == 0
    assert "ok   assets/portals" in capsys.readouterr().out


def test_sheet_size_must_match_frames(tmp_path, capsys):
    root = props(tmp_path)
    strip(root / "portal/exit-back.sheet.png", 3)
    assert "is 144x24 but expected 192x24 (4 frames of 48x24)" in errors(root, capsys)


def test_sheet_must_be_rgba(tmp_path, capsys):
    root = props(tmp_path)
    strip(root / "portal/exit-back.sheet.png", 4, mode="RGB")
    assert "must be an RGBA PNG (got mode RGB)" in errors(root, capsys)


def test_timeline_totals(tmp_path, capsys):
    def edit(m):
        m["styles"]["portal"]["enter"]["back"]["durations_ms"] = [300, 400]
        m["styles"]["portal"]["enter"]["front"]["durations_ms"] = [300, 400]

    err = errors(props(tmp_path, edit), capsys)
    assert "styles.portal.enter.back.durations_ms: total 700 ms; enter timelines must total 800 ms" in err


def test_exit_frames_share_one_duration(tmp_path, capsys):
    def edit(m):
        m["styles"]["portal"]["exit"]["back"]["durations_ms"] = [100, 220, 160, 160]

    assert "exit frames must all share one duration" in errors(props(tmp_path, edit), capsys)


def test_front_layer_follows_back_timing(tmp_path, capsys):
    def edit(m):
        m["styles"]["portal"]["enter"]["front"]["durations_ms"] = [400, 400]

    err = errors(props(tmp_path, edit), capsys)
    assert "styles.portal.enter.front.durations_ms: must equal the back layer's durations_ms" in err


@pytest.mark.parametrize(
    ("sheet", "reason"),
    [
        ("../escape.png", "must not contain . or .. segments"),
        ("/abs.png", "must be relative (no leading /)"),
        ("portal/exit.apng", "must end in .png"),
        ("portal/missing.png", "file not found"),
    ],
)
def test_sheet_paths_are_safe(tmp_path, capsys, sheet, reason):
    def edit(m):
        m["styles"]["portal"]["exit"]["back"]["sheet"] = sheet

    assert reason in errors(props(tmp_path, edit), capsys)


def test_frame_size_and_anchor(tmp_path, capsys):
    def edit(m):
        m["frame"] = {"width": 32, "height": 24}
        m["anchor"] = [60, 12]

    err = errors(props(tmp_path, edit), capsys)
    assert 'frame: must be {"width": 48, "height": 24}' in err
    assert "anchor: point (60, 12) is outside the 48x24 frame" in err


def test_bundled_packs_follow_the_transition_timing():
    for pack in sorted((ROOT / "assets/packs").iterdir()):
        anims = json.loads((pack / "pack.json").read_text(encoding="utf-8"))["animations"]
        dive, emerge = anims["dive"]["durations_ms"], anims["emerge"]["durations_ms"]
        assert sum(dive) == 480 and len(set(dive)) == 1, pack.name
        assert sum(emerge) == 640, pack.name
        assert anims["dive"]["loop"] is False and anims["emerge"]["loop"] is False
