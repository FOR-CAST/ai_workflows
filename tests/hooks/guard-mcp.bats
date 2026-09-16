#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-mcp.sh"
}

mcp_hook() {
  hook "$G" "$(tool_payload "$1")"
}

@test "without publishRequiresApproval, MCP writes are not asked about" {
  mcp_hook mcp__github__create_pull_request
  [ "$status" -eq 0 ]
  [ "$(decision)" = none ]
}

@test "publish policy asks before a snake_case MCP write" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook mcp__github__create_pull_request
  [ "$(decision)" = ask ]
  mcp_hook mcp__claude_ai_Google_Drive__trash_file
  [ "$(decision)" = ask ]
}

@test "publish policy asks before a camelCase MCP write" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook mcp__tracker__addIssueComment
  [ "$(decision)" = ask ]
}

@test "publish policy asks before an MCP tool that runs code" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook mcp__r-btw__btw_tool_run_r
  [ "$(decision)" = ask ]
}

@test "publish policy does not ask for MCP reads" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook mcp__github__get_file_contents
  [ "$(decision)" = none ]
  mcp_hook mcp__claude_ai_Google_Drive__read_file_content
  [ "$(decision)" = none ]
}

@test "a verb in the server name alone does not trigger an ask" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook mcp__post-office__list_items
  [ "$(decision)" = none ]
}

@test "a non-MCP tool is ignored" {
  with_policy '{"publishRequiresApproval": true}'
  mcp_hook Write
  [ -z "$output" ]
}

@test "hooks.json routes MCP tools to guard-mcp.sh" {
  run jq -e '.hooks.PreToolUse[] | select(.matcher == "mcp__.*") | .hooks[].command | select(test("guard-mcp.sh"))' \
    "$REPO_ROOT/plugins/r-project-core/hooks/hooks.json"
  [ "$status" -eq 0 ]
}
