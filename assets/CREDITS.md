# Asset credits

All bundled art and sound in tern-cat is original and generated from code in this repository.
No third-party sprites, samples or fonts are included.

| Asset | Path | Author | License | Source |
|---|---|---|---|---|
| Orange Menace sprite pack (default) | `assets/packs/orange-menace/` | Ahmad Raaiyan | CC-BY-4.0 | `tools/art/`, built by `tools/build_packs.py` |
| Void sprite pack | `assets/packs/void/` | Ahmad Raaiyan | CC-BY-4.0 | `tools/art/`, built by `tools/build_packs.py` |
| Tuxedo sprite pack | `assets/packs/tuxedo/` | Ahmad Raaiyan | CC-BY-4.0 | `tools/art/`, built by `tools/build_packs.py` |
| Default sound pack (meow, purr, surprise, happy, swat) | `assets/sounds/default/` | Ahmad Raaiyan | CC-BY-4.0 | synthesized by `tools/build_sounds.py` |
| Pack contact sheet | `docs/images/packs-preview.png` | Ahmad Raaiyan | CC-BY-4.0 | `tools/build_packs.py` |

## Licenses

- **Assets** (everything under `assets/`, plus `docs/images/packs-preview.png`) are licensed under the
  [Creative Commons Attribution 4.0 International License](https://creativecommons.org/licenses/by/4.0/)
  (CC BY 4.0). You may share and adapt them for any purpose, including commercially, as long as you
  give appropriate credit, link to the license, and indicate if you made changes.
- **Code** (the plugin, `cat/`, `tools/`, tests and scripts), including the code that generates
  these assets, is licensed under the MIT License in [`../LICENSE`](../LICENSE).

## How to attribute

When you redistribute or modify the sprites or sounds, include a notice such as:

> "Orange Menace" sprites by Ahmad Raaiyan (tern-cat), licensed under CC BY 4.0
> (https://creativecommons.org/licenses/by/4.0/). Changes: recolored.

Replace the pack name with the one you used (`Orange Menace`, `Void`, `Tuxedo`, or
`Default Cat Sounds`), and describe your changes or omit that sentence if there are none. Each
sprite pack also carries its own `LICENSE.txt`, and the `author` and `license` fields in
`pack.json` / `sounds.json` record the same information in machine-readable form.

Community packs keep their own authors and licenses, declared in their own manifests.

## Regenerating

```sh
uv run tools/build_packs.py    # sprite packs + docs/images/packs-preview.png
uv run tools/build_sounds.py   # assets/sounds/default
uv run tools/validate_packs.py # structural checks (and the Luau validator when lune is installed)
```

Both builders are deterministic: rerunning them reproduces byte-identical files.
