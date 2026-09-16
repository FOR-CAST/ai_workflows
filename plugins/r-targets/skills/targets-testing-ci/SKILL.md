---
name: targets-testing-ci
description: "Add a hermetic testthat suite, a static pipeline validator, and GitHub Actions CI to a {targets} + renv analysis project that is not an R package. Ships a tested validator that catches what targets itself accepts -- commands naming another project's target or a gated-off stage, helpers missing two calls deep, pattern= over non-targets, untracked option reads -- bugs that survive for months because a function returns early on empty input. Use when setting up, extending, or fixing tests or CI for a pipeline project."
when_to_use: "Adding tests, validation or CI to a targets project; tests pass locally but fail in CI; a pipeline CI run is slow, cold, or never ran; configuring setup-r or setup-renv; asked whether a pipeline's commands resolve; after restructuring _targets.R, adding a gated stage, or splitting a repo into several targets projects."
argument-hint: "[project path]"
paths:
  - "**/_targets*.R"
  - "**/_targets.yaml"
  - "**/.github/workflows/**"
  - "**/tests/testthat/**"
  - "**/tests/validate/**"
---

# Testing and CI for a targets project

The short version:

- **Test the functions the pipeline calls, not the targets.**
- **Tests run in a clone with no data, no outputs and no store** -- that is what CI has.
- **`targets` does not check that the names in a command resolve.** Add the bundled
  validator; it catches a bug class nothing else does.
- **The CI details are not obvious** and several widely-copied choices are wrong: an extra
  cache step, a spatial PPA, `R_PROFILE_USER: /dev/null` on a step that needs renv, and the
  default `setup-renv` cache setting, which discards a failed cold build.

Every step below was worked out on real pipeline projects; the references record why.

## Before starting

**Find out, without asking:**

- Does `R/` hold standalone scripts? `tar_source()` executes every file. Check with
  `top_level_side_effects("R")` from `scripts/validate_lib.R`. If `_targets.R` sources a named
  list instead, the tests must source that same list.
- The projects in `_targets.yaml`, and **every setting that changes which targets exist**:
  environment variables, options, user-dependent switches in the local config file,
  static-branching keys.
- The R version in `renv.lock`, and whether the pipeline uses `tar_quarto()`.
- Which branch work is integrated on, and whether any GitHub dependency repo is private
  (`gh repo view <owner>/<repo> --json visibility`).

**Collect these decisions and ask them together, in one prompt:**

- which variants must be validated (default, CI graph, all stages on, ...);
- whether CI is wanted at all, given cold builds can take hours of runner minutes on a
  private repository;
- whether a private dependency justifies a PAT secret;
- where heavy steps run -- a shared control node is the wrong place for test suites and
  checks; use a compute node, or a memory-capped scope;
- whether refreshing the lockfile against current CRAN is on the table.

## Step 1 -- a hermetic test suite

Read `references/test-suite.md`. In brief:

1. `tests/testthat/test-*.R`, helpers in `helper-*.R`, run through `assets/run-tests.R`
   (edition 3 needs **both** `TESTTHAT_EDITION=3` and `NOT_CRAN=true`).
2. Record testthat in `renv.lock` with `renv::install("testthat", lock = TRUE)`; diff the
   lockfile before and after. Never `renv::snapshot()`.
3. Tests never touch real data: redirect locations with a directory argument or
   `withr::local_dir(withr::local_tempdir())`, and remember that editing a widely-reached
   helper's source invalidates every target that reaches it.
4. `skip_if_not()` for assertions that need built artefacts.
5. Closed-form test cases; turn recorded gotchas into regression tests.
6. For each test file, break the rule it guards and confirm it fails.
7. Add `assets/test-pipeline-sources.R`: no top-level side effects in `R/`, and sourcing
   order does not matter.

## Step 2 -- the validator

Read `references/validator.md`. In brief:

```bash
mkdir -p scripts tests/validate
cp "${CLAUDE_SKILL_DIR}"/scripts/validate-projects.R "${CLAUDE_SKILL_DIR}"/scripts/validate_lib.R scripts/
cp "${CLAUDE_SKILL_DIR}"/assets/validate.yml "${CLAUDE_SKILL_DIR}"/assets/unresolved_allowlist.csv tests/validate/
```

