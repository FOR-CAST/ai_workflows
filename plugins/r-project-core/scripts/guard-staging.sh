#!/usr/bin/env bash
# PreToolUse(Bash): stage explicit paths, never the whole tree.
#
# Multiple agent sessions routinely share one worktree. `git add -A` / `git add .`
# / `git commit -a` then sweeps in another session's half-finished work. One such
# commit recorded an unpushed submodule pointer and broke every node in a cluster.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

cmd="$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0
n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "

bad=""
printf '%s' "$n" | grep -Eq " git +add +((-A|--all)$B|-[a-zA-Z]*A[a-zA-Z]* )" && bad="git add -A"
printf '%s' "$n" | grep -Eq ' git +add +\.( |$)'                              && bad="git add ."
printf '%s' "$n" | grep -Eq " git +add +(-u|--update)$B"                      && bad="git add -u"
printf '%s' "$n" | grep -Eq " git +commit( [^;|&]*)? (-[a-zA-Z]*a[a-zA-Z]*|--all)$B" && bad="git commit -a"
[ -z "$bad" ] && exit 0

deny "BLOCKED: '$bad' stages files this session did not touch.

More than one agent session may be working in this worktree, and the tree also
carries generated churn (renv.lock, _targets metadata, .Rproj.user, regenerated
man/*.Rd). Sweeping commits here have previously captured another session's
unpushed work and broken every node in a cluster.

Instead:
  git status --porcelain          # look first
  git add path/one.R path/two.R   # name every path you changed

If you genuinely need everything, list the paths explicitly after reviewing
'git status'. If the tree contains changes you did not make, ask the user before
staging them."
