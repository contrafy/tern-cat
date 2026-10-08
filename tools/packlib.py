"""Deterministic PNG/APNG/sheet encoders shared by tools/build_packs.py and tools/pack_build.py.

Every encoder returns bytes so callers can either write them or compare them against files
on disk. Images are re-created from raw RGBA pixels before encoding, so no source metadata
(ICC profiles, text chunks, gamma, dpi) reaches the output; together with fixed compression
settings this makes the output bytes a pure function of pixels, durations and loop flag for
a given zlib build. Different platforms ship different zlib implementations, which can
compress identical data to different bytes, so cross-machine comparisons use same_image.
"""

from __future__ import annotations

import io
import struct
import zlib

from PIL import Image


def clean_rgba(im: Image.Image) -> Image.Image:
    """Metadata-free RGBA copy of `im` (pixels only)."""
    rgba = im if im.mode == "RGBA" else im.convert("RGBA")
    return Image.frombytes("RGBA", rgba.size, rgba.tobytes())


def encode_png(im: Image.Image) -> bytes:
    buf = io.BytesIO()
    clean_rgba(im).save(buf, format="PNG", optimize=True)
    return buf.getvalue()


def first_duplicate(frames: list[Image.Image]) -> int | None:
    """0-based index i where frames[i] and frames[i + 1] have identical pixels, else None.

    Pillow's APNG writer silently merges identical consecutive frames (adding their
    durations), so such input would produce fewer APNG frames than the manifest lists.
    """
    data = [clean_rgba(f).tobytes() for f in frames]
    for i in range(len(data) - 1):
        if data[i] == data[i + 1]:
            return i
    return None


def encode_apng(frames: list[Image.Image], durations: list[int], loop: bool) -> bytes:
    """Animated PNG; num_plays 0 repeats forever, 1 plays exactly once and holds the last frame."""
    clean = [clean_rgba(f) for f in frames]
    buf = io.BytesIO()
    clean[0].save(
        buf,
        format="PNG",
        save_all=True,
        append_images=clean[1:],
        duration=list(durations),
        loop=0 if loop else 1,
        disposal=0,
        blend=0,
        compress_level=9,
    )
    data = buf.getvalue()
    if len(clean) == 1:
        # Pillow writes a plain PNG for a single frame; add acTL + fcTL so it is a 1-frame APNG.
        data = _single_frame_apng(data, clean[0].width, clean[0].height, durations[0], loop)
    with Image.open(io.BytesIO(data)) as check:
        got = getattr(check, "n_frames", 1)
    if got != len(clean):
        raise ValueError(f"APNG encoder wrote {got} frames, expected {len(clean)} (identical consecutive frames?)")
    return data


def _chunk(kind: bytes, payload: bytes) -> bytes:
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload))


def _single_frame_apng(png: bytes, width: int, height: int, duration_ms: int, loop: bool) -> bytes:
    if not 0 < duration_ms <= 0xFFFF:
        raise ValueError(f"duration {duration_ms} ms does not fit an APNG frame delay")
    pos = 8
    while pos + 8 <= len(png):
        length, kind = struct.unpack(">I4s", png[pos : pos + 8])
        if kind == b"acTL":
            return png
        if kind == b"IDAT":
            actl = _chunk(b"acTL", struct.pack(">II", 1, 0 if loop else 1))
            fctl = _chunk(b"fcTL", struct.pack(">IIIIIHHBB", 0, width, height, 0, 0, duration_ms, 1000, 0, 0))
            return png[:pos] + actl + fctl + png[pos:]
        pos += 12 + length
    raise ValueError("encoded PNG has no IDAT chunk")


def sheet_image(frames: list[Image.Image], width: int, height: int) -> Image.Image:
    """Horizontal strip: frame i occupies x in [i * width, (i + 1) * width)."""
    sheet = Image.new("RGBA", (width * len(frames), height))
    for i, im in enumerate(frames):
        sheet.paste(clean_rgba(im), (i * width, 0))
    return sheet


def encode_sheet(frames: list[Image.Image], width: int, height: int) -> bytes:
    return encode_png(sheet_image(frames, width, height))


PNG_SIG = b"\x89PNG\r\n\x1a\n"


def _actl(data: bytes) -> tuple[int, int] | None:
    """(num_frames, num_plays) from the acTL chunk, or None for a still PNG."""
    pos = len(PNG_SIG)
    while pos + 8 <= len(data):
        length, kind = struct.unpack(">I4s", data[pos : pos + 8])
        if kind == b"acTL" and length >= 8:
            return struct.unpack(">II", data[pos + 8 : pos + 16])
        if kind in (b"IDAT", b"IEND"):
            return None
        pos += 12 + length
    return None


def decoded(data: bytes) -> tuple | None:
    """Compression-independent content of a PNG/APNG, or None when it cannot be decoded.

    Covers dimensions, acTL (frame count and num_plays), and for every displayed frame its
    duration and fully composited RGBA pixels.
    """
    if not data.startswith(PNG_SIG):
        return None
    actl = _actl(data)
    try:
        with Image.open(io.BytesIO(data)) as im:
            frames = []
            for i in range(getattr(im, "n_frames", 1)):
                im.seek(i)
                duration = im.info.get("duration") if actl else None
                frames.append((duration, im.convert("RGBA").tobytes()))
            return (im.size, actl, tuple(frames))
    except Exception:  # noqa: BLE001 - any decoder failure means "not the same image"
        return None


def same_image(a: bytes, b: bytes) -> bool:
    """True when two PNG/APNG files are byte-identical or decode to identical content."""
    if a == b:
        return True
    da = decoded(a)
    return da is not None and da == decoded(b)
