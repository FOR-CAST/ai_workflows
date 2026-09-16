## Self-test for scripts/validate-projects.R. Copies a synthetic two-project pipeline with planted
## bugs to a temporary directory, runs the validator on it, and asserts it reports EXACTLY the
## planted set: every bug found, and none of the look-alike cases that must not be flagged.
##
##   Rscript selftest/run-selftest.R        (from the skill directory)
##
## Light: tar_manifest() only, no targets are run, no data. Exits 1 on any failed assertion.

self <- normalizePath(sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE)))
skill <- dirname(dirname(self))
lib <- file.path(skill, "scripts", "validate_lib.R")
validator <- file.path(skill, "scripts", "validate-projects.R")

failures <- 0L
check <- function(ok, what) {
  cat(if (isTRUE(ok)) "PASS" else "FAIL", what, "\n")
  if (!isTRUE(ok)) failures <<- failures + 1L
}

## ---- unit checks on the helpers ---------------------------------------------------------------
h <- new.env()
sys.source(lib, envir = h)

g <- h$command_globals(quote(dplyr::filter(d, col > 1)))
check(identical(g$variables, "d") && identical(g$nse_variables, "col"), "dplyr column is set aside, data kept")
g <- h$command_globals(quote(terra::subset(r, other_target)))
check(setequal(g$variables, c("r", "other_target")), "terra::subset is not treated as NSE")
g <- h$command_globals(quote(f(tbl[, 1], ~ .x)))
check(identical(g$variables, "tbl"), "empty argument and formula do not break the walk")
check(is.null(h$parse_command("identity(<environment>)")), "unparseable command is detected")
check(identical(h$pattern_variables("map(a, cross(b, c))"), c("a", "b", "c")), "pattern names are collected")

side <- tempfile("side-effects-"); dir.create(side)
writeLines(c("f <- function() 1", "library(stats)", "if (FALSE) { run_me() }"), file.path(side, "ok.R"))
writeLines(c("g <- function() 2", "unlink(\"outputs\", recursive = TRUE)"), file.path(side, "script.R"))
se <- h$top_level_side_effects(side)
check(identical(basename(names(se)), "script.R"), "top-level side effects flag only the standalone script")

## ---- end-to-end on the planted project -------------------------------------------------------
proj <- tempfile("validator-selftest-"); dir.create(proj)
src <- file.path(dirname(self), "project")
invisible(file.copy(list.files(src, full.names = TRUE, all.files = TRUE, no.. = TRUE), proj, recursive = TRUE))

res <- processx::run(file.path(R.home("bin"), "Rscript"), validator, wd = proj,
                     error_on_status = FALSE, stderr_to_stdout = TRUE)
out <- strsplit(res$stdout, "\n", fixed = TRUE)[[1L]]
cat(out, sep = "\n")

check(identical(res$status, 1L), "validator exits 1 when there are findings")

fails <- regmatches(out, regexec("^\\s+FAIL (\\S+)\\s+(\\S+) (\\S+): (.*)$", out))
fails <- do.call(rbind, lapply(Filter(length, fails), function(m) m[2:5]))
got <- if (is.null(fails)) character() else sort(unique(paste(fails[, 1], fails[, 2], fails[, 3])))

planted <- function(variant) paste(c(
  "cross_graph", "unresolved_function", "pattern", "option_cue", "option_cue", "file_name_index",
  "unresolved", "unparseable"
), paste0("alpha/", variant), c(
  "bug_cross_project", "<functions>", "bug_pattern", "bug_option_uncued", "bug_option_via_function",
  "bug_file_by_name", "bug_missing_function", "bug_unparseable"
))
expected <- sort(c(planted("default"), planted("stage"), "cross_graph alpha/default bug_gated_reference"))

missed <- setdiff(expected, got)
extra <- setdiff(got, expected)
check(!length(missed), paste("every planted bug is reported", if (length(missed)) paste0("(missed: ", toString(missed), ")") else ""))
check(!length(extra), paste("nothing else is reported", if (length(extra)) paste0("(false positives: ", toString(extra), ")") else ""))
check(any(grepl("tidy_values\\(\\) calls helper_missing\\(\\)", out)), "the two-calls-deep missing helper is named")
check(sum(grepl("STALE allowlist row", out)) == 2L, "the stale allowlist row is reported in both variants")
check(!any(grepl("dt_columns", out)), "allowlisted data.table columns are not reported")
check(!any(grepl("alpha/stage bug_gated_reference", out)), "a gated reference is fine where the stage is on")
check(any(grepl("^ok\\s+beta/default", out)), "a clean project reports ok")

## ---- negative control: with the planted bugs and stale row removed, it must pass --------------
clean <- tempfile("validator-selftest-clean-"); dir.create(clean)
invisible(file.copy(list.files(src, full.names = TRUE, all.files = TRUE, no.. = TRUE), clean, recursive = TRUE))
allow <- readLines(file.path(clean, "tests", "validate", "unresolved_allowlist.csv"))
writeLines(allow[!grepl("planted stale row", allow)], file.path(clean, "tests", "validate", "unresolved_allowlist.csv"))
res2 <- withr::with_envvar(c(SELFTEST_NO_BUGS = "true"),
  processx::run(file.path(R.home("bin"), "Rscript"), validator, wd = clean,
                error_on_status = FALSE, stderr_to_stdout = TRUE))
check(identical(res2$status, 0L), paste("a clean pipeline passes with exit 0",
      if (!identical(res2$status, 0L)) paste0("\n", res2$stdout) else ""))

cat(sprintf("\n%d failure(s)\n", failures))
quit(status = if (failures) 1L else 0L)
