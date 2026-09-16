#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-long-run-interlock.sh"
  export FORCAST_LONGRUN_PATTERNS='sleep 3001'
}

start_fake_run() {
  sleep 3001 &
  FAKE_RUN_PID=$!
}

teardown() {
  [ -n "${FAKE_RUN_PID:-}" ] && kill "$FAKE_RUN_PID" 2>/dev/null
  return 0
}

@test "with no live run, a library install is allowed" {
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "a live run blocks renv::install and names the running command" {
  start_fake_run
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q "$FAKE_RUN_PID"
  reason | grep -q 'sleep 3001'
}

@test "a live run blocks pak, Require and SpaDES.project installs" {
  start_fake_run
  bash_hook "$G" "Rscript -e 'pak::pak(\"sf\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'Require::Install(\"LandR\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'SpaDES.project::setupProject()'"
  [ "$(decision)" = deny ]
}

@test "a live run blocks renv::checkout" {
  start_fake_run
  bash_hook "$G" "Rscript -e 'renv::checkout(date = \"2026-01-01\")'"
  [ "$(decision)" = deny ]
}

@test "a live run does not block read-only inspection" {
  start_fake_run
  bash_hook "$G" "Rscript -e 'targets::tar_progress()'"
  [ -z "$output" ]
}

@test "the interlock honours longRunPatterns from the project policy" {
  unset FORCAST_LONGRUN_PATTERNS
  with_policy '{"longRunPatterns": ["sleep 3003"]}'
  sleep 3003 &
  FAKE_RUN_PID=$!
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q 'sleep 3003'
}
