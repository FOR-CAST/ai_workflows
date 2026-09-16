## Install the system libraries that the packages in renv.lock declare, on a Debian/Ubuntu runner.
##
## Derived from each record's SystemRequirements with pak's database, not a hand-kept apt list, so
## it cannot drift from the lockfile. pak only MATCHES here; renv still installs the R packages.
## (pak::pkg_sysreqs() on lockfile refs can fail to solve when GitHub packages' Remotes conflict
## with the pinned SHAs, which is why the database is queried directly.)
##
## Run it from OUTSIDE the project (e.g. working-directory: ${{ runner.temp }}): inside it, the
## project .Rprofile activates renv, and pak has failed there with "Subprocess is busy".
##
##   Rscript ci-sysreqs.R path/to/renv.lock [--dry-run] [--with-scripts]
##
## pak's pre_install / post_install scripts (e.g. a rustup download, `R CMD javareconf`) are
## skipped unless --with-scripts is given: install what you know you need.

args <- commandArgs(trailingOnly = TRUE)
lockfile <- args[!startsWith(args, "--")][1L]
dry_run <- "--dry-run" %in% args
with_scripts <- "--with-scripts" %in% args
stopifnot(!is.na(lockfile), file.exists(lockfile))

os <- readLines("/etc/os-release")
field <- function(k) gsub('"', "", sub(paste0("^", k, "="), "", grep(paste0("^", k, "="), os, value = TRUE)))
platform <- paste0(field("ID"), "-", field("VERSION_ID"))

records <- jsonlite::fromJSON(lockfile, simplifyVector = FALSE)$Packages
specs <- unique(unname(unlist(lapply(records, `[[`, "SystemRequirements"))))
cat(sprintf("%d package(s) declare SystemRequirements; platform %s\n", length(specs), platform))
if (!length(specs)) quit(status = 0L)

matched <- pak::sysreqs_db_match(specs, sysreqs_platform = platform)
pkgs <- sort(unique(unlist(lapply(matched, function(df) unlist(df$packages)))))
pre <- unique(unlist(lapply(matched, function(df) unlist(df$pre_install))))
post <- unique(unlist(lapply(matched, function(df) unlist(df$post_install))))
cat(sprintf("%d system package(s): %s\n", length(pkgs), paste(pkgs, collapse = " ")))
if (length(pre) || length(post)) {
  cat(if (with_scripts) "running" else "SKIPPING", "pre/post-install scripts:\n")
  cat(paste0("  ", c(pre, post)), sep = "\n")
}
if (dry_run || !length(pkgs)) quit(status = 0L)

run <- function(cmd) {
  cat("+", cmd, "\n")
  if (system(cmd) != 0L) stop("failed: ", cmd, call. = FALSE)
}
run("sudo apt-get update -y")
if (with_scripts) for (s in pre) run(s)
run(paste("sudo apt-get install -y --no-install-recommends", paste(pkgs, collapse = " ")))
if (with_scripts) for (s in post) run(s)
