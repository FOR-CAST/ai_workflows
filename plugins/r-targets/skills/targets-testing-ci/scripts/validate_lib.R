## Helpers for validate-projects.R. Side-effect free, so tests can source them.
##
## Kept out of R/ on purpose: tar_source() would define these in every pipeline's environment,
## where they could mask the very missing symbol a check is looking for.
##
## {targets} never checks that the names a command uses resolve. A command can name a target in a
## DIFFERENT project, a target that only exists when a stage is switched on, or a helper whose file
## is not sourced -- and the pipeline still validates. If the function returns early on empty
## input, the missing argument is never forced and the target is recorded as BUILT. It fails the
## first time real input arrives.

## Verbs whose arguments after the first are column expressions, not variables. Only the data
## argument is checked as a variable; the column arguments are set aside (see prune_nse()).
NSE_VERBS <- c(
  "select", "filter", "mutate", "transmute", "summarise", "summarize", "arrange", "group_by",
  "rename", "distinct", "count", "pull", "relocate", "reframe", "slice_max", "slice_min",
  "across", "if_all", "if_any", "pivot_longer", "pivot_wider", "unnest", "nest", "complete",
  "expand", "drop_na", "fill", "separate", "unite", "aes", "with", "within", "subset", "transform"
)

## A pkg::verb() call is treated as NSE only for these packages. A bare verb() always is.
## This stops terra::subset(r, other_target) being pruned like base::subset().
NSE_PACKAGES <- c("dplyr", "tidyr", "ggplot2", "base")

## data.table specials exist only inside `[.data.table`, so exists() never finds them.
DATA_TABLE_SYMBOLS <- c(".", "J", ".N", ".SD", ".I", ".GRP", ".BY", ".EACHI", ".SDcols", ":=")

UNPARSEABLE <- "<unparseable command>"

## Parse a deparsed command. A command that embeds an object (an environment or pointer spliced in
## with bquote(), say) deparses to text that does not parse back: return NULL so the caller reports
## it instead of skipping the target or aborting the whole check.
parse_command <- function(text) {
  text <- paste(text, collapse = "\n")
  if (is.na(text) || !nzchar(text)) {
    return(NULL)
  }
  tryCatch(str2lang(text), error = function(e) NULL)
}

## Remove every formula. A formula's contents are evaluated later by whatever receives it
## (`~ .x + 1` in purrr, a model formula in lm()), so names inside one are not lookups the command
## performs. Tests expr[[i]] in place: binding an empty argument (the gap in `x[, 1]`) to a
## variable makes every later use of that variable an "argument is missing" error.
strip_formulas <- function(expr) {
  if (!is.call(expr)) {
    return(expr)
  }
  if (identical(expr[[1L]], as.name("~"))) {
    return(NULL)
  }
  for (i in seq_along(expr)) {
    if (is.call(expr[[i]])) {
      stripped <- strip_formulas(expr[[i]])
      if (is.null(stripped)) {
        expr[i] <- list(NULL)
      } else {
        expr[[i]] <- stripped
      }
    }
  }
  expr
}

nse_verb_name <- function(head, verbs = NSE_VERBS, packages = NSE_PACKAGES) {
  if (is.symbol(head)) {
    v <- as.character(head)
    if (v %in% verbs) return(v)
  } else if (is.call(head) && identical(head[[1L]], as.symbol("::")) && is.symbol(head[[2L]])) {
    if (as.character(head[[2L]]) %in% packages && as.character(head[[3L]]) %in% verbs) {
      return(as.character(head[[3L]]))
    }
  }
  NA_character_
}

