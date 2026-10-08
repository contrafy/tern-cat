"""Pane-transition props: the swirly portal, the floor vent and the cardboard box.

Shared by every pack. Each style has an `enter` timeline (the prop the cat emerges from in
the newly focused pane) and an `exit` timeline (the prop it dives into in the pane it left).
A timeline is a list of frames with a `back` layer (drawn behind the cat) and, for the box,
a `front` layer (drawn over the cat so it is visibly inside).

Frames are FRAME_W x FRAME_H. ANCHOR is in pixel-edge coordinates: the bottom-centre edge of
the cat's 32x32 frame lands on it, so rows above ANCHOR[1] are above the cat's feet line and
the cat's lowest row covers prop row ANCHOR[1] - 1. Raster shapes are positioned by pixel
index, so the anchor point is (CX, CY) in drawing coordinates.

Timing: the cat's emerge (640 ms) starts with the enter timeline (ENTER_MS) and its dive
(480 ms) with the exit timeline (EXIT_MS). The overlay steps exit timelines with a CSS
transition, so exit frames all last EXIT_FRAME_MS. Every timeline ends on an empty frame,
which is the held end state.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from .raster import Canvas

FRAME_W = 48
FRAME_H = 24
ANCHOR = (24, 12)
CX = ANCHOR[0] - 0.5
CY = ANCHOR[1] - 0.5
ENTER_MS = 800
EXIT_MS = 640
EXIT_FRAMES = 8
EXIT_FRAME_MS = EXIT_MS // EXIT_FRAMES


def _rgb(hex_color: str) -> tuple[int, int, int, int]:
    h = hex_color.lstrip("#")
    return (int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16), 255)


PALETTE: dict[str, tuple[int, int, int, int]] = {
    # Shared outline (same as the packs' prop outline).
    "O": _rgb("#2b2733"),
    # Portal: dark core to glowing rim; sparkles.
    "1": _rgb("#170c2e"),
    "2": _rgb("#3d1f78"),
    "3": _rgb("#7446d8"),
    "4": _rgb("#b48cff"),
    "5": _rgb("#22c3b2"),
    "6": _rgb("#a2f7e9"),
    "7": _rgb("#ffffff"),
    # Vent: metal shades, the dark slot and highlights.
    "a": _rgb("#c4cbd8"),
    "b": _rgb("#8d96a9"),
    "c": _rgb("#5b6377"),
    "d": _rgb("#121119"),
    "e": _rgb("#eef2f8"),
    # Cardboard box: outside, shade, side, inside, packing tape.
    "f": _rgb("#d9a066"),
    "g": _rgb("#b77d45"),
    "h": _rgb("#8f5b2c"),
    "i": _rgb("#4a2f18"),
    "k": _rgb("#2e1c0d"),
    "l": _rgb("#ecc08a"),
    "j": _rgb("#f1e0b4"),
}
SOLID = "123456abcdefghiklj"


def rgba(index: str) -> tuple[int, int, int, int]:
    return (0, 0, 0, 0) if index == "." else PALETTE[index]


@dataclass(frozen=True)
class Frame:
    back: Canvas
    front: Canvas | None
    ms: int


@dataclass(frozen=True)
class Style:
    id: str
    name: str
    enter: list[Frame]
    exit: list[Frame]


def _blank() -> Canvas:
    return Canvas(FRAME_W, FRAME_H)


def _outlined(c: Canvas) -> Canvas:
    c.outline(SOLID, "O")
    return c


# --- swirly portal -----------------------------------------------------------------------

PORTAL_RX = 15.5
PORTAL_RY = 5.2
SPARKS = [(12, 5), (33, 3), (22, 1), (38, 6), (17, 2), (28, 5)]


def _portal(size: float, phase: float = 0.0, sparks: int = -1) -> Canvas:
    """Floor portal: an elliptical iris of `size` (0..1) with swirl arms rotated by `phase`."""
    c = _blank()
    if size <= 0:
        return c
    rx, ry = PORTAL_RX * size, PORTAL_RY * size
    for y in range(FRAME_H):
        for x in range(FRAME_W):
            u, v = (x - CX) / rx, (y - CY) / ry
            r = math.hypot(u, v)
            if r > 1.0:
                continue
            arm = (math.atan2(v, u) / (2 * math.pi) * 3 + r * 1.4 + phase) % 1.0
            if r > 0.8:
                c.put(x, y, "6" if arm < 0.45 else "5")
            elif r > 0.5:
                c.put(x, y, "4" if arm < 0.4 else "3")
            elif r > 0.22:
                c.put(x, y, "3" if arm < 0.3 else "2")
            else:
                c.put(x, y, "1")
    if size < 0.3:
        # A newborn (or dying) iris is a bright pinprick.
        c.ellipse(CX, CY, rx * 0.6, ry * 0.6, "7")
    _outlined(c)
    if sparks >= 0:
        for i, (sx, sy) in enumerate(SPARKS):
            rise = (sparks + i) % 3
            c.put(sx, sy - rise + 2, "7" if (sparks + i) % 2 else "6")
    return c


def _portal_style() -> Style:
    turn = [i / 6 for i in range(6)]
    enter = [
        Frame(_portal(0.2), None, 40),
        Frame(_portal(0.45), None, 40),
        Frame(_portal(0.75, turn[0]), None, 40),
        Frame(_portal(1.0, turn[1]), None, 40),
        *[Frame(_portal(1.0, turn[(2 + i) % 6], sparks=i), None, 80) for i in range(6)],
        Frame(_portal(0.6, turn[2]), None, 60),
        Frame(_portal(0.25), None, 50),
        Frame(_blank(), None, 50),
    ]
    exit_ = [
        _portal(0.3),
        _portal(0.7, turn[0]),
        _portal(1.0, turn[1], sparks=0),
        _portal(1.0, turn[2], sparks=1),
        _portal(1.0, turn[3], sparks=2),
        _portal(0.6, turn[4]),
        _portal(0.25),
        _blank(),
    ]
    return Style("portal", "Swirly portal", enter, [Frame(b, None, EXIT_FRAME_MS) for b in exit_])


# --- floor vent --------------------------------------------------------------------------

VENT_X0, VENT_X1 = 11, 36  # front edge columns
VENT_Y0, VENT_Y1 = 9, 14  # back and front edge rows (the cat's feet line runs between)
VENT_INSET = 2  # the back edge is this much narrower on each side (floor perspective)


def _vent(state: str, scale: float = 1.0, dust: int = -1) -> Canvas:
    """Floor vent. `state`: closed | lifting | open. `scale` shrinks a closed vent popping in."""
    c = _blank()
    if state == "closed":
        hw = (VENT_X1 - VENT_X0) / 2 * scale
        hh = (VENT_Y1 - VENT_Y0) / 2 * scale
        x0, x1 = round(CX - hw), round(CX + hw)
        y0, y1 = round(CY - hh), round(CY + hh)
        _grate(c, x0, x1, y0, y1, VENT_INSET if scale >= 1.0 else 1)
        if scale >= 1.0:
            for sx, sy in ((x0 + 3, y0), (x1 - 3, y0), (x0 + 1, y1), (x1 - 1, y1)):
                c.put(sx, sy, "e")
        return _outlined(c)
    # Open or opening: the metal rim around the dark slot, its front lip catching the light.
    _trapezoid(c, VENT_X0, VENT_X1, VENT_Y0, VENT_Y1, VENT_INSET, "c")
    _trapezoid(c, VENT_X0 + 2, VENT_X1 - 2, VENT_Y0 + 1, VENT_Y1 - 1, VENT_INSET - 1, "d")
    for x in range(VENT_X0, VENT_X1 + 1):
        c.put(x, VENT_Y1, "b")
    top0, top1 = VENT_X0 + VENT_INSET, VENT_X1 - VENT_INSET
    if state == "lifting":
        # Cover hinged on the back edge, tilted halfway up: foreshortened, grate still facing up.
        _grate(c, top0, top1, VENT_Y0 - 4, VENT_Y0, 0)
    else:
        # Cover standing upright behind the slot, grate facing the viewer.
        _grate(c, top0, top1, 0, VENT_Y0, 0)
    _outlined(c)
    if dust >= 0:
        for i, (dx, dy) in enumerate(((9, 9), (39, 8), (8, 5), (40, 4))):
            c.put(dx + (dust + i) % 2, dy - 2 * dust, "a")
    return c


def _trapezoid(c: Canvas, x0: int, x1: int, y0: int, y1: int, inset: int, fill: str) -> None:
    c.polygon([(x0 + inset, y0), (x1 - inset, y0), (x1, y1), (x0, y1)], fill)


def _grate(c: Canvas, x0: int, x1: int, y0: int, y1: int, inset: int) -> None:
    """Slotted metal plate from row y0 (back) to y1 (front); the back edge is `inset` narrower."""
    _trapezoid(c, x0, x1, y0, y1, inset, "b")
    for x in range(x0, x1 + 1):
        c.put(x, y0, "a", only="b")
        c.put(x, y1, "c", only="b")
    mid = (x0 + x1) // 2
    for y in range(y0 + 1, y1 - 1, 2):
        for x in range(x0 + 2, x1 - 1):
            if x not in (mid, mid + 1):
                c.put(x, y, "d", only="b")


def _vent_style() -> Style:
    enter = [
        Frame(_vent("closed", 0.6), None, 40),
        Frame(_vent("closed"), None, 40),
        Frame(_vent("lifting"), None, 40),
        Frame(_vent("open"), None, 40),
        Frame(_vent("open", dust=0), None, 80),
        Frame(_vent("open", dust=1), None, 80),
        Frame(_vent("open"), None, 320),
        Frame(_vent("lifting"), None, 40),
        Frame(_vent("closed"), None, 40),
        Frame(_vent("closed", 0.6), None, 40),
        Frame(_blank(), None, 40),
    ]
    exit_ = [
        _vent("closed"),
        _vent("lifting"),
        _vent("open"),
        _vent("open", dust=0),
        _vent("open", dust=1),
        _vent("lifting"),
        _vent("closed"),
        _blank(),
    ]
    return Style("vent", "Floor vent", enter, [Frame(b, None, EXIT_FRAME_MS) for b in exit_])


# --- cardboard box -----------------------------------------------------------------------

BOX_FLOOR = 22  # bottom row of the front face
BOX_X0, BOX_X1 = 11, 33  # front face columns
BOX_DEPTH = 4  # the back edge sits this many pixels up and to the right


def _box(height: int, lid: str) -> tuple[Canvas, Canvas]:
    """Cardboard box `height` rows tall. `lid`: closed | half | open. Returns (back, front)."""
    back, front = _blank(), _blank()
    if height <= 0:
        return back, front
    d = BOX_DEPTH
    ft = BOX_FLOOR - height + 1  # front top edge row
    bt = ft - d  # back top edge row
    x0, x1 = BOX_X0, BOX_X1
    opening = [(x0, ft), (x0 + d, bt), (x1 + d, bt), (x1, ft)]
    # Back layer: everything behind the cat (inside walls, back and side flaps).
    if lid == "closed":
        back.polygon(opening, "f")
        for i in range(x1 - x0 + 1):
            back.put(x0 + i + d // 2 + 1, ft - d // 2, "j")
    else:
        back.polygon(opening, "i")
        back.polygon([(x0, ft), (x0 + d, bt), (x0 + d, bt + 2), (x0 + 1, ft)], "k")
        for x in range(x0 + d, x1 + d + 1):
            back.put(x, bt, "h")
        if lid == "half":
            back.polygon([(x0, ft), (x0 + d, bt), (x0 + 1, bt - 3), (x0 - 3, ft - 3)], "l")
            back.polygon([(x1, ft), (x1 + d, bt), (x1 + d + 3, bt - 3), (x1 + 3, ft - 3)], "l")
            back.polygon([(x0 + d, bt), (x1 + d, bt), (x1 + d - 1, bt - 3), (x0 + d + 1, bt - 3)], "g")
        else:
            back.polygon([(x0, ft), (x0 + d, bt), (x0 + d - 6, bt + 1), (x0 - 6, ft + 1)], "l")
            back.polygon([(x1, ft), (x1 + d, bt), (x1 + d + 6, bt + 1), (x1 + 6, ft + 1)], "l")
            back.polygon([(x0 + d, bt), (x1 + d, bt), (x1 + d, bt - 4), (x0 + d, bt - 4)], "g")
    # Front layer: the faces in front of the cat.
    front.polygon([(x0, ft), (x1, ft), (x1, BOX_FLOOR), (x0, BOX_FLOOR)], "f")
    front.polygon([(x1 + 1, ft), (x1 + d, bt + 1), (x1 + d, BOX_FLOOR - d), (x1 + 1, BOX_FLOOR)], "g")
    for x in range(x0, x1 + 1):
        front.put(x, BOX_FLOOR, "g")
    if height >= 8:
        # Packing-tape stripe down the front, and a printed "this side up" arrow.
        for y in range(ft, ft + 3):
            front.put((x0 + x1) // 2, y, "j")
            front.put((x0 + x1) // 2 + 1, y, "j")
        front.stamp(x0 + 3, BOX_FLOOR - 6, ["..h..", ".hhh.", "h.h.h", "..h..", "..h.."])
    if lid == "open":
        front.polygon([(x0, ft), (x1, ft), (x1 - 1, ft + 3), (x0 + 1, ft + 3)], "l")
        for x in range(x0 + 1, x1):
            front.put(x, ft + 3, "g")
    elif lid == "half":
        front.polygon([(x0, ft), (x1, ft), (x1 - 1, ft - 3), (x0 - 1, ft - 3)], "l")
    _outlined(back)
    _outlined(front)
    return back, front


def _box_style() -> Style:
    full = BOX_FLOOR - 5
    enter_states = [
        (3, "closed", 40),
        (9, "closed", 40),
        (full, "closed", 40),
        (full, "half", 40),
        (full, "open", 480),
        (full, "half", 60),
        (9, "closed", 50),
        (0, "closed", 50),
    ]
    exit_states = [
        (11, "open"),
        (full, "open"),
        (full, "open"),
        (full, "open"),
        (full, "open"),
        (full, "half"),
        (8, "closed"),
        (0, "closed"),
    ]
    enter = []
    for h, lid, ms in enter_states:
        back, front = _box(h, lid)
        enter.append(Frame(back, front, ms))
    exit_ = []
    for h, lid in exit_states:
        back, front = _box(h, lid)
        exit_.append(Frame(back, front, EXIT_FRAME_MS))
    return Style("box", "Cardboard box", enter, exit_)


def all_styles() -> list[Style]:
    return [_portal_style(), _vent_style(), _box_style()]
