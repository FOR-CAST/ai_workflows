# Maintaining this marketplace

For people changing the plugins here. Using them: [installation.md](installation.md).

## Check before pushing

CI runs everything below on every push to `main` or `development` and on every pull
request ([`.github/workflows/check.yaml`](../.github/workflows/check.yaml)). The same
scripts run locally. None of them needs a Claude login, and all are light enough for
a control node.

| What | Command | Catches |
| --- | --- | --- |
| Manifests | `claude plugin validate --strict .` and the same for each `plugins/*/` | schema errors, unknown fields |
| Plugin loading | `.github/scripts/check-plugin-loading.sh` | errors that only appear on a real marketplace install. `validate` passes these, and so does `--plugin-dir`. Example: a `plugin.json` `"hooks"` entry naming the default `hooks/hooks.json` refuses every hook in the plugin |
| Consistency | `.github/scripts/check-consistency.sh` | marketplace entries vs `plugins/`, names, a `version` in the wrong place, hook scripts missing or not executable, skill names vs directories, non-ASCII, CRLF, broken relative links in the docs |
| Version bumps | `.github/scripts/check-version-bumps.sh` | a plugin whose files changed since its last release tag without a version bump |
| Hook behaviour | `bats tests/hooks` | every guard's decisions, plus a portability lint and shellcheck. CI runs it on Ubuntu **and** macOS |
| Cheatsheet | `./cheatsheet/render.sh` | a skill, hook or subagent with no entry on the printed sheet, and an entry left behind after one is removed. The render aborts and names the id |
| Skills | `.github/scripts/check-skills.sh` | skill structure, frontmatter, links and token budgets ([skill-validator](https://github.com/agent-ecosystem/skill-validator)) |

Tools: `claude`, `jq`, [bats-core](https://github.com/bats-core/bats-core),
`shellcheck` (optional; its test is skipped without it), and `skill-validator`.

## Changing a hook

1. Write the test first, in `tests/hooks/<script>.bats`: the command, and the
   decision you expect (`deny`, `ask`, advice, or nothing). Run it and watch it fail.
2. Change the script until it passes, then run the whole suite.
3. Keep scripts portable. macOS ships bash 3.2 and BSD tools, so avoid:
   - `mapfile` and `readarray`
   - `pgrep -a` (use `list_procs` from `_policy.sh`)
   - `\b`, `\s` and `\w` in `grep -E` (use `$B` and POSIX classes)
   - `sed -i`, and `$USER` without a fallback

   `tests/hooks/portability.bats` checks for these.
4. Fail open. On bad input or a missing tool, exit 0 and print nothing.
5. Update [hooks.md](hooks.md), and the policy-key tables in
   [installation.md](installation.md) and the `project-policy` skill if a key changed.

## Changing the cheatsheet

[`cheatsheet/`](../cheatsheet) builds a two-sided printed reference from the plugin
tree. Its terse labels are hand-written -- a `description` in a `SKILL.md` is two to
four sentences, a cheatsheet entry is four to seven words -- so the document cannot
generate itself. What it does instead is refuse to build when it is out of date.

`cheatsheet/R/inventory.R` scans `plugins/` for every skill, subagent and hook
registration; the document checks that set against its own labels and calls `stop()`
on any difference. **Add a skill, hook or subagent and the render fails until it is
on the sheet.** CI runs the render, so this fails the build rather than going
unnoticed.

After changing a plugin:

```sh
./cheatsheet/render.sh          # aborts and names anything missing a label
```

then commit the regenerated `cheatsheet/ai-workflows-cheatsheet.pdf` alongside your
change. A CI step warns when `plugins/` moved but the committed PDF did not; it
warns rather than fails, because nothing inside the document can see what is checked
in.

Notes:

- Needs `quarto` and R with `yaml`, `jsonlite` and `knitr`. Quarto bundles Typst, so
  **no TeX is needed**, on any machine or in CI.
- Keep labels short. The sheet is two columns per side; anything past roughly 26
  characters wraps and the page loses its scannability.
- The sheet carries one accent colour and two status colours, and never lets colour
  alone carry meaning. Eight per-plugin hues were tried and rejected: shown together
  they fail colourblind separation, and a black-and-white print collapses them into
  one grey. A glyph or a named header always says what the colour says.
- CI renders with fallback fonts, which changes line breaks. The committed PDF is
  the one rendered locally, where the intended fonts are present.

## Versions and releases

`version` lives **only** in each plugin's `.claude-plugin/plugin.json`. Claude Code
uses the `plugin.json` value when both files set one, silently, so a second copy in
`marketplace.json` can only go stale.

Users receive a change only when that version moves. So:

1. Change a plugin; bump its `version` in the same branch (patch for fixes, minor
   for new skills or hooks, major for anything that removes or renames). CI fails a
   change without a bump once the previous version has been released.
2. Merge to `main`.
3. After CI passes on `main`, the `release-tags` job runs
   `.github/scripts/tag-releases.sh`, which calls `claude plugin tag --push` for every
   plugin whose version has no `{name}--v{version}` tag yet. Those tags are what
   dependency version ranges resolve against.

To preview what would be tagged: `.github/scripts/tag-releases.sh --dry-run`.

## Bundles and cross-marketplace dependencies

A bundle (`r-bundle-*`) is a manifest with no components: a name, a version and a
`dependencies` list. Enabling one enables everything under it, transitively, and a
dependency is enabled explicitly even if it sets `defaultEnabled: false`. Bump a
bundle's own `version` when you change what it pulls in, or nobody receives the
change.

A dependency in another marketplace needs two things:

1. that marketplace listed in `allowCrossMarketplaceDependenciesOn` at the root of
   `marketplace.json` (only the root marketplace's allowlist is consulted), and
2. the marketplace already added on the machine. **Nothing auto-adds it** --
   [reproduced] with a throwaway `CLAUDE_CONFIG_DIR`: the install reports
   `Dependency "r-lib@posit-dev-skills" is not installed`, and every bundle above it
   reports its own dependency as disabled. Adding the marketplace clears all of it
   and installs the dependency.

`check-plugin-loading.sh` therefore adds those marketplaces before installing, from
a `source_for()` table mapping marketplace name to source. A new entry in the
allowlist fails that check until it is added to the table.

Renaming or removing a plugin breaks every install that names it. Keep `name`
stable and change `displayName`. If a rename is unavoidable, add a top-level
`renames` entry to `marketplace.json`, and keep old entries forever.

## Cost of a plugin

Every enabled plugin puts its skill and agent descriptions in context on every
turn. Check before adding one:

```sh
claude --plugin-dir ./plugins/r-targets plugin details r-targets
```

The combined `description` and `when_to_use` of a skill is cut off at 1,536
characters in the listing. Put the trigger first.
