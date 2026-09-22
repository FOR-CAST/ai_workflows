## Run the project's testthat suite the same way CI does. Copy to scripts/run-tests.R.
##
## There is no DESCRIPTION, so nothing selects a testthat edition: TESTTHAT_EDITION=3 turns edition
## 3 on for every file. NOT_CRAN=true is needed as well, or expect_snapshot() SKIPS with "On CRAN"
## -- a snapshot test then "passes" by not running.
##
## Source exactly what the project itself sources before it runs. If R/ also holds standalone
## scripts (ones that delete, upload or rewrite things), source the explicit list the project
## uses instead of the whole directory.
##
##   Rscript scripts/run-tests.R                  # everything
##   Rscript scripts/run-tests.R some-filter      # files matching a filter

Sys.setenv(TESTTHAT_EDITION = "3", NOT_CRAN = "true")
filter <- commandArgs(trailingOnly = TRUE)

## ADJUST: the files the project sources, in the order it sources them
for (f in sort(list.files("R", pattern = "[.][Rr]$", full.names = TRUE), method = "radix")) {
  source(f)
}

testthat::test_dir(
  "tests/testthat",
  filter = if (length(filter)) filter[[1L]] else NULL,
  stop_on_failure = TRUE
)
