# Third-party skills and plugins

What to point people at, by workflow stage. Every enabled plugin puts its skill and
agent descriptions in context on every turn -- enable per project, not globally.
Where a third-party skill overlaps one here, the one here wins: it knows the policy.

## Already in use

| Source | Provides | Notes |
| --- | --- | --- |
| `r-lib@posit-dev-skills` | `r-package-development`, `testing-r-packages`, `cran-extrachecks`, `lifecycle`, `cli`, `mirai`, `alt-text`, `r-cli-app`, `r-cran-status` | The package workflow. `r-package-dev` here carries only the deltas. |
| built-in | `dataviz`, `code-review`, `simplify`, `security-review`, `update-config`, `fewer-permission-prompts`, `loop`, `schedule` | No install. |

`superpowers@claude-plugins-official` is all-or-nothing: enabling it for one skill
also brings its session-start bootstrap (see Context cost). Its specs and plans
default to committed `docs/superpowers/`; both skills defer to a stated preference,
so put "plans and specs go in `_tmp/`, uncommitted" in the project `CLAUDE.md`.

## Plan

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `brainstorming` | superpowers | new pipeline stage, module or package feature with open design questions | approval gate on every task, however small |
| `writing-plans` | superpowers | a multi-task change another session will execute | template is pytest/npm-shaped; save to `_tmp/PLAN_<topic>.md` (`design-log`) |
| `/feature-dev` | `feature-dev@claude-plugins-official` | the same, on demand, no bootstrap | use this or `brainstorming`, not both |
| `working-on` | `posit-dev@posit-dev-skills` | keep a tracking doc current through a long task | give it a `_tmp/HANDOFF_*.md` path; skip `new-work` (`_dev/todos/`) |
| `describe-design` | `posit-dev@posit-dev-skills` | onboarding doc for a pipeline or module graph | confirms the path before writing |

## Implement

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `subagent-driven-development` | superpowers | executing a written plan task by task, reviewed between tasks | decides ambiguities itself; tell it parameter, CRS, threshold and reference-data choices are stop-and-ask |
| `dispatching-parallel-agents` | superpowers | independent failures in separate files or modules | not for agents sharing a targets store or the same files |
| `test-driven-development` | superpowers | package helpers whose right answer is derivable by hand | not a substitute for `verification-method` on model output |
| `quarto-authoring`, `brand-yml` | `quarto@posit-dev-skills` | Quarto syntax: cross-refs, cell options, callouts, branding | pairs with `r-reporting:quarto-reports`; its `alt-text` duplicates r-lib's |

## Debug

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `systematic-debugging` | superpowers | before proposing any fix | pair with `root-cause-fixes`, which says where the fix goes; in a `{targets}` project "reproduce" means `tar_meta()` / `tar_workspace()` first (`targets-debugging`), not re-running a long target |

## Verify

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `verification-before-completion` | superpowers | before saying done, fixed or passing | proves the command ran; `verification-method` proves the number is right -- use both |
| `review-testing` | `posit-dev@posit-dev-skills` | after writing testthat tests | its "implementation mirror" smell is our independent-reference rule |

## Review

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `r-code-review` agents | here | spatial, dependency, run-failure review; `r-targets` adds the staleness auditor | first choice for research code |
| `/code-review` | built-in | general bugs on the diff or a PR | `--comment` publishes |
| `critical-code-reviewer` | `posit-dev@posit-dev-skills` | a collaborator's PR to your package | drafts, then pending review, then submit -- each on request; flags `df`/`x` naming in analysis code |
| `receiving-code-review` | superpowers | acting on review feedback | verify each item before changing code |
| `/pr-review-toolkit:review-pr errors tests` | `pr-review-toolkit@claude-plugins-official` | silent `tryCatch()` / fallback hunting | agents assume JS and Sentry; ~6 KB of agent descriptions always loaded |
| `/security-review` | built-in | before opening a repo to the public | on demand |

## Finish and release

| Use | From | When | Mind |
| --- | --- | --- | --- |
| `package-change-workflow` | here | any package change | development -> CI -> main -> install; replaces `finishing-a-development-branch` |
| `pr-create` | `github@posit-dev-skills` | repos that use PRs, e.g. upstream contributions | pushes fix commits until CI passes; local checks such as `devtools::check()` and `air format` run first |
| `pr-threads-address` | `github@posit-dev-skills` | working through PR review threads | installs the third-party `gh pr-review` extension |
| `create-release-checklist` | `open-source@posit-dev-skills` | CRAN release issue | needs `usethis` outside renv; creates a GitHub issue |
| `/schedule` + `r-cran-status` | built-in, r-lib | recurring CRAN check-result lookups | cloud agents cannot reach cluster nodes or local stores |
| `/project-artifact` | `project-artifact@claude-plugins-official` | status page for a multi-month effort | keep host names out of it |

