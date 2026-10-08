"""Pose builders: stand, sit, curl (sleep loaf), loaf (sleepy sit), belly-up flop."""

from __future__ import annotations

from .cat import Leg, Pose
from .raster import Point, bezier

TAILS_STAND: dict[str, list[Point]] = {
    "up": bezier((5.5, 20), (-0.5, 17), (2.5, 9), 5) + [(4, 8)],
    "flick": bezier((5.5, 20), (-0.5, 17), (2.0, 10), 5) + [(1, 8)],
    "curl": bezier((5.5, 20), (-0.5, 17), (2.5, 9), 5) + [(4, 8), (5, 9)],
    "sway": bezier((5.5, 20), (0.5, 18), (1.0, 10), 5) + [(2.5, 8.5)],
    "high": [(6, 19.5), (5, 15), (4.5, 11), (4.5, 8), (5.5, 6.5)],
    "low": bezier((5.5, 21), (1, 23), (1.5, 28), 5),
    "lowflick": bezier((5.5, 21), (1, 23), (0.5, 27), 5) + [(1.5, 28.5)],
    "flat": bezier((5.5, 22), (1, 22), (0.5, 26), 4) + [(1, 28)],
    "puff": [(6, 19), (4.5, 15), (4, 11), (4, 7), (5, 5)],
}


def stand(
    breath: float = 0.0,
    tail: str = "up",
    head_dx: int = 0,
    head_dy: int = 0,
    legs: str = "stand",
    body_dy: float = 0.0,
    **kw,
) -> Pose:
    cy = 21.5 + body_dy
    torso = [(14.0, cy - breath * 0.5, 7.6, 4.6 + breath * 0.5), (9.0, cy + 0.5, 4.0, 4.3)]
    return Pose(
        torso=torso,
        chest=(21.0, cy + 1.5, 3.0, 3.0),
        legs=LEGS[legs](body_dy),
        tail=[(x, y + body_dy) for x, y in TAILS_STAND[tail]],
        head=(17 + head_dx, 8 + head_dy + round(body_dy)),
        **kw,
    )


def _legs_stand(dy: float) -> list[Leg]:
    t = 24 + dy
    return [
        Leg((11.5, t), (11.5, 30), near=False),
        Leg((21.5, t), (21.5, 30), near=False),
        Leg((8.5, t), (8.5, 30)),
        Leg((18.5, t), (18.5, 30)),
    ]


def _walk(phase: int):
    def legs(dy: float) -> list[Leg]:
        t = 24 + dy
        # Diagonal gait: near-front pairs with far-back.
        a = [(-2, 0), (0, 0), (2, 0), (0, -1)][phase]
        b = [(2, 0), (0, -1), (-2, 0), (0, 0)][phase]
        return [
            Leg((11.5, t), (11.5 + a[0], 30 + a[1]), near=False),
            Leg((21.5, t), (21.5 + b[0], 30 + b[1]), near=False),
            Leg((8.5, t), (8.5 + b[0], 30 + b[1])),
            Leg((18.5, t), (18.5 + a[0], 30 + a[1])),
        ]

    return legs


def _legs_tuck(dy: float) -> list[Leg]:
    t = 24 + dy
    return [
        Leg((11.5, t), (10.5, t + 3), near=False),
        Leg((21.5, t), (23.0, t + 3), near=False),
        Leg((8.5, t), (6.5, t + 4)),
        Leg((18.5, t), (20.5, t + 4)),
    ]


def _legs_stretch_out(dy: float) -> list[Leg]:
    t = 24 + dy
    return [
        Leg((11.5, t), (8.5, 30), near=False),
        Leg((21.5, t), (24.5, 30), near=False),
        Leg((8.5, t), (5.5, 30)),
        Leg((18.5, t), (21.5, 30)),
    ]


def _legs_stiff(dy: float) -> list[Leg]:
    t = 24 + dy
    return [
        Leg((11.5, t), (10.5, 30), near=False),
        Leg((20.5, t), (21.5, 30), near=False),
        Leg((8.5, t), (7.5, 30)),
        Leg((17.5, t), (18.5, 30)),
    ]


def _legs_swat(stage: int):
    def legs(dy: float) -> list[Leg]:
        t = 24 + dy
        front = {
            0: Leg((18.5, t), (18.5, 30)),
            1: Leg((19.5, t - 1), (22.0, t - 2), knee=(21.5, t)),
            2: Leg((19.5, t - 1), (25.5, t + 3), knee=(22.5, t + 0.5)),
            3: Leg((18.5, t), (20.5, 30)),
        }[stage]
        return [
            Leg((11.5, t), (11.5, 30), near=False),
            Leg((21.5, t), (21.5, 30), near=False),
            Leg((8.5, t), (8.5, 30)),
            front,
        ]

    return legs


LEGS = {
    "stand": _legs_stand,
    "walk0": _walk(0),
    "walk1": _walk(1),
    "walk2": _walk(2),
    "walk3": _walk(3),
    "tuck": _legs_tuck,
    "stretch": _legs_stretch_out,
    "stiff": _legs_stiff,
    "swat0": _legs_swat(0),
    "swat1": _legs_swat(1),
    "swat2": _legs_swat(2),
    "swat3": _legs_swat(3),
}


