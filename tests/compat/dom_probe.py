"""DOM-hook probe for scripts/compat.sh (Python 3 standard library only).

Drives a sandboxed control window (`tern --control`) with a 2-pane split and asserts that every
undocumented Tern hook tern-cat relies on still exists: the selectors of cat/render/overlay.luau,
cat/render/travel.luau and tern-cat.css, the `--tv-px`/`--tv-py`/`--tv-aside` variables, the
pane insets travel.insets models, the floated card's classes, and the window-half reads of
window.luau (through the probe plugin in tests/compat/probe). It also exercises the behaviors
built on them: the overlay at four corners, pointer pass-through, the walk and portal switches,
the full-screen hide, the floated card's buttons and settings page, and reduced motion.

Run by scripts/compat.sh, which sources scripts/sandbox-env.sh, links the snapshot packages and
cleans up. Environment: SB (sandbox), TERN_BIN (the tern executable, for the static checks).
Exit status: 0 when every check passes, 1 otherwise (missing hooks are listed at the end).
"""

from __future__ import annotations

import json
import os
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

SB = Path(os.environ["SB"])
OUT = SB / "compat"
SHOTS = OUT / "shots"
EP = SB / "probe-win.sock"
WORK = SB / "work"
SETTINGS = SB / "config" / "settings.json"
DATA = SB / "config" / "plugin-data"
CFG = DATA / "tern-cat" / "config.json"
KV = DATA / "tern-cat" / "kv.json"
PROBE = DATA / "tern-cat-probe" / "probe.json"
PROBE_CSS = OUT / "probe.css"
OVERLAY = "plugin:local:tern-cat:overlay"
TRAVEL = "plugin:local:tern-cat:travel"
CORNERS = ("top-right", "top-left", "bottom-right", "bottom-left")
# cat/render/travel.luau insets(): padding and header at a 13 px interface.
TERN_UI_PX = 13
HEADER_PX = 30
TOLERANCE_PX = 1.0

results: list[tuple[bool, str, str]] = []
missing: list[str] = []


def check(ok: bool, name: str, detail: str = "", hook: str | None = None) -> bool:
    results.append((ok, name, detail))
    print(f"{'PASS' if ok else 'FAIL'}  {name}{': ' + detail if detail and not ok else ''}", flush=True)
    if not ok and hook:
        missing.append(f"{hook} ({name}{': ' + detail if detail else ''})")
    return ok


def ctl(*args: str) -> dict:
    try:
        r = subprocess.run(
            ["tern", "ctl", "--control", str(EP), *args],
            capture_output=True,
            text=True,
            timeout=30,
            cwd=SB,
        )
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "timeout"}
    try:
        return json.loads(r.stdout)
    except ValueError:
        return {"ok": False, "error": (r.stdout + r.stderr).strip()[-300:]}


def wait_for(fn, secs: float, step: float = 0.15):
    end = time.time() + secs
    while True:
        value = fn()
        if value or time.time() >= end:
            return value
        time.sleep(step)


# Window and daemon --------------------------------------------------------------------------


def stop_window() -> None:
    if EP.exists():
        ctl("quit")
        time.sleep(1)
    for pattern in (f"tern --control {EP}", f"tern daemon --socket {SB}/daemon.sock"):
        pids = subprocess.run(["pgrep", "-f", pattern], capture_output=True, text=True).stdout.split()
        for pid in pids:
            try:
                os.kill(int(pid), signal.SIGTERM)
            except (ProcessLookupError, ValueError):
                pass
    for path in (EP, SB / "daemon.sock.state"):
        path.unlink(missing_ok=True)
    time.sleep(0.5)


def start_window(settings: dict | None) -> bool:
    stop_window()
    if settings:
        SETTINGS.write_text(json.dumps(settings))
    else:
        SETTINGS.unlink(missing_ok=True)
    WORK.mkdir(parents=True, exist_ok=True)
    with open(SB / "logs" / "probe-win.out", "ab") as log:
        subprocess.Popen(
            ["tern", "--control", str(EP), str(WORK)],
            cwd=SB,
            stdout=log,
            stderr=log,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
        )
    if not wait_for(EP.exists, 30, 0.2):
        return False
    return wait_for(lambda: ctl("ready").get("ok"), 30, 0.5) is True


# Reading the DOM ----------------------------------------------------------------------------


