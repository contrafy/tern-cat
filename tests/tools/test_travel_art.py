"""Tests for the walk-between-panes art (climb, leap, run) and its canonical names.

Run: uv run --with pytest --with pillow pytest tests/tools
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))

import validate_packs  # noqa: E402
from art.animations import all_animations  # noqa: E402
from art.cat import render  # noqa: E402
from art.palettes import CAT_INDICES  # noqa: E402
from art.raster import Canvas  # noqa: E402

TRAVEL = {
    # name: (frames, ms per frame, loop)
    "climb": (4, 90, True),
    "leap": (6, 80, False),
    "run": (4, 70, True),
}


def lua_canonical() -> list[str]:
    src = (ROOT / "cat/render/animations.luau").read_text(encoding="utf-8")
    block = re.search(r"local CANONICAL: \{ T\.Animation \} = \{(.*?)\n\}", src, re.S)
    assert block, "CANONICAL not found in cat/render/animations.luau"
    return re.findall(r'"([a-z]+)"', block.group(1))


def anims() -> dict:
    return {a.name: a for a in all_animations()}


def test_validator_canonical_list_matches_the_renderer():
    assert validate_packs.CANONICAL == lua_canonical()
    for name in TRAVEL:
        assert name in validate_packs.CANONICAL


def test_bundled_packs_follow_the_travel_timing():
    for pack in sorted((ROOT / "assets/packs").iterdir()):
        manifest = json.loads((pack / "pack.json").read_text(encoding="utf-8"))["animations"]
        for name, (frames, ms, loop) in TRAVEL.items():
            spec = manifest[name]
            assert spec["durations_ms"] == [ms] * frames, (pack.name, name)
            assert spec["loop"] is loop, (pack.name, name)


def test_turned_ccw_makes_the_floor_the_right_wall():
    c = Canvas(3, 2)
    c.px = [list("abc"), list("def")]
    turned = c.turned_ccw()
    assert (turned.width, turned.height) == (2, 3)
    assert turned.rows() == ["cf", "be", "ad"]


def test_climb_faces_up_with_paws_on_the_right_wall():
    for pose, _ in anims()["climb"].frames:
        c = render(pose)
        box = c.bbox(CAT_INDICES)
        assert box is not None
        x0, y0, x1, y1 = box
        assert x1 >= 29, "a paw must reach the wall at the right edge"
        assert y0 <= 2, "the head is at the top"
        assert y1 - y0 > x1 - x0, "the body runs up the wall"


def test_leap_lands_on_idle_first_frame():
    a = anims()
    assert render(a["leap"].frames[-1][0]).px == render(a["idle"].frames[0][0]).px