TAILS_SIT: dict[str, list[Point]] = {
    "wrap": [(9, 27.5), (6, 29), (4, 29), (2.5, 27.5), (2.5, 25.5)],
    "wrapflick": [(9, 27.5), (6, 29), (4, 29), (2.5, 27.5), (1.5, 26)],
    "wrapcurl": [(9, 27.5), (6, 29), (4, 29), (2.5, 27.5), (3, 25.5), (4, 25)],
    "front": [(9, 28), (7, 29.5), (13, 29.5), (19, 29.5), (23, 29)],
    "up": [(8, 26), (5, 23), (4, 19), (4, 15), (5, 13)],
    "thump": [(8, 27.5), (4, 28), (1.5, 29)],
}


def sit(
    breath: float = 0.0,
    tail: str = "wrap",
    head_dx: int = 0,
    head_dy: int = 0,
    paw: str = "down",
    **kw,
) -> Pose:
    legs = [
        Leg((21.0, 22), (21.0, 30), near=False),
        Leg((12.5, 28.5), (16.5, 30.0), paw_forward=1),
    ]
    if paw == "down":
        legs.append(Leg((18.5, 21), (18.5, 30)))
    elif paw == "raise":
        legs.append(Leg((18.5, 21), (22.5, 19.5), knee=(21.5, 23), lined=True, paw_forward=0))
    elif paw == "lick":
        legs.append(Leg((18.5, 21), (22.5, 17.5), knee=(21.5, 22), lined=True, over_head=True, paw_forward=0))
    elif paw == "wipe":
        legs.append(Leg((18.5, 21), (23.5, 13.5), knee=(21.5, 19), lined=True, over_head=True, paw_forward=0))
    return Pose(
        torso=[(13.0 - breath * 0.0, 24.5 - breath * 0.5, 6.0, 5.5 + breath * 0.5), (17.5, 19.5, 3.6, 5.5)],
        chest=(19.5, 21.0, 2.6, 4.0),
        legs=legs,
        tail=TAILS_SIT[tail],
        head=(14 + head_dx, 5 + head_dy),
        stripes=True,
        **kw,
    )


def curl(breath: float = 0.0, head_dy: int = 0, eyes: str = "sleep", ears: str = "normal", **kw) -> Pose:
    return Pose(
        torso=[(14.0, 25.0 - breath * 0.5, 10.0, 5.5 + breath * 0.5)],
        chest=None,
        legs=[Leg((19.5, 27.0), (23.5, 29.0), paw_forward=1, lined=True)],
        tail=[(5, 28), (9, 30), (15, 30), (20, 30), (24, 29.5)],
        tail_over=True,
        head=(17, 15 + head_dy),
        eyes=eyes,
        ears=ears,
        mouth=kw.pop("mouth", "none"),
        **kw,
    )


def flop(stage: int = 0, **kw) -> Pose:
    """Belly-up flop. Stage 0/1 alternate the paw positions (a slow wiggle)."""
    a = 0.0 if stage == 0 else 1.0
    legs = [
        Leg((5.0, 25), (3.0 - a, 18.5 + a), near=False, paw_forward=-1),
        Leg((12.5, 25), (13.0 + a, 18.0), near=False, paw_forward=1),
        Leg((8.5, 25), (7.5, 17.5 + a), lined=True, paw_forward=-1),
        Leg((16.0, 25), (17.0, 18.0 - a), lined=True, paw_forward=1),
    ]
    return Pose(
        torso=[(12.0, 27.0, 9.0, 3.5)],
        belly=(11.5, 25.0, 6.0, 1.8),
        legs=legs,
        tail=[(4.0, 28.5), (1.5, 28.5), (0.5, 27 - a)],
        head=(18, 20),
        head_turn="flip",
        stripes=False,
        **kw,
    )


def tipping(**kw) -> Pose:
    """Mid-fall between sitting and the flop: body low, legs loose, head still upright."""
    return Pose(
        torso=[(13.0, 26.0, 8.5, 4.0)],
        chest=(19.0, 26.5, 2.5, 2.5),
        legs=[
            Leg((17.0, 27), (21.5, 29.5), near=False),
            Leg((10.0, 27), (6.0, 25.0), knee=(7.5, 28), lined=True, paw_forward=0),
            Leg((18.0, 27), (22.5, 24.0), knee=(21.0, 28.0), lined=True, paw_forward=0),
        ],
        tail=[(5.0, 25.0), (2.5, 22), (2, 19)],
        head=(18, 13),
        **kw,
    )


