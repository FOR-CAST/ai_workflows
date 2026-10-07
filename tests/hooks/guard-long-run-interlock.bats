#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-long-run-interlock.sh"
  export FORCAST_LONGRUN_PATTERNS='sleep 3001'
}

# start_fake_run [dir]: a stand-in long run, by default outside the project.
start_fake_run() {
  local dir="${1:-$BATS_TEST_TMPDIR}"
  mkdir -p "$dir"
  (cd "$dir" && exec sleep 3001) &
  FAKE_RUN_PID=$!
}

stop_fake_run() {
  kill "$FAKE_RUN_PID"
  wait "$FAKE_RUN_PID" 2>/dev/null || true
}

# Telling one project's runs from another's reads /proc; without it (macOS) every
# run counts, so a test that expects a run elsewhere to be ignored cannot pass.
needs_proc() {
  [ -d /proc ] || skip "needs /proc to tell projects apart"
}

# renv_repo <dir>: a git repo that keeps its own renv library.
renv_repo() {
  mkdir -p "$1/renv"
  git -C "$1" init -q
  echo '{}' > "$1/renv.lock"
  : > "$1/renv/activate.R"
}

# bash_hook_in <cwd> <command>: a payload whose session cwd is <cwd>
bash_hook_in() {
  hook "$G" "$(jq -nc --arg d "$1" --arg c "$2" \
    '{hook_event_name: "PreToolUse", tool_name: "Bash", cwd: $d, tool_input: {command: $c}}')"
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

# --- an renv project: only its own runs block --------------------------------

@test "in an renv project, a run in the project or a subdirectory blocks an install" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "$CLAUDE_PROJECT_DIR"
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q 'a long run of the project at'
  stop_fake_run
  start_fake_run "$CLAUDE_PROJECT_DIR/reports"
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
}

@test "in an renv project, a run in another project does not block an install" {
  needs_proc
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "$BATS_TEST_TMPDIR/other-project"
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\", rebuild = FALSE)'"
  [ -z "$output" ]
}

@test "in an renv project, a run in a sibling sharing its name prefix does not block" {
  needs_proc
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "${CLAUDE_PROJECT_DIR}-other"
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ -z "$output" ]
}

@test "a worker outside the repo that inherited RENV_PROJECT for it blocks an install" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  mkdir -p "$BATS_TEST_TMPDIR/scenario"
  (cd "$BATS_TEST_TMPDIR/scenario" && RENV_PROJECT="$CLAUDE_PROJECT_DIR" exec sleep 3001) &
  FAKE_RUN_PID=$!
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
}

# --- changes that reach past one project library -----------------------------

@test "renv::purge and rebuild are checked against runs in every project" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "$BATS_TEST_TMPDIR/other-project"
  bash_hook "$G" "Rscript -e 'renv::purge(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q 'shared renv cache'
  bash_hook "$G" "Rscript -e 'renv::rebuild(\"sf\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\", rebuild = TRUE)'"
  [ "$(decision)" = deny ]
}

@test "in a repo without renv, a run in another project blocks an install" {
  start_fake_run "$BATS_TEST_TMPDIR/other-project"
  bash_hook "$G" "Rscript -e 'install.packages(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q 'no renv library'
}

@test "R started with --vanilla -e is checked against runs in every project" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "$BATS_TEST_TMPDIR/other-project"
  bash_hook "$G" "Rscript --vanilla -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
}

# --- which project the command targets ---------------------------------------

@test "a cd into another renv project is checked against that project's runs" {
  needs_proc
  renv_repo "$CLAUDE_PROJECT_DIR"
  B="$BATS_TEST_TMPDIR/b"
  renv_repo "$B"
  start_fake_run "$B"
  bash_hook "$G" "cd ../b && Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q "$B"
  stop_fake_run
  start_fake_run "$CLAUDE_PROJECT_DIR"
  bash_hook "$G" "cd \"$B\" && Rscript -e 'renv::install(\"sf\")'"
  [ -z "$output" ]
  HOME="$BATS_TEST_TMPDIR" bash_hook "$G" "cd ~/b && Rscript -e 'renv::install(\"sf\")'"
  [ -z "$output" ]
}

@test "the session cwd from the payload sets the target project" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  B="$BATS_TEST_TMPDIR/b"
  renv_repo "$B"
  start_fake_run "$B"
  bash_hook_in "$B" "Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
}

@test "a directory change the hook cannot follow is checked against every project" {
  renv_repo "$CLAUDE_PROJECT_DIR"
  start_fake_run "$BATS_TEST_TMPDIR/other-project"
  bash_hook "$G" "Rscript -e 'setwd(\"/elsewhere\"); renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  reason | grep -q 'could not be determined'
  bash_hook "$G" "cd \"\$OTHER\" && Rscript -e 'renv::install(\"sf\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'renv::install(\"sf\", project = \"/elsewhere\")'"
  [ "$(decision)" = deny ]
}
