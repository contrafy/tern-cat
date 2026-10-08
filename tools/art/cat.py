"""Parametric cat renderer: a Pose describes body parts; render() returns an index Canvas.

All three packs share the same index geometry; only palettes differ (tools/art/palettes.py).
"""

from __future__ import annotations

from dataclasses import dataclass, field, replace
from typing import Callable, Sequence

from .palettes import CAT_INDICES, FLAT_INDICES, PROP_INDICES
from .raster import Canvas, Point

SIZE = 32

# Head, 13x11, three-quarter view facing right. Ears are part of the grid so variants
# (perked, flat, back) keep the face aligned. Face features are stamped by FACE below.
HEADS: dict[str, list[str]] = {
    "normal": [
        ".b.......b...",
        ".bb.....bbb..",
        ".bkb...bkkb..",
        "bbkbbbbbkkbbb",
        "bbbbbsbsbbbbb",
        "bbbbbbsbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbwwwwwbbb",
        ".bbbwwwwwwwb.",
        "..bbbwwwwbb..",
    ],
    "perk": [
        ".b.......b...",
        ".bk......kb..",
        ".bkb....bkb..",
        "bbkbbbbbbkbbb",
        "bbbbbsbsbbbbb",
        "bbbbbbsbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbwwwwwbbb",
        ".bbbwwwwwwwb.",
        "..bbbwwwwbb..",
    ],
    "flat": [
        ".............",
        ".............",
        "bb.........bb",
        "bkbbbbbbbbbkb",
        "bbbbbsbsbbbbb",
        "bbbbbbsbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbwwwwwbbb",
        ".bbbwwwwwwwb.",
        "..bbbwwwwbb..",
    ],
    "back": [
        ".............",
        "b..........b.",
        "bkb.......bkb",
        ".bkbbbbbbbkb.",
        "bbbbbsbsbbbbb",
        "bbbbbbsbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbbbbbbbbb",
        "bbbbbwwwwwbbb",
        ".bbbwwwwwwwb.",
        "..bbbwwwwbb..",
    ],
}

# Eye origins (top-left of a 2x2 cell) and nose/mouth positions inside the head grid.
EYE_L = (4, 6)
EYE_R = (8, 6)
NOSE = (7, 8)

EYES: dict[str, tuple[list[str], list[str]]] = {
    "open": (["ei", "ep"], ["ei", "ep"]),
    "blink": (["..", "mm"], ["..", "mm"]),
    "half": (["mm", "ep"], ["mm", "ep"]),
    "narrow": (["mm", "pp"], ["mm", "pp"]),
    "up": (["pp", "ee"], ["pp", "ee"]),
    "back": (["ie", "pe"], ["ie", "pe"]),
    "wide": (["ie", "ee"], ["ie", "ee"]),
    "happy": ([".m.", "m.m"], [".m.", "m.m"]),
    "sleep": (["...", "mmm"], ["...", "mmm"]),
    "squeeze": (["m..", ".mm"], ["..m", "mm."]),
    "sad": (["m.", "ep"], [".m", "ep"]),
}

MOUTHS: dict[str, list[str]] = {
    "neutral": ["m.m"],
    "smile": ["m.m", ".m."],
    "open": ["mpm", ".p."],
    "yawn": ["mpm", "ptp", ".p."],
    "tongue": ["m.m", ".t."],
    "frown": [".m.", "m.m"],
    "meow": ["mpm", ".t."],
    "none": [],
}


@dataclass(frozen=True)
class Leg:
    top: Point
    paw: Point
    near: bool = True
    knee: Point | None = None
    paw_forward: int = 1
    lined: bool = False
    over_head: bool = False


@dataclass(frozen=True)
class Pose:
    torso: Sequence[tuple[float, float, float, float]]
    legs: Sequence[Leg]
    tail: Sequence[Point]
    head: tuple[int, int]
    ears: str = "normal"
    eyes: str = "open"
    mouth: str = "neutral"
    head_turn: str = "none"
    tail_r: float = 0.8
    chest: tuple[float, float, float, float] | None = None
    stripes: bool = True
    fur_up: bool = False
    dy: int = 0
    head_first: bool = False
    tail_over: bool = False
    belly: tuple[float, float, float, float] | None = None
    props: Sequence[Callable[[Canvas], None]] = field(default_factory=tuple)
    under: Sequence[Callable[[Canvas], None]] = field(default_factory=tuple)
    extra: Sequence[Callable[[Canvas], None]] = field(default_factory=tuple)

    def but(self, **kw) -> "Pose":
        return replace(self, **kw)


BODY = "bdhswv"


def _merge(c: Canvas, part: Canvas, lined: bool, skip: Point | None = None) -> None:
    """Copy `part` onto `c`; when `lined`, draw an inner line where the part overlaps the body."""
    if lined:
        for y in range(c.height):
            for x in range(c.width):
                if part.get(x, y) != "." or c.get(x, y) not in BODY:
                    continue
                if skip is not None and (x - skip[0]) ** 2 + (y - skip[1]) ** 2 <= 2.6**2:
                    continue
                if any(part.get(x + dx, y + dy) != "." for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1))):
                    c.put(x, y, "q")
    for y in range(c.height):
        for x in range(c.width):
            if part.px[y][x] != ".":
                c.px[y][x] = part.px[y][x]