def bow(stage: int = 0, **kw) -> Pose:
    """Stretch. Stage 0: play-bow (front low, rear high); stage 1: rear-leg stretch."""
    if stage == 0:
        return Pose(
            torso=[(11.0, 20.5, 5.5, 4.3), (17.5, 24.5, 5.0, 3.2)],
            chest=(21.0, 26.0, 2.5, 1.8),
            legs=[
                Leg((12.5, 23), (12.5, 30), near=False),
                Leg((19.0, 26), (26.0, 29.5), near=False, paw_forward=1),
                Leg((9.5, 23), (9.5, 30)),
                Leg((18.5, 27), (25.0, 30.0), paw_forward=1),
            ],
            tail=[(6.0, 18.5), (4.0, 15.0), (3.5, 11.0), (4.5, 8.0), (6.0, 7.0)],
            head=(18, 15),
            **kw,
        )
    return Pose(
        torso=[(14.5, 22.0, 7.0, 4.2), (10.0, 22.5, 3.5, 3.8)],
        chest=(21.0, 23.0, 2.8, 2.8),
        legs=[
            Leg((12.0, 24), (12.0, 30), near=False),
            Leg((21.5, 24), (21.5, 30), near=False),
            Leg((9.5, 24), (3.5, 28.5), knee=(6.5, 26.5), paw_forward=-1),
            Leg((18.5, 24), (19.5, 30)),
        ],
        tail=[(7.5, 20.5), (4.5, 19.5), (2.0, 19.0), (0.5, 18.0)],
        head=(18, 9),
        **kw,
    )


def arch(fluff: int = 0, **kw) -> Pose:
    """Startled Halloween-cat arch: spine bowed high, belly lifted, stiff legs, head low."""
    r = 3.4 + fluff * 0.3
    spine = bezier((7.5, 21.5), (13.0, 9.5), (19.0, 21.0), 8)
    return Pose(
        torso=[(13.0, 16.5, 4.0, 3.2)] + [(x, y, r, r) for x, y in spine],
        chest=(20.0, 23.0, 2.3, 2.0),
        legs=[
            Leg((10.0, 23), (10.5, 30), near=False),
            Leg((20.0, 23), (21.5, 30), near=False),
            Leg((7.5, 23), (7.0, 30)),
            Leg((18.0, 23), (18.5, 30)),
        ],
        tail=[(6.0, 19.0), (4.0, 15.0), (3.5, 10.0), (4.5, 5.5)],
        tail_r=1.1,
        fur_up=True,
        head=(18, 12),
        **kw,
    )


def crouch(wiggle: int = 0, **kw) -> Pose:
    """Hunting crouch: belly low, rear up, ready to pounce."""
    return Pose(
        torso=[(13.5, 24.5, 7.5, 3.8), (8.5, 23.5 - wiggle, 4.0, 3.8)],
        chest=(20.5, 26.0, 2.5, 2.0),
        legs=[
            Leg((11.0, 26), (12.0, 30), near=False),
            Leg((21.0, 27), (23.0, 30), near=False),
            Leg((8.5, 26 - wiggle), (9.5, 30), knee=(7.0, 28)),
            Leg((18.5, 27), (20.5, 30)),
        ],
        tail=[(5.0, 23.5 - wiggle), (2.5, 24.0), (1.0, 26.0 - wiggle * 2), (1.5, 28.0 - wiggle * 2)],
        head=(18, 14),
        ears="perk",
        eyes="wide",
        **kw,
    )


def plunge(tail: int = 0, **kw) -> Pose:
    """Nose-first dive: body vertical, head down (face toward the floor), rear and tail up.

    Pitched forward 90 degrees, so the back faces right and the legs trail on the left.
    `tail` 0/1 swaps the tail between a straight and a flicked tip.
    """
    tip = [(19.5, 1.0), (21.0, -0.5)] if tail else [(18.5, 0.5), (19.0, -1.0)]
    return Pose(
        torso=[(16.0, 15.0, 4.0, 5.5), (15.5, 8.5, 3.6, 3.6)],
        chest=(13.0, 17.5, 1.8, 2.5),
        legs=[
            Leg((13.5, 15), (11.5, 27.5), near=False, paw_forward=0),
            Leg((14.5, 17), (12.5, 29.0), paw_forward=0, lined=True, over_head=True),
            Leg((13.0, 9), (10.0, 3.0), near=False, paw_forward=0),
            Leg((14.0, 10), (11.5, 3.5), knee=(11.5, 7.5), paw_forward=0, lined=True),
        ],
        tail=[(17.5, 6.0), (18.0, 3.0)] + tip,
        head=(10, 18),
        head_turn="cw",
        mouth=kw.pop("mouth", "none"),
        **kw,
    )


def climb(**kw) -> Pose:
    """Climbing out of a hole in the floor: head up, front paws planted on the rim, body below."""
    return Pose(
        torso=[(14.5, 28.0, 5.0, 6.0)],
        chest=(17.5, 27.5, 2.6, 4.0),
        legs=[
            Leg((19.0, 25), (24.5, 30.0), knee=(22.5, 25.0), near=False),
            Leg((11.0, 25), (7.0, 30.0), knee=(8.5, 25.0), paw_forward=-1),
            Leg((19.5, 26), (26.0, 30.5), knee=(24.0, 26.0), lined=True, over_head=True),
        ],
        tail=[(10.0, 33.0), (10.0, 34.0)],
        head=(10, 14),
        **kw,
    )
