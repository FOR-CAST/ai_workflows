## Inventory of the ai_workflows marketplace, read from the plugin tree.
##
## The cheatsheet's terse labels are hand-written; this file is what stops them
## drifting. Everything catalogued here must carry a label on the sheet, and every
## label must correspond to something catalogued here -- see check_coverage().

`%||%` <- function(x, y) if (is.null(x)) y else x

#' Read the YAML frontmatter of a markdown file
#'
#' @param path Path to a file whose first line is a `---` fence.
#' @return The parsed frontmatter as a list.
read_frontmatter <- function(path) {
  lines <- readLines(path, warn = FALSE)
  fence <- which(trimws(lines) == "---")
  if (length(fence) < 2L || fence[1L] != 1L) {
    stop("no YAML frontmatter in ", path, call. = FALSE)
  }
  body <- lines[(fence[1L] + 1L):(fence[2L] - 1L)]
  yaml::yaml.load(paste(body, collapse = "\n"))
}

#' Build an empty inventory row set with the canonical columns
#'
#' @return A zero-row data.frame carrying every inventory column.
inventory_columns <- function() {
  data.frame(
    reg_id = character(), id = character(), plugin = character(), kind = character(),
    name = character(), event = character(), matcher = character(), script = character(),
    scoped = logical(), slash_only = logical(), colour = character(), deps = character()
  )
}

#' Catalogue the skills of one plugin
#'
#' @param dir Plugin directory, e.g. `plugins/r-targets`.
#' @return A data.frame of `kind == "skill"` rows.
scan_skills <- function(dir) {
  files <- Sys.glob(file.path(dir, "skills", "*", "SKILL.md"))
  if (length(files) == 0L) {
    return(inventory_columns())
  }
  plugin <- basename(dir)
  rows <- lapply(files, function(f) {
    fm <- read_frontmatter(f)
    id <- paste(plugin, "skill", fm$name, sep = "/")
    data.frame(
      reg_id = id, id = id,
      plugin = plugin, kind = "skill", name = fm$name,
      event = NA_character_, matcher = NA_character_, script = NA_character_,
      scoped = !is.null(fm$paths),
      slash_only = isTRUE(fm[["disable-model-invocation"]]),
      colour = NA_character_, deps = NA_character_
    )
  })
  do.call(rbind, rows)
}

#' Catalogue the review subagents of one plugin
#'
#' @param dir Plugin directory.
#' @return A data.frame of `kind == "agent"` rows.
scan_agents <- function(dir) {
  files <- Sys.glob(file.path(dir, "agents", "*.md"))
  if (length(files) == 0L) {
    return(inventory_columns())
  }
  plugin <- basename(dir)
  rows <- lapply(files, function(f) {
    fm <- read_frontmatter(f)
    id <- paste(plugin, "agent", fm$name, sep = "/")
    data.frame(
      reg_id = id, id = id,
      plugin = plugin, kind = "agent", name = fm$name,
      event = NA_character_, matcher = NA_character_, script = NA_character_,
      scoped = FALSE, slash_only = FALSE,
      colour = if (is.null(fm$color)) NA_character_ else fm$color, deps = NA_character_
    )
  })
  do.call(rbind, rows)
}

#' Catalogue the hook registrations of one plugin
#'
#' Counts registrations rather than files, so a script that is present but never
#' wired up is not catalogued, and a shared library such as `_policy.sh` is
#' correctly excluded without naming it.
#'
#' One row per registration, because the sheet groups hooks by event and a script
#' may be wired to several. `id` keys on the script, so such a script still needs
#' exactly one label; `reg_id` is what must be unique.
#'
#' @param dir Plugin directory.
#' @return A data.frame of `kind == "hook"` rows, one per registration.
scan_hooks <- function(dir) {
  manifest <- file.path(dir, "hooks", "hooks.json")
  if (!file.exists(manifest)) {
    return(inventory_columns())
  }
  plugin <- basename(dir)
  events <- jsonlite::fromJSON(manifest, simplifyVector = FALSE)$hooks
  rows <- list()
  for (event in names(events)) {
    for (group in events[[event]]) {
      matcher <- if (is.null(group$matcher)) NA_character_ else group$matcher
      for (hook in group$hooks) {
        script <- basename(hook$command)
        rows[[length(rows) + 1L]] <- data.frame(
          reg_id = paste(plugin, "hook", script, event, matcher, sep = "/"),
          id = paste(plugin, "hook", script, sep = "/"),
          plugin = plugin, kind = "hook", name = script,
          event = event, matcher = matcher, script = script,
          scoped = FALSE, slash_only = FALSE, colour = NA_character_, deps = NA_character_
        )
      }
    }
  }
  if (length(rows) == 0L) {
    return(inventory_columns())
  }
  do.call(rbind, rows)
}

