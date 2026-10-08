# RFC: visible-screen cell geometry and an ephemeral overlay sprite layer for window plugins

Status: draft proposal to Tern upstream.

Origin: tern-cat M0. The evidence is in [sdk-capability-matrix.md](sdk-capability-matrix.md).

Target: Tern 0.6.2 (4b3ed42) and later.

## Motivation

Pet and annotation plugins want small visuals that sit on top of terminal content. Examples:

- A cat sitting on a word printed by `ls`.
- A marker next to an error line.

Today a plugin cannot do this safely. A plugin that tried would have to scrape text and guess where it sits on screen.

### What works today

These hold for window-half `tern.css` decorations (VERIFIED in the OverlaySpike experiment):

- Fixed-position pseudo-elements render above panes, PiP cards and the tab bar.
- With `pointer-events: none`, clicks, selection and typing pass through.
- `cx.session:read` returns identical terminal content with the decoration on and off.
- Motion quantized with `steps()` costs about 2 % of one core at 10 Hz. Smooth motion costs about 13 %.
- Rules such as `.tn-pane.on > .tn-body::after` can follow the focused pane's corner without any Lua.

### What does not work today

- **No geometry.** Cell size, origin, scroll offset and glyph positions are unavailable (VERIFIED: absent from `tern.d.luau`). A decoration can only use fixed pixel offsets or pane corners.
- **No interaction.** Hit-testing requires `pointer-events: auto`, which blocks input to the terminal underneath. Window halves have no DOM API, no class toggles and no pointer position or hover (VERIFIED).
- **Coarse movement.** The only way to move a decoration is to re-install a whole style sheet. Each move costs a restyle, about 6 % of a core at 10 Hz (VERIFIED).
- **Text has no position.** The only text source, `cx.session:read`, returns line strings with no screen row or column. It also reaches far more data than a decoration needs: up to 2000 lines of scrollback, with no consent.
- **No visibility signal.** Hosts cannot tell whether a window is occluded, so animations keep running while unseen. The CSS-only `.sf-paused` class does not reach Lua timers.

## Goals and non-goals

### Goals

- Opt-in.
- Read-only.
- Visible screen only.
- Ephemeral drawing, never mixed into PTY output, selection, scrollback or model context.
- No input synthesis.

### Non-goals

- Scrollback access.
- Bulk text export.
- Persistent annotations.
- Drawing outside Tern windows.

## API sketch

