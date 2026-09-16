## Run the project's testthat suite the same way CI does. Copy to scripts/run-tests.R.
##
## There is no DESCRIPTION, so nothing selects a testthat edition: TESTTHAT_EDITION=3 turns edition
## 3 on for every file. NOT_CRAN=true is needed as well, or expect_snapshot() SKIPS with "On CRAN"
## -- a snapshot test then "passes" by not running.
##
## Source exactly what the pipeline sources. If _targets.R calls tar_source(), do the same. If it
## sources an explicit list of files (because R/ also holds standalone scripts), source THAT list:
## tar_source() executes every file in R/, including any that delete, upload or rewrite things.
##
##   Rscript scripts/run-tests.R                  # everything
##   Rscript scripts/run-tests.R some-filter      # files matching a filter

Sys.setenv(TESTTHAT_EDITION = "3", NOT_CRAN = "true")
filter <- commandArgs(trailingOnly = TRUE)

targets::tar_source()                     # or: for (f in c("R/a.R", "R/b.R")) source(f)

testthat::test_dir(
  "tests/testthat",
  filter = if (length(filter)) filter[[1L]] else NULL,
  stop_on_failure = TRUE
)