## Split an expression into what is checked as variables (`kept`) and the column-expression
## arguments of NSE verbs (`dropped`). Dropped arguments are not required to resolve -- they are
## usually column names -- but are cross-checked against target names in other graphs, which is
## how `.data$batch == other_projects_target` is still caught.
prune_nse <- function(expr, verbs = NSE_VERBS) {
  if (!is.call(expr)) {
    return(list(kept = expr, dropped = list()))
  }
  ## Bind each argument and test with missing(): an empty argument (`x[, 1]`) cannot be passed
  ## to is.null() or identical() without "argument is missing" errors.
  if (!is.na(nse_verb_name(expr[[1L]], verbs))) {
    dropped <- list()
    if (length(expr) >= 3L) {
      for (i in seq.int(3L, length(expr))) {
        arg <- expr[[i]]
        if (!missing(arg) && !is.null(arg)) dropped <- c(dropped, list(arg))
      }
    }
    if (length(expr) >= 2L) {
      data_arg <- expr[[2L]]
      if (!missing(data_arg) && !is.null(data_arg)) {
        sub <- prune_nse(data_arg, verbs)
        return(list(kept = as.call(list(expr[[1L]], sub$kept)), dropped = c(dropped, sub$dropped)))
      }
    }
    return(list(kept = as.call(list(expr[[1L]])), dropped = dropped))
  }
  dropped <- list()
  for (i in seq_along(expr)[-1L]) {
    arg <- expr[[i]]
    if (!missing(arg) && !is.null(arg)) {
      sub <- prune_nse(arg, verbs)
      expr[[i]] <- sub$kept
      dropped <- c(dropped, sub$dropped)
    }
  }
  list(kept = expr, dropped = dropped)
}

## Free names of an expression, via codetools -- the same scoping {targets} itself uses: local
## assignments, function formals and `for` variables are bound; `x$field` gives only `x`;
## `pkg::fn` gives nothing but `::`.
globals_of <- function(expr) {
  if (is.null(expr)) {
    return(list(functions = character(), variables = character()))
  }
  g <- codetools::findGlobals(eval(call("function", NULL, expr)), merge = FALSE)
  list(
    functions = setdiff(g$functions, DATA_TABLE_SYMBOLS),
    variables = setdiff(g$variables, DATA_TABLE_SYMBOLS)
  )
}

## Free names of one command, split three ways. `functions` comes from the full expression (a
## helper called inside a column argument must still exist); `variables` from the pruned one (a
## column is not mistaken for a target); `nse_variables` are the column-argument names.
command_globals <- function(expr, verbs = NSE_VERBS) {
  expr <- strip_formulas(expr)
  if (is.null(expr)) {
    return(list(functions = character(), variables = character(), nse_variables = character()))
  }
  parts <- prune_nse(expr, verbs)
  dropped <- if (length(parts$dropped)) as.call(c(list(as.symbol("{")), parts$dropped)) else NULL
  list(
    functions = globals_of(expr)$functions,
    variables = globals_of(parts$kept)$variables,
    nse_variables = globals_of(dropped)$variables
  )
}

## Names a `pattern =` branches over. They must all be targets of the same graph: tar_manifest()
## and tar_validate() both accept `map(a, not_a_target)`; only tar_make() fails.
pattern_variables <- function(text) {
  if (is.na(text) || !nzchar(text)) {
    return(character())
  }
  expr <- parse_command(text)
  if (is.null(expr)) {
    return(UNPARSEABLE)
  }
  globals_of(expr)$variables
}

## Top-level names a script binds. In scope at definition time, but neither targets nor in R/.
script_bindings <- function(path) {
  out <- vapply(as.list(parse(path, keep.source = FALSE)), function(e) {
    if (is.call(e) && length(e) >= 3L && is.symbol(e[[1L]]) &&
      as.character(e[[1L]]) %in% c("<-", "<<-", "=") && is.symbol(e[[2L]])) {
      return(as.character(e[[2L]]))
    }
    NA_character_
  }, character(1))
  unique(out[!is.na(out)])
}

## The project's own closures (defined in `envir`) reachable from `roots`, transitively.
reachable_functions <- function(roots, envir = globalenv()) {
  own <- function(s) {
    exists(s, envir = envir, inherits = FALSE) &&
      is.function(f <- get(s, envir = envir, inherits = FALSE)) &&
      identical(environment(f), envir)
  }
  seen <- character()
  queue <- unique(Filter(own, roots))
  while (length(queue)) {
    s <- queue[[1L]]
    queue <- queue[-1L]
    if (s %in% seen) next
    seen <- c(seen, s)
    calls <- codetools::findGlobals(get(s, envir = envir), merge = FALSE)$functions
    queue <- c(queue, setdiff(Filter(own, calls), seen))
  }
  seen
}

## Functions called by reachable project functions that do not exist. Catches a helper whose file
## a partial tar_source(files = ) list omits: "object not found" on a worker, days into a run.
## Only call position is checked; free variables in bodies are usually columns.
unresolved_functions <- function(roots, envir = globalenv()) {
  reached <- reachable_functions(roots, envir)
  out <- list()
  for (s in reached) {
    calls <- setdiff(codetools::findGlobals(get(s, envir = envir), merge = FALSE)$functions,
                     DATA_TABLE_SYMBOLS)
    bad <- calls[!vapply(calls, exists, logical(1), envir = envir)]
    if (length(bad)) out[[s]] <- sort(bad)
  }
  list(reached = reached, unresolved = out)
}

