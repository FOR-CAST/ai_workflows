---
name: commit
description: Write a commit in the FOR-CAST house style -- Conventional Commits with a scope, a contrastive subject that states the decision, and a body that reads as lab notes (measurement, falsified hypothesis, verification, downstream consequences). Stages named paths only, checks submodule pointers against the remote, and appends the Co-Authored-By trailer.
argument-hint: "[optional: what changed, or paths to stage]"
disable-model-invocation: true
allowed-tools: Bash(git status:*), Bash(git diff:*), Bash(git log:*), Bash(git add:*), Bash(git commit:*), Bash(git submodule status:*), Bash(git -C:*), Bash(git ls-files:*), Read, Grep
---

# Commit, house style

Run this only when the user asks for a commit. Never commit unprompted.

## 1. Look before staging

```sh
git status --porcelain
git diff --stat
git diff                      # actually read it
```

Stage **named paths**, never `-a` and never `.`:

```sh
git add R/targets_fire.R params/fire/severity.csv
```

`git commit -a` sweeps in unrelated churn -- `renv.lock`, `_targets` metadata,
`.Rproj.user`, regenerated `man/*.Rd`. A `PreToolUse` hook in this plugin flags it.

## 2. If a submodule pointer is staged, verify it exists on the remote

This incident broke every worker node on a shared cluster:

> The superproject recorded the submodule at a SHA that was **another session's
> commit**, and had not been pushed. It landed in the submodule working tree
> between my install and my `git add packages/<pkg>`, and `add` stages
> whatever HEAD is at that moment. Every node then failed to sync:
> `fatal: remote error: upload-pack: not our ref c7be5647`.
>
> **LESSON: verifying the renv.lock diff before staging is not enough. A
> submodule pointer must be checked at STAGE time against what is actually on the
> remote, because `git add <submodule>` reads a moving target in a shared worktree.**

For each staged gitlink:

```sh
sha=$(git ls-files -s <submodule> | awk '{print $2}')
git -C <submodule> fetch --quiet origin
git -C <submodule> branch -r --contains "$sha"      # must print something
```

If it prints nothing, stop: the SHA is local-only. Push the submodule first, or
unstage the pointer.

Also confirm the pointer agrees with the version recorded in `renv.lock` -- these
have silently disagreed before.

## 3. Write the subject

Conventional Commits with a scope: `type(scope): subject`.

Types actually used, in frequency order: `feat`, `fix`, `chore`, `docs`,
`refactor`, `perf`, `revert`, `build`, `style`. Scopes name the pipeline area (`deps`, `calibration`, `fire`, `growth`) or the
sub-project (`prep-fit:`, `predict:`). Package repos also use a `[vX.Y.Z]` subject
prefix on the commit that bumps `Version:`.

**The subject states the decision, not the area touched.** The house pattern is
contrastive -- "X, not Y":

```
fix(ic): landis_datatype() takes the max map code, not the raster
fix(growth): the comparator sets are priors, not published, and not independent
revert(ic): keep overrideBiomassInFires ON -- turning it off made things worse
```

ASCII only: `--` for a dash, `->` for an arrow.

## 4. Write the body -- this is the part that matters

Bodies here average ~21 lines and read as lab notes. Include, where each applies:

- **the measurement**, with numbers (a small table is normal);
- **the hypothesis that was falsified**, so the dead end is not retried;
- **the verification performed** (`tar_validate() passes (24 targets)`, a synthetic
  test case with exact expected values, an independent reference comparison);
- **what is invalidated downstream** -- name the targets;
- **known consequences** still outstanding.

Two house conventions worth keeping:

- A rejected option is recorded with its numbers, marked `NOT DISCARDED`, *"because
  without the specific reasons written down this is easy to re-derive and re-adopt."*
- A `LESSON:` line when the commit encodes a process fix rather than a code fix.

Wrap at ~90 characters.

## 5. Trailer

```
Co-Authored-By: Claude <model> <noreply@anthropic.com>
```

Use the actual model name, as the corpus does: `Claude Opus 5 (1M context)`,
`Claude Opus 4.8`. Trailer discipline is currently inconsistent (some
agent-authored commits carry none) -- always add it.

Do **not** add a `Generated with Claude Code` footer; there are zero in the corpus.

## 6. Repo-specific extras

- **R packages**: add a `NEWS.md` entry and bump the version. Run `devtools::document()` first if
  roxygen changed.
- **Pipeline / analysis projects**: `NEWS.md` is typically **not** maintained --
  check before adding an entry.
- `[skip-ci]` in the subject skips CI where CI exists.
- These repos commit directly to a long-lived branch; there is no PR or squash
  workflow. Do not open a PR unless asked.

## 7. Do not push

Push only when the user asks. If you do push, never bare `--force` -- use
`--force-with-lease` (a hook enforces this).
