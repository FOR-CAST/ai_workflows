#!/usr/bin/env bash
# PreToolUse(Bash): policy-driven guards. Every rule here is OFF unless the repo
# opts in via .claude/r-project-policy.json, because the corpus contains genuine,
# deliberate disagreements between projects on each of these points.
#
# Recognised keys (all optional):
#   "packageInstall": "renv"        -- deny install.packages, devtools/remotes/pak/
#                                      BiocManager/Require installs, setupProject(),
#                                      and a bare renv::snapshot()
#   "rBinary": "Rscript-4.6.1"      -- advise when a bare Rscript/R call is used
#   "noAirFormat": true             -- deny `air format` in this repo
#   "publishRequiresApproval": true -- ASK before push, gh writes (incl. gh api
#                                      POST/PATCH/PUT/DELETE and implicit POSTs),
#                                      and gh extension installs
#   "controllerHosts": ["hostA"]    -- deny heavy compute when running on those hosts
#   "heavyCommands": [...]          -- regex list; defaults below
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

cmd="$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0
n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "

## ---------------------------------------------------------------- installs --
if [ "$(policy_get '.packageInstall')" = "renv" ]; then
  if printf '%s' "$n" | grep -Eq 'install\.packages\(|devtools::install(_[a-z]+)?\(|remotes::install_|BiocManager::install\(|pak::(pak|pkg_install|local_install|local_install_deps)\(|Require::(Install|Require)\(|setupProject\('; then
    deny "BLOCKED: this project installs packages through renv only.