#' Read a plugin's declared dependencies
#'
#' An entry is either a bare plugin name or an object naming another marketplace.
#'
#' @param manifest Parsed `plugin.json`.
#' @return A character vector, cross-marketplace entries rendered as `name@market`.
dependency_names <- function(manifest) {
  deps <- manifest$dependencies
  if (is.null(deps) || length(deps) == 0L) {
    return(character())
  }
  vapply(deps, function(d) {
    if (is.character(d)) d else paste0(d$name, "@", d$marketplace)
  }, character(1L))
}

#' Catalogue a bundle: a plugin that ships nothing and only pulls others in
#'
#' Bundles carry no skills, agents or hooks, so they would otherwise be invisible
#' to the sheet and would trip the not-empty assertion in [scan_plugins()].
#'
#' @param dir Plugin directory.
#' @return A one-row data.frame of `kind == "bundle"`, or no rows.
scan_bundle <- function(dir) {
  plugin <- basename(dir)
  manifest <- jsonlite::fromJSON(
    file.path(dir, ".claude-plugin", "plugin.json"),
    simplifyVector = FALSE
  )
  ships <- length(Sys.glob(file.path(dir, "skills", "*", "SKILL.md"))) +
    length(Sys.glob(file.path(dir, "agents", "*.md"))) +
    as.integer(file.exists(file.path(dir, "hooks", "hooks.json")))
  deps <- dependency_names(manifest)
  if (ships > 0L || length(deps) == 0L) {
    return(inventory_columns())
  }
  id <- paste(plugin, "bundle", sep = "/")
  data.frame(
    reg_id = id, id = id, plugin = plugin, kind = "bundle", name = plugin,
    event = NA_character_, matcher = NA_character_, script = NA_character_,
    scoped = FALSE, slash_only = FALSE, colour = NA_character_,
    deps = paste(deps, collapse = ", ")
  )
}

#' Catalogue every skill, subagent and hook registration in the marketplace
#'
#' @param root Directory holding the plugins, relative to the repository root.
#' @return A data.frame with one row per catalogued item.
scan_plugins <- function(root = "plugins") {
  dirs <- sort(Sys.glob(file.path(root, "*")))
  dirs <- dirs[dir.exists(dirs) & file.exists(file.path(dirs, ".claude-plugin", "plugin.json"))]
  if (length(dirs) == 0L) {
    stop("no plugins found under ", root, " -- is the working directory the repo root?",
         call. = FALSE)
  }

  inv <- do.call(rbind, lapply(dirs, function(d) {
    rbind(scan_skills(d), scan_agents(d), scan_hooks(d), scan_bundle(d))
  }))

  ## A scanner that silently returns nothing would let the coverage guard pass
  ## vacuously, so assert the shape of what it found before anyone trusts it.
  ## A bundle legitimately ships nothing, so it is catalogued as a bundle row above
  ## rather than excused here. Anything still empty is a real problem.
  empty <- setdiff(basename(dirs), unique(inv$plugin))
  if (length(empty) > 0L) {
    stop("plugin(s) yielded no skills, agents, hooks or dependencies: ",
         paste(empty, collapse = ", "), call. = FALSE)
  }
  dupes <- inv$reg_id[duplicated(inv$reg_id)]
  if (length(dupes) > 0L) {
    stop("duplicate inventory ids: ", paste(unique(dupes), collapse = ", "), call. = FALSE)
  }
  hooks <- inv[inv$kind == "hook", ]
  missing_scripts <- vapply(seq_len(nrow(hooks)), function(i) {
    !file.exists(file.path(root, hooks$plugin[i], "scripts", hooks$script[i]))
  }, logical(1L))
  if (any(missing_scripts)) {
    stop("hooks.json references scripts that do not exist: ",
         paste(hooks$id[missing_scripts], collapse = ", "), call. = FALSE)
  }

  inv[order(inv$plugin, inv$kind, inv$name), ]
}

#' Read marketplace-level metadata
#'
#' @param path Path to the marketplace manifest.
#' @return A list with `name`, `version` and `description`.
scan_marketplace <- function(path = ".claude-plugin/marketplace.json") {
  mk <- jsonlite::fromJSON(path, simplifyVector = FALSE)
  list(
    name = mk$name,
    owner = mk$owner$name,
    version = mk$metadata$version,
    description = mk$metadata$description,
    ## Nothing auto-adds another marketplace, so a dependency on one is a manual
    ## install step the sheet has to state.
    cross = unlist(mk$allowCrossMarketplaceDependenciesOn) %||% character()
  )
}

