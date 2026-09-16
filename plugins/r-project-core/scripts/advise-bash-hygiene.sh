#!/usr/bin/env bash
# PreToolUse(Bash), non-blocking: two mechanical failure modes that together
# account for thousands of wasted tool calls in the record.
#
#   * `cd` at the start of a command -- the shell's cwd does not persist between
#     tool calls, so the next command silently runs somewhere else. This produced
#     ~3,000 "Shell cwd was reset" events, and `cd` is the single most common
#     first token in the corpus.
#   * a long-running command with the default 2-minute timeout, which then dies
#     at exactly 2m and looks like a hang or a crash.
set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0
tmo="$(printf '%s' "$payload" | jq -r '.tool_input.timeout // 0' 2>/dev/null)"
bg="$(printf '%s' "$payload" | jq -r '.tool_input.run_in_background // false' 2>/dev/null)"

notes=""

if printf '%s' "$cmd" | grep -Eq '^[[:space:]]*cd '; then
  notes="${notes}- This command starts with 'cd'. The working directory does NOT persist to the
  next Bash call, so anything you run afterwards may silently execute elsewhere.
  Prefer absolute paths, 'git -C <dir> ...', 'make -C <dir>', or keep the 'cd' and
  the work in one compound command.
"
fi

if [ "$bg" != "true" ] && [ "${tmo:-0}" -lt 600000 ] 2>/dev/null; then
  if printf '%s' "$cmd" | grep -Eq 'tar_make|tar_destroy|devtools::(check|install)|R CMD check|renv::(restore|install|rebuild)|quarto +render|quarto_render|docker +(build|run)|julia |spades\(|simInitAndSpades'; then
    notes="${notes}- This is a long-running command and the Bash timeout is still the default.
  It will be killed mid-run and the failure will look like a crash. Either pass a
  larger 'timeout' (up to 600000 ms) or set run_in_background: true and poll.
"
  fi
fi

[ -z "$notes" ] && exit 0
jq -n --arg c "Bash hygiene:
$notes" '{hookSpecificOutput: {hookEventName: "PreToolUse", additionalContext: $c}}'
exit 0