def segments(path: str) -> list[tuple[str, set[str]]]:
    out = []
    for seg in path.split(">"):
        seg = seg.split("#")[0]
        tag, *classes = seg.split(".")
        out.append((tag, set(classes)))
    return out


def matches(path: str, chain: list[tuple[str, set[str]]]) -> bool:
    """True when the path's last segments are exactly `chain` (child combinators)."""
    segs = segments(path)
    if len(segs) < len(chain):
        return False
    for (tag, classes), (want_tag, want) in zip(segs[-len(chain) :], chain):
        if tag != want_tag or not want <= classes:
            return False
    return True


def sel(text: str) -> list[tuple[str, set[str]]]:
    return segments(text.replace(" ", ""))


def dump(selector: str = "") -> list[dict]:
    d = ctl("dump", selector) if selector else ctl("dump")
    return d.get("elements", []) if d.get("ok") else []


def visible(elements: list[dict]) -> list[dict]:
    return [e for e in elements if e["rect"][2] > 0 and e["rect"][3] > 0]


def classes_of(path: str, index: int) -> set[str]:
    return segments(path)[index][1]


def pane_index(path: str) -> int:
    return next(i for i, (tag, cl) in enumerate(segments(path)) if tag == "section" and "tn-pane" in cl)


def pane_key(path: str) -> str:
    """The path up to and including its section.tn-pane segment."""
    parts = path.split(">")
    return ">".join(parts[: pane_index(path) + 1])


def sheets() -> dict[str, int]:
    d = ctl("css")
    return {s["name"]: s["rules"] for s in d.get("sheets", [])}


def probe_report() -> dict | None:
    PROBE.unlink(missing_ok=True)
    ctl("plugins", "run", "plugin.tern-cat-probe.report")
    if not wait_for(PROBE.exists, 5, 0.1):
        return None
    time.sleep(0.05)
    try:
        return json.loads(PROBE.read_text())
    except ValueError:
        return None


def set_config(**changes) -> None:
    cfg = json.loads(CFG.read_text())
    for key, value in changes.items():
        section, field = key.split("__")
        cfg.setdefault(section, {})[field] = value
    CFG.write_text(json.dumps(cfg, indent=2))
    ctl("plugins", "run", "plugin.tern-cat.reload-config")


def kv_pets() -> int:
    try:
        state = json.loads(KV.read_text()).get("state") or {}
        return int(((state.get("profile") or {}).get("stats") or {}).get("pets", -1))
    except (OSError, ValueError):
        return -1


def focused_view() -> tuple[list[float], str] | None:
    for e in visible(dump("div.tv")):
        cl = classes_of(e["path"], pane_index(e["path"]))
        if "on" in cl and "off" not in cl and "pip" not in cl:
            return e["rect"], pane_key(e["path"])
    return None


def cat_at(corner: str, view: list[float]) -> dict | None:
    """The overlay cat's pseudo box near `corner` of `view`, found with `ctl pick`."""
    x, y, w, h = view
    vert, horiz = corner.split("-")
    for dy in (44, 28, 60, 14):
        yy = y + dy if vert == "top" else y + h - dy
        for dx in range(20, 300, 12):
            xx = x + w - dx if horiz == "right" else x + dx
            r = ctl("pick", str(int(xx)), str(int(yy)))
            if r.get("ok") and matches(r.get("path", ""), sel("div.tv-fx.top > span")):
                return r
    return None


def shot(name: str) -> None:
    r = ctl("shot", name)
    src = SB / r.get("png", "")
    if r.get("ok") and src.is_file():
        SHOTS.mkdir(parents=True, exist_ok=True)
        shutil.copy(src, SHOTS / f"{name}.png")


# Checks -------------------------------------------------------------------------------------

PANE_CHAIN = sel("div.tn-stage > section.tn-pane")
VIEW = "section.tn-pane > div.tn-body > div.tv"
HOOKS = {
    "div.tv-fx.top (cat host)": sel(VIEW + " > div.tv-fx.top"),
    "div.tv-grid > div.tv-fx (back prop)": sel(VIEW + " > div.tv-grid > div.tv-fx"),
    "div.tv-layer (front prop)": sel(VIEW + " > div.tv-layer"),
}


