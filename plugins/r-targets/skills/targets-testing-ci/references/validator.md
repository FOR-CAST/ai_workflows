# The pipeline validator

## Contents
- The bug class
- Installing it in a project
- What each check catches
- Variants: every graph the configuration can build
- False positives and the allowlist
- Limits
- Proving it works

## The bug class

`targets` never verifies that the names in a target's command resolve. A command can name a
target in a different project of the same repository, a target that exists only when an
optional stage is switched on, or a helper whose file is not sourced -- and the pipeline
validates, builds, and reports success.

It survives because R is lazily evaluated:

```r
zonal_summaries <- function(outputs, study_area, LCC) {
  if (length(outputs) == 0L) {
    return(character(0))        # returns before forcing study_area or LCC
  }
  ...
}
```

When the input was empty -- the normal state, because the expensive upstream stage was
opt-in -- the function returned before looking up its other arguments. `targets` recorded
the target as **built**. It failed the first time real input existed. The same class has
been found, independently, in three separate projects.

> A target that returns early on an empty input is not evidence that its arguments resolve.

The guide-style fix -- walking each command's syntax tree by hand -- produced 35 false
positives on one real pipeline. The bundled validator uses `codetools`, the same scoping
`targets` itself uses, and adds the checks the hand-written versions lacked.

## Installing it in a project

```bash
mkdir -p scripts tests/validate
cp "${CLAUDE_SKILL_DIR}/scripts/validate-projects.R" "${CLAUDE_SKILL_DIR}/scripts/validate_lib.R" scripts/
cp "${CLAUDE_SKILL_DIR}/assets/validate.yml" "${CLAUDE_SKILL_DIR}/assets/unresolved_allowlist.csv" tests/validate/
Rscript-<version> scripts/validate-projects.R
```

It exits 1 on any finding or stale allowlist row. **An exit status is not optional**: a
validator that only prints, pasted into CI, always passes.

Run it after touching `_targets*.R`, `_targets.yaml`, the local config file, or anything in
`R/`. It only builds manifests, so it is light -- but a project whose pipeline definition
reads large files is not; place it accordingly.

## What each check catches

| Check | Catches |
| --- | --- |
| `definition` | the pipeline definition itself errors (a clean clone missing data, a bad `tar_quarto()` chunk option) |
| `package` | a package the pipeline declares cannot be loaded |
| `unparseable` | a command that embeds an object (spliced with `bquote()`) and does not deparse to valid R -- reported, not silently skipped |
| `unresolved` | a name in a command that is not a target, not a script binding, and does not exist |
| `unresolved_function` | a project function reachable from the commands calls a function that does not exist -- typically a file missing from a partial `tar_source(files = )` list, which otherwise surfaces as "object not found" on a worker days into a run |
| `pattern` | `pattern = map(a, not_a_target)`: `tar_manifest()` and `tar_validate()` both accept it; only `tar_make()` fails |
| `file_name_index` | `x[["csv"]]` on a `format = "file"` target, whose stored value is bare unnamed paths |
| `option_cue` | a target whose command, or any function it reaches, reads a run-scoping `getOption()` without `cue = "always"` and `deployment = "main"` -- the option is not a tracked dependency, so the target keeps a stale value. One project found six real stale-configuration bugs with this check |
| `cross_graph` | a name that is a target in another graph (another project, or the same project under another variant) but not in this one -- checked even when the name resolves, because a missing target called `factorial` or `local` silently resolves to the base function |

Each graph is checked in a **fresh R process** (`callr`, loading the project `.Rprofile` so
renv activates). A project that sources only part of `R/` would otherwise resolve a missing
file against another project's leftovers.

## Variants: every graph the configuration can build

Configuration decides which targets exist: optional stages behind environment variables or
options, user-dependent switches in a local config file, CI-only graphs. **A gated stage that
no variant switches on is never checked** -- and gated stages are where the early-return bug
hides. List every setting in `tests/validate/validate.yml`:

```yaml
variants:
  default: {}
  ci:
    env: { PIPELINE_AS_CI: "true" }
  all-stages:
    env: { PROJ_DATAPREP: "true", PROJ_FORWARDSIM: "true" }
```

- **Use a project-specific variable to reproduce the CI graph locally, not `CI=true`.** A
  personal `~/.Renviron` that sets `CI` overrides the shell, so `CI=true Rscript ...`
  silently validates the wrong graph.
- **Make gates readable from an environment variable at definition time.** An option the
  local config file sets unconditionally cannot be flipped from outside.
- **Make static-branching keys selectable too.** If only one of eighteen study areas is
  active by default, the other seventeen are never validated.

## False positives and the allowlist

Handled automatically: local assignments, function formals, `for` variables, `x$field`,
`pkg::fn`, `quote()`, formulas (`~ .x`, model formulas), empty arguments (`x[, 1]`),
data.table specials (`.N`, `.SD`, `:=`), and column arguments of common dplyr/tidyr/ggplot2
verbs and base `subset`/`with`/`transform`. Column arguments are set aside rather than
ignored: they are still cross-checked against other graphs' target names, which catches
`.data$batch == another_projects_target`.

Everything else goes in `tests/validate/unresolved_allowlist.csv`, one row per reason:

```csv
project,variant,target,check,symbol,reason
main,any,scenario_table,unresolved,climate_id|harvest_id,column names inside a data.table [
main,ci,report_fire,cross_graph,comparison_png,optional figure; the report guards it with tar_exist_objects()
```

- `target` and `symbol` are anchored regular expressions; `project`, `variant`, `check` may
  be `any`.
- **A row whose target is present but matches nothing is STALE and fails the run**, so the
  list cannot rot.
- A row whose target the graph does not contain (a gated-off stage) is skipped.
- Prefer extending the NSE verb list in `validate_lib.R` over allowlisting a column name:
  allowlisting a name also hides a real target of that name.

## Limits

- A function passed as an argument (`lapply(x, helper)`) is a variable, not a call, so it is
  checked for existence but not walked into.
- `exists()` searches the whole search path, so an unrelated attached function can satisfy a
  name.
- Building a pipeline definition runs the script: if the script writes directories at
  definition time, so does the validator.
- The NSE handling is a heuristic over known verbs.
- It checks only the variants you list.

## Projects generated from one factory

If several projects are generated from shared factory code (one per region or scenario), a
change in that shared code can reach one project and not the others. Two habits catch it:

- **Validate every project after touching anything a pipeline reads**, not only the one you
  were working on -- the bundled validator does this by default.
- **Assert that projects of the same kind agree on target count.** Group projects by a naming
  convention and compare counts within each group:
  ```r
  counts <- vapply(results, function(r) length(r$targets), integer(1))
  kind <- sub("_[^_]+$", "", names(counts))          # ADJUST to the project naming scheme
  disagree <- tapply(counts, kind, function(n) length(unique(n)) > 1L)
  ```
  Prefer this to hard-coding an expected count, which every intentional addition would force
  you to update in two places.

## Proving it works

The skill ships `selftest/run-selftest.R`: a synthetic two-project pipeline with a planted bug
for every check -- including a missing helper two calls deep and a reference to a gated-off
stage -- alongside look-alike cases that must not be flagged, plus a negative control that
must exit 0. It runs in a few seconds and uses almost no memory.

In a real project, prove it the same way: reintroduce a bug the validator should catch,
confirm the run fails and names it, then revert.
