library(targets)
tar_source("R")

VINTAGE <- "2026-01-01"
stage_on <- isTRUE(as.logical(Sys.getenv("SELFTEST_STAGE", "false")))

looks_suspicious_but_fine <- list(
  ## ---- must NOT be reported ------------------------------------------------------------------
  tar_target(raw, c(1, 2, 3)),
  tar_target(clean, raw[raw > 1]),
  tar_target(uses_binding, paste(VINTAGE, length(clean))),
  tar_target(locals_and_lambdas, {
    z <- clean * 2
    lapply(z, function(v) v + 1)
  }),
  tar_target(formula_arg, apply_each(clean, ~ .x + offset_in_formula)),
  tar_target(field_access, list(a = clean)$a),
  tar_target(pkg_namespace, stats::median(clean)),
  tar_target(nse_columns, subset(data.frame(v = clean), v > 1)),
  tar_target(error_handler, tryCatch(clean, error = function(e) conditionMessage(e))),
  tar_target(empty_arg, matrix(clean)[, 1]),
  tar_target(dt_columns, data.table::data.table(v = clean)[, w := v * 2]),
  tar_target(option_cued, getOption("selftest.n_reps", 3L),
             cue = tar_cue(mode = "always"), deployment = "main"),
  tar_target(files_out, write_two(tempdir()), format = "file"),
  tar_target(file_by_position, readLines(files_out[[1L]])),
  tar_target(branch_ok, clean * 2, pattern = map(clean))
)

planted_bugs <- list(
  ## ---- planted bugs: each MUST be reported ---------------------------------------------------
  tar_target(bug_cross_project, zonal_summaries(character(0), beta_only)),
  tar_target(bug_reached_function, summarise_input(clean)),
  tar_target(bug_pattern, clean * 2, pattern = map(clean, not_a_target)),
  tar_target(bug_option_uncued, getOption("selftest.n_reps", 3L)),
  tar_target(bug_option_via_function, scale_reps()),
  tar_target(bug_file_by_name, readLines(files_out[["csv"]])),
  tar_target(bug_gated_reference, if (length(raw)) 0 else stage_output),
  tar_target(bug_missing_function, not_defined_anywhere(clean)),
  tar_target_raw("bug_unparseable", as.call(list(quote(identity), new.env())))
)

## SELFTEST_NO_BUGS=true is the negative control: the same pipeline without the planted bugs.
with_bugs <- !isTRUE(as.logical(Sys.getenv("SELFTEST_NO_BUGS", "false")))
pipeline <- c(looks_suspicious_but_fine, if (with_bugs) planted_bugs)
if (stage_on) {
  pipeline <- c(pipeline, list(tar_target(stage_output, raw + 1)))
}
pipeline
