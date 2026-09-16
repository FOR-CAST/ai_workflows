#!/usr/bin/env bash
# Shared helper: locate and read the per-project policy file.
#
# These guardrails ship the MECHANISM; each repo declares its own POLICY, because
# the corpus contains genuine, deliberate contradictions between projects (air
# format is mandatory in most repos and forbidden in a few; R is pinned to
# different versions; some projects use renv exclusively and others do not).
# Hardcoding either side would be wrong somewhere.
#
# Policy file, searched upward from $CLAUDE_PROJECT_DIR then cwd:
#   .claude/r-project-policy.json
# Every key is optional; an absent file means "no opinion", and only the
# universally-safe guards stay active.

# Canonical repo root. Repos here are reachable under more than one path (parts of
# ~/GitHub are symlinks into other directories), so identifying a repo by the raw
# cwd string gives different answers depending on which path the session was opened
# from -- and a policy lookup, an air opt-out, or a control-node check would then
# silently disagree with itself. Always resolve through git, then readlink -f.
repo_root() {
  local d top
  d="${CLAUDE_PROJECT_DIR:-$PWD}"
  top="$(git -C "$d" rev-parse --show-toplevel 2>/dev/null)" || top="$d"
  readlink -f "$top" 2>/dev/null || printf '%s' "$top"
}

policy_file() {
  local d
  d="$(repo_root)"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    [ -f "$d/.claude/r-project-policy.json" ] && { printf '%s' "$d/.claude/r-project-policy.json"; return 0; }
    d="$(dirname "$d")"
  done
  return 1
}

# policy_get <jq-path> [default]
policy_get() {
  local f; f="$(policy_file)" || { printf '%s' "${2-}"; return 0; }
  local v; v="$(jq -r "$1 // empty" "$f" 2>/dev/null)"
  [ -z "$v" ] && v="${2-}"
  printf '%s' "$v"
}

# policy_list <jq-path>  -> newline-separated
policy_list() {
  local f; f="$(policy_file)" || return 0
  jq -r "$1 // [] | .[]" "$f" 2>/dev/null
}

# Word boundary for `grep -E`. `\b` is a GNU extension; BSD grep on macOS does not
# promise it. Unlike `\b` this consumes a character, so put it only at the END of a
# pattern (or before an alternative that does not start with a space).
# shellcheck disable=SC2034  # used by the scripts that source this file
B='([^[:alnum:]_]|$)'

# list_procs <regex> [user]  ->  "PID ARGS" per matching process.
# `pgrep -a` is Linux-only (on BSD/macOS -a means "include ancestors" and prints
# no command line), so collect PIDs with pgrep and read the command line with ps.
list_procs() {
  local pids
  if [ -n "${2-}" ]; then
    pids="$(pgrep -d, -u "$2" -f "$1" 2>/dev/null)"
  else
    pids="$(pgrep -d, -f "$1" 2>/dev/null)"
  fi
  [ -z "$pids" ] && return 0
  ps -o pid=,args= -p "$pids" 2>/dev/null | sed 's/^ *//' | grep -v pgrep
}

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r}}'
  exit 0
}

advise() {
  jq -n --arg c "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $c}}'
  exit 0
}

# Force a permission prompt for the USER (not the model). Used for actions that are
# legitimate once a person has looked -- a hook "deny" cannot be approved from the
# prompt, so a gate that should end in "yes, go ahead" must ask rather than deny.
# The reason text is shown to the user; it is not shown to the model.
ask_user() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason: $r}}'
  exit 0
}