## Literal option names read with getOption("...").
option_names <- function(code) {
  re <- 'getOption\\(\\s*["\']([^"\']+)["\']'
  hits <- regmatches(code, gregexpr(re, code, perl = TRUE))[[1L]]
  unique(sub(re, "\\1", hits, perl = TRUE))
}

## Where a command indexes a `format = "file"` target by name. {targets} stores a file target as
## bare unnamed paths, so x[["csv"]] is an error at best and a silent fallback at worst.
file_target_name_indexing <- function(expr, file_targets) {
  found <- character()
  walk <- function(e) {
    if (!is.call(e)) return(invisible())
    h <- e[[1L]]
    if (is.symbol(h) && as.character(h) %in% c("[[", "$") && length(e) >= 3L &&
      is.symbol(e[[2L]]) && as.character(e[[2L]]) %in% file_targets &&
      (is.character(e[[3L]]) || identical(as.character(h), "$"))) {
      found <<- c(found, deparse(e, nlines = 1L)[[1L]])
    }
    for (i in seq_along(e)) if (is.call(e[[i]])) walk(e[[i]])
  }
  walk(expr)
  found
}

## Files in `dir` whose top level does more than define things. tar_source() EXECUTES every file,
## so a standalone script in R/ that deletes outputs or signs in to a service runs at pipeline
## definition time. Allowed at top level: assignments, library()/requireNamespace()/
## suppressPackageStartupMessages(), and `if (FALSE)` blocks.
top_level_side_effects <- function(dir = "R") {
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

## Check ONE graph (project x variant). Runs inside a fresh R process: see validate-projects.R.
check_graph <- function(project, variant, run_scoping = "", option_exceptions = character(),
                        verbs = NSE_VERBS) {
  script <- targets::tar_config_get("script", project = project)
  fields <- c("name", "command", "pattern", "format", "cue_mode", "deployment", "packages")
  manifest <- tryCatch(
    targets::tar_manifest(fields = tidyselect::any_of(fields), script = script,
                          callr_function = NULL, envir = globalenv()),
    error = function(e) e
  )
  base <- list(project = project, variant = variant, targets = character(), findings = NULL,
               nse = list(), variables = list(), reached = 0L)
  finding <- function(target, check, detail) {
    if (!length(detail)) return(NULL)
    data.frame(project = project, variant = variant, target = target, check = check,
               detail = detail, stringsAsFactors = FALSE)
  }
  if (inherits(manifest, "error")) {
    base$findings <- finding("<definition>", "definition", conditionMessage(manifest))
    return(base)
  }
  pkgs <- unique(c(targets::tar_option_get("packages"), unlist(manifest$packages)))
  missing_pkgs <- character()
  for (p in pkgs) {
    ok <- suppressWarnings(suppressPackageStartupMessages(
      requireNamespace(p, quietly = TRUE) && library(p, character.only = TRUE, logical.return = TRUE)
    ))
    if (!isTRUE(ok)) missing_pkgs <- c(missing_pkgs, p)
  }
  get_col <- function(nm, default) if (nm %in% names(manifest)) manifest[[nm]] else rep(default, nrow(manifest))
  commands <- manifest$command
  patterns <- get_col("pattern", NA_character_)
  formats <- get_col("format", NA_character_)
  cues <- get_col("cue_mode", NA_character_)
  deploys <- get_col("deployment", NA_character_)
  names_all <- manifest$name
  in_scope <- unique(c(names_all, script_bindings(script)))
  file_targets <- names_all[formats %in% "file"]

  rows <- list(finding("<definition>", "package", missing_pkgs))
  roots <- character()
  nse <- list()
  vars <- list()
  parsed <- vector("list", nrow(manifest))
  for (i in seq_len(nrow(manifest))) {
    nm <- names_all[[i]]
    expr <- parse_command(commands[[i]])
    parsed[i] <- list(expr)
    if (is.null(expr)) {
      rows <- c(rows, list(finding(nm, "unparseable", UNPARSEABLE)))
      next
    }
    g <- command_globals(expr, verbs)
    roots <- c(roots, g$functions)
    syms <- unique(c(g$functions, g$variables))
    unresolved <- syms[!syms %in% in_scope & !vapply(syms, exists, logical(1), envir = globalenv())]
    rows <- c(rows, list(finding(nm, "unresolved", sort(unresolved))))
    rows <- c(rows, list(finding(nm, "file_name_index", file_target_name_indexing(expr, file_targets))))
    pv <- pattern_variables(patterns[[i]])
    rows <- c(rows, list(finding(nm, "pattern", sort(setdiff(pv, names_all)))))
    if (length(g$variables)) vars[[nm]] <- g$variables
    if (length(g$nse_variables)) nse[[nm]] <- g$nse_variables
  }
  fns <- unresolved_functions(unique(roots))
  for (f in names(fns$unresolved)) {
    rows <- c(rows, list(finding("<functions>", "unresolved_function",
                                 paste0(f, "() calls ", fns$unresolved[[f]], "()"))))
  }
  if (nzchar(run_scoping)) {
    for (i in seq_len(nrow(manifest))) {
      nm <- names_all[[i]]
      if (nm %in% option_exceptions || is.null(parsed[[i]])) next
      g <- command_globals(parsed[[i]], verbs)
      bodies <- vapply(reachable_functions(g$functions),
                       function(s) paste(deparse(get(s, envir = globalenv())), collapse = "\n"), "")
      opts <- unique(c(option_names(paste(commands[[i]], collapse = "\n")),
                       unlist(lapply(bodies, option_names))))
      opts <- sort(opts[grepl(run_scoping, opts)])
      ok <- identical(cues[[i]], "always") && identical(deploys[[i]], "main")
      if (length(opts) && !ok) {
        rows <- c(rows, list(finding(nm, "option_cue", sprintf(
          "%s (cue = %s, deployment = %s)", paste(opts, collapse = ", "), cues[[i]], deploys[[i]]
        ))))
      }
    }
  }
  base$targets <- names_all
  base$findings <- do.call(rbind, Filter(Negate(is.null), rows))
  base$nse <- nse
  base$variables <- vars
  base$reached <- length(fns$reached)
  base
}

## Names a graph's commands use that are targets in some OTHER graph (another project, or the same
## project under another variant) but not in this one. Checked whether or not the name happens to
## resolve: a missing target named like a base function (`factorial`, `local`) resolves to the
## function, and a gated-off stage's target referenced from an ungated one is exactly the bug that
## survives because the consumer returns early.
cross_graph_refs <- function(results) {
  out <- list()
  for (k in seq_along(results)) {
    r <- results[[k]]
    others <- setdiff(unique(unlist(lapply(results[-k], `[[`, "targets"))), r$targets)
    for (tg in unique(c(names(r$variables), names(r$nse)))) {
      refs <- sort(intersect(unique(c(r$variables[[tg]], r$nse[[tg]])), others))
      if (length(refs)) {
        out[[length(out) + 1L]] <- data.frame(project = r$project, variant = r$variant,
          target = tg, check = "cross_graph", detail = refs, stringsAsFactors = FALSE)
      }
    }
  }
  do.call(rbind, out)
}

## Apply the allowlist. Columns: project, variant, target, check, symbol, reason. `target` and
## `symbol` are anchored regular expressions; `project`, `variant` and `check` may be `any`.
## An applicable row whose target is present in that graph but which matches no finding is STALE,
## so the list cannot quietly rot. A row whose target the graph does not contain (gated off) is
## skipped.
apply_allowlist <- function(findings, allow, results) {
  anchored <- function(p, x) grepl(paste0("^(", p, ")$"), x)
  any_or <- function(p, x) p == "any" | p == x
  allowed <- rep(FALSE, NROW(findings))
  stale <- character()
  for (i in seq_len(NROW(allow))) {
    a <- allow[i, ]
    for (r in results) {
      if (!any_or(a$project, r$project) || !any_or(a$variant, r$variant)) next
      if (!any(anchored(a$target, r$targets))) next
      hit <- if (NROW(findings)) {
        findings$project == r$project & findings$variant == r$variant &
          anchored(a$target, findings$target) & anchored(a$symbol, findings$detail) &
          any_or(a$check, findings$check)
      } else logical()
      if (!any(hit)) stale <- c(stale, sprintf("%s/%s %s %s", r$project, r$variant, a$target, a$symbol))
      allowed <- allowed | hit
    }
  }
  list(allowed = allowed, stale = unique(stale))
}
