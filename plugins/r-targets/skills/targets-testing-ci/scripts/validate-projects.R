#!/usr/bin/env Rscript
## Validate every {targets} project, under every pipeline variant, without running a target.
##
## Checks per graph (project x variant), each in a FRESH R process so a partial tar_source() list
## cannot resolve against leftovers from another project:
##   definition           the pipeline definition builds (tar_manifest() succeeds)
##   package              every package the pipeline declares can be loaded
##   unparseable          a command that does not parse back is reported, never skipped
##   unresolved           every name a command uses is a target, a script binding, or exists
##   unresolved_function  every function reachable from the commands calls functions that exist
##   pattern              every name a `pattern =` branches over is a target of the same graph
##   file_name_index      no command indexes a format = "file" target by name
##   option_cue           targets reading run-scoping options are cue "always" + deployment "main"
##   cross_graph          no command names a target that exists only in another graph
##
## Configuration (optional): tests/validate/validate.yml -- see the template beside this script.
## Allowlist (optional):     tests/validate/unresolved_allowlist.csv
##
## Usage, from the project root, with the project's pinned R:
##   Rscript scripts/validate-projects.R
## Exits 1 on any failure or stale allowlist row. Pasted into CI without an exit status, a
## validator always passes.

`%||%` <- function(a, b) if (is.null(a)) b else a

self <- sub("^--file=", "", grep("^--file=", commandArgs(FALSE), value = TRUE))
lib <- normalizePath(file.path(dirname(self), "validate_lib.R"), mustWork = TRUE)
source(lib, local = (helpers <- new.env()))

config_path <- Sys.getenv("VALIDATE_CONFIG", "tests/validate/validate.yml")
allow_path <- Sys.getenv("VALIDATE_ALLOWLIST", "tests/validate/unresolved_allowlist.csv")
cfg <- if (file.exists(config_path)) yaml::read_yaml(config_path) else list()

variants <- cfg$variants %||% list(default = list())
run_scoping <- cfg$run_scoping_options %||% ""
exceptions <- names(cfg$option_exceptions %||% list())
projects <- unlist(cfg$projects) %||%
  (if (file.exists("_targets.yaml")) names(yaml::read_yaml("_targets.yaml")) else "main")

results <- list()
for (p in projects) {
  script <- targets::tar_config_get("script", project = p)
  if (!file.exists(script)) {
    cat(sprintf("skip %s: script %s does not exist\n", p, script))
    next
  }
  for (v in names(variants)) {
    spec <- variants[[v]] %||% list()
    env <- unlist(lapply(spec$env %||% list(), as.character))
    res <- tryCatch(
      callr::r(
        function(project, variant, opts, lib, run_scoping, exceptions) {
          checks <- new.env()
          sys.source(lib, envir = checks)
          if (length(opts)) options(opts)
          Sys.setenv(TAR_PROJECT = project)
          checks$check_graph(project, variant, run_scoping, exceptions)
        },
        args = list(project = p, variant = v, opts = spec$options %||% list(), lib = lib,
                    run_scoping = run_scoping, exceptions = exceptions),
        env = c(callr::rcmd_safe_env(), env),
        user_profile = "project",
        show = FALSE
      ),
      error = function(e) {
        list(project = p, variant = v, targets = character(), variables = list(), nse = list(),
             reached = 0L, findings = data.frame(project = p, variant = v, target = "<validator>",
             check = "definition", detail = conditionMessage(e), stringsAsFactors = FALSE))
      }
    )
    results[[paste(p, v, sep = "/")]] <- res
  }
}

findings <- do.call(rbind, c(lapply(results, `[[`, "findings"), list(helpers$cross_graph_refs(results))))
if (is.null(findings)) {
  findings <- data.frame(project = character(), variant = character(), target = character(),
                         check = character(), detail = character())
}

allow <- if (file.exists(allow_path)) {
  a <- utils::read.csv(allow_path, colClasses = "character", stringsAsFactors = FALSE)
  for (col in c("project", "variant", "check")) if (!col %in% names(a)) a[[col]] <- "any"
  a
} else {
  data.frame()
}
## A name that is a target in another graph is reported once, as cross_graph, not also as unresolved.
key <- function(d) paste(d$project, d$variant, d$target, d$detail, sep = "\r")
xg <- findings$check == "cross_graph"
findings <- findings[!(findings$check == "unresolved" & key(findings) %in% key(findings[xg, ])), , drop = FALSE]
rownames(findings) <- NULL

al <- helpers$apply_allowlist(findings, allow, results)
bad <- findings[!al$allowed, , drop = FALSE]

for (r in results) {
  n_bad <- sum(bad$project == r$project & bad$variant == r$variant)
  cat(sprintf("%-4s %s/%s: %d targets, %d project functions reached%s\n",
              if (n_bad) "FAIL" else "ok", r$project, r$variant, length(r$targets), r$reached,
              if (n_bad) sprintf(", %d finding(s)", n_bad) else ""))
}
for (i in seq_len(nrow(bad))) {
  cat(sprintf("  FAIL %-19s %s/%s %s: %s\n", bad$check[[i]], bad$project[[i]], bad$variant[[i]],
              bad$target[[i]], bad$detail[[i]]))
}
for (s in al$stale) cat("  STALE allowlist row (target present, matches nothing):", s, "\n")
cat(sprintf("%d graph(s), %d finding(s), %d allowlisted, %d stale\n",
            length(results), nrow(findings), sum(al$allowed), length(al$stale)))
if (nrow(bad) || length(al$stale)) quit(status = 1L)