def expected_insets(settings: dict) -> tuple[float, float]:
    layout = settings.get("layout") if isinstance(settings.get("layout"), str) else "Tiles"
    size = settings.get("ui_font_size")
    if not isinstance(size, (int, float)):
        size = settings.get("font_size")
    if not isinstance(size, (int, float)) or not 8 <= size <= 32:
        size = TERN_UI_PX
    if settings.get("density") == "Islands":
        pad = 4
    elif layout in ("Rail", "Float", "Studio"):
        pad = 0
    else:
        pad = 3
    header = HEADER_PX if settings.get("pane_headers") in ("Split", "Always") else 0
    scale = size / TERN_UI_PX
    return pad * scale, header * scale


def check_structure(tag: str, report: dict | None) -> None:
    stage = visible(dump("div.tn-stage"))
    if not check(len(stage) == 1, f"{tag}: div.tn-stage", f"{len(stage)} visible", "div.tn-stage"):
        return
    stage_rect = stage[0]["rect"]
    elements = dump()
    panes = [e for e in visible(elements) if matches(e["path"], PANE_CHAIN)]
    check(len(panes) == 2, f"{tag}: two section.tn-pane in div.tn-stage", f"{len(panes)} visible", "div.tn-stage > section.tn-pane")
    if len(panes) != 2:
        return
    on = [p for p in panes if {"on"} <= classes_of(p["path"], -1) and "off" not in classes_of(p["path"], -1)]
    off = [p for p in panes if "on" not in classes_of(p["path"], -1)]
    check(
        len(on) == 1 and len(off) == 1,
        f"{tag}: focused pane .on:not(.off), the other without .on",
        f"classes {[sorted(classes_of(p['path'], -1)) for p in panes]}",
        "section.tn-pane.on / :not(.on)",
    )
    by_pane: dict[str, dict[str, dict]] = {}
    for e in visible(elements):
        if "tn-pane" not in e["path"]:
            continue
        key = pane_key(e["path"])
        for name, chain in {"tv": sel(VIEW), **HOOKS}.items():
            if matches(e["path"], chain):
                by_pane.setdefault(key, {})[name] = e
    pad, header = expected_insets((report or {}).get("settings") or {})
    for p in panes:
        side = "focused" if p in on else "other"
        found = by_pane.get(p["path"], {})
        for name in HOOKS:
            check(name in found, f"{tag}: {side} pane has {name}", hook=name)
        tv = found.get("tv")
        if not check(tv is not None, f"{tag}: {side} pane has div.tn-body > div.tv", hook="div.tn-body > div.tv"):
            continue
        host = found.get("div.tv-fx.top (cat host)")
        if host:
            delta = max(abs(a - b) for a, b in zip(host["rect"], tv["rect"]))
            check(delta <= TOLERANCE_PX, f"{tag}: {side} div.tv-fx.top covers div.tv", f"off by {delta:.1f} px", "div.tv-fx.top inset 0")
        px, py = tv["rect"][0] - p["rect"][0], tv["rect"][1] - p["rect"][1]
        check(
            abs(px - pad) <= TOLERANCE_PX and abs(py - pad - header) <= TOLERANCE_PX,
            f"{tag}: {side} view inset matches travel.insets",
            f"measured left {px:.2f} top {py:.2f}, expected {pad:.2f} and {pad + header:.2f}",
            "pane padding / header height",
        )
    # Ratio-exact tiling of the stage (travel.luau places the traveler in stage percentages).
    root = (((report or {}).get("layout") or {}).get("root")) or {}
    ratio = root.get("ratio")
    if check(isinstance(ratio, (int, float)) and root.get("split") == "right", f"{tag}: layout root is a right split with a ratio", json.dumps(root)[:160], "cx.session:layout(tab).root"):
        left, right = sorted(panes, key=lambda e: e["rect"][0])
        sx, sy, sw, sh = stage_rect
        cut = sx + sw * ratio
        errs = [
            abs(left["rect"][0] - sx),
            abs(left["rect"][0] + left["rect"][2] - cut),
            abs(right["rect"][0] - cut),
            abs(right["rect"][0] + right["rect"][2] - (sx + sw)),
            abs(left["rect"][1] - sy),
            abs(left["rect"][3] - sh),
        ]
        check(max(errs) <= TOLERANCE_PX, f"{tag}: panes tile div.tn-stage by the split ratio", f"off by {max(errs):.2f} px", "div.tn-stage ratio tiling")


