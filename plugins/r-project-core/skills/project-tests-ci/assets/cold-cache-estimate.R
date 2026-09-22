## Estimate how many packages a cold CI restore builds from source.
##
## A lockfile pins exact versions; Posit Package Manager's `latest` Linux snapshot serves binaries
## only for CURRENT CRAN versions. Every pinned version that is not current, and every package from
## GitHub or another non-CRAN source, builds from source. Measure this before choosing
## timeout-minutes or promising anyone a fast pipeline. Dated snapshots rarely help: a lockfile
## accretes over time and matches no single snapshot date.
##
##   Rscript cold-cache-estimate.R renv.lock [codename]      # codename default: noble

args <- commandArgs(trailingOnly = TRUE)
lockfile <- if (length(args)) args[[1L]] else "renv.lock"
codename <- if (length(args) >= 2L) args[[2L]] else "noble"

url <- sprintf("https://packagemanager.posit.co/cran/__linux__/%s/latest/src/contrib/PACKAGES", codename)
db <- read.dcf(url(url), fields = c("Package", "Version"))
current <- stats::setNames(db[, "Version"], db[, "Package"])

records <- jsonlite::fromJSON(lockfile, simplifyVector = FALSE)$Packages
kind <- vapply(records, function(p) {
  if (!identical(p$Source, "Repository")) return("source: not from a repository (GitHub etc.)")
  if (identical(unname(current[p$Package]), p$Version)) "binary" else "source: pinned version not current"
}, character(1))
print(table(kind))
cat(sprintf("\n%d of %d packages build from source on a cold cache (%s)\n",
            sum(startsWith(kind, "source")), length(kind), codename))
