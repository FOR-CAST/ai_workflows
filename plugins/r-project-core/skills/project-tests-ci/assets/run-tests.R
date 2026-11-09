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

## The tests use at most 4 cores (TEST_CORES may set fewer): a test must never take a shared
## machine. R starts OpenMP and BLAS before this script runs, so their limits must be in the
## environment R starts with: without them, the script runs itself again in a new R process that
## has them. data.table reads the same limit when it loads; R processes the tests start inherit it.
local({
  asked <- suppressWarnings(as.integer(Sys.getenv("TEST_CORES")))
  cores <- if (is.na(asked)) 4L else min(4L, max(1L, asked))
  limit <- suppressWarnings(as.integer(Sys.getenv("OMP_THREAD_LIMIT")))
  if (is.na(limit) || limit > cores) {
    status <- system2(
      file.path(R.home("bin"), "R"),
      shQuote(commandArgs(trailingOnly = FALSE)[-1L]),
      env = paste0(
        c("OMP_THREAD_LIMIT=", "OMP_NUM_THREADS=", "OPENBLAS_NUM_THREADS=", "MKL_NUM_THREADS="),
        cores
      )
    )
    quit(save = "no", status = status)
  }
})

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