#' Abort when the sheet and the plugin tree disagree
#'
#' Checks coverage, not accuracy: it cannot tell that a label still describes its
#' skill. That stays a review responsibility.
#'
#' @param inv Inventory from [scan_plugins()].
#' @param labels Named character vector or list, keyed by inventory `id`.
#' @return `invisible(TRUE)` when every id is covered exactly once.
check_coverage <- function(inv, labels) {
  missing <- setdiff(unique(inv$id), names(labels))
  removed <- setdiff(names(labels), unique(inv$id))
  if (length(missing) > 0L || length(removed) > 0L) {
    bullet <- function(what, ids) {
      paste0("  ", what, ":\n", paste0("    ", ids, collapse = "\n"), "\n")
    }
    stop(
      "cheatsheet out of sync with plugins/\n",
      if (length(missing) > 0L) bullet("catalogued but not on the sheet", missing),
      if (length(removed) > 0L) bullet("on the sheet but no longer in plugins/", removed),
      "Add or remove the entry in cheatsheet/ai-workflows-cheatsheet.qmd.",
      call. = FALSE
    )
  }
  invisible(TRUE)
}

#' Read the policy-file key names from the installation documentation
#'
#' The keys are documented in one table in `docs/installation.md`; parsing them
#' keeps the sheet's policy panel from drifting when a key is added there.
#'
#' @param path Path to the installation documentation.
#' @return A character vector of key names, in documented order.
scan_policy_keys <- function(path = "docs/installation.md") {
  lines <- readLines(path, warn = FALSE)
  start <- grep("^\\| Key \\| Effect \\|", lines)
  if (length(start) != 1L) {
    stop("expected exactly one policy-key table in ", path, call. = FALSE)
  }
  rest <- lines[(start + 2L):length(lines)]
  rows <- rest[seq_len(which(!grepl("^\\|", rest))[1L] - 1L)]
  keys <- sub("^\\| `([A-Za-z]+).*$", "\\1", rows)
  if (any(keys == rows)) {
    stop("could not parse a key from: ", paste(rows[keys == rows], collapse = " / "), call. = FALSE)
  }
  keys
}

#' Read the licence and copyright line the repository actually declares
#'
#' Parsed rather than typed, because a licence is a thing that changes and a sheet
#' that states one from memory goes wrong silently.
#'
#' @param path Path to the LICENSE file.
#' @param root Directory holding the plugins, for the SPDX cross-check.
#' @return A list with `name`, `spdx`, `year` and `holder`.
scan_licence <- function(path = "LICENSE", root = "plugins") {
  lines <- readLines(path, warn = FALSE)
  name <- trimws(lines[1L])
  hit <- grep("^Copyright \\(c\\) ", lines, value = TRUE)
  if (length(hit) != 1L) {
    stop("expected exactly one 'Copyright (c)' line in ", path, call. = FALSE)
  }
  year <- sub("^Copyright \\(c\\) ([0-9]{4}).*$", "\\1", hit)
  holder <- trimws(sub("^Copyright \\(c\\) [0-9]{4}[, ]*", "", hit))
  if (year == hit || holder == "") {
    stop("could not parse the copyright line: ", hit, call. = FALSE)
  }

  ## Every plugin declares an SPDX id; they must agree with each other and with
  ## the LICENSE file, or the sheet would print one of two different answers.
  spdx <- unique(vapply(
    Sys.glob(file.path(root, "*", ".claude-plugin", "plugin.json")),
    function(f) {
      lic <- jsonlite::fromJSON(f, simplifyVector = FALSE)$license
      if (is.null(lic)) NA_character_ else lic
    },
    character(1L)
  ))
  if (length(spdx) != 1L || is.na(spdx)) {
    stop("plugins disagree about their licence: ", paste(spdx, collapse = ", "),
         call. = FALSE)
  }
  if (!grepl(spdx, name, fixed = TRUE)) {
    stop("LICENSE says '", name, "' but the manifests say '", spdx, "'", call. = FALSE)
  }

  list(name = name, spdx = spdx, year = year, holder = holder)
}

#' Read the repository every plugin manifest declares
#'
#' @param root Directory holding the plugins.
#' @return The repository URL, without its scheme.
scan_repository <- function(root = "plugins") {
  repos <- unique(vapply(
    Sys.glob(file.path(root, "*", ".claude-plugin", "plugin.json")),
    function(f) {
      r <- jsonlite::fromJSON(f, simplifyVector = FALSE)$repository
      if (is.null(r)) NA_character_ else r
    },
    character(1L)
  ))
  if (length(repos) != 1L || is.na(repos)) {
    stop("plugins disagree about their repository: ", paste(repos, collapse = ", "),
         call. = FALSE)
  }
  sub("^https?://", "", repos)
}