## Maintain this marketplace

Start with [maintaining.md](maintaining.md): the local checks, CI, and the release flow.
`claude plugin details <name>` shows a plugin's always-on token cost; `/skill-doctor`
lists skills that are never invoked.

| Use | From | For | Mind |
| --- | --- | --- | --- |
| `writing-skills` | superpowers | test a skill against a no-skill baseline before shipping | "description = triggers only" contradicts skill-creator's "be pushy" |
| `skill-creator` | `skill-creator@claude-plugins-official` | trigger-rate evals on descriptions | `quick_validate.py` rejects `when_to_use`, `paths`, `argument-hint`, `disable-model-invocation` -- all valid; evals run 10 `claude -p` at once and ignore `paths` |
| `plugin-validator`, `test-hook.sh`, `validate-hook-schema.sh` | `plugin-dev@claude-plugins-official` | manifest and hook checks | prefers prompt hooks and `set -e`; ours are deterministic and fail open; `skill-reviewer` wrongly calls `when_to_use` deprecated |
| `/hookify` | `hookify@claude-plugins-official` | prototype a guard in a minute | deny only (no `ask`), rules relative to cwd, local files; port keepers to `hooks/` here |
| `session-report` | `session-report@claude-plugins-official` | what each plugin and skill costs in tokens | writes HTML to cwd |
| `claude-md-improver` | `claude-md-management@claude-plugins-official` | audit a CLAUDE.md for bloat | `/revise-claude-md` grows CLAUDE.md; move recurring lessons into a skill or hook |

## Avoid, or caveat hard

| Plugin or skill | Why |
| --- | --- |
| `commit-commands` | `/commit` stages and commits in one step without looking; `/commit-push-pr` pushes and opens a PR; `/clean_gone` runs `git worktree remove --force` and `git branch -D`. Use `/r-project-core:commit`. |
| `code-simplifier` | JS/React standards baked in; told to run proactively. Use `/simplify` on demand and check it kept deliberate tripwires. |
| `code-review` plugin | PR-only and posts its comment automatically; the built-in covers it. |
| `github` MCP | its writes are MCP tools, which `guard-mcp.sh` can only judge by name; `gh` is covered by exact command patterns. Prefer `gh`. |
| `security-guidance` | its LLM review skips `.R`, `.qmd`, `.Rmd`; model call after each turn and each commit; pip-builds a venv at session start. If kept: `ENABLE_STOP_REVIEW=0` in shared worktrees. |
| `using-git-worktrees` | a new worktree has no renv library, `_targets/` store, `_local.R`/`_hosts.R` or untracked inputs; may commit a `.gitignore` edit. |
| `finishing-a-development-branch` | offers local merge or push-and-PR with no CI step. |
| `implement` (posit-dev) | 3-5 parallel implementers in one worktree; rebases fresh branches. |
| `ralph-loop` | Stop hook replays the prompt, unlimited iterations by default. |
| `claude-code-setup` | JS-oriented detection; recommends plugins rejected here. |
| `release-post` | tidyverse/Shiny blog voice, against `report-writing`. |
| `serena`, `context7` | serena runs unpinned GitHub HEAD via `uvx` and needs R `languageserver` visible to the project R; context7 is a hosted lookup with uneven R coverage -- `?fn` in the project R is version-exact. |

## Context cost

superpowers injects its ~3 KB `using-superpowers` skill at startup, `/clear` and
compaction, adds ~2 KB of descriptions, and tells the model to load a skill on a 1%
chance of relevance. plugin-dev (~7 KB) and pr-review-toolkit (~6 KB) carry long
agent descriptions. Enable those for the sessions that use them. Measure with
`session-report`.

## Other languages and marketplaces

`pyright-lsp` (Python) and `typescript-lsp` (web) from `claude-plugins-official`.
There is no R LSP plugin; `serena` above is the nearest. The screened community
marketplace: `/plugin marketplace add anthropics/claude-plugins-community`.

## Reducing permission prompts

Run `/fewer-permission-prompts`, then replace one-rule-per-invocation entries with a
few globs, e.g. `Bash(git -C:*)`, `Bash(Rscript-4.6.1 -e:*)`,
`WebFetch(domain:raw.githubusercontent.com)`. One repo here had 521 entries, 243 of
them one-per-URL `curl` rules.
