#!/usr/bin/env bash
# PreToolUse(Bash): refuse to mutate the R library or sync cluster nodes while a
# long pipeline run is in flight.
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
printf '%s' "$cmd" | grep -Eq \
  'renv::(install|restore|snapshot|rebuild|purge|hydrate|checkout)|install\.packages|remotes::install|devtools::install|BiocManager::install|pak::(pak|pkg_install|local_install[a-z_]*)\(|Require::(Install|Require)\(|setupProject\(|sync-nodes\.R|rebuild_renv\.R|install_landr_profile\.R' \
  || exit 0

## FORCAST_LONGRUN_PATTERNS (this session), else longRunPatterns (project policy), else defaults
patterns="${FORCAST_LONGRUN_PATTERNS:-}"
[ -z "$patterns" ] && patterns="$(policy_list '.longRunPatterns' | paste -sd'|' -)"
[ -z "$patterns" ] && patterns='tar_make|DEoptim|landis|Omniscape|julia -t'
running="$(list_procs "$patterns" | head -5)"
[ -z "$running" ] && exit 0

reason="BLOCKED: a long run appears to be in flight on this machine.

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
