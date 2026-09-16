#!/usr/bin/env bash
# PreToolUse(mcp__.*): ask before an MCP tool that writes, publishes, or runs code,
# when the project requires approval for publishing.
#
# The publish check in guard-policy.sh only sees Bash. An MCP server does the same
# things without a shell command: a GitHub server opens a pull request, a drive
# connector shares a file, an R-session server runs code. MCP tools carry no
# machine-readable read/write flag, so this goes by the verb in the tool's name --
# the FIRST recognised verb decides, so `get_pull_request_review_comments` is a read
# and `btw_tool_run_r` is not. An unrecognised name is let through: this is a
# backstop for publishRequiresApproval, not a sandbox.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

tool="$(cat | jq -r '.tool_name // empty' 2>/dev/null)"
case "$tool" in mcp__*) ;; *) exit 0 ;; esac
[ "$(policy_get '.publishRequiresApproval')" = "true" ] || exit 0

## The tool's own name follows the last "__"; the server name may contain verbs.
## camelCase and kebab-case become one lowercase word per line.
words="$(printf '%s' "${tool##*__}" | sed -E 's/([a-z0-9])([A-Z])/\1_\2/g' |
  tr '[:upper:]' '[:lower:]' | tr -- '-_' '\n')"

reads='get|list|search|find|read|fetch|query|view|show|describe|download|lookup|check|count|inspect|status|diff|log|resolve|guide|export'
writes='create|update|delete|remove|trash|merge|push|post|comment|reply|review|submit|publish|send|share|upload|write|edit|patch|put|insert|add|set|commit|close|reopen|approve|fork|transfer|move|rename|invite|run|exec|execute|eval|deploy|trigger|dispatch'

verb="$(printf '%s\n' "$words" | grep -Ex "$reads|$writes" | head -1)"
[ -z "$verb" ] && exit 0
printf '%s' "$verb" | grep -Eqx "$reads" && exit 0

ask_user "Publish check (MCP '$verb'): $tool looks like it writes, publishes or runs code without going through the shell, and this project requires your confirmation first (publishRequiresApproval). Review the call, then approve or deny."