Use, in the project session:
  renv::install(\"<repo>/<pkg>@<branch>\", lock = TRUE, prompt = FALSE)
  renv::restore()

pak, Require::Install() and SpaDES.project::setupProject() all install without
recording the result in renv.lock, so the next restore on another machine silently
differs.

Never install development tools into the project library. For dev dependencies use
a vanilla session and pak::local_install_dev_deps(), so the project renv library
stays exactly what the lockfile says it is."
  fi
  if printf '%s' "$n" | grep -Eq 'renv::snapshot\( *\)'; then
    deny "BLOCKED: a bare renv::snapshot() rewrites the lockfile from whatever happens
to be installed right now. It has previously cut a lockfile from 437 entries to 69,
and it silently drops the GitHub remotes that pinned packages depend on.

Record the dependency at install time instead:
  renv::install(\"<repo>/<pkg>@<branch>\", lock = TRUE, prompt = FALSE)

If you truly need a snapshot, pass explicit packages and have the user review the
lockfile diff before it is committed."
  fi
fi

## ------------------------------------------------------------- air format --
if [ "$(policy_get '.noAirFormat')" = "true" ] && printf '%s' "$n" | grep -Eq ' air +format'; then
  deny "BLOCKED: this repo opts out of air formatting (noAirFormat in
.claude/r-project-policy.json).

Its HEAD is not air-clean, so a reformat buries the real change in hundreds of
unrelated lines. Match the surrounding style by hand in the lines you touch."
fi
printf '%s' "$n" | grep -Eq ' air +format[^;|&]*--exclude' && \
  deny "BLOCKED: 'air format' has no --exclude flag. Put the exclusion in air.toml under [format] exclude = [...]."

## ----------------------------------------------------------- publishing ----
if [ "$(policy_get '.publishRequiresApproval')" = "true" ]; then
  pub=""
  printf '%s' "$n" | grep -Eq " git +push$B" && pub="git push"
  printf '%s' "$n" | grep -Eq " gh +(pr|issue) +(create|merge|comment|review|edit|ready|close|reopen|delete|transfer|lock|unlock)$B" && pub="gh publish"
  printf '%s' "$n" | grep -Eq " gh +(release|repo|gist|label|secret|variable) +(create|edit|delete|upload|fork|rename|archive|set)$B" && pub="gh publish"
  printf '%s' "$n" | grep -Eq " gh +(workflow +run|run +(rerun|cancel))$B" && pub="gh remote run"
  printf '%s' "$n" | grep -Eq " gh +extension +(install|upgrade)$B" && pub="gh extension install: third-party code"
  ## gh api writes: an explicit method other than GET, or request fields with no
  ## method at all -- gh then sends a POST, which is how review replies get posted.
  while IFS= read -r call; do
    [ -z "$call" ] && continue
    method="$(printf '%s' "$call" | grep -Eio '(-X *|--method[ =]+)[a-z]+' | grep -Eio '[a-z]+$' | tail -1 | tr '[:lower:]' '[:upper:]')"
    if [ -n "$method" ]; then
      [ "$method" != GET ] && pub="gh api $method"
    elif printf '%s' "$call" | grep -Eq ' (-f|-F|--field|--raw-field|--input)( |=|[^ -])'; then
      pub="gh api POST (implied by request fields)"
    fi
  done < <(printf '%s' "$n" | grep -Eo ' gh +api [^;|&]*')
  if [ -n "$pub" ]; then
    ask_user "Publish check ($pub): this project requires your confirmation before anything leaves this machine (publishRequiresApproval). Review the command, then approve or deny."
  fi
fi

## --------------------------------------------------- compute location ------
controllers=()
while IFS= read -r c; do [ -n "$c" ] && controllers+=("$c"); done < <(policy_list '.controllerHosts')
if [ "${#controllers[@]}" -gt 0 ]; then
  host="$(hostname -s 2>/dev/null || echo unknown)"
  for c in "${controllers[@]}"; do
    [ "$host" != "$c" ] && continue
    printf '%s' "$n" | grep -Eq '^ *ssh ' && break
    ## a memory-capped scope is the sanctioned way to run something here
    printf '%s' "$n" | grep -Eq 'systemd-run +--user +--scope[^;|&]*MemoryMax=' && break
    heavy="$(policy_list '.heavyCommands' | paste -sd'|' -)"
    [ -z "$heavy" ] && heavy='tar_make\(|quarto +render|quarto_render|rmarkdown::render|devtools::(check|test|install|build)|testthat::test_|R +CMD +(check|build|INSTALL)|rcmdcheck::|renv::(install|restore|rebuild)|pak::|DEoptim|simInitAndSpades|spades\(|docker +run|sf::st_read|st_read\(|fread\(|rasterize\(|download\.file'
    if printf '%s' "$n" | grep -Eq "$heavy"; then
      deny "BLOCKED: '$host' is a control node, and this command is heavy compute.

Running builds, renders, simulations or checks here has repeatedly exhausted the
control node's memory and killed the user's interactive session along with the
scheduler.

Heavy includes package tests and checks, source builds, renders, and large data
reads -- not only pipeline runs.

Dispatch it to a compute node instead:
  ssh <compute-node> 'bash -s' < script.sh
or launch it through the project's own submission path (a crew/crew.ssh controller,
or the project's launch script), which places the work on a worker.

If it genuinely must run here, cap it so a runaway dies alone:
  systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 <command>

Light orchestration (git, tar_progress, tar_manifest, tar_meta, tar_outdated,
tar_validate) on the control node is fine."
    fi
    break
  done
fi

## --------------------------------------------------------- R binary pin ----
rbin="$(policy_get '.rBinary')"
if [ -n "$rbin" ] && printf '%s' "$n" | grep -Eq '(^| )(Rscript|R) +(-e|--vanilla|--no-init-file|CMD)'; then
  printf '%s' "$n" | grep -q "$rbin" || \
    advise "NOTE: this project pins its R binary to '$rbin' (rBinary in
.claude/r-project-policy.json). A bare 'Rscript'/'R' call resolves to the version
manager's default, which is often an older R with a different library, and the
resulting errors look like package problems rather than a version mismatch.
Prefer: $rbin -e '...'"
fi

exit 0
