# The failure catalogue

What the tooling in this repo was built from. Distilled from the git histories of
ten research repositories (roughly 8,000 commits) and ~115 Claude Code session
transcripts. Projects are not named; the lessons are what transfer.

The organizing observation: **in research code, the dangerous failures do not throw
errors.** They produce a plausible number, render a map that looks right, and
report a clean run. Every item marked *silent* below was found weeks or months
after it was introduced, usually by accident.

---

## 1. Silent pipeline staleness -- the most repeated failure

At least eight separate incidents in one project alone; the commit fixing the
eighth notes the same trap had already been fixed twice before.

`targets` hashes the command *expression* and the globals it can see. It does not
see: `getOption()` values, symbols bound to config values, functions inside
installed packages, path strings, or env vars read at definition time.

*Silent.* One case: switching the study area left the pipeline running the old one,
and a scoped calibration "finished in 3 minutes having skipped the calibration
entirely."

A second, independently-found variant: **a target returning a stable path string
does not invalidate its consumers when the contents behind it change.** The remedy
is a `*_manifest` companion target carrying path/size/mtime fingerprints.

How they were actually caught: file mtimes rather than the run summary, and
validation numbers coming back *identical to the decimal* across a change that
should have moved them.

-> `r-targets:targets-staleness`, `r-targets` agent `pipeline-invalidation-auditor`

## 1b. Targets that "built" without ever resolving their inputs

`targets` never checks that the names in a command resolve. A command naming a target from
another project, or from an optional stage that is switched off, still validates and builds
-- because the function it calls returns early on empty input and never forces the missing
argument. Found independently in three projects; one survived for months. A static validator
over every project and every configuration variant catches it, along with helpers missing
from a partial `tar_source()` list and `pattern =` over non-targets.

-> `r-targets:targets-testing-ci`, on top of `r-project-core:project-tests-ci`

## 2. Dependency and version drift -- the largest ongoing cost

`renv.lock` is the single most-touched file in two of the largest repos (16% and
23% of recent commits); submodule pointers moved ~250 times in 800 commits.

Three distinct sub-traps:

- **One repo requested at two branches fails the whole solve** and misreports every
  *other* package as conflicting -- which reads like a far bigger problem than it is.
- **A submodule pointer recorded at an unpushed commit** breaks `git submodule
  update` on every other machine and every fresh clone.
- **The package cache key encodes version but not ABI**, so another project's
  binaries can overwrite yours and kill a mid-flight run.

In R packages specifically, the top failure is a symbol used but not declared, and
the offenders are always base-adjacent: `stats::setNames`, `utils::head`,
`utils::packageVersion`. One such line cost four commits and a spurious version bump.

-> `r-package-dev:package-dependencies`, `dependency-auditor`

## 3. Spatial objects that do not survive serialisation

`SpatRaster`/`SpatVector` hold data behind an external pointer. A plain
`tar_target` stores the dead pointer **without complaint**; the failure surfaces in
the *consumer*, minutes later, as `NULL value passed as symbol address`. The same
happens with any worker, cache or saved `.rds`.

The design fix is not `wrap()`/`unwrap()` -- it is to make files the currency, passing
filenames across every boundary (in a pipeline, `geotargets::tar_terra_*` or
`format = "file"`).

-> `r-geospatial:spatial-io-and-crs`, `r-targets:targets-spatial`

## 4. Geometry operations that silently drop data

Five separate corrective commits in one repo converge on one safe sequence:
`st_make_valid()` -> `st_set_geometry("geom")` -> `st_set_agr("constant")` ->
*operation* -> `st_make_valid()` -> cast MULTIPOLYGON -> cast POLYGON.

Each step fixed a real loss: invalid input yielding empty output, geometry-column
drift, dropped attributes, and features lost when casting a mixed set directly to
POLYGON.

Related: `sf::st_make_valid()` collapses reversed-winding polygons to slivers where
`terra::makeValid()` does not; non-recursive `list.files()` dropped nested layers
*"indistinguishable from a legitimate 'doesn't intersect' drop, with no warning"*;
key abbreviation collided 68 times in 399, and *"colliding units silently overwrite
each other's aggregates and figures."*

-> `r-geospatial:vector-geometry-hygiene`

## 5. The single most expensive bug: a missing geotransform

A simulation engine writes output maps with no geotransform. GDAL reports the
identity transform -- positive pixel height, i.e. south-up -- so `terra::rast()`
**reverses the rows**. Every output map was a vertical mirror.

> Landscape totals survived that; core-vs-buffer attribution, reporting-polygon
> summaries and every map figure did not.

It invalidated a 25-generation calibration and produced **no error at all**. Note
why it survived: the aggregate was unaffected.

-> `r-landis-ii:landis-outputs`

## 6. Two outputs that were numerically identical for eight months

A function erased the very buffers that distinguished two age classes, so
"mature+old interior forest" and "old-only interior forest" returned the same
number. Anything reported as the former was really the latter.

