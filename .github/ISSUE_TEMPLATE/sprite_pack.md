---
name: Sprite pack
about: Submit or list a sprite or sound pack, or report a pack format problem
title: "pack: "
labels: pack
---

## Pack

- Name and id:
- Kind: sprite / sound
- Link (repository or archive):
- Author:
- License (SPDX id):
- Proposed for: listing as a community pack / bundling in `assets/` / format problem

## Checklist

- [ ] The art or audio is my original work, or I have the right to redistribute it under the stated license
- [ ] `pack.json` (or `sounds.json`) has `author` and `license`, and the pack includes `LICENSE.txt`
- [ ] `uv run tools/pack_build.py --check <dir>` reports the derived files up to date (sprite packs)
- [ ] `uv run tools/validate_packs.py <dir>` passes
- [ ] For bundling: CC-BY-4.0, all 20 canonical animations, directory named after `id`

## Preview

<!-- A screenshot or contact sheet of the animations. -->

## Validator output (format problems)

```text
```
