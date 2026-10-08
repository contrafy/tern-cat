# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Synthesize the default tern-cat sound pack (original, code-generated).

Usage: uv run tools/build_sounds.py

Writes assets/sounds/default/{meow,purr,surprise,happy,swat}.wav and sounds.json.
22050 Hz mono 16-bit PCM, peak-normalized to -6 dBFS. Deterministic: fixed seeds and
no timestamps (the stdlib wave writer emits only RIFF/fmt/data chunks).
"""

from __future__ import annotations

import json
import math
import random
import struct
import wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "assets" / "sounds" / "default"
RATE = 22050
PEAK_DBFS = -6.0
MAX_SECONDS = 1.5
AUTHOR = "Ahmad Raaiyan"
TAU = 2.0 * math.pi


def envelope(n: int, attack: float, release: float) -> list[float]:
    a = max(1, int(attack * RATE))
    r = max(1, int(release * RATE))
    out = []
    for i in range(n):
        g = 1.0
        if i < a:
            g = i / a
        if i > n - r:
            g = min(g, max(0.0, (n - i) / r))
        out.append(g)
    return out


def lowpass(xs: list[float], cutoff: float) -> list[float]:
    k = 1.0 - math.exp(-TAU * cutoff / RATE)
    y = 0.0
    out = []
    for x in xs:
        y += k * (x - y)
        out.append(y)
    return out


def highpass(xs: list[float], cutoff: float) -> list[float]:
    low = lowpass(xs, cutoff)
    return [x - lo for x, lo in zip(xs, low)]


def formant_gain(f: float, centers: tuple[float, ...], width: float) -> float:
    return sum(math.exp(-(((f - c) / width) ** 2)) for c in centers) + 0.08


def meow() -> list[float]:
    dur = 0.62
    n = int(dur * RATE)
    env = envelope(n, 0.03, 0.18)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n
        # "mi-AAA-ow": rise then fall, with a slight vibrato.
        f0 = 470 + 340 * math.sin(math.pi * min(1.0, t * 1.15)) - 140 * max(0.0, t - 0.75) / 0.25
        f0 *= 1.0 + 0.012 * math.sin(TAU * 6.0 * i / RATE)
        phase += TAU * f0 / RATE
        # Vowel morph: bright "ee" formants to round "ow" formants.
        f1 = 350 + 450 * min(1.0, t * 1.8) - 250 * max(0.0, t - 0.55)
        f2 = 2300 - 1200 * t
        s = 0.0
        for k in range(1, 12):
            fk = f0 * k
            if fk > RATE / 2.2:
                break
            s += formant_gain(fk, (f1, f2), 260.0) * math.sin(phase * k) / k**0.5
        out.append(s * env[i])
    return out


def purr(rng: random.Random) -> list[float]:
    dur = 1.2
    n = int(dur * RATE)
    noise = [rng.uniform(-1.0, 1.0) for _ in range(n)]
    rumble = lowpass(lowpass(lowpass(noise, 200.0), 240.0), 280.0)
    env = envelope(n, 0.08, 0.2)
    out = []
    for i in range(n):
        t = i / RATE
        # ~26 Hz flutter; two breaths (out louder than in) over the clip.
        flutter = 0.5 + 0.5 * math.sin(TAU * 26.0 * t) ** 2
        breath = 0.65 + 0.35 * math.sin(TAU * t / 1.2 * 2.0 - math.pi / 2) ** 2
        tone = 0.25 * math.sin(TAU * 52.0 * t)
        out.append((rumble[i] * 6.0 + tone) * flutter * breath * env[i])
    return highpass(out, 30.0)


def surprise() -> list[float]:
    dur = 0.28
    n = int(dur * RATE)
    env = envelope(n, 0.005, 0.12)
    out = []
    phase = 0.0
    for i in range(n):
        t = i / n
        f = 380.0 * (1600.0 / 380.0) ** (t**0.7)
        phase += TAU * f / RATE
        s = math.sin(phase) + 0.35 * math.sin(2 * phase) + 0.15 * math.sin(3 * phase)
        out.append(s * env[i])
    return out


def happy() -> list[float]:
    notes = [880.0, 1174.66, 880.0, 1174.66, 1318.51]
    lengths = [0.075, 0.075, 0.075, 0.075, 0.16]
    out: list[float] = []
    phase = 0.0
    for f, length in zip(notes, lengths):
        n = int(length * RATE)
        env = envelope(n, 0.006, 0.03)
        for i in range(n):
            vib = 1.0 + 0.01 * math.sin(TAU * 9.0 * i / RATE)
            phase += TAU * f * vib / RATE
            s = math.sin(phase) + 0.3 * math.sin(2 * phase) + 0.1 * math.sin(3 * phase)
            out.append(s * env[i])
    return out


def swat(rng: random.Random) -> list[float]:
    whoosh_n = int(0.2 * RATE)
    noise = [rng.uniform(-1.0, 1.0) for _ in range(whoosh_n)]
    band = highpass(lowpass(noise, 2400.0), 500.0)
    out = []
    for i in range(whoosh_n):
        t = i / whoosh_n
        g = math.sin(math.pi * t) ** 1.5
        out.append(band[i] * g * 3.0)
    out += [0.0] * int(0.02 * RATE)
    tick_n = int(0.05 * RATE)
    for i in range(tick_n):
        t = i / RATE
        out.append(math.exp(-t * 140.0) * (math.sin(TAU * 2100.0 * t) + 0.5 * math.sin(TAU * 3300.0 * t)))
    out += [0.0] * int(0.03 * RATE)
    return out


def to_pcm(samples: list[float]) -> bytes:
    peak = max(abs(s) for s in samples) or 1.0
    target = 10 ** (PEAK_DBFS / 20.0) * 32767.0
    scale = target / peak
    return b"".join(struct.pack("<h", int(round(s * scale))) for s in samples)


def write_wav(name: str, samples: list[float]) -> str:
    if len(samples) / RATE > MAX_SECONDS:
        raise SystemExit(f"{name}: {len(samples) / RATE:.2f}s exceeds {MAX_SECONDS}s")
    path = OUT / f"{name}.wav"
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(to_pcm(samples))
    return path.name


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    sounds = {
        "meow": write_wav("meow", meow()),
        "purr": write_wav("purr", purr(random.Random(0x7075))),
        "surprise": write_wav("surprise", surprise()),
        "happy": write_wav("happy", happy()),
        "swat": write_wav("swat", swat(random.Random(0x5357))),
    }
    manifest = {
        "schema_version": 1,
        "id": "default",
        "name": "Default Cat Sounds",
        "author": AUTHOR,
        "license": "CC-BY-4.0",
        "sounds": sounds,
    }
    (OUT / "sounds.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for name, file in sounds.items():
        print(f"wrote assets/sounds/default/{file} ({(OUT / file).stat().st_size} bytes)")


if __name__ == "__main__":
    main()
