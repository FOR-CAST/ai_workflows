#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/session-context.sh"
}

teardown() {
  [ -n "${FAKE_RUN_PID:-}" ] && kill "$FAKE_RUN_PID" 2>/dev/null
  return 0
}

@test "prints the host and says when no policy is present" {
  run "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^Host: $(hostname -s)"
  echo "$output" | grep -q 'No .claude/r-project-policy.json found'
}

@test "labels a listed control node" {
  with_policy "{\"controllerHosts\": [\"other\", \"$(hostname -s)\"]}"
  run "$G" </dev/null
  echo "$output" | grep -q 'CONTROL NODE'
}

@test "lists long-running processes with their command lines" {
  with_policy '{"longRunPatterns": ["sleep 3002"]}'
  sleep 3002 &
  FAKE_RUN_PID=$!
  run "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^$FAKE_RUN_PID .*sleep 3002"
}

@test "does not abort when USER is unset" {
  run env -u USER "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^Git:\|No .claude/r-project-policy.json found'
}
