#!/usr/bin/env bash
# SessionStart: surface the shared-machine state that determines what is safe to do.
#
# Three of the most costly recorded mistakes -- running heavy compute on a control
# node, signalling another project's process, and staging a concurrent session's
# work -- all happen because this information was not visible at the moment it
# mattered. Print it once, up front, and label what is NOT ours.
#
# stdout on SessionStart is added to the model's context.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

root="$(repo_root)"
host="$(hostname -s 2>/dev/null || echo unknown)"

echo "## Machine and project state (read before running anything)"
echo
echo "Host: ${host}"

# --- role -------------------------------------------------------------------
role="unspecified"
while read -r c; do [ "$c" = "$host" ] && role="CONTROL NODE"; done < <(policy_list '.controllerHosts')
if [ "$role" = "CONTROL NODE" ]; then
  echo "Role: **CONTROL NODE** -- do NOT run builds, renders, simulations or checks here."
  echo "      Dispatch heavy work to a compute node (ssh) or via the project's launcher."
else
  pf="$(policy_file 2>/dev/null || true)"
  [ -n "$pf" ] && echo "Role: compute/dev node (not listed in controllerHosts)."
fi

# --- project policy ---------------------------------------------------------
pf="$(policy_file 2>/dev/null || true)"
if [ -n "$pf" ]; then
  echo
  echo "Project policy (${pf#"$root"/}):"
  jq -r 'to_entries[] | "  - \(.key): \(.value|tostring)"' "$pf" 2>/dev/null
else
  echo
  echo "No .claude/r-project-policy.json found -- policy-driven guards are inactive."
  echo "Run /r-project-core:project-policy to create one."
fi

# --- how defects get fixed --------------------------------------------------
# A workaround at the call site leaves the defect for the next caller. The rule is
# stated here, every session, because it is broken mid-task, before any skill loads.
echo
echo "Fixing a defect: name the root cause as file:line before proposing a fix, and fix it"
echo "where it lives -- in the package, with a regression test, not in the calling script."
echo "A second workaround for one symptom means stop and find the cause (skill: root-cause-fixes)."

# --- long-running work that is NOT ours -------------------------------------
pats="$(policy_list '.longRunPatterns' | paste -sd'|' -)"
[ -z "$pats" ] && pats='tar_make|DEoptim|spades|landis|Omniscape|julia'
procs="$(list_procs "$pats" "${USER:-$(id -un)}" | head -8)"
if [ -n "$procs" ]; then
  echo
  echo "### Long-running processes already on this host -- NOT STARTED BY THIS SESSION"
  echo '```'
  while IFS= read -r line; do
    pid="${line%% *}"
    et="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
    printf '%s  [running %s]  %s\n' "$pid" "${et:-?}" "$(printf '%s' "${line#* }" | cut -c1-110)"
  done <<< "$procs"
  echo '```'
  echo "Do NOT signal, kill, or docker-stop any of these. Do not install packages or"
  echo "sync nodes while they run -- that swaps the library out from under them."
fi

# --- containers / screens ---------------------------------------------------
if command -v docker >/dev/null 2>&1; then
  dc="$(docker ps --format '{{.Names}} ({{.Status}})' 2>/dev/null | head -5)"
  [ -n "$dc" ] && { echo; echo "Containers running (NOT yours): $(printf '%s' "$dc" | paste -sd'; ' -)"; }
fi
sc="$(screen -ls 2>/dev/null | grep -cE '^[[:space:]]+[0-9]+\.' || true)"
[ "${sc:-0}" -gt 0 ] && echo "Detached screen sessions: ${sc} (\`screen -ls\` to inspect; do not quit ones you did not start)"

# --- worktree state ---------------------------------------------------------
if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
  echo
  branch="$(git -C "$root" branch --show-current 2>/dev/null)"; [ -z "$branch" ] && branch="(detached or unborn)"
  dirty="$(git -C "$root" status --porcelain 2>/dev/null | head -12)"
  echo "Git: branch \`${branch}\`"
  if [ -n "$dirty" ]; then
    echo
    echo "### Uncommitted changes present BEFORE this session started"
    echo '```'
    printf '%s\n' "$dirty"
    echo '```'
    echo "Another session or the user may own these. Stage explicit paths only; ask"
    echo "before committing anything you did not change."
  fi
  subs="$(git -C "$root" submodule status 2>/dev/null | grep -cE '^[+-]' || true)"
  [ "${subs:-0}" -gt 0 ] && echo "WARNING: ${subs} submodule pointer(s) differ from the recorded SHA (\`git submodule status\`)."
fi

exit 0
