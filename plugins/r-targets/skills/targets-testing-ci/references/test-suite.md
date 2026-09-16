# A hermetic testthat suite for a targets project

## Contents
- Layout and invocation
- Where testthat comes from
- Edition 3 needs two variables
- Tests never touch real data
- Checks that genuinely need built artefacts
- What is worth testing
- Prove every test can fail
- Load-time traps
- Prove the suite is hermetic
- Pre-commit and pre-push hooks

## Layout and invocation

There is no DESCRIPTION, so nothing drives the suite for you. Tests live in
`tests/testthat/test-<thing>.R`; shared helpers in `tests/testthat/helper-*.R`, which
`test_dir()` sources first. Run everything through one script so local runs and CI are
identical -- `assets/run-tests.R`:

```r
Sys.setenv(TESTTHAT_EDITION = "3", NOT_CRAN = "true")
targets::tar_source()                 # or the explicit file list _targets.R uses
testthat::test_dir("tests/testthat", stop_on_failure = TRUE)
```

**Source exactly what the pipeline sources.** `tar_source()` executes every file in `R/`.
Where `R/` also holds standalone scripts -- one that deletes old outputs, one that signs in
to a cloud drive, one that rewrites DESCRIPTION -- the pipeline deliberately sources a named
list of files instead, and the tests must use that same list. Check before you start:
`top_level_side_effects("R")` in `scripts/validate_lib.R` lists every file that does more
than define things at top level.

**Put shared helpers in `helper-*.R`, and never name one after a base function.** A helper
called `box()` defined in one test file silently resolved to `graphics::box()` in another.

## Where testthat comes from

Record testthat in `renv.lock` (and declare it in `_dependencies.R` inside
`if (FALSE) { library(testthat) }` so renv keeps it). When testthat was loaded from a
personal library alongside the project library, a compiled spatial package failed to load
(`Unable to load module "spat"`). The suite must load only the project library.

Record it with `renv::install("testthat", lock = TRUE)` and diff the lockfile before and
after (`Package`, `Version`, `Source`) to prove nothing else moved -- `lock = TRUE`
resolves transitive dependencies to their latest versions. Never `renv::snapshot()`.

## Edition 3 needs two variables

Edition 3 is normally selected by `Config/testthat/edition: 3` in DESCRIPTION, which you
do not have. `TESTTHAT_EDITION=3` selects it for every file. **`NOT_CRAN=true` is also
needed**: without it `expect_snapshot()` *skips* with "Reason: On CRAN", so a snapshot
test passes by not running. The same trap applies to per-file `local_edition(3)`.
Snapshots land in `tests/testthat/_snaps/`.

## Tests never touch real data

A test that reads the project's real inputs passes on your machine and fails in CI -- and
worse, it can *write* somewhere real. Keep tests light, with no real data. If a test truly
needs real data, use only publicly available data, trimmed to the smallest piece that
exercises the code.

Two ways to redirect locations; choose deliberately:

- **A directory argument that defaults to the real location.** The cleanest design:
  ```r
  district_input_layer <- function(district, file, dir = NULL) {
    path <- file.path(dir %||% district_path("inputs", district), file)
    if (!file.exists(path)) stop("no ", file, " for district ", district, call. = FALSE)
    path
  }
  ```
  **But** `targets` hashes a function's deparsed source, so adding an argument to a helper
  that many targets reach invalidates all of them. In a pipeline with an expensive built
  store, batch such edits with a change that already forces a rebuild.
- **Redirect the working directory in the test**, leaving function source untouched:
  ```r
  withr::local_dir(withr::local_tempdir())
  ```
  Works when paths are relative to the working directory.

Watch for **path resolvers with side effects**: a `get_path()` that calls
`fs::dir_create()` on what it returns makes a test create real (possibly network-mounted)
directories even when it only asked for a path. Do not call such resolvers from tests.

Read environment variables through function arguments with an env-var default, and test
with `withr::with_envvar(c(MY_VAR = NA), ...)`.

## Checks that genuinely need built artefacts

Some assertions are only meaningful against real outputs. Do not delete them, and do not
let them fail in CI -- skip:

```r
test_that("the reader finds what the writer wrote", {
  written <- file.path(district_path("inputs", spec), "BEC.gpkg")
  skip_if_not(file.exists(written), "data-prep layers not built")
  expect_identical(district_input_layer(spec, "BEC.gpkg"), written)
})
```

## What is worth testing

Analysis bugs mostly do not throw; they return plausible numbers that are wrong. A test
that only checks "it ran" buys almost nothing. Build the suite around **closed-form cases**:
concentric rings whose areas you compute by hand, points at known separations, fixtures
whose answer was derived independently of the code.

**Test the functions, not the targets.** Let the pipeline compose them.

Turn each hard-won gotcha into a regression test -- the ones recorded in project memory,
`CLAUDE.md`, or dated `## NOTE:` comments are exactly the bugs that recur.

When you fix a bug, add the case that pins it.

## Prove every test can fail

For each test file, temporarily break the rule it guards and confirm the test fails, then
restore. A test that cannot fail is documentation. Record the break you used in the commit
body.

## Load-time traps

- **`tar_source()` order follows the collation locale.** `foo.R` and `foo_bar.R` swap
  places between `C` and `en_*.UTF-8`, so a file that reads another file's top-level object
  while being sourced works on one machine and fails on the next. `assets/test-pipeline-sources.R`
  sources `R/` forwards and backwards and compares.
- **Sorting in your own functions follows the locale too.** Fix the functions with
  `sort(method = "radix")` rather than pinning a CI locale.
- **Pipeline definition must work in a clean clone.** A local config file that checks for
  data files at definition time, or a `tar_quarto()` report with an invalid YAML escape in a
  chunk option, breaks `tar_manifest()` -- and so the validator and `tar_make()` -- for the
  whole project.

## Prove the suite is hermetic

Do not assume it. Simulate a clone with nothing but the repository -- on a compute node, or
under a memory cap, not on a shared control node:

```bash
git clone --shared /path/to/project "$SCRATCH/ci-sim"
cd "$SCRATCH/ci-sim"
ln -s /path/to/project/renv/library renv/library       # borrow the library, not the data
R_ENVIRON_USER=/dev/null Rscript-<version> scripts/run-tests.R
R_ENVIRON_USER=/dev/null Rscript-<version> scripts/validate-projects.R
git status --porcelain                                   # expect only ?? renv/library
ls -d inputs outputs data _targets* 2>/dev/null          # expect nothing
```

- **Use the lockfile's R version.** A bare `Rscript` may be a different R, and the library
  then looks empty.
- **`R_ENVIRON_USER=/dev/null`** removes your dotfile's influence: a personal `~/.Renviron`
  can set `CI=false`, a shared renv cache path, credentials. Without it the proof does not
  show the suite needs none of them.
- **Check for writes, not just failures.** `git status` cannot see gitignored paths, which
  are exactly where a stray write lands; check they do not exist. The symlinked
  `renv/library` shows as `?? renv/library` (renv's `.gitignore` pattern matches directories,
  not symlinks) -- that one line is expected.

One such run found three failures in a suite that was green locally, all from touching real
data.

## Pre-commit and pre-push hooks

A 30-second suite plus a 20-second validator is too slow for a pre-commit hook when several
sessions commit to one repository. CI is the gate; an opt-in pre-push hook is reasonable if
the user wants one.
