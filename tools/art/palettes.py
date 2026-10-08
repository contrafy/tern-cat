"""Palettes mapping shared art indices to RGBA per pack.

Cat indices (outlined together):
  b body  d body shade (far limbs)  h highlight  s stripe  w marking  v marking shade
  e iris  p pupil  i eye shine  n nose  k inner ear  m mouth line  t tongue
Prop indices (outlined with O):
  R heart  Y ball  U ball shade  F bowl  G bowl shade  K kibble  A sweat drop  E exclamation  W white
Flat glyph indices (no outline; mid-tone so they read on light and dark themes):
  Z sleep-z  Q question mark  L letter glyph  X motion/purr lines
"""

from __future__ import annotations

CAT_INDICES = "bdhswvepinkmtq"
PROP_INDICES = "RYUFGKAEW"
FLAT_INDICES = "ZQLX"


def _rgb(hex_color: str, alpha: int = 255) -> tuple[int, int, int, int]:
    h = hex_color.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), alpha)


PROPS = {
    "O": _rgb("#2b2733"),
    "Z": _rgb("#5b8def"),
    "Q": _rgb("#f0a020"),
    "R": _rgb("#ff4f73"),
    "Y": _rgb("#f06bab"),
    "U": _rgb("#b8407c"),
    "F": _rgb("#3f82e6"),
    "G": _rgb("#2a5fb3"),
    "K": _rgb("#a8672e"),
    "L": _rgb("#8a93ad"),
    "A": _rgb("#7ed0ff"),
    "E": _rgb("#ffd23f"),
    "W": _rgb("#ffffff"),
    "X": _rgb("#9d9aae"),
}

PACKS: dict[str, dict] = {
    "orange-menace": {
        "name": "Orange Menace",
        "description": "The default: an orange tabby with darker stripes, a cream chin and strong opinions.",
        "colors": {
            "o": _rgb("#4a2410"),
            "b": _rgb("#f39234"),
            "d": _rgb("#c9681f"),
            "h": _rgb("#ffb860"),
            "s": _rgb("#c4561a"),
            "w": _rgb("#ffe4bd"),
            "v": _rgb("#e5bd8c"),
            "e": _rgb("#86d24a"),
            "p": _rgb("#1d1a16"),
            "i": _rgb("#ffffff"),
            "n": _rgb("#ff8ea6"),
            "k": _rgb("#ff9fb3"),
            "m": _rgb("#4a2410"),
            "q": _rgb("#a14f17"),
            "t": _rgb("#ff6f8e"),
        },
    },
    "void": {
        "name": "Void",
        "description": "A black cat with yellow eyes and a soft lilac rim so it reads on light and dark themes.",
        "colors": {
            "o": _rgb("#6f6c8c"),
            "b": _rgb("#25242e"),
            "d": _rgb("#17161d"),
            "h": _rgb("#3d3b4c"),
            "s": _rgb("#25242e"),
            "w": _rgb("#302f3b"),
            "v": _rgb("#1f1e27"),
            "e": _rgb("#ffd83a"),
            "p": _rgb("#121116"),
            "i": _rgb("#fff6c8"),
            "n": _rgb("#4b3a4c"),
            "k": _rgb("#4b3a4c"),
            "m": _rgb("#6f6c8c"),
            "q": _rgb("#4c4a60"),
            "t": _rgb("#e5728f"),
        },
    },
    "tuxedo": {
        "name": "Tuxedo",
        "description": "Black and white, with a white chest, muzzle and socks. Dressed for every occasion.",
        "colors": {
            "o": _rgb("#5b5a6c"),
            "b": _rgb("#2a2932"),
            "d": _rgb("#1b1a21"),
            "h": _rgb("#43414f"),
            "s": _rgb("#2a2932"),
            "w": _rgb("#f7f5f0"),
            "v": _rgb("#d3cfc6"),
            "e": _rgb("#f2ac36"),
            "p": _rgb("#15141a"),
            "i": _rgb("#ffffff"),
            "n": _rgb("#ff9db2"),
            "k": _rgb("#e98b9e"),
            "m": _rgb("#5b5a6c"),
            "q": _rgb("#55546a"),
            "t": _rgb("#ff7894"),
        },
    },
}


def rgba(pack_id: str, index: str) -> tuple[int, int, int, int]:
    if index == ".":
        return (0, 0, 0, 0)
    colors = PACKS[pack_id]["colors"]
    if index in colors:
        return colors[index]
    return PROPS[index]
