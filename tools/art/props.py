"""Small prop sprites drawn around the cat. Solid props get a dark outline; glyph strokes stay flat."""

from __future__ import annotations

from typing import Callable

from .raster import Canvas

Prop = Callable[[Canvas], None]

GLYPHS: dict[str, list[str]] = {
    "z_small": ["ZZZ", ".Z.", "Z..", "ZZZ"],
    "z_big": ["ZZZZ", "...Z", "..Z.", ".Z..", "ZZZZ"],
    "question": ["QQQ", "..Q", ".QQ", "...", ".Q."],
    "heart": [".R.R.", "RRRRR", "RRRRR", ".RRR.", "..R.."],
    "heart_small": ["R.R", "RRR", ".R."],
    "ball": [".YY.", "YUYY", "YYUY", ".YY."],
    "bowl": [".KKKKK.", "FFFFFFF", "FFFFFFF", ".GGGGG."],
    "bowl_half": ["..K.K..", "FFFFFFF", "FFFFFFF", ".GGGGG."],
    "letter_s": [".LL", "L..", ".L.", "..L", "LL."],
    "letter_s_side": ["L..L.", "L.L.L", ".L..L"],
    "bang": ["EE", "EE", "EE", "..", "EE"],
    "drop": [".A", "AA", "AA"],
    "puff": [".WW", "WWW", "WW."],
    "puff_small": ["WW", "WW"],
    "purr_a": ["X.", ".X", "X."],
    "purr_b": [".X", "X.", ".X"],
    "dash": ["XXX"],
    "dash_short": ["XX"],
    "spark": [".X.", "X.X", ".X."],
}


def glyph(name: str, x: int, y: int) -> Prop:
    rows = GLYPHS[name]

    def draw(c: Canvas) -> None:
        c.stamp(x, y, rows)

    return draw