The API is window half only and gated by a new per-plugin grant (see [Consent](#consent)).

```lua
-- (a) Geometry, read-only, visible screen only
type ViewportInfo = {
	pane: number, cols: number, rows: number,
	cell_w: number, cell_h: number,      -- logical px
	origin_x: number, origin_y: number,  -- pane-local logical px of cell (0,0)
	scale: number, serial: number,       -- serial bumps on scroll, resize, clear, alt-screen switch
}
type CellRect = { col: number, row: number, x: number, y: number, w: number, h: number }

cx.session:viewport(pane: number): ViewportInfo?
cx.session:find_cells(pane: number, pattern: string, opts: { max: number? }?): { CellRect }
tern.on("viewport_changed", function(ev: { pane: number, serial: number }, cx) end)

-- (b) Ephemeral overlay sprite layer, above panes and below Tern chrome
type Sprite = {
	blob: string,                 -- from cx:blob
	x: number, y: number, w: number, h: number,
	opacity: number?, ttl_ms: number?,
	hit: boolean?,                -- opt into overlay_pointer for this sprite
}
cx.overlay:open(opts: { pane: number?, pointer: "passthrough" | "hit" }): number
cx.overlay:set(id: number, sprites: { Sprite }): ()
cx.overlay:close(id: number): ()
tern.on("overlay_pointer", function(ev: {
	id: number, sprite: number, kind: "click" | "dblclick" | "enter" | "leave",
	x: number, y: number, mods: { string },
}, cx) end)

-- (c) Plugin surfaces: pointer position and hover inside a block's own nodes
-- actions = { hover = "act", move = "act" } -> UiEvent { ev="action", act, x, y } throttled to <= 30 Hz

-- (d) Host visibility: per-pane flag the host half can read or subscribe to
tern.on("visibility", function(ev: { pane: number, visible: boolean, occluded: boolean }) end)
```

### Behaviour

- `find_cells` matches on Tern's side, against the visible screen only. It returns rectangles and never text.
- `pattern` must be a member of the plugin's **declared allowlist**, for example manifest `[overlay] patterns = ["^[A-Za-z0-9._-]{1,32}$"]`.
- Overlays are dropped automatically when `serial` changes, so a sprite never drifts onto unrelated text after a scroll.
- With `pointer = "passthrough"`, every event reaches the terminal. With `"hit"`, only the opaque pixels of sprites marked `hit` capture events. Everything else passes through.
- Overlay events carry no terminal text. Effect APIs (`cx:run`, `tern.pane.write`) are unavailable inside `overlay_pointer` handlers.

### Limits

| Limit | Value |
|---|---|
| Sprites per overlay | 8 |
| Overlays per plugin per window | 2 |
| Blob size | 256 KiB per sprite |
| `set` rate | 15 per second; excess calls are coalesced |
| `ttl_ms` | Default 1500, maximum 10000. A sprite with no refresh disappears |
| `find_cells` | 4 calls per second, `max` 32 results |
| Opacity | The total opaque area per overlay is capped (for example 5 % of the pane) |

## Security and privacy assessment

Today Tern has no permission model. Any plugin can already read 2000 lines of scrollback (`cx.session:read`), type into panes, and install global CSS ([concepts/security](https://docs.stencil.so/tern/concepts/security.html)).

This proposal exposes less data than `read`: geometry plus allowlisted matches on the visible screen. It is still the first API that makes **precise visual spoofing** easy, so it introduces the first grant.

| Threat | Mitigation |
|---|---|
| **Clickjacking and phishing.** A sprite mimics a prompt, button or `sudo` dialog over real output; a `hit` overlay captures a click meant for the terminal | Sprites are clipped to the pane. The cursor row and prompt line cannot be covered. Opaque area is capped. `hit` needs a separate grant from `passthrough`. A Tern-drawn frame or badge marks the overlay region on hover |
| **Pattern oracle.** `find_cells` reveals whether a chosen string (a token or hostname) is on screen | Patterns come from a declared allowlist shown at grant time; no runtime arbitrary regex. Rate limit plus a result cap. Results are rectangles only |
| **Password prompts** | Panes with echo off, secure keyboard entry, or a known password prompt return `nil` from `viewport` and an empty `find_cells`, and hide overlays |
| **Alt-screen programs** (editors, pagers, TUIs) | Excluded by default; the user enables them per plugin. `serial` bumps on alt-screen switch |
| **Scrollback scraping** | Visible screen only. No text is ever returned |
| **Persistence and recording** | Overlays are ephemeral (`ttl_ms`), never stored in the session state, and excluded from screenshots taken for Carly or exports unless the user opts in |
| **Audit** | A per-window indicator shows while a plugin holds geometry or overlay access. Each grant and revocation is logged with the plugin id. Preferences, Plugins lists the grants |
| **Dismissal** | A Tern-owned chord that plugins cannot rebind, plus a click on the indicator, hides all overlays in the window immediately and pauses the grant for the session |
| **Remote panes** | Geometry for a remote pane is computed locally by the window. Remote host plugins get nothing new |

### Consent

The manifest declares `[overlay] geometry = true`, `pointer = "hit" | "passthrough"`, and the `patterns` allowlist.

Tern prompts once per plugin version:

- The prompt shows the patterns and pointer mode.
- If the declared values change, Tern prompts again.
- Without the grant, the APIs are `nil`. Plugins use feature detection: `if cx.overlay then`.

### Pointer and visibility additions (c, d)

- Hover and move inside a plugin's **own** block are low risk: the plugin already owns those pixels. They should be throttled.
- The visibility and occlusion signal leaks only whether a pane is on screen. It lets hosts stop sending frames to unseen windows.
- RenderSpike measured about 1.7 % of a core (window plus daemon) spent animating a block nobody could see.

## Alternatives considered

- **Global CSS only (status quo).** Decorative only, with no geometry and no interaction. tern-cat ships this as an optional decoration.
- **Floated block (`cx.layout:float`).** Interactive, but it is a fixed-size corner card, and the plugin cannot set its size or position.
- **Text scraping plus guessed positions.** Rejected. It is privacy-hostile and breaks with soft wraps and scrolling.
