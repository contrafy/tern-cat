"""Index-color raster canvas and drawing primitives for the tern-cat pixel art.

A canvas is a fixed grid of single-character palette indices; "." is transparent.
Pixel (x, y) is sampled at its center, so shapes are positioned in pixel units.
"""

from __future__ import annotations

import math
from typing import Iterable, Sequence

CLEAR = "."

Point = tuple[float, float]


class Canvas:
    def __init__(self, width: int, height: int) -> None:
        self.width = width
        self.height = height
        self.px: list[list[str]] = [[CLEAR] * width for _ in range(height)]

    def inside(self, x: int, y: int) -> bool:
        return 0 <= x < self.width and 0 <= y < self.height

    def get(self, x: int, y: int) -> str:
        return self.px[y][x] if self.inside(x, y) else CLEAR

    def put(self, x: int, y: int, c: str, only: str | None = None) -> None:
        if not self.inside(x, y):
            return
        if only is not None and self.px[y][x] not in only:
            return
        self.px[y][x] = c

    def rows(self) -> list[str]:
        return ["".join(r) for r in self.px]

    def bbox(self, keep: Iterable[str] | None = None) -> tuple[int, int, int, int] | None:
        keep_set = set(keep) if keep is not None else None
        xs: list[int] = []
        ys: list[int] = []
        for y, row in enumerate(self.px):
            for x, c in enumerate(row):
                if c != CLEAR and (keep_set is None or c in keep_set):
                    xs.append(x)
                    ys.append(y)
        if not xs:
            return None
        return min(xs), min(ys), max(xs), max(ys)

    def _span(self, lo: float, hi: float, limit: int) -> range:
        return range(max(0, math.floor(lo) - 1), min(limit, math.ceil(hi) + 2))

    def ellipse(self, cx: float, cy: float, rx: float, ry: float, c: str, only: str | None = None) -> None:
        for y in self._span(cy - ry, cy + ry, self.height):
            for x in self._span(cx - rx, cx + rx, self.width):
                if ((x - cx) / rx) ** 2 + ((y - cy) / ry) ** 2 <= 1.0:
                    self.put(x, y, c, only)

    def capsule(self, a: Point, b: Point, r: float, c: str, only: str | None = None) -> None:
        (ax, ay), (bx, by) = a, b
        dx, dy = bx - ax, by - ay
        ll = dx * dx + dy * dy
        for y in self._span(min(ay, by) - r, max(ay, by) + r, self.height):
            for x in self._span(min(ax, bx) - r, max(ax, bx) + r, self.width):
                t = 0.0 if ll == 0 else max(0.0, min(1.0, ((x - ax) * dx + (y - ay) * dy) / ll))
                px, py = ax + t * dx, ay + t * dy
                if (x - px) ** 2 + (y - py) ** 2 <= r * r:
                    self.put(x, y, c, only)

    def stroke(self, pts: Sequence[Point], r: float, c: str, only: str | None = None) -> None:
        if len(pts) == 1:
            self.capsule(pts[0], pts[0], r, c, only)
        for a, b in zip(pts, pts[1:]):
            self.capsule(a, b, r, c, only)

    def stamp(self, x0: int, y0: int, rows: Sequence[str], only: str | None = None) -> None:
        for dy, row in enumerate(rows):
            for dx, c in enumerate(row):
                if c != CLEAR and c != " ":
                    self.put(x0 + dx, y0 + dy, c, only)

    def outline(self, body: str, c: str, diagonal: bool = False) -> None:
        """Paint transparent pixels touching any `body` index with `c`."""
        nbrs = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        if diagonal:
            nbrs += [(1, 1), (-1, 1), (1, -1), (-1, -1)]
        marks = []
        for y in range(self.height):
            for x in range(self.width):
                if self.px[y][x] != CLEAR:
                    continue
                if any(self.get(x + dx, y + dy) in body for dx, dy in nbrs):
                    marks.append((x, y))
        for x, y in marks:
            self.px[y][x] = c

    def shift(self, dx: int, dy: int) -> "Canvas":
        out = Canvas(self.width, self.height)
        for y in range(self.height):
            for x in range(self.width):
                c = self.px[y][x]
                if c != CLEAR:
                    out.put(x + dx, y + dy, c)
        return out


def bezier(p0: Point, p1: Point, p2: Point, steps: int = 8) -> list[Point]:
    out = []
    for i in range(steps + 1):
        t = i / steps
        u = 1 - t
        out.append(
            (u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1])
        )
    return out
