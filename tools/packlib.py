"""Deterministic PNG/APNG/sheet encoders shared by tools/build_packs.py and tools/pack_build.py.

Every encoder returns bytes so callers can either write them or compare them against files
on disk. Images are re-created from raw RGBA pixels before encoding, so no source metadata
(ICC profiles, text chunks, gamma, dpi) reaches the output; together with fixed compression
settings this makes the output bytes a pure function of pixels, durations and loop flag.
"""

from __future__ import annotations

import io

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
    with Image.open(io.BytesIO(data)) as check:
        got = getattr(check, "n_frames", 1)
    if got != len(clean):
        raise ValueError(f"APNG encoder wrote {got} frames, expected {len(clean)} (identical consecutive frames?)")
    return data


def sheet_image(frames: list[Image.Image], width: int, height: int) -> Image.Image:
    """Horizontal strip: frame i occupies x in [i * width, (i + 1) * width)."""
    sheet = Image.new("RGBA", (width * len(frames), height))
    for i, im in enumerate(frames):
        sheet.paste(clean_rgba(im), (i * width, 0))
    return sheet


def encode_sheet(frames: list[Image.Image], width: int, height: int) -> bytes:
    return encode_png(sheet_image(frames, width, height))
