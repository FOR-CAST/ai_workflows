## Conventions for the R the pipeline evaluates. Copy to tests/testthat/. Each test exists because
## breaking the rule once cost time, and the failure pointed somewhere other than the cause.
## Assumes scripts/validate_lib.R is present (it holds top_level_side_effects()).

root <- testthat::test_path("..", "..")

test_that("files in R/ only define things at top level", {
  ## tar_source() EXECUTES every file in R/. A standalone script there -- one that deletes old
  ## outputs, signs in to a cloud service, or rewrites DESCRIPTION -- runs at pipeline definition
  ## time. Move such scripts out of R/, or guard them with `if (FALSE)`/a main-guard.
  h <- new.env()
  sys.source(file.path(root, "scripts", "validate_lib.R"), envir = h)
  expect_identical(h$top_level_side_effects(file.path(root, "R")), list())
})

test_that("R/ files do not depend on the order they are sourced in", {
  ## tar_source() takes list.files() order, which follows the collation locale: `foo.R` and
  ## `foo_bar.R` swap places between C and en_*.UTF-8. A file that reads another file's top-level
  ## object while being sourced then works on one machine and fails on the next. Sourcing in both
  ## directions exposes any such read.
  files <- sort(list.files(file.path(root, "R"), pattern = "[.][Rr]$", full.names = TRUE),
                method = "radix")
  source_all <- function(files) {
    env <- new.env(parent = globalenv())
    for (f in files) sys.source(f, envir = env)
    sort(ls(env, all.names = TRUE))
  }
  forward <- callr::r(source_all, args = list(files = files))
  reverse <- callr::r(source_all, args = list(files = rev(files)))
  expect_identical(reverse, forward)
})

test_that("no browser() is left in pipeline code", {
  files <- list.files(file.path(root, "R"), pattern = "[.][Rr]$", full.names = TRUE)
  hits <- unlist(lapply(files, function(f) {
    if (any(grepl("\\bbrowser\\(\\)", readLines(f)))) basename(f)
  }))
  expect_identical(c(character(), hits), character())
})
