# Hooks

Hooks are the deterministic half of this toolkit. A `CLAUDE.md` rule is advisory --
the model can forget it, and in these projects demonstrably did, repeatedly. A hook
runs every time.

All hooks here are written to **fail open**: an error inside a hook never blocks
your work. Every blocking hook names the safe alternative in its message, so a
block redirects rather than stalls.

The scripts run on Linux and on macOS (bash 3.2, BSD userland). Each has tests in
[`tests/hooks/`](../tests/hooks), which CI runs on both; see
[maintaining.md](maintaining.md).

## r-project-core

### SessionStart

| Script | What it does |
| --- | --- |
| `session-context.sh` | Prints host and its role (control vs compute), the loaded project policy, long-running processes already on the machine **labelled as not yours**, running containers, detached screens, the git branch, uncommitted changes that predate the session, and any drifted submodule pointers. |

This exists because three of the most expensive recorded mistakes -- running heavy
compute on a control node, signalling another project's process, and staging a
concurrent session's work -- all happen because that information was not visible at
the moment it mattered.

### PreToolUse / Bash

| Script | Denies | Why |
| --- | --- | --- |
| `guard-destructive.sh` | `git reset --hard`, whole-tree `checkout`/`restore`, `git clean -f*`, `git branch -D`, `git worktree remove --force`, bare `--force` push, `--no-verify`, `rm -rf` of an renv library, forcible submodule ops | each discards work that is not cheaply recoverable; `--force-with-lease`, `git branch -d` and a plain `git worktree remove` are allowed |
| `guard-process-ownership.sh` | `pkill`, `killall`, `kill -9`, `docker kill/stop/rm/system prune`, `screen -X quit`, service stops | an agent once killed another project's multi-day run on a shared node. Escape hatch: add `# owner-verified: ...` after checking `ps -o pid,user,lstart` |
| `guard-staging.sh` | `git add -A`, `git add .`, `git add -u`, `git commit -a` | multiple sessions share worktrees; sweeping commits have captured unpushed submodule pointers and broken every node in a cluster |
| `guard-policy.sh` | *policy-driven*: package installs, `air format`, heavy compute on a control node; **asks you to confirm** publishing; advises on a bare `Rscript` | see below |
| `guard-host-names.sh` | with `hostPatterns`, **asks you to confirm** a commit message, PR or issue body, release note or staged diff that names one of your machines | a name in a commit is public and permanent, and says nothing about reproducibility. An `ssh` destination is not a published name, so it passes |
| `guard-long-run-interlock.sh` | package installs (renv, pak, remotes, devtools, Require, `setupProject()`), `renv::checkout()` and node syncs **while a long run is live** | syncing swaps the R library out from under active workers |
| `advise-bash-hygiene.sh` | *(never denies)* notes a leading `cd` (the shell's cwd does not persist between calls) and a long command still on the default 2-minute timeout | ~3,000 cwd resets and 64 timeouts in the record |

### PreToolUse / MCP tools

| Script | What it does |
| --- | --- |
| `guard-mcp.sh` | with `publishRequiresApproval`, **asks you to confirm** an MCP tool whose name says it writes, publishes or runs code (`create_pull_request`, `trash_file`, `btw_tool_run_r`). The first recognised verb in the tool's own name decides, so `get_pull_request_review_comments` is a read. MCP tools have no read/write flag, so this is a backstop: a tool with an unrecognised name goes through |

The Bash guards never see MCP tools. Without this, a GitHub MCP server could open a
pull request, or an R-session server run code, with no prompt.

### PreToolUse / Edit, Write, NotebookEdit

| Script | Denies |
| --- | --- |
| `guard-generated-files.sh` | hand-edits to `man/*.Rd`, `NAMESPACE`, `renv.lock`, `renv/activate.R`, `_targets/meta/`, and to `README.md`/`*.html` where a `.qmd`/`.Rmd` source sits beside them |
| `guard-ascii.sh` | non-ASCII in `.R`, `.qmd`, `.Rmd`, `.bib` (or the policy's `asciiExtensions`); reports each character, its code point, the first line it appears on, and the ASCII or LaTeX replacement |
| `guard-host-names.sh` | *(asks, never denies)* a machine name from `hostPatterns` written into a file git tracks. Gitignored files -- `_hosts.R`, drafts -- and files outside a repository pass untouched |

### PostToolUse / Edit, Write

| Script | What it does |
| --- | --- |
| `r-format-and-parse.sh` | parse-checks every edited `.R` file and runs `air format` where the project has an `air.toml`; reports back so a syntax error surfaces in the same turn |
| `check-citations.sh` | extracts every DOI written, resolves it, and reports **the title it actually resolves to**. A DOI that 404s is flagged as probably fabricated; a DOI resolving to a different paper than claimed is visible in the reported title; new bib entries with no DOI are listed as unverified. Degrades to "could not verify" offline -- it never false-accuses. Also runs by hand on files R generated, which the hook never sees: `check-citations.sh --file citations/r-packages.bib CITATION.cff` exits 1 if a DOI does not resolve |

## r-package-dev

| Event | Script | What it does |
| --- | --- | --- |
| PostToolUse | `rbuildignore-claude.sh` | appends `^\.claude$` to `.Rbuildignore` when a `.claude/` dir appears beside a `DESCRIPTION` -- removes a check NOTE that occurred 28 times |
| Stop | `check-doc-sync.sh` | blocks the turn if roxygen lines changed in `R/` but `man/` and `NAMESPACE` were not regenerated, and reminds you to check the roxygen2 version first |

## Policy-driven guards

`guard-policy.sh` reads `.claude/r-project-policy.json` from the repo root. **Every
rule in it is off unless the repo opts in**, because these projects deliberately
disagree with each other:

- `air format` is mandatory in most repos and explicitly forbidden in a few whose
  HEAD is not air-clean;
- R is pinned to different versions, and some repos pin nothing;
- only some machines are control nodes.

Hardcoding either side would be wrong somewhere. See
[installation.md](installation.md) for the keys.

## Turning things off

- One plugin: `/plugin disable r-package-dev@ai-workflows`
- One hook: remove its entry from that plugin's `hooks/hooks.json`
- Everything, temporarily: `"disableAllHooks": true` in settings
- A single policy rule: remove the key from `.claude/r-project-policy.json`

If a guard fires when it should not, the fix is almost always a policy value rather
than a code change. Report which key and why.

## Writing your own

Two things learned building these:

1. **Resolve repo identity through git, not the working directory.** Repos here are
   reachable under more than one path (parts of `~/GitHub` are symlinks), so a hook
   that string-matches `$PWD` gives different answers depending on how the session
   was opened. Use `git rev-parse --show-toplevel | xargs readlink -f`.
2. **Pick the weakest decision that is still safe.**
   - `deny` -- only when there is a safe alternative the model can take instead
     (`--force-with-lease`, `renv::install(..., lock = TRUE)`, dispatching over
     `ssh`). A deny cannot be approved from the permission prompt, so never use it
     for something that should end in "yes, go ahead".
   - `ask` -- for actions that are fine once a person has looked, such as a push or
     a merge. It forces a permission prompt even in auto mode. The reason text is
     shown to you, not to the model.
   - `additionalContext` with no decision -- for legitimate-but-risky commands.
     Informs the model without blocking.