def _draw_leg(c: Canvas, leg: Leg) -> None:
    fill = "b" if leg.near else "d"
    mark = "w" if leg.near else "v"
    part = Canvas(c.width, c.height)
    pts = [leg.top] + ([leg.knee] if leg.knee else []) + [leg.paw]
    part.stroke(pts, 0.75, fill)
    px, py = leg.paw
    # Sock: pixels within reach of the paw end become marking color.
    for y in range(part.height):
        for x in range(part.width):
            if part.px[y][x] == fill and (x - px) ** 2 + (y - py) ** 2 <= 1.8**2:
                part.px[y][x] = mark
    if leg.paw_forward:
        ix, iy = round(px - 0.5), round(py)
        part.put(ix + (2 if leg.paw_forward > 0 else -1), iy, mark)
    _merge(c, part, leg.lined, leg.top)


def _draw_tail(c: Canvas, pose: Pose, stripes: bool) -> None:
    pts = list(pose.tail)
    r = pose.tail_r + (0.5 if pose.fur_up else 0.0)
    part = Canvas(c.width, c.height)
    part.stroke(pts, r, "b")
    if stripes and len(pts) >= 3:
        for i, p in enumerate(pts[2:], start=2):
            if i % 2 == 0:
                part.capsule(p, p, r, "s", only="b")
        part.capsule(pts[-1], pts[-1], r, "s", only="b")
    _merge(c, part, pose.tail_over, pts[0])


def _draw_torso(c: Canvas, pose: Pose) -> None:
    t = Canvas(c.width, c.height)
    for cx, cy, rx, ry in pose.torso:
        t.ellipse(cx, cy, rx, ry, "b")
    if pose.stripes and pose.torso:
        cx, cy, rx, ry = pose.torso[0]
        for off in (-5, -2, 1, 4):
            x = int(round(cx + off))
            col = [y for y in range(c.height) if t.get(x, y) == "b"]
            for y in col[1:4]:
                t.put(x, y, "s")
    for y in range(t.height - 1, 0, -1):
        for x in range(t.width):
            if t.get(x, y - 1) == "b" and t.get(x, y - 2) == "." and t.get(x, y) == "b":
                t.put(x, y, "h")
    if pose.chest:
        cx, cy, rx, ry = pose.chest
        t.ellipse(cx, cy, rx, ry, "w", only="bhs")
    if pose.belly:
        cx, cy, rx, ry = pose.belly
        t.ellipse(cx, cy, rx, ry, "w", only="bhs")
    for y in range(t.height):
        for x in range(t.width):
            if t.px[y][x] != ".":
                c.px[y][x] = t.px[y][x]


def head_canvas(ears: str, eyes: str, mouth: str, turn: str = "none") -> Canvas:
    grid = HEADS[ears]
    h = Canvas(len(grid[0]), len(grid))
    h.stamp(0, 0, grid)
    left, right = EYES[eyes]
    lx, ly = EYE_L
    rx, ry = EYE_R
    wide = len(left[0]) == 3
    h.stamp(lx - (1 if wide else 0), ly, [r.replace(".", " ") for r in left])
    h.stamp(rx, ry, [r.replace(".", " ") for r in right])
    nx, ny = NOSE
    h.put(nx, ny, "n")
    h.stamp(nx - 1, ny + 1, [r.replace(".", " ") for r in MOUTHS[mouth]])
    if turn == "flip":
        h.px = h.px[::-1]
    elif turn == "cw":
        rows = h.px
        rot = Canvas(h.height, h.width)
        rot.px = [[rows[h.height - 1 - x][y] for x in range(h.height)] for y in range(h.width)]
        h = rot
    elif turn == "ccw":
        rows = h.px
        rot = Canvas(h.height, h.width)
        rot.px = [[rows[x][h.width - 1 - y] for x in range(h.height)] for y in range(h.width)]
        h = rot
    return h


def _draw_head(c: Canvas, pose: Pose) -> None:
    hx, hy = pose.head
    h = head_canvas(pose.ears, pose.eyes, pose.mouth, pose.head_turn)
    c.stamp(hx, hy, h.rows())


def _fur_spikes(c: Canvas) -> None:
    spikes = []
    for y in range(1, c.height):
        for x in range(c.width):
            if c.get(x, y) in "bhs" and c.get(x, y - 1) == "." and (x % 2 == 0):
                spikes.append((x, y - 1))
    for x, y in spikes:
        c.put(x, y, "b")


def render(pose: Pose) -> Canvas:
    c = Canvas(SIZE, SIZE)
    for fn in pose.under:
        fn(c)
    for leg in pose.legs:
        if not leg.near:
            _draw_leg(c, leg)
    if not pose.tail_over:
        _draw_tail(c, pose, pose.stripes)
    if pose.head_first:
        _draw_head(c, pose)
    _draw_torso(c, pose)
    if pose.tail_over:
        _draw_tail(c, pose, pose.stripes)
    for leg in pose.legs:
        if leg.near and not leg.over_head:
            _draw_leg(c, leg)
    for fn in pose.extra:
        fn(c)
    if not pose.head_first:
        _draw_head(c, pose)
    for leg in pose.legs:
        if leg.over_head:
            _draw_leg(c, leg)
    if pose.fur_up:
        _fur_spikes(c)
    c.outline(CAT_INDICES, "o")
    if pose.dy:
        c = c.shift(0, pose.dy)
    props = Canvas(SIZE, SIZE)
    for fn in pose.props:
        fn(props)
    props.outline(PROP_INDICES, "O")
    for y in range(SIZE):
        for x in range(SIZE):
            p = props.get(x, y)
            if p == ".":
                continue
            if p in FLAT_INDICES and c.get(x, y) != ".":
                continue
            if p == "O" and c.get(x, y) != ".":
                continue
            c.put(x, y, p)
    return c