def check_tv_vars(tag: str) -> None:
    """--tv-px/--tv-py: a probe pseudo at (var(--tv-px), var(--tv-py)) must sit on the grid origin."""
    PROBE_CSS.write_text(
        "section.tn-pane > div.tn-body > div.tv > div.tv-layer::before { content: \"\"; position: absolute;"
        " left: var(--tv-px, -5000px); top: var(--tv-py, -5000px); width: 4px; height: 4px; pointer-events: auto; }\n"
    )
    installed = ctl("css", "tern-cat-compat-probe", str(PROBE_CSS))
    if not check(installed.get("ok") is True and installed.get("rules") == 1, f"{tag}: probe sheet installs", json.dumps(installed)[:200]):
        return
    focused = focused_view()
    grid = None
    if focused:
        for e in visible(dump("div.tv-grid")):
            if pane_key(e["path"]) == focused[1]:
                grid = e["rect"]
    if check(grid is not None, f"{tag}: focused div.tv-grid", hook="div.tv > div.tv-grid"):
        r = ctl("pick", str(grid[0] + 2), str(grid[1] + 2))
        ok = r.get("ok") and matches(r.get("path", ""), sel("div.tv-layer > span"))
        rect = r.get("rect") or [0, 0, 0, 0]
        ok = ok and abs(rect[0] - grid[0]) <= TOLERANCE_PX and abs(rect[1] - grid[1]) <= TOLERANCE_PX
        check(bool(ok), f"{tag}: --tv-px/--tv-py give the grid's offset", f"pick {r.get('path', r)} {rect}", "--tv-px / --tv-py")
    ctl("css", "tern-cat-compat-probe")


def check_static() -> None:
    """Tern's own sheets still read the variables tern-cat's CSS uses (unset ones cannot be probed live)."""
    binary = os.environ.get("TERN_BIN", "")
    if not binary or not Path(binary).is_file():
        check(False, "static: tern executable found", binary or "unset")
        return
    data = Path(binary).read_bytes()
    for var in ("--tv-px", "--tv-py", "--tv-aside"):
        check(f"var({var}".encode() in data, f"static: Tern's CSS reads var({var})", hook=var)


def check_settings(report: dict | None) -> None:
    if not check(report is not None, "probe plugin reports (window half reads)", hook="probe plugin"):
        return
    s = report.get("settings") or {}
    for key, allowed in (
        ("layout", ("Tiles", "Rail", "Float", "Studio")),
        ("density", ("Compact", "Islands")),
        ("pane_headers", ("Never", "Split", "Always")),
        ("reduce_motion", ("system", "on", "off")),
    ):
        check(s.get(key) in allowed, f"settings: cx.settings:get(\"{key}\") in {'/'.join(allowed)}", repr(s.get(key)), f"setting {key}")
    check(isinstance(s.get("font_size"), (int, float)), "settings: font_size is a number", repr(s.get("font_size")), "setting font_size")
    check(s.get("ui_font_size") == "<nil>" or isinstance(s.get("ui_font_size"), (int, float)), "settings: ui_font_size is a number or nil", repr(s.get("ui_font_size")), "setting ui_font_size")
    pane = report.get("pane") or {}
    check(isinstance(pane, dict) and pane.get("kind") == "terminal" and isinstance(pane.get("program"), str), "PaneInfo: focused terminal has kind and program", json.dumps(pane)[:200], "PaneInfo.program")
    check(isinstance(pane, dict) and isinstance(pane.get("at_prompt"), bool), "PaneInfo: at_prompt is a boolean", json.dumps(pane)[:200], "PaneInfo.at_prompt")
    chord = report.get("chord")
    check(isinstance(chord, list) and "plugin.tern-cat.toggle-overlay" in chord, "keys: ctrl+alt+cmd+c is bound to the toggle", repr(chord), "cx.actions:keys() chord")


def check_corners() -> None:
    view = focused_view()
    if not check(view is not None, "overlay: focused div.tv found"):
        return
    for corner in CORNERS:
        set_config(rendering__overlay_position=corner)
        found = wait_for(lambda: cat_at(corner, focused_view()[0]) if focused_view() else None, 5, 0.3)
        check(found is not None, f"overlay: cat drawn at {corner} (div.tv-fx.top::after picked)", hook="section.tn-pane.on:not(.off) > div.tn-body > div.tv > div.tv-fx.top::after")
        if corner == "bottom-left":
            shot("overlay-bottom-left")
    set_config(rendering__overlay_position="top-right")
    wait_for(lambda: cat_at("top-right", focused_view()[0]), 5, 0.3)


