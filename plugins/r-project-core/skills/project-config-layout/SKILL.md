---
name: project-config-layout
description: The three-way .Rprofile / _local.R / _hosts.R config split used by FOR-CAST pipeline projects, and which settings belong in which file. Crew workers do NOT source _local.R -- putting a worker-visible setting there is a silent no-op. Use when editing any of those files, adding an option or env var, or debugging why a setting did not reach a worker.
when_to_use: Editing .Rprofile, _local.R, _hosts.R, _hosts.R.example, or _targets.R; adding a Sys.setenv() or options() call to a pipeline project; debugging a setting that "did not take" on a worker or in a callr subprocess.
paths:
  - "**/.Rprofile"
  - "**/_local.R"
  - "**/_hosts.R"
  - "**/_hosts.R.example"
  - "**/_targets.R"
  - "**/_targets*.R"
---

# Where does this setting go?

One project states this rule four separate times inside `.Rprofile` alone, which is
a reliable signal that it kept being got wrong:

> Set here (`.Rprofile`, **NOT** `_local.R`, which crew workers do not source) so
> every R process inherits it.

Load order in `_targets.R`: `source("_local.R")` -> optional `source("_hosts.R")`
-> controllers -> `tar_option_set()` -> `tar_source()`.

## The decision table

| File | Tracked? | Read by | Put here |
| --- | --- | --- | --- |
| `.Rprofile` | yes | **every** R process, including crew workers and `callr` subprocesses | env vars (`Sys.setenv`), cache paths, GDAL/PROJ config, anything a worker must see at **run time** |
| `_local.R` | usually yes | the **control** session only, at pipeline-**definition** time | run toggles, study-area choice, `n_reps`, CRS/resolution, paths that get baked into target commands |
| `_hosts.R` | **no** -- gitignored, `.example` shipped | control node only | cluster identity: node names, worker counts, SSH details |

Three consequences that bite:

1. **A `Sys.setenv()` in `_local.R` never reaches a crew worker.** It looks set on
   the control node and is simply absent on the worker. Move it to `.Rprofile`.
2. **A value read from `_local.R` is baked in at definition time.** Anything that
   depends on it must be `deployment = "main"`, and changing it does not
   invalidate targets on its own -- see the `r-targets` plugin's
   `targets-staleness` skill.
3. **`_local.R` values do not exist inside a running target.** As one project's
   docs put it: *"Do not assume `local$...` exists inside a running target."*

## One source of truth per setting

From a project's `_local.R`: *"Do NOT also set these in `.Rprofile` or pass an
equivalent argument to the target factory -- that would create a second source."*

If a value appears in two places, one of them will drift. Pick the layer that the
consumer actually reads and delete the other.

The deliberate exception is a setting whose *absence* is silent and expensive:
`OGR_SQLITE_ALLOW_ANY_EXTENSION=YES` is set in `.Rprofile` **and** repeated in
each `_targets.R`, with a comment saying exactly why (workers inherit it from
`.Rprofile`; the repeat covers interactive use). Duplicate only with that
justification written down.

## Infrastructure identity stays out of the repo

In one incident, cluster node names leaked from the gitignored `_hosts.R` into
comments across the pipeline config, the Quarto config, an ops script, and an
archived config.

> Infrastructure identity does not belong in the repo. Comments now refer to
> roles ("the control node", "a compute node") instead of machines.

One leak was also functional -- a hostname-match guard. It was replaced with
`file.exists("_hosts.R")` *"so the guard is both hostname-free and robust to the
cluster being renamed or moved."* Prefer capability tests over identity tests.

## `.renvignore` and `_dependencies.R`

- `.renvignore` scopes renv's dependency scan (to `R/`, `scripts/`, root `*.R`),
  excluding archived module trees and rendered output.
- `_dependencies.R` is an `if (FALSE) { library(...) }` block that pins indirect
  dependencies renv would otherwise drop: *"renv follows only
  Imports/Depends/LinkingTo, so nothing pulls it in on our behalf any more"* once
  an upstream package demotes a dependency to Suggests.

## Secrets

`*.Renviron`, `.httr-oauth*`, service-account `*.json`, and `_hosts.R` are
gitignored. A good pattern denies **all** `.json` and allowlists the few tracked ones:

```gitignore
*.json
!renv/settings.json
!.vscode/settings.json
!_input_manifest.json
```

Consequence to remember: **a new tracked `.json` needs an explicit `!` allowlist
entry**, or it silently will not be committed.
