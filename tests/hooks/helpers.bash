# Shared helpers for the hook test suite.
#
# Every hook reads a Claude Code hook payload (JSON) on stdin and writes either
# nothing, or a JSON decision on stdout. These helpers build payloads and read the
# decision back, so each test states one command and one expected outcome.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
CORE="$REPO_ROOT/plugins/r-project-core/scripts"
PKGDEV="$REPO_ROOT/plugins/r-package-dev/scripts"

# Hermetic by default: no policy file is reachable unless a test creates one.
isolate_project() {
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CLAUDE_PROJECT_DIR"
}

# with_policy '<json>': a git repo carrying .claude/r-project-policy.json
with_policy() {
  export CLAUDE_PROJECT_DIR="$BATS_TEST_TMPDIR/policy-project"
  mkdir -p "$CLAUDE_PROJECT_DIR/.claude"
  git -C "$CLAUDE_PROJECT_DIR" init -q
  printf '%s\n' "$1" > "$CLAUDE_PROJECT_DIR/.claude/r-project-policy.json"
}

bash_payload() {
  jq -nc --arg c "$1" '{hook_event_name: "PreToolUse", tool_name: "Bash", tool_input: {command: $c}}'
}

# write_payload <file_path> <content>
write_payload() {
  jq -nc --arg f "$1" --arg t "$2" '{hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: $t}}'
}

# tool_payload <tool_name>: e.g. an MCP tool call
tool_payload() {
  jq -nc --arg t "$1" '{hook_event_name: "PreToolUse", tool_name: $t, tool_input: {}}'
}

# hook <script> <payload>: run a hook the way Claude Code does
hook() {
  run "$1" <<<"$2"
}

# bash_hook <script> <command>
bash_hook() {
  hook "$1" "$(bash_payload "$2")"
}

decision() {
  if [ -z "$output" ]; then
    echo none
  else
    jq -r '.hookSpecificOutput.permissionDecision // "none"' <<<"$output"
  fi
}

reason() {
  jq -r '.hookSpecificOutput.permissionDecisionReason // empty' <<<"$output"
}

context() {
  jq -r '.hookSpecificOutput.additionalContext // empty' <<<"$output"
}
