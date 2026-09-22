# What a targets project adds to the general suite and CI

The suite, the hermetic proof and the CI template come from `project-tests-ci` in
`r-project-core`. These are the changes a `{targets}` project needs on top.

## Contents
- The test runner sources what `_targets.R` sources
- Editing a helper invalidates targets
- Pipeline definition must work in a clean clone
- The hermetic proof also runs the validator
- CI steps to add

## The test runner sources what `_targets.R` sources

In `scripts/run-tests.R`, replace the `source()` loop with what `_targets.R` does:

```r
targets::tar_source()                 # or the explicit file list _targets.R uses
```

`tar_source()` executes every file in `R/`. Where `R/` also holds standalone scripts, the
pipeline sources a named list instead, and the tests must use that same list. In a
multi-project layout, source each project's own `R/`.

## Editing a helper invalidates targets

`targets` hashes a function's deparsed source, so adding an argument to a helper -- a
directory argument for testability, say -- invalidates every target that reaches it. In a
pipeline with an expensive built store, redirect locations with
`withr::local_dir(withr::local_tempdir())` instead, or batch the helper edit with a change
that already forces a rebuild. Check the reach first: `targets::tar_outdated()` after a
trial edit.

## Pipeline definition must work in a clean clone

A `_local.R` that checks for data files at definition time, or a `tar_quarto()` report with
an invalid YAML escape in a chunk option, breaks `tar_manifest()` -- and so the validator and
`tar_make()` -- for the whole project.

## The hermetic proof also runs the validator

In the `--shared` clone:

```bash
R_ENVIRON_USER=/dev/null Rscript-<version> scripts/run-tests.R
R_ENVIRON_USER=/dev/null Rscript-<version> scripts/validate-projects.R
ls -d inputs outputs data _targets* 2>/dev/null          # expect nothing
```

## CI steps to add

Into the `tests` job of the general `check.yaml`:

```yaml
      ## Before setup-renv, and only if the pipeline uses tarchetypes::tar_quarto(): it runs
      ## `quarto inspect` at pipeline DEFINITION time, so tar_source() and the validator fail
      ## without Quarto.
      - uses: quarto-dev/quarto-actions/setup@v2

      ## After the Tests step:
      - name: Validate every targets project and variant
        run: Rscript scripts/validate-projects.R
```

and extend the final guard so it also fails when a store appeared:

```yaml
          if find . -maxdepth 1 -type d -name '_targets*' | grep -q .; then
            echo "tests or validation created a targets store"; exit 1
          fi
```

Set the job's CI switch to the project's own variable for the CI graph (for example
`PIPELINE_AS_CI: "true"`), not `CI=true` -- a personal `~/.Renviron` can override that.
