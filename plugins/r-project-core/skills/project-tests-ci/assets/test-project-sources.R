## Conventions for the R files a project sources. Copy to tests/testthat/. Each test exists because
## breaking the rule once cost time, and the failure pointed somewhere other than the cause.

root <- testthat::test_path("..", "..")

## Top-level calls other than definitions, library() and `if (FALSE)` blocks.
top_level_side_effects <- function(dir) {
  ok_heads <- c("<-", "=", "<<-", "library", "require", "requireNamespace",
                "suppressPackageStartupMessages", "function")
  files <- list.files(dir, pattern = "[.][Rr]$", full.names = TRUE)
  out <- list()
  for (f in files) {
    exprs <- tryCatch(as.list(parse(f, keep.source = FALSE)), error = function(e) list())
    bad <- Filter(function(e) {
      if (!is.call(e)) return(FALSE)
      h <- if (is.symbol(e[[1L]])) as.character(e[[1L]]) else ""
      if (h %in% ok_heads) return(FALSE)
      if (identical(h, "if") && identical(e[[2L]], FALSE)) return(FALSE)
      TRUE
    }, exprs)
    if (length(bad)) out[[f]] <- vapply(bad, function(e) deparse(e, nlines = 1L)[[1L]], "")
  }
  out
}

test_that("files in R/ only define things at top level", {
  ## Sourcing R/ wholesale EXECUTES every file in it. A standalone script there -- one that deletes
  ## old outputs, signs in to a cloud service, or rewrites DESCRIPTION -- runs every time the
  ## project loads. Move such scripts out of R/, or guard them with `if (FALSE)`/a main-guard.
  expect_identical(top_level_side_effects(file.path(root, "R")), list())
})

test_that("R/ files do not depend on the order they are sourced in", {
  ## list.files() order follows the collation locale: `foo.R` and `foo_bar.R` swap places between
  ## C and en_*.UTF-8. A file that reads another file's top-level object while being sourced then
  ## works on one machine and fails on the next. Sourcing in both directions exposes any such read.
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

test_that("no browser() is left in project code", {
  files <- list.files(file.path(root, "R"), pattern = "[.][Rr]$", full.names = TRUE)
  hits <- unlist(lapply(files, function(f) {
    if (any(grepl("\\bbrowser\\(\\)", readLines(f)))) basename(f)
  }))
  expect_identical(c(character(), hits), character())
})
