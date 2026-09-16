## Two calls deep: summarise_input() -> tidy_values() -> helper_missing(), which nothing defines.
summarise_input <- function(x) tidy_values(x)
tidy_values <- function(x) helper_missing(x)

## Returns before forcing `study_area`, so a missing argument is never looked up on empty input.
zonal_summaries <- function(outputs, study_area) {
  if (length(outputs) == 0L) {
    return(character(0))
  }
  study_area
}

apply_each <- function(x, f) lapply(x, f)
write_two <- function(dir) c(file.path(dir, "a.csv"), file.path(dir, "b.txt"))
scale_reps <- function() getOption("selftest.n_reps", 3L) * 2L
