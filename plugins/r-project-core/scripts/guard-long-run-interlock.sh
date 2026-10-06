#!/usr/bin/env bash
# PreToolUse(Bash): refuse to mutate the R library or sync cluster nodes while a
# long pipeline run that loads that library is in flight.
#
# A node-sync or package install swaps the R library out from under workers that
# are mid-run, which kills the run and can corrupt partially-written results.
# The standard preflight before any long run is a process check for
# "tar_make|DEoptim"; this hook applies the same check in the other direction.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

# Only library-mutating / node-syncing commands are gated.
gated='renv::(install|restore|snapshot|rebuild|purge|hydrate|checkout)|install\.packages|remotes::install|devtools::install|BiocManager::install|pak::(pak|pkg_install|local_install[a-z_]*)\(|Require::(Install|Require)\(|setupProject\(|sync-nodes\.R|rebuild_renv\.R|install_landr_profile\.R'
[[ $cmd =~ $gated ]] || exit 0
pre="${cmd%%"${BASH_REMATCH[0]}"*}"

## FORCAST_LONGRUN_PATTERNS (this session), else longRunPatterns (project policy), else defaults
patterns="${FORCAST_LONGRUN_PATTERNS:-}"
[ -z "$patterns" ] && patterns="$(policy_list '.longRunPatterns' | paste -sd'|' -)"
[ -z "$patterns" ] && patterns='tar_make|DEoptim|landis|Omniscape|julia -t'

# target_dir: where the gated call runs -- the session's cwd from the payload, moved
# by each `cd` before it. Fails when the command changes directory or library in a
# way this cannot follow.
target_dir() {
  local d seg rest t
  printf '%s' "$cmd" | grep -Eq 'setwd\(|pushd|renv::(load|activate)\(|project[[:space:]]*=|RENV_PROJECT=|R_LIBS' && return 1
  d="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
  [ -n "$d" ] || d="${CLAUDE_PROJECT_DIR:-$PWD}"
  while IFS= read -r seg; do
    seg="${seg#"${seg%%[![:space:]]*}"}"
    case "$seg" in
      cd) t="$HOME" ;;
      cd[[:space:]]*)
        rest="${seg#cd}"; rest="${rest#"${rest%%[![:space:]]*}"}"
        case "$rest" in
          \"*) t="${rest#\"}"; t="${t%%\"*}" ;;
          \'*) t="${rest#\'}"; t="${t%%\'*}" ;;
          *) t="${rest%%[[:space:]]*}" ;;
        esac ;;
      *) continue ;;
    esac
    case "$t" in
      '' | '~') t="$HOME" ;;
      \~/*) t="$HOME/${t#\~/}" ;;
      -* | *'$'* | *'`'*) return 1 ;;
    esac
    case "$t" in /*) d="$t" ;; *) d="$d/$t" ;; esac
    [ -d "$d" ] || return 1
  done < <(printf '%s\n' "$pre" | awk '{ gsub(/&&|\|\||[;|(]/, "\n"); print }')
  printf '%s' "$d"
}

## An renv project library is private: only runs of that project load it, so only
## they can block a change to it. Every run on the machine counts when the change
## reaches further, or its target is unclear:
##   * renv::purge, renv::rebuild and `rebuild =` delete or replace shared renv cache
##     entries in place, and other projects' libraries link to those entries;
##   * a repo without renv installs into the user library, which every non-renv R
##     session loads, and so does R started with --vanilla/--no-init-file -e, which
##     skips the .Rprofile that activates renv;
##   * the command changes directory in a way target_dir cannot follow.
scope=""
if printf '%s' "$cmd" | grep -Eq 'renv::(purge|rebuild)|rebuild[[:space:]]*=[[:space:]]*[^F[:space:]]'; then
  why="it changes the shared renv cache, which other projects' libraries link to"
elif ! dir="$(target_dir)"; then
  why="its target project could not be determined"
elif root="$(git_root "$dir")" && ! renv_project "$root"; then
  why="$root has no renv library, so installs go to a library other projects share"
elif printf '%s' "$cmd" | grep -Eq -- '--(vanilla|no-init-file)' &&
  printf '%s' "$cmd" | grep -Eq -- '(^|[[:space:]])-e[[:space:]]'; then
  why="R starts without the .Rprofile that activates renv"
else
  scope="$root"
fi

running="$(list_procs "$patterns" | while read -r pid args; do
  if [ -n "$scope" ]; then
    proc_in_repo "$pid" "$scope" || [ $? -ne 1 ] || continue
  fi
  printf '%s %s\n' "$pid" "$args"
done | head -5)"
[ -z "$running" ] && exit 0

if [ -n "$scope" ]; then
  msg="BLOCKED: a long run of the project at $scope appears to be in flight."
else
  msg="BLOCKED: a long run appears to be in flight on this machine. This command is
checked against runs in every project because $why."
fi

reason="$msg

Currently running:
$running

Installing packages or syncing nodes now swaps the R library out from under the
active workers. Inspecting a run is fine; mutating its library is not.

Do one of:
  * wait for the run to finish (check with: ps -o pid,etime,args -p \"\$(pgrep -d, -f '$patterns')\");
  * if those processes are stale, confirm with the user and have them clear them;
  * set FORCAST_LONGRUN_PATTERNS to narrow the check for this session.

Read-only inspection (tar_progress, tar_meta, tail -f on the log) is unaffected."

jq -n --arg r "$reason" '{hookSpecificOutput: {
  hookEventName: "PreToolUse",
  permissionDecision: "deny",
  permissionDecisionReason: $r}}'
exit 0