Fixed with `match.arg()`, a synthetic concentric test case with exactly computable
areas, and a published corrections notice.

-> `spatial-correctness-reviewer`, `r-code-review:verification-method`

## 7. Aggregates hide per-cell error

An unseeded resample inside a *dependency package* meant every rebuild produced a
different landscape:

> stand age differs 4,848 cells (0.181%); biomass differs 90,883 cells (3.385%) ...
> landscape mean age 91.3 vs 91.3 ... **The stable aggregates are why this went
> unnoticed.**

A sibling case: a 5-year offset hid inside a +/-5-year agreement check reporting 100%,
visible only in the medians.

Rules: compare **per-cell or on medians, never aggregates**, and **do not change
packages mid-test** -- one comparison was confounded by a library sync landing
between the two runs.

## 8. Configuration that never reaches the worker

The three-way split -- `.Rprofile` (every process, including workers) / local config
(control session, definition time) / hosts file (control node, gitignored) -- is
stated **four times inside one `.Rprofile`**, a reliable signal it kept being got
wrong. A `Sys.setenv()` in the wrong file is a silent no-op on the worker.

Related: crew workers do not inherit the shell `PATH`, so an external binary found
in the IDE is missing on a worker.

-> `r-project-core:project-config-layout`, `r-targets:targets-project-setup`

## 9. Shared-machine hazards

The clearest signal in the session transcripts, because the user had to say it
repeatedly and in capitals:

- **"Do not run heavy compute on the controller"** -- 24 turns across >=5 sessions,
  at least three OOM incidents, one of which killed the user's interactive session.
  This rule existed in exactly one repo's docs, invisible to the other nine.
- **"Never touch processes you did not start"** -- after an agent killed another
  project's calibration run. 89 `pkill`/`kill -9` and 93 container-destroy calls
  were issued across the corpus.
- **Concurrent sessions in one worktree** -- 203 `git add -A` and 33 `git commit -a`
  calls, concentrated in the repos where the rule was not written down.
- **Installing or syncing while a run is live** swaps the library under active
  workers.

-> `r-project-core:hpc-cluster-runs`; `r-project-core` hooks: `guard-process-ownership`, `guard-staging`,
`guard-long-run-interlock`, `guard-policy`, `session-context`

## 10. Mechanical friction that is pure waste

From the transcripts: `Shell cwd was reset` **2,989 times** (`cd` is the most common
first token); non-ASCII breaking LaTeX **196 times**, one fatally
(*"Unicode character (U+2194) ... no output PDF file produced"*); `.claude`
triggering an `R CMD check` NOTE **28 times**; commands timing out at exactly 2
minutes **64 times**; **1,049** bare `Rscript` calls against a pinned R version.

All five are fixed by a hook rather than by remembering.

## 11. Report and prose drift

Quarto in project mode mirrors the input directory, so PDFs do not land flat. A
guard written against the flat path meant every re-render republished a **stale**
PDF while the fresh one sat orphaned. `file.copy()` only warns on failure, so the
target succeeded while shipping the old deliverable.

The structural fix for prose: **generate report tables from the same registry the
pipeline uses**, so the report cannot drift from the code.

-> `r-reporting:quarto-reports`

## 12. Fabricated citations

Marked IMPERATIVE, in capitals, in the two `CLAUDE.md` files that address it:

> NEVER invent citations or any part of one ... It is better to omit a citation
> than to include an unverified one.

A catalogue's own suggested-citation block was itself stale and shipped a wrong
release year. The house response is an **honest scaffold**: populate only
code-verifiable fields, leave the rest `null` with a `_todo`, and ask.

This is the one rule with no natural verification loop -- nothing downstream fails
loudly -- so it gets a hook that resolves every DOI written and reports the title it
actually resolves to.

-> `r-project-core:citation-integrity` + `check-citations.sh`

---

## What the record says about AI-assisted work specifically

Adoption is recent and near-total in new work: 78% and 63% of commits since
mid-2026 in the two largest repos carry a Claude co-author trailer, and one
project's entire pipeline rewrite is AI-assisted. **Commit-message quality improved
sharply with adoption** -- from `tweaky fixy` and `oops -- wth prev` to
multi-paragraph forensics with measurements and rejected hypotheses.

The failure modes that showed up in AI-authored changes were specific:

- **The plausible-but-wrong diagnosis.** A coherent explanation led to a fix that
  was *"redundant and actively harmful"* -- it masked the real bug. It was disproved
  only by reading the upstream source. This is the one to guard hardest against.
- **The fix of the fix.** Several changes were corrected within 1--3 commits, the
  first fix's guard being wrong.
- **Silent parameter drift** -- undocumented changes to scientific parameters,
  reverted later.
- A commit whose *subject line was the shell command*, quoting unterminated.

The project's own response is the right one and is worth copying: **record the
falsified reasoning and its measurement inline next to the setting**, so the dead
end is not retried -- including for false alarms, so those are not re-raised either.

-> `r-project-core:root-cause-fixes`, `r-code-review:verification-method`,
`r-project-core:design-log`