def check_passthrough() -> None:
    view = focused_view()
    cat = cat_at("top-right", view[0]) if view else None
    if not check(cat is not None, "pointer: cat found for the pass-through check"):
        return
    x, y, w, h = cat["rect"]
    cx, cy = str(int(x + w / 2)), str(int(y + h / 2))
    ctl("move", cx, cy)
    time.sleep(0.4)
    shot("pointer-hover")
    r = ctl("click", cx, cy)
    check(r.get("focused") == "textarea.tv-input", "pointer: a click on the cat leaves the terminal input focused", repr(r.get("focused")), "pass-through")
    mark = f"tccompat{os.getpid()}"
    ctl("type", f'"true {mark}"')
    ctl("key", "Enter")
    ran = wait_for(lambda: ((ctl("state").get("focused") or {}).get("last") or {}).get("line") == f"true {mark}", 5, 0.3)
    check(bool(ran), "pointer: typing after the click runs in the pane", hook="pass-through")
    ctl("move", "5", "5")


def check_walk() -> None:
    set_config(rendering__pane_transition="walk")
    time.sleep(1.5)
    before = focused_view()
    ctl("focus", "left")
    started = wait_for(lambda: sheets().get(TRAVEL, 0) > 0, 3, 0.1)
    check(bool(started), "walk: travel sheet installed on a pane switch", repr(sheets()), "div.tn-stage::after traveler")
    cleared = wait_for(lambda: sheets().get(TRAVEL, -1) == 0, 5, 0.2)
    check(bool(cleared), "walk: travel sheet cleared after the trip", repr(sheets()))
    after = focused_view()
    moved = before is not None and after is not None and before[0][0] != after[0][0]
    if check(moved, "walk: focus moved to the other pane"):
        here = wait_for(lambda: cat_at("top-right", after[0]), 3, 0.3)
        check(here is not None, "walk: cat arrived in the new pane")
        check(cat_at("top-right", before[0]) is None, "walk: no cat left in the old pane", hook="section.tn-pane:not(.on) cat hidden")


def check_portal() -> None:
    set_config(rendering__pane_transition="portal")
    time.sleep(1.5)
    before = focused_view()
    ctl("focus", "right")
    after = wait_for(lambda: (lambda v: v if v and before and v[0][0] != before[0][0] else None)(focused_view()), 3, 0.2)
    if check(after is not None, "portal: focus moved to the other pane"):
        here = wait_for(lambda: cat_at("top-right", after[0]), 4, 0.3)
        check(here is not None, "portal: cat emerged in the new pane")
        check(cat_at("top-right", before[0]) is None, "portal: old pane's cat dived", hook="dive on section.tn-pane > ... > div.tv-fx.top::after")


def check_fullscreen() -> None:
    view = focused_view()
    ctl("type", '"less /etc/hosts"')
    ctl("key", "Enter")
    hidden = wait_for(lambda: cat_at("top-right", view[0]) is None, 4, 0.4)
    check(bool(hidden), "full-screen: cat steps aside while less runs", hook="PaneInfo.running / at_prompt")
    time.sleep(1.5)
    check(cat_at("top-right", view[0]) is None, "full-screen: cat stays aside over timer ticks", hook="PaneInfo.running / at_prompt")
    ctl("key", "q")
    back = wait_for(lambda: cat_at("top-right", view[0]) is not None, 5, 0.4)
    check(back is not None, "full-screen: cat returns after less exits")


