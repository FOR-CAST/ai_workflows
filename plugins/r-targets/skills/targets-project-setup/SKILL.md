---
name: targets-project-setup
description: Structure a FOR-CAST {targets} pipeline -- multi-project _targets.yaml and TAR_PROJECT, the targets_* list module pattern required by tarborist, tar_source() vs explicit source(), tar_option_set choices, env-var stage gates, crew controllers, and the deliberate tripwires (cue="never", pinned run fleets) that must never be tidied away.
when_to_use: Creating or restructuring a _targets.R; adding a new R/targets_*.R module or target group; setting up a second targets project; choosing tar_option_set values; wiring crew controllers; reviewing a pipeline's architecture.
paths:
  - "**/_targets.R"
  - "**/_targets*.R"
  - "**/_targets.yaml"
  - "**/R/targets_*.R"
---

# Structuring a targets pipeline

## The module pattern (required, not stylistic)

Each `R/targets_*.R` defines **a top-level `targets_* <- list(...)` object**, assembled in
`_targets.R`. Do not wrap target lists in a `get_targets_*()` function:

> the tarborist IDE extension uses static AST analysis and cannot resolve function
> calls, so it requires literal `list()` assignments to discover targets.

And in `_targets.R`: *"Use `list()` (not `c()`) so tarborist recognises the pipeline container."*

The sanctioned exception is a group that must read an option set in `_local.R`,
which is sourced *after* `tar_source()`. Document the reason at the wrapper.

Register custom factories so tarborist can see their targets, in `.vscode/settings.json`:

```json
{ "tarborist.additionalSingleTargetFactories":
  ["tar_terra_rast", "tar_terra_vect", "tar_terra_sprc", "tar_terra_tiles",
   "tar_simspades", "<pkg>::tar_landis"] }
```

## `tar_source()` is not always safe

**Check what is in `R/` before adding `tar_source()`.** One project deliberately
`source()`s six *specific* files:

> Gated "extended analyses" ... These define functions only; `R/` also holds
> standalone scripts, so source the specific files rather than `tar_source()`-ing
> the whole dir.

`R/` there also contains `remove_old_sim_files.R`, which **deletes files**, plus
`upload.R` and `update_FMA_boundaries.R`. Replacing those `source()` calls with
`tar_source()` executes all of them at pipeline-definition time. This is the
sharpest single guardrail in that repo.

Related: in a multi-project layout the root `R/` may hold manual-maintenance
helpers that are deliberately
**not** sourced by either pipeline; each project sources only its own
`tar_source("<proj>/R")`.

## Load order in `_targets.R`

```r
source("_local.R")                       # definition-time knobs
if (file.exists("_hosts.R")) source("_hosts.R")   # BEFORE tar_option_set()
# ... controllers ...
tar_option_set(...)
tar_source("<proj>/R")
```

`_hosts.R` must be sourced before `tar_option_set()` *"so the `crew.ssh.*` options
drive the controller construction below. `_local.R`, sourced later, would be too
late."*

Guard cluster config with `file.exists("_hosts.R")`, never a hostname match --
that keeps the guard hostname-free and survives the cluster being renamed.

## Multi-project layouts

`_targets.yaml` with **no default project** is a deliberate safety pattern:

```r
Sys.setenv(TAR_PROJECT = "prep-fit")   # or "predict"; a bare tar_make() will NOT build
targets::tar_make()
```

Each project gets its own `_targets.R`, `_local.R`, `R/`, and store. `tar_destroy()`
and `tar_prune()` act on the **active** project only.

Projects hand off by `format = "file"`, never by cross-store `tar_read(store = )` --
see `targets-staleness`.

## `tar_option_set()` choices, as actually made

| Option | When to set it |
| --- | --- |
| `workspace_on_error = TRUE` | always -- it is what makes `tar_workspace(<target>)` debugging possible |
| `memory = "transient"`, `storage`/`retrieval = "worker"` | large spatial pipelines, to keep objects off the main process |
| `format = "file"` per target | any heavy or spatial output; see the `r-geospatial` plugin |
| `error = "trim"` | when unrelated targets should keep building |
| `error = "continue"` | **temporary only.** Failed branches are silently skipped. If you set it, write a dated revert condition in a comment, and always check `tar_meta(fields = "error")` afterwards |
| `trust_timestamps = TRUE` | only for multi-GB archives where hashing is prohibitive |
| `format = "qs"` | fine, but the backend changed: targets 1.9.0 switched it from `qs` to `qs2`, and `qs` was archived from CRAN on 2026-01-17. A lockfile still pinning `qs` will not restore from CRAN |
| `seed` | set it; see the reproducibility section of `targets-staleness` |

## Stage gating by environment variable

Expensive optional stages are appended only when an env var is set, so a plain
`tar_make()` can never pick up a 40-hour experiment:

```r
if (isTRUE(as.logical(Sys.getenv("PROJ_DATAPREP", "false")))) {
  targets_all <- c(targets_all, targets_dataprep)
}
```

Name them `<PROJ>_<STAGE>` so they are greppable and obviously project-scoped.
These are read at **definition** time -- set them before `tar_make()`, not inside it.

Some gates must be **off** for a valid run -- one reuse-cached-aggregates gate skips
a ~2 h recompute and is documented *"MUST be FALSE for a fresh run"*. When you see a
gate, find out which way it has to point before running.

## Deliberate tripwires -- do not tidy these away

Three separate patterns exist purely to stop an accidental expensive run. All are
removal-gated by human review:

```r
cue = tar_cue(mode = "never")   ## FROZEN 2026-07-10 ... REMOVE before the production run phase
                                ## (it freezes ALL branches, not just the baselines)
```
```r
landis.run_scenarios = c("ForCS_only", "ForCS_fire")   ## pin the run fleet so no tar_make can
                                                       ## launch production
```
```r
## Deliberately NOT a variant of mainSim_<sa>: the spec is COPIED, not shared, so editing it can
## never invalidate mainSim_<sa> (a 22 h rebuild); gated behind an env var.
```

If a comment says a duplication or a freeze is deliberate, believe it. "Refactoring"
these is how a 22-hour rebuild or a production launch happens by accident.

## Comments are the spec

These projects encode their institutional memory as dated `##` post-mortems
inline in `_targets.R`, `.Rprofile`, `_local.R`, and `.gitignore`. A refactor that
drops them is a regression, not a cleanup. Preserve them; add to them.

## Naming

| Suffix | Meaning |
| --- | --- |
| `_v` | terra `SpatVector` |
| `_png` | figure file target |
| `_files`, `_manifest` | file-path / fingerprint companion target |
| `qmd_*`, `*_pub` | Quarto render target, and the target that publishes its PDF |
| `*_year`, `rep_index` | dynamic branch dimensions |
| `prod_*` | production per-scenario branches |
| `<stage>_<studyArea>` | static per-study-area branching |
