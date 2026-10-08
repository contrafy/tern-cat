"""Frame scripts for every canonical animation. Shared by all packs (only palettes differ)."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Sequence

from . import poses as P
from .cat import SIZE, Pose
from .props import glyph as g


@dataclass(frozen=True)
class Anim:
    name: str
    loop: bool
    frames: Sequence[tuple[Pose, int]]


def _idle() -> Anim:
    return Anim(
        "idle",
        True,
        [
            (P.stand(tail="up"), 420),
            (P.stand(breath=1, tail="up"), 420),
            (P.stand(breath=1, tail="sway", ears="perk"), 300),
            (P.stand(tail="flick"), 160),
            (P.stand(tail="curl"), 260),
        ],
    )


def _walk() -> Anim:
    return Anim(
        "walk",
        True,
        [
            (P.stand(legs="walk0", tail="up", body_dy=1), 130),
            (P.stand(legs="walk1", tail="sway"), 130),
            (P.stand(legs="walk2", tail="up", body_dy=1), 130),
            (P.stand(legs="walk3", tail="curl"), 130),
        ],
    )


def _sit() -> Anim:
    return Anim(
        "sit",
        True,
        [
            (P.sit(tail="wrap"), 520),
            (P.sit(breath=1, tail="wrap"), 520),
            (P.sit(breath=1, tail="wrapflick"), 180),
            (P.sit(tail="wrapcurl", eyes="half"), 320),
        ],
    )


def _sleep() -> Anim:
    return Anim(
        "sleep",
        True,
        [
            (P.curl(props=[g("z_small", 25, 11)]), 520),
            (P.curl(breath=1, props=[g("z_small", 26, 8)]), 520),
            (P.curl(breath=1, props=[g("z_small", 26, 8), g("z_big", 22, 2)]), 520),
            (P.curl(props=[g("z_big", 23, 1)]), 520),
        ],
    )


def _wake() -> Anim:
    return Anim(
        "wake",
        False,
        [
            (P.curl(), 300),
            (P.curl(eyes="half", head_dy=-1), 260),
            (P.curl(eyes="blink", mouth="yawn", head_dy=-2), 420),
            (P.sit(eyes="blink", mouth="yawn"), 300),
            (P.sit(eyes="half"), 220),
            (P.sit(eyes="open"), 360),
        ],
    )


def _stretch() -> Anim:
    return Anim(
        "stretch",
        False,
        [
            (P.stand(), 200),
            (P.bow(0, eyes="half", mouth="neutral"), 260),
            (P.bow(0, eyes="blink", mouth="yawn"), 520),
            (P.bow(1, eyes="blink", mouth="neutral"), 420),
            (P.stand(eyes="half", tail="curl"), 260),
            (P.stand(tail="up"), 300),
        ],
    )


def _groom() -> Anim:
    return Anim(
        "groom",
        True,
        [
            (P.sit(paw="raise", eyes="half"), 260),
            (P.sit(paw="lick", eyes="blink", mouth="tongue"), 200),
            (P.sit(paw="lick", eyes="blink", mouth="neutral", head_dy=1), 200),
            (P.sit(paw="lick", eyes="blink", mouth="tongue"), 200),
            (P.sit(paw="wipe", eyes="blink", ears="back"), 280),
            (P.sit(paw="lick", eyes="blink", mouth="neutral", ears="back"), 220),
        ],
    )


def _blink() -> Anim:
    return Anim(
        "blink",
        False,
        [
            (P.stand(), 300),
            (P.stand(eyes="half"), 60),
            (P.stand(eyes="blink"), 120),
            (P.stand(eyes="half"), 60),
            (P.stand(eyes="open", tail="flick"), 260),
        ],
    )


def _look() -> Anim:
    return Anim(
        "look",
        False,
        [
            (P.stand(ears="perk"), 140),
            (P.stand(ears="perk", eyes="up", head_dy=-1, tail="high", props=[g("question", 28, 0)]), 260),
            (P.stand(ears="perk", eyes="up", head_dy=-1, tail="curl", props=[g("question", 28, 1)]), 300),
            (P.stand(ears="perk", eyes="back", head_dy=-1, tail="high"), 400),
        ],
    )


def _pet() -> Anim:
    happy = {"eyes": "happy", "mouth": "smile"}
    return Anim(
        "pet",
        True,
        [
            (P.sit(**happy, props=[g("purr_a", 11, 8), g("purr_a", 8, 11)]), 300),
            (
                P.sit(
                    **happy,
                    ears="flat",
                    head_dy=1,
                    props=[g("purr_b", 11, 8), g("purr_b", 8, 11), g("heart_small", 28, 3)],
                ),
                300,
            ),
            (P.sit(**happy, breath=1, props=[g("purr_a", 11, 8), g("purr_a", 8, 11), g("heart_small", 28, 1)]), 300),
            (
                P.sit(**happy, ears="flat", head_dy=1, tail="wrapcurl", props=[g("purr_b", 11, 8), g("purr_b", 8, 11)]),
                300,
            ),
        ],
    )


def _poke() -> Anim:
    return Anim(
        "poke",
        False,
        [
            (
                P.stand(
                    eyes="squeeze", ears="back", body_dy=1, head_dx=-1, props=[g("dash", 28, 6), g("dash_short", 29, 9)]
                ),
                130,
            ),
            (P.stand(eyes="wide", ears="back", head_dx=-1, tail="puff", fur_up=True, props=[g("bang", 29, 0)]), 200),
            (P.stand(eyes="narrow", ears="back", mouth="frown", tail="lowflick"), 320),
            (P.stand(eyes="narrow", ears="normal", mouth="frown", tail="low"), 360),
        ],
    )


def _eat() -> Anim:
    bowl_x, bowl_y = 24, 27
    return Anim(
        "eat",
        True,
        [
            (
                P.stand(head_dy=6, head_dx=1, eyes="blink", mouth="open", tail="up", props=[g("bowl", bowl_x, bowl_y)]),
                200,
            ),
            (
                P.stand(
                    head_dy=7, head_dx=1, eyes="blink", mouth="neutral", tail="up", props=[g("bowl", bowl_x, bowl_y)]
                ),
                200,
            ),
            (
                P.stand(
                    head_dy=6,
                    head_dx=1,
                    eyes="blink",
                    mouth="open",
                    tail="sway",
                    props=[g("bowl_half", bowl_x, bowl_y), g("spark", 28, 22)],
                ),
                200,
            ),
            (
                P.stand(
                    head_dy=7,
                    head_dx=1,
                    eyes="happy",
                    mouth="neutral",
                    tail="curl",
                    props=[g("bowl_half", bowl_x, bowl_y)],
                ),
                240,
            ),
        ],
    )


def _play() -> Anim:
    return Anim(
        "play",
        True,
        [
            (P.crouch(0, props=[g("ball", 27, 27)]), 220),
            (P.crouch(1, tail_over=False, props=[g("ball", 27, 27)]), 140),
            (P.crouch(0, props=[g("ball", 27, 27)]), 140),
            (P.stand(legs="stretch", dy=-4, ears="perk", eyes="wide", tail="high", props=[g("ball", 27, 27)]), 120),
            (
                P.stand(
                    legs="swat2",
                    head_dx=1,
                    eyes="happy",
                    mouth="smile",
                    props=[g("ball", 27, 27), g("dash_short", 29, 24)],
                ),
                160,
            ),
            (
                P.stand(
                    legs="swat3",
                    head_dx=1,
                    eyes="up",
                    mouth="smile",
                    tail="curl",
                    props=[g("ball", 28, 25), g("dash", 25, 23)],
                ),
                220,
            ),
        ],
    )


def _happy() -> Anim:
    happy = {"eyes": "happy", "mouth": "smile"}
    return Anim(
        "happy",
        True,
        [
            (P.stand(**happy, tail="high", props=[g("heart", 27, 3)]), 180),
            (P.stand(**happy, tail="high", legs="tuck", dy=-3, ears="perk", props=[g("heart", 27, 1)]), 160),
            (P.stand(**happy, tail="curl", props=[g("heart_small", 29, 1), g("heart_small", 2, 3)]), 180),
            (P.stand(**happy, tail="high", legs="tuck", dy=-2, ears="perk", props=[g("heart_small", 1, 1)]), 160),
        ],
    )


def _disappointed() -> Anim:
    return Anim(
        "disappointed",
        False,
        [
            (P.stand(eyes="open"), 200),
            (P.stand(ears="flat", eyes="sad", mouth="frown", head_dy=1, tail="low"), 320),
            (
                P.stand(ears="flat", eyes="half", mouth="frown", head_dy=2, tail="lowflick", props=[g("puff", 29, 18)]),
                420,
            ),
            (
                P.stand(
                    ears="flat", eyes="sad", mouth="frown", head_dy=2, tail="flat", props=[g("puff_small", 30, 16)]
                ),
                400,
            ),
            (P.stand(ears="flat", eyes="sad", mouth="frown", head_dy=2, tail="flat"), 600),
        ],
    )


def _swat() -> Anim:
    return Anim(
        "swat",
        False,
        [
            (P.stand(eyes="narrow", ears="perk", props=[g("letter_s", 26, 26)]), 360),
            (P.stand(legs="swat1", eyes="narrow", ears="back", tail="curl", props=[g("letter_s", 26, 26)]), 220),
            (
                P.stand(
                    legs="swat2",
                    eyes="squeeze",
                    ears="back",
                    tail="flick",
                    props=[g("letter_s", 27, 20), g("dash", 23, 22), g("dash_short", 23, 25)],
                ),
                110,
            ),
            (
                P.stand(
                    legs="swat3",
                    eyes="happy",
                    mouth="smile",
                    tail="high",
                    props=[g("letter_s_side", 26, 3), g("dash_short", 23, 7), g("dash_short", 29, 13)],
                ),
                160,
            ),
            (P.stand(eyes="half", mouth="smile", tail="curl", props=[g("letter_s", 30, 0)]), 220),
            (P.stand(eyes="half", mouth="smile", tail="up"), 400),
        ],
    )


def _startled() -> Anim:
    return Anim(
        "startled",
        False,
        [
            (
                P.stand(
                    legs="stiff", dy=-2, eyes="wide", ears="back", tail="puff", fur_up=True, props=[g("bang", 29, 0)]
                ),
                130,
            ),
            (P.arch(0, eyes="wide", ears="flat", props=[g("bang", 29, 1)]), 220),
            (P.arch(1, eyes="wide", ears="flat", mouth="open", props=[g("drop", 16, 9)]), 240),
            (P.arch(0, eyes="narrow", ears="back", mouth="frown"), 360),
        ],
    )


def _flop() -> Anim:
    return Anim(
        "flop",
        False,
        [
            (P.sit(eyes="half"), 260),
            (P.tipping(eyes="blink", ears="back"), 140),
            (P.flop(0, eyes="happy", mouth="smile"), 380),
            (P.flop(1, eyes="happy", mouth="smile"), 380),
            (P.flop(0, eyes="sleep", mouth="smile"), 600),
        ],
    )


def _stare() -> Anim:
    return Anim(
        "stare",
        True,
        [
            (P.sit(eyes="narrow"), 900),
            (P.sit(eyes="narrow", tail="wrapflick"), 160),
            (P.sit(eyes="narrow", tail="wrap", ears="back"), 700),
            (P.sit(eyes="narrow", tail="wrapcurl"), 180),
        ],
    )


def _hop() -> Anim:
    return Anim(
        "hop",
        False,
        [
            (P.stand(body_dy=1, ears="perk"), 120),
            (P.stand(legs="stretch", dy=-3, tail="high", eyes="wide"), 90),
            (P.stand(legs="tuck", dy=-5, tail="high", ears="perk", eyes="happy"), 140),
            (P.stand(legs="stretch", dy=-2, tail="curl"), 90),
            (P.stand(body_dy=1, tail="up"), 120),
            (P.stand(tail="up"), 220),
        ],
    )


# The frame's bottom edge is the floor (and the portal's opening): shifting a pose down by
# `dy` sinks it into the floor, and BELOW puts the whole cat under it (an empty frame).
BELOW = SIZE


def _dive() -> Anim:
    # Equal frame durations: the overlay plays the dive as a stepped CSS transition, which
    # can only step evenly. The last frame is empty and is held once the cat is gone.
    ms = 60
    return Anim(
        "dive",
        False,
        [
            (P.crouch(0), ms),
            (P.crouch(1, tail_over=False).but(eyes="narrow"), ms),
            (P.stand(legs="tuck", dy=-5, tail="high", ears="perk", eyes="happy"), ms),
            (P.plunge(0, eyes="squeeze", dy=-1), ms),
            (P.plunge(1, eyes="squeeze", dy=7), ms),
            (P.plunge(0, eyes="squeeze", dy=15), ms),
            (P.plunge(1, eyes="squeeze", dy=23), ms),
            (P.plunge(0, dy=BELOW), ms),
        ],
    )


def _emerge() -> Anim:
    # Starts empty while the portal opens, then ears, head, a scramble onto the rim, a hop
    # out, the landing and a shake. The last frame matches idle's first frame.
    return Anim(
        "emerge",
        False,
        [
            (P.climb(dy=BELOW), 160),
            (P.climb(ears="perk", dy=15), 70),
            (P.climb(ears="perk", eyes="wide", dy=10), 70),
            (P.climb(ears="perk", eyes="squeeze"), 80),
            (P.stand(legs="tuck", dy=-4, tail="high", ears="perk", eyes="happy"), 80),
            (P.stand(body_dy=1, legs="stretch", ears="back", eyes="blink", tail="curl"), 60),
            (
                P.stand(
                    fur_up=True,
                    eyes="squeeze",
                    ears="flat",
                    tail="sway",
                    props=[g("purr_a", 0, 12), g("purr_b", 29, 12)],
                ),
                60,
            ),
            (P.stand(tail="up"), 60),
        ],
    )


BUILDERS = [
    _idle,
    _walk,
    _sit,
    _sleep,
    _wake,
    _stretch,
    _groom,
    _blink,
    _look,
    _pet,
    _poke,
    _eat,
    _play,
    _happy,
    _disappointed,
    _swat,
    _startled,
    _flop,
    _stare,
    _hop,
    _dive,
    _emerge,
]


def all_animations() -> list[Anim]:
    return [b() for b in BUILDERS]
