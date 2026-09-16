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
