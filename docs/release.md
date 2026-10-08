# Releasing tern-cat

## Versioning

- [Semantic Versioning](https://semver.org/). The version lives in `plugin.toml` (`version`, a
  free-form string to Tern, which never compares versions) and in the git tag `vX.Y.Z`.
- tern-cat is in public beta: releases are `0.x.y`. While on `0.x`, a minor bump (`0.2.0`) may
  break config keys, `pack.json` fields or Carly export signatures; a patch bump (`0.2.1`) only
  fixes bugs and never breaks them. Breaking changes are listed under **Changed** or **Removed**
  in the changelog with migration notes.
- Data formats carry their own `schema_version` (config, `tern.kv` state envelope, `pack.json`,
  `sounds.json`). Changing a format bumps its schema version and adds a migration; a release
  never silently drops user state.
- Tern has no plugin API version. Each release notes the Tern version it was tested against
  (currently 0.6.2) in the changelog entry.

## Checklist

Work through this on a clean checkout of the release commit.

1. **Changelog.** Move the `## [Unreleased]` entries in `CHANGELOG.md` under
   `## [X.Y.Z] - YYYY-MM-DD`, add the tested Tern version, and update the compare links at the
   bottom.
2. **Version.** Set `version = "X.Y.Z"` in `plugin.toml`.
3. **Checks.** `CI=1 bash scripts/check.sh` passes (format, lint, typecheck, tests, packs), and
   the CI workflow is green on macOS and Linux for the release commit.
4. **Packs.**
   - `uv run tools/validate_packs.py` passes (all bundled sprite and sound packs, both
     validators).
   - `uv run tools/pack_build.py --check assets/packs/orange-menace assets/packs/void assets/packs/tuxedo`
     reports the derived files up to date.
   - Regenerating with `uv run tools/build_packs.py` and `uv run tools/build_sounds.py` leaves
     `git status` clean.
5. **Credits.** Every new asset is listed in `assets/CREDITS.md` with author and license, and
   each pack has `LICENSE.txt`.
6. **Sandbox smoke** (needs Tern; see [develop-with-omp-tern.md](develop-with-omp-tern.md)). In a
   shell that sourced `scripts/sandbox-env.sh`:
   - `bash scripts/dev-link.sh`, then `tern plugin list` shows tern-cat without problems;
   - in a sandbox window: the overlay cat appears, clicks and typing pass through it, the block
     opens from the palette, pet/poke/feed/play work, hide and snooze work, sound stays silent
     until enabled;
   - `tern plugin reload` keeps the cat's identity and stats; two windows do not double count;
   - `$SB/logs` shows no plugin errors or budget trips.
7. **Install test** (needs Tern). In a fresh sandbox (`SB=/tmp/tern-cat-release source
   scripts/sandbox-env.sh`), after pushing the tag:
   `tern plugin install github.com/contrafy/tern-cat`, then `tern plugin list`.
8. **Screenshots.** Retake any screenshot whose content changed. Shots must not show personal
   paths, user names, hostnames, prompts or account details: use the sandbox, a neutral working
   directory and a plain prompt, and redact anything left.
9. **Tag.** `git tag -a vX.Y.Z -m "tern-cat X.Y.Z"` and `git push origin vX.Y.Z`.
10. **GitHub release.** Create a release from the tag titled `vX.Y.Z`, paste the changelog
    section, attach updated screenshots, and include the install command:

    ```sh
    tern plugin install github.com/contrafy/tern-cat
    ```

    Pre-1.0 releases are marked as pre-release.

## Installing, updating, uninstalling

These go in the release notes and README:

```sh
tern plugin install github.com/contrafy/tern-cat           # install
tern plugin install github.com/contrafy/tern-cat --force   # update (replaces the installed copy)
tern plugin remove tern-cat                                # uninstall
```

`tern plugin remove` deletes only the package folder inside the plugins folder
([Tern CLI reference](https://docs.stencil.so/tern/reference/cli.html)). The data folder
`<state>/plugin-data/tern-cat/` (state, config, inbox, exports, user packs) is separate; delete it
to remove all data ([security-privacy.md](security-privacy.md#what-is-stored-where)).
