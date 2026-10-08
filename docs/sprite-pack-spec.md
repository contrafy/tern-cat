# Sprite and sound pack specification

This is the format tern-cat loads for cat appearances ("sprite packs") and sound effects ("sound
packs"). It describes what the code enforces today:

- `cat/sprite/manifest.luau`: the load-time validator (the plugin runs it for every pack).
- `cat/sprite/loader.luau`: pack discovery and selection.
- `cat/render/animations.luau`: canonical animation names and fallback chains.
- `tools/validate_packs.py` and `tools/validate_pack.luau`: the CI validators.
- `cat/integrations/sound.luau`: sound pack loading.

Packs are data only. tern-cat never executes anything from a pack: it parses `pack.json` as
JSON, reads PNG headers without decoding pixels (`cat/sprite/png.luau`), and passes image bytes to
Tern. A pack that fails validation is skipped and reported; it never crashes the plugin.

## Pack layout

```text
my-cat/
  pack.json                  manifest (required, at most 64 KiB)
  LICENSE.txt                license and attribution notice (required for bundled packs, recommended otherwise)
  frames/<animation>/NN.png  one PNG per frame (any safe relative path works; this is the convention)
  build/<animation>.apng     derived: animated PNG of all frames (block renderer)
  build/<animation>.sheet.png  derived: horizontal strip of all frames (overlay renderer)
```

Only files referenced from `pack.json` are read. Other files in the directory are ignored.

## Where packs live

| Source | Directory | Notes |
|---|---|---|
| Bundled | `<plugin dir>/assets/packs/<id>/` | `orange-menace` (default), `void`, `tuxedo`. |
| User | `<tern.plugin.data>/packs/<id>/` | `tern.plugin.data` is the plugin's writable state directory (`cat/adapters/paths.luau`, `user_packs`). |

Discovery rules (`cat/sprite/loader.luau`):

- Bundled packs load before user packs. A user pack whose `id` is already taken by a bundled pack
  (or by an earlier user pack) is ignored with a problem message. User packs cannot replace
  bundled ones.
- Directory names must match `^[A-Za-z0-9][A-Za-z0-9._-]*$` and be at most 64 characters; other
  entries are skipped. At most 64 pack directories per root are considered.
- The directory name does not have to equal `id`, but by convention it does (and the CI validator
  requires it for bundled packs).
- The active pack is the configured `cat.appearance` id. If it is missing or invalid, the default
  `orange-menace` is used; if that is missing too, the first valid pack id in sort order.

## `pack.json`

A UTF-8 JSON object. Unknown top-level fields and unknown fields inside an animation are dropped
(not passed to renderers) without an error.

| Field | Type | Required | Rule |
|---|---|---|---|
| `schema_version` | integer | yes | Must be `1`. |
| `id` | string | yes | `^[a-z][a-z0-9-]*$`, 1-32 characters. |
| `name` | string | yes | 1-64 characters. Shown in the UI. |
| `license` | string | yes | 1-64 characters. Use an SPDX identifier, e.g. `CC-BY-4.0`. |
| `author` | string | no | At most 64 characters. |
| `description` | string | no | At most 512 characters. |
| `canvas` | object | yes | `{ "width": int, "height": int }`, each 8-256. Every frame has exactly this size. |
| `animations` | object | yes | Keyed by canonical animation name; at most 32 keys; must contain `idle`. |

Animation object (`animations.<name>`):

| Field | Type | Required | Rule |
|---|---|---|---|
| `frames` | array of paths | yes | 1-64 entries. Each a safe path (see below) to a PNG of exactly `canvas.width` x `canvas.height`. |
| `durations_ms` | array of integers | yes | One entry per frame, each 40-10000. |
| `loop` | boolean | yes | `true` repeats; `false` plays once and holds the last frame. |
| `anchor` | `[x, y]` integers | no | Point inside the canvas (`0 <= x <= width`, `0 <= y <= height`). Conventionally the feet, e.g. `[16, 31]` on a 32x32 canvas. |
| `hitbox` | `[x, y, w, h]` integers | no | `w, h >= 1`, `x, y >= 0`, and the box lies inside the canvas. |
| `apng` | path | no | Derived APNG of all frames. Must contain an `acTL` chunk whose frame count equals `#frames`, and be `canvas` sized. |
| `sheet` | path | no | Derived horizontal strip: exactly `canvas.width * #frames` x `canvas.height`. |

Animation keys that are not canonical names produce a warning and are ignored; they still count
toward the 32-key limit.

### What the renderers use

- The **overlay** (window half, `cat/window/packs.luau`) uses `sheet`. Without `sheet` it shows
  `frames[1]` as a still image.
- The **block** (host half) is designed to use `apng`, one blob per animation
  ([architecture.md](architecture.md#renderers)).
- Ship both derived files for every animation. `apng` must always be animated: a one-frame
  animation needs a one-frame APNG (an `acTL` chunk declaring 1 frame); a plain PNG in the `apng`
  field is rejected.

### Limits

From `LIMITS` in `cat/sprite/manifest.luau` (mirrored in `tools/validate_packs.py`):

| Limit | Value |
|---|---|
| `schema_version` | 1 |
| `id` length | 32 |
| `name`, `license`, `author` length | 64 |
| `description` length | 512 |
| Canvas width and height | 8-256 px |
| Animations per pack | 32 |
| Frames per animation | 64 |
| Frame duration | 40-10000 ms |
| Path length | 200 characters |
| Single file size | 1 MiB (1048576 bytes) |
| Distinct files referenced | 512 |
| Total bytes of referenced files | 16 MiB |
| `pack.json` size | 64 KiB (`cat/sprite/loader.luau`) |

The validator never asks the filesystem adapter for more than 1 MiB + 1 byte per file and checks
the file count before reading anything.

### Path safety

Every path in `frames`, `apng` and `sheet` is checked before any filesystem access
(`checkPath` in `cat/sprite/manifest.luau`). A path must:

- be a non-empty string of at most 200 characters;
- be relative to the pack directory: no leading `/`, no `:` (rejects URL schemes such as
  `data:`/`https:` and drive letters), no `\`;
- contain no empty segments (`a//b`), no `.` and no `..` segments;
- use only `A-Z a-z 0-9 . _ -` in each segment, separated by `/`;
- end in lowercase `.png` or `.apng`.

The Python validator additionally resolves each path and rejects anything that lands outside the
pack directory (for example through a symlink).

### Image checks

- Every referenced file must start with the PNG signature and have a valid `IHDR` first chunk and
  image data (`cat/sprite/png.luau`). JPEG, GIF, WebP and SVG are rejected.
- Frames must be exactly the canvas size.
- `apng`: `acTL` present, frame count equals `#frames`, canvas sized.
- `sheet`: `canvas.width * #frames` wide, `canvas.height` high.
- Use RGBA with a transparent background. Pixel art is scaled with nearest-neighbour filtering by
  the renderers, so draw at native resolution.

## Canonical animations

Only these names are used. `idle` is required; every other animation is optional because the
engine falls back along a fixed chain (`FALLBACKS` in `cat/render/animations.luau`). The first
available animation in the chain is shown, and every chain ends in `idle`.

| Animation | Meaning | Fallback chain |
|---|---|---|
| `idle` | Default standing loop | (required) |
| `walk` | Pacing | `idle` |
| `sit` | Sitting loop | `idle` |
| `sleep` | Sleeping loop | `sit`, `idle` |
| `wake` | Waking up (the only exit from sleep) | `stretch`, `blink`, `idle` |
| `stretch` | Stretch | `blink`, `idle` |
| `groom` | Licking a paw | `sit`, `idle` |
| `blink` | Blink | `idle` |
| `look` | Looks around | `blink`, `idle` |
| `pet` | Reacts to petting | `happy`, `blink`, `idle` |
| `poke` | Reacts to a poke | `startled`, `look`, `idle` |
| `eat` | Eating | `happy`, `idle` |
| `play` | Playing with a toy | `swat`, `happy`, `idle` |
| `happy` | Pleased | `blink`, `idle` |
| `disappointed` | Reacts to a failed command | `look`, `sit`, `idle` |
| `swat` | Paw swat | `play`, `happy`, `idle` |
| `startled` | Jump scare | `hop`, `look`, `idle` |
| `flop` | Dramatic flop | `disappointed`, `sit`, `idle` |
| `stare` | Long stare | `look`, `sit`, `idle` |
| `hop` | Small hop | `look`, `idle` |
| `dive` | Sinks into the floor portal (overlay pane switch only) | `hop`, `idle` (the overlay clips the decision sheet instead) |
| `emerge` | Rises out of the floor portal and lands (overlay pane switch only) | `wake`, `blink`, `idle` (the overlay clips the decision sheet instead) |

`durations_ms` only times the frames. How long the cat stays in an animation is decided by the
behavior engine (`defaultDurationMs` in `cat/render/animations.luau`), not by the pack. The
engine treats `idle`, `walk`, `sit` and `sleep` as looping states, so set `"loop": true` on those
and `false` on one-shot reactions.

`dive` and `emerge` are only played by the overlay's pane-switch transition (see
[architecture.md](architecture.md#pane-switch-transition)); they are never decisions and cannot
be performed. Draw them inside the normal frame with its bottom edge as the floor: `dive` sinks
the cat below that edge and ends on an empty frame, `emerge` starts empty and ends on the pose
of `idle`'s first frame. Timing guidance (bundled packs match it exactly): `dive` 480 ms in
frames of equal duration (the overlay plays it with a CSS transition, which steps evenly, so
unequal durations are averaged), `emerge` 640 ms, its empty first frame lasting about 160 ms
while the prop opens. A pack without them sinks and rises with a height clip of whatever the
cat is doing.

Bundled packs must provide all 22 animations (`tools/validate_packs.py` enforces this when run
without arguments). Community packs only need `idle`.

## Minimal complete example

A pack with two animations on a 32x32 canvas. Every file listed must exist.

```json
{
  "schema_version": 1,
  "id": "grey-loaf",
  "name": "Grey Loaf",
  "author": "Your Name",
  "license": "CC-BY-4.0",
  "description": "A grey cat that mostly sleeps.",
  "canvas": { "width": 32, "height": 32 },
  "animations": {
    "idle": {
      "frames": ["frames/idle/01.png", "frames/idle/02.png"],
      "durations_ms": [400, 200],
      "loop": true,
      "anchor": [16, 31],
      "hitbox": [2, 10, 28, 22],
      "apng": "build/idle.apng",
      "sheet": "build/idle.sheet.png"
    },
    "sleep": {
      "frames": ["frames/sleep/01.png", "frames/sleep/02.png"],
      "durations_ms": [900, 900],
      "loop": true,
      "anchor": [16, 31],
      "apng": "build/sleep.apng",
      "sheet": "build/sleep.sheet.png"
    }
  }
}
```

The bundled packs are complete references: `assets/packs/orange-menace/pack.json`. The test
fixtures under `tests/fixtures/packs/` show valid (`good-*`) and invalid (`bad-*`) packs.

## Building the derived files

`apng` and `sheet` are generated from the frames; do not draw them by hand.

- **Bundled packs** are rendered from code in `tools/art/` by `uv run tools/build_packs.py`
  (frames, derived files, `pack.json`, `LICENSE.txt` and `docs/images/packs-preview.png`). It does
  not take a pack directory and is not meant for community packs.
- **Community packs**: write the frame PNGs and a `pack.json` with `frames`, `durations_ms`,
  `loop` (plus optional `anchor`, `hitbox` and metadata), then run

  ```sh
  uv run tools/pack_build.py [--check] [--no-lune] PACK_DIR [PACK_DIR ...]
  ```

  For every animation it writes `build/<animation>.apng` (exact durations; plays forever when
  `loop` is `true`, once otherwise) and `build/<animation>.sheet.png`, and sets the animation's
  `apng`/`sheet` fields. `apng` is always written; a one-frame animation produces a one-frame
  APNG. `pack.json` is rewritten with 2-space indentation and a trailing newline, keeping key
  order and all other fields. Output is deterministic: rebuilding unchanged frames reproduces
  byte-identical files. It then runs `tools/validate_packs.py` and, when `lune` is on `PATH`, the
  Luau validator (`--no-lune` skips it).

  - Frames must exist, use safe paths, and be single still PNGs of exactly the canvas size. Any
    8-bit PNG colour type is converted to RGBA losslessly; 16-bit images are rejected. Errors name
    the animation and frame, e.g.
    `animations.hop.frames[2] 'frames/hop/02.png': image is 17x12 but canvas is 16x12`.
  - Two identical consecutive frames are an error: APNG encoders merge them into one frame, and
    the count would no longer match `frames`. Delete the repeat and add its duration to the
    previous frame.
  - `--check` writes nothing and exits 1 when a derived file or an `apng`/`sheet` field is
    missing or stale (byte comparison against a fresh in-memory build). Use it in CI.
  - Exit codes: 0 ok, 1 build, check or validation failure, 2 usage error.

## Validating

Run from the repository root:

```sh
lune run tools/validate_pack.luau path/to/my-cat [more packs ...]   # the plugin's own rules
uv run tools/validate_packs.py path/to/my-cat [more packs ...]      # Pillow checks, then the Luau validator
uv run tools/validate_packs.py                                      # every bundled sprite and sound pack
```

- `validate_pack.luau` exits 0 when all packs are valid, 1 when any is invalid, 2 on usage errors.
  It prints `ok   <dir>`, or `FAIL <dir>: <field>: <reason>` per problem, and `WARN` lines for
  ignored animation names.
- `validate_packs.py` decodes every image with Pillow, checks APNG frame counts against both the
  `acTL` chunk and the decoded frames, then calls the Luau validator when `lune` is on `PATH`
  (`--no-lune` skips it), so both implementations must agree. Exits 0 or 1.
- Passing a directory that contains `sounds.json` validates it as a sound pack.

## Installing and removing a pack

Install a pack by copying its folder, with the derived files built, to
`<tern.plugin.data>/packs/<id>/` (macOS `~/Library/Application Support/Tern/plugin-data/tern-cat/packs/`,
Linux `~/.local/state/tern/plugin-data/tern-cat/packs/`). Select it by setting `cat.appearance`
to its `id` in `config.json`; Settings > Appearance lists it after that or after the next plugin
reload (`tern plugin reload`), since the host scans every pack folder only once per load.

Remove a user pack in the block: Settings > Appearance > **Remove <name>**, then **Confirm**
within 10 seconds. The host (`removePack` in `cat/host/brain.luau`):

- removes only `user` packs. Bundled packs have no Remove row and are refused: they live in the
  plugin directory, and writing there reloads the plugin;
- deletes only a folder that is a direct child of the user packs folder and has a folder name the
  loader scans (`removableDir` in `cat/sprite/loader.luau`). Paths with `.` or `..` segments, a
  backslash or a colon are refused, never resolved;
- deletes it with `tern.fs.remove` (recursive). If the pack folder is a symlink, Tern 0.6.2
  removes the link and leaves its target untouched;
- switches `cat.appearance` back to `orange-menace` in `config.json` when the removed pack was
  selected. If `config.json` cannot be written, the pack is still removed, the default pack is
  shown with a note, and the toast says the appearance was not saved.

Windows pick up the change within about 3 seconds: they re-read `config.json` and re-check that
the selected pack's `pack.json` still exists, so a pack whose folder you delete by hand stops
showing too.

## Licensing

- `license` is required. State the license of the art, not of tern-cat's code.
- Only submit art you made or that is licensed for redistribution with compatible terms; include
  the attribution text in `LICENSE.txt` and set `author`.
- Bundled packs in this repository are original work, CC-BY-4.0, by Ahmad Raaiyan
  ([assets/CREDITS.md](../assets/CREDITS.md)). Contributions to `assets/` must be original and
  licensed CC-BY-4.0. No third-party sprites, ripped game assets or hotlinked images.

## Sound packs

Tern has no audio API; tern-cat plays short files through a local player
([security-privacy.md](security-privacy.md#process-execution-is-limited-to-the-sound-player)). Sound is muted by default.

Layout and locations:

| Source | Directory |
|---|---|
| Bundled | `<plugin dir>/assets/sounds/<id>/` (`default`) |
| User | `<tern.plugin.data>/sounds/<id>/` |

`sounds.json` (see `assets/sounds/default/sounds.json`):

```json
{
  "schema_version": 1,
  "id": "default",
  "name": "Default Cat Sounds",
  "author": "Ahmad Raaiyan",
  "license": "CC-BY-4.0",
  "sounds": {
    "meow": "meow.wav",
    "purr": "purr.wav",
    "surprise": "surprise.wav",
    "happy": "happy.wav",
    "swat": "swat.wav"
  }
}
```

Sound ids: `meow`, `purr`, `surprise`, `happy`, `swat`. Unknown ids are ignored with a warning.
Paths follow the sprite path rules above, with an audio extension instead of `.png`.

| Rule | Load time (`cat/integrations/sound.luau`) | CI (`tools/validate_packs.py`) |
|---|---|---|
| Manifest | JSON object, at most 16 KiB; `id` must equal the folder name; `sounds` must be an object | `schema_version` 1; `id`, `name`, `license` as for sprite packs; non-empty `sounds` |
| Extensions | `.wav`, `.aiff`, `.aif`, `.mp3`, `.ogg` | `.wav` only |
| Format | not inspected; missing files are skipped with a warning | mono, 16-bit PCM, 8000-48000 Hz |
| Size and length | not checked | at most 80 KiB and 1.5 s per file |

Bundled sounds must pass the CI column. Community packs should too: short mono WAV plays with
every supported player (`afplay`, `pw-play`, `paplay`, `aplay`). The bundled sounds are
synthesized by `uv run tools/build_sounds.py`.
