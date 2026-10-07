#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/session-context.sh"
}

teardown() {
  [ -n "${FAKE_RUN_PID:-}" ] && kill "$FAKE_RUN_PID" 2>/dev/null
  [ -n "${OTHER_RUN_PID:-}" ] && kill "$OTHER_RUN_PID" 2>/dev/null
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

@test "labels each run with its project, and in an renv project only its own runs block installs" {
  [ -d /proc ] || skip "needs /proc to tell projects apart"
  with_policy '{"longRunPatterns": ["sleep 3002"]}'
  mkdir -p "$CLAUDE_PROJECT_DIR/renv" "$BATS_TEST_TMPDIR/other"
  echo '{}' > "$CLAUDE_PROJECT_DIR/renv.lock"
  : > "$CLAUDE_PROJECT_DIR/renv/activate.R"
  git -C "$BATS_TEST_TMPDIR/other" init -q
  (cd "$CLAUDE_PROJECT_DIR" && exec sleep 3002) &
  FAKE_RUN_PID=$!
  (cd "$BATS_TEST_TMPDIR/other" && exec sleep 3002) &
  OTHER_RUN_PID=$!
  run "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "^$FAKE_RUN_PID .*this project.*sleep 3002"
  echo "$output" | grep -q "^$OTHER_RUN_PID .*other: other.*sleep 3002"
  echo "$output" | grep -q 'while a run of THIS project is live'
}

@test "states the root-cause rule and names the skill that carries it" {
  run "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'root-cause-fixes'
  echo "$output" | grep -q 'file:line'
}

@test "does not abort when USER is unset" {
  run env -u USER "$G" </dev/null
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^Git:\|No .claude/r-project-policy.json found'
}