def check_card() -> None:
    ctl("plugins", "run", "plugin.tern-cat.open")
    card = wait_for(lambda: [e for e in visible(dump("section.tn-pane")) if "pip" in classes_of(e["path"], -1)], 5, 0.3)
    if not check(bool(card), "card: Open cat floats a section.tn-pane.pip", hook="section.tn-pane.pip"):
        return
    cl = classes_of(card[0]["path"], -1)
    check({"pip-focus", "pip-r", "pip-b"} <= cl, "card: focused bottom-right card (pip-focus pip-r pip-b)", f"classes {sorted(cl)}", "pip classes")
    elements = dump()
    region = [e for e in visible(elements) if "pip" in e["path"] and matches(e["path"], sel("div.tv > div.tv-cover > div.sf-region.sf-main"))]
    check(bool(region), "card: block renders in div.tv > div.tv-cover > div.sf-region.sf-main", hook="div.sf-region.sf-main")
    frames = [e for e in elements if "pip" in e["path"] and "sf-img-frame" in segments(e["path"])[-1][1]]
    check(bool(frames), "card: sprite image has .sf-img-frame (tern-cat.css)", hook=".sf-image .sf-img-frame")
    check(wait_for(lambda: sheets().get(OVERLAY, -1) == 0, 3, 0.2) is True, "card: overlay steps aside under the focused card", repr(sheets()))
    shot("card")
    pets = kv_pets()
    r = ctl("click", "section.tn-pane.pip button[data-act='pet']")
    check(r.get("ok") is True and wait_for(lambda: kv_pets() == pets + 1, 3, 0.2) is True, "card: Pet button works", f"{r} pets {pets} -> {kv_pets()}", "pip-focus takes clicks")
    r = ctl("click", "section.tn-pane.pip button[data-act='settings']")
    opened = wait_for(lambda: visible(dump("section.tn-pane.pip button[data-act='close-settings']")), 3, 0.3)
    check(r.get("ok") is True and bool(opened), "card: settings page opens", repr(r))
    shot("card-settings")
    ctl("click", "section.tn-pane.pip button.tn-close")
    gone = wait_for(lambda: not [e for e in visible(dump("section.tn-pane")) if "pip" in classes_of(e["path"], -1)], 4, 0.3)
    check(bool(gone), "card: closes from its header", hook="button.tn-close")
    check(wait_for(lambda: sheets().get(OVERLAY, 0) > 0, 4, 0.2) is True, "card: overlay returns after the card closes", repr(sheets()))


def check_reduced_motion() -> None:
    def animating() -> list[str]:
        return ((ctl("stats").get("animating") or {}).get("elements")) or []

    cat_animating = lambda: any(matches(p, sel("div.tv-fx.top > span")) for p in animating())
    check(wait_for(cat_animating, 6, 0.3) is True, "reduced motion: the cat animates with it off", repr(animating()))
    ctl("reduce-motion", "on")
    still = wait_for(lambda: not cat_animating(), 4, 0.3)
    check(bool(still), "reduced motion: system Reduce Motion stops the cat's animation", repr(animating()), "@media (prefers-reduced-motion)")
    shot("reduced-motion")
    ctl("reduce-motion", "off")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    print("==> static hooks", flush=True)
    check_static()

    print("==> window 1: Tern's default settings", flush=True)
    if not check(start_window(None), "window starts"):
        return finish()
    check(wait_for(lambda: sheets().get(OVERLAY, 0) > 0, 30, 0.3) is True, "overlay sheet installed", repr(sheets()))
    ctl("split", "right")
    time.sleep(1.5)
    report = probe_report()
    check_settings(report)
    check_structure("default", report)
    check_tv_vars("default")
    set_config(behavior__allow_pacing=False, rendering__overlay_offset_px=12)
    check_corners()
    check_passthrough()
    check_walk()
    check_portal()
    check_fullscreen()
    check_card()
    check_reduced_motion()
    shot("default")

    settings = {"pane_headers": "Split", "density": "Islands", "ui_font_size": 16}
    print(f"==> window 2: {json.dumps(settings)}", flush=True)
    if check(start_window(settings), "window starts with headers, Islands, 16 px interface"):
        ctl("split", "right")
        time.sleep(1.5)
        report = probe_report()
        check(report is not None and (report.get("settings") or {}).get("pane_headers") == "Split", "settings: pane_headers reads Split", hook="setting pane_headers")
        check_structure("headers", report)
        check_tv_vars("headers")
        shot("headers")
    stop_window()
    SETTINGS.unlink(missing_ok=True)
    return finish()


def finish() -> int:
    failed = [r for r in results if not r[0]]
    lines = [f"{'PASS' if ok else 'FAIL'}  {name}{': ' + detail if detail and not ok else ''}" for ok, name, detail in results]
    summary = [f"dom probe: {len(results) - len(failed)} passed, {len(failed)} failed"]
    if missing:
        summary.append("missing or changed Tern hooks:")
        summary += [f"  - {m}" for m in dict.fromkeys(missing)]
    (OUT / "dom-probe.txt").write_text("\n".join(lines + [""] + summary) + "\n")
    print("\n".join(summary), flush=True)
    return 1 if failed else 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    finally:
        stop_window()