1. List every variant in `tests/validate/validate.yml`. Use a project-specific variable for
   the CI graph, not `CI=true` -- a personal `~/.Renviron` can override it.
2. Set `run_scoping_options` to the project's option prefix.
3. Run `Rscript-<version> scripts/validate-projects.R`. Triage each finding: **fix real
   defects first** -- expect some; every project this has run on had them.
4. Allowlist only genuine false positives, one reason per row. Stale rows fail the run.
5. Prove it: reintroduce a bug it should catch, confirm it fails and names it, revert.

If you change the bundled validator, run its self-test (a few seconds, negligible memory):
`Rscript-<version> "${CLAUDE_SKILL_DIR}"/selftest/run-selftest.R`.

## Step 3 -- prove it is hermetic

A `git clone --shared` with the renv library symlinked in, run with the lockfile's R and
`R_ENVIRON_USER=/dev/null`, checking for **writes** (including to gitignored data paths),
not just failures. Details in `references/test-suite.md`. One such run found three failures
in a suite that was green locally.

## Step 4 -- the CI workflow

Start from `assets/check.yaml` and `assets/ci-sysreqs.R`; read
`references/github-actions.md` before changing either. The choices most often got wrong:

- `setup-r` with `r-version: renv`; `setup-renv@v2` with **`bypass-cache: never`**, and no
  `actions/cache` step.
- System libraries from the stock distribution, derived from `renv.lock` -- **no PPA**.
- Quarto installed **before** anything defines the pipeline, if `tar_quarto()` is used.
- `R_PROFILE_USER: /dev/null` only on steps that must not start renv, with explicit `repos`.
- A private dependency needs a PAT; `GITHUB_TOKEN` reads only this repository.
- A guard that tests and validation left the checkout -- and gitignored data paths --
  untouched.
- Current action versions, checked rather than copied.

Estimate source builds first: `Rscript assets/cold-cache-estimate.R renv.lock noble`.

## Step 5 -- the first run

1. Trigger the workflow with `workflow_dispatch` on the working branch. **Until it has run,
   any timing is a guess** -- in one project the quoted times belonged to another job.
2. Record the real cold-cache time; set `timeout-minutes` from it with margin.
3. Read the restore log for "The dependency tree was repaired", and the template's
   `renv::status()` warning: if they appear, CI is testing versions the lockfile does not
   record. Say so in the project docs.
4. Seed the cache with a run on the default branch; PR caches are not visible to it.

## Checklist

- [ ] `tests/testthat/` with helpers; `scripts/run-tests.R` sources what the pipeline sources
- [ ] testthat in `renv.lock`; `TESTTHAT_EDITION=3` and `NOT_CRAN=true`
- [ ] No test reads or writes real data; artefact-dependent checks skip
- [ ] Each test file shown to fail when its rule is broken
- [ ] Validator installed, every variant listed, findings fixed or allowlisted with reasons
- [ ] Validator shown to catch a reintroduced bug
- [ ] Hermetic `--shared` clone run: no failures, no writes
- [ ] Workflow: syntax job; tests job with stock sysreqs, Quarto if needed, `bypass-cache: never`
- [ ] Dependency visibility checked; PAT only if a dependency is private
- [ ] First run triggered, cold time recorded, restore log read

## Bundled files

| File | Use |
| --- | --- |
| `scripts/validate-projects.R`, `scripts/validate_lib.R` | the validator; copy into the project's `scripts/` |
| `selftest/` | planted-bug project and self-test for the validator itself |
| `assets/validate.yml`, `assets/unresolved_allowlist.csv` | validator configuration templates |
| `assets/run-tests.R` | the suite runner |
| `assets/test-pipeline-sources.R` | side-effect and sourcing-order tests |
| `assets/check.yaml` | the workflow |
| `assets/ci-sysreqs.R` | system libraries from `renv.lock` via pak |
| `assets/cold-cache-estimate.R` | how many packages build from source |
| `references/test-suite.md` | the suite, hermetic proof, load-time traps |
| `references/validator.md` | checks, variants, allowlist, limits |
| `references/github-actions.md` | action internals, caching, system libraries, renv surprises |

## Related

- Why targets go stale without the validator noticing: `targets-staleness`.
- Where heavy steps may run, and launching long jobs: `hpc-cluster-runs`.
- Changing a co-developed package the tests depend on: `package-change-workflow` in
  `r-package-dev`.
