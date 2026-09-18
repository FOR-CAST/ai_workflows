#!/usr/bin/env bats
#
# guard-host-names.sh: machine names must not reach anything published.
#
# The guard is OFF unless the repo names its own patterns, and it ASKS rather than
# denying, because a machine name is often an ordinary word in the domain (species,
# place, person). Only a human can tell the two apart.

load helpers

GUARD() { echo "$CORE/guard-host-names.sh"; }

POLICY='{"hostPatterns": ["nodeone", "nodetwo"]}'

# A git repo carrying the policy, one committed file, and a .gitignore.
with_host_project() {
  with_policy "$POLICY"
  git -C "$CLAUDE_PROJECT_DIR" config user.email t@example.com
  git -C "$CLAUDE_PROJECT_DIR" config user.name Test
  printf '_hosts.R\n_tmp_*.md\n' > "$CLAUDE_PROJECT_DIR/.gitignore"
  printf 'x <- 1\n' > "$CLAUDE_PROJECT_DIR/code.R"
  git -C "$CLAUDE_PROJECT_DIR" add .gitignore code.R
  git -C "$CLAUDE_PROJECT_DIR" commit -qm init
}

# stage <file> <content>
stage() {
  printf '%s\n' "$2" > "$CLAUDE_PROJECT_DIR/$1"
  git -C "$CLAUDE_PROJECT_DIR" add "$1"
}

## ------------------------------------------------------------------- off --

@test "silent when the repo declares no patterns" {
  isolate_project
  bash_hook "$(GUARD)" 'git commit -m "fix the run on nodeone"'
  [ "$(decision)" = none ]
}

@test "silent on an empty or malformed payload" {
  isolate_project
  hook "$(GUARD)" ''
  [ "$(decision)" = none ]
  hook "$(GUARD)" 'not json'
  [ "$(decision)" = none ]
}

## -------------------------------------------------------- commit messages --

@test "asks when a commit message names a machine" {
  with_host_project
  bash_hook "$(GUARD)" 'git commit -m "rerun on nodeone after the oom"'
  [ "$(decision)" = ask ]
  [[ "$(reason)" == *nodeone* ]]
}

@test "matches regardless of case" {
  with_host_project
  bash_hook "$(GUARD)" 'git commit -m "rerun on NodeOne"'
  [ "$(decision)" = ask ]
}

@test "passes a clean commit message" {
  with_host_project
  bash_hook "$(GUARD)" 'git commit -m "rerun on a compute node after the oom"'
  [ "$(decision)" = none ]
}

@test "reads --message= and -F alike" {
  with_host_project
  bash_hook "$(GUARD)" 'git commit --message="ran on nodetwo"'
  [ "$(decision)" = ask ]
}

## ------------------------------------------------------------- publishing --

@test "asks when a PR body names a machine" {
  with_host_project
  bash_hook "$(GUARD)" 'gh pr create --title "speed up" --body "measured on nodetwo"'
  [ "$(decision)" = ask ]
}

@test "asks when an issue comment names a machine" {
  with_host_project
  bash_hook "$(GUARD)" 'gh issue comment 12 --body "reproduced on nodeone"'
  [ "$(decision)" = ask ]
}

## ------------------------------------------------------------ ssh targets --

@test "an ssh target is not a published name" {
  with_host_project
  bash_hook "$(GUARD)" 'ssh nodeone "hostname -s"'
  [ "$(decision)" = none ]
}

@test "an ssh target with a clean commit message still passes" {
  with_host_project
  bash_hook "$(GUARD)" 'ssh nodeone "cd repo && git commit -m \"fix the seed\""'
  [ "$(decision)" = none ]
}

## --------------------------------------------------------- staged content --

@test "asks when staged content names a machine, and says which file" {
  with_host_project
  stage notes.R '## ran on nodeone'
  bash_hook "$(GUARD)" 'git commit'
  [ "$(decision)" = ask ]
  [[ "$(reason)" == *notes.R* ]]
}

@test "ignores staged content in a gitignored file" {
  with_host_project
  printf 'nodes <- c("nodeone")\n' > "$CLAUDE_PROJECT_DIR/_hosts.R"
  bash_hook "$(GUARD)" 'git commit'
  [ "$(decision)" = none ]
}

@test "passes a clean staged diff" {
  with_host_project
  stage notes.R '## ran on a compute node'
  bash_hook "$(GUARD)" 'git commit'
  [ "$(decision)" = none ]
}

@test "does not scan the staged diff for commands that do not commit" {
  with_host_project
  stage notes.R '## ran on nodeone'
  bash_hook "$(GUARD)" 'git status'
  [ "$(decision)" = none ]
}

## ---------------------------------------------------------- file contents --

@test "asks before writing a machine name into a tracked file" {
  with_host_project
  hook "$(GUARD)" "$(write_payload "$CLAUDE_PROJECT_DIR/code.R" '# runs on nodeone')"
  [ "$(decision)" = ask ]
}

@test "allows a machine name in a gitignored file" {
  with_host_project
  hook "$(GUARD)" "$(write_payload "$CLAUDE_PROJECT_DIR/_hosts.R" 'nodes <- c("nodeone")')"
  [ "$(decision)" = none ]
}

@test "allows a machine name in a gitignored draft" {
  with_host_project
  hook "$(GUARD)" "$(write_payload "$CLAUDE_PROJECT_DIR/_tmp_notes.md" 'ran on nodeone')"
  [ "$(decision)" = none ]
}

@test "ignores files outside any repository" {
  with_host_project
  hook "$(GUARD)" "$(write_payload "$BATS_TEST_TMPDIR/loose.R" '# nodeone')"
  [ "$(decision)" = none ]
}

@test "covers an Edit new_string and a multi-edit" {
  with_host_project
  hook "$(GUARD)" "$(jq -nc --arg f "$CLAUDE_PROJECT_DIR/code.R" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $f, old_string: "x <- 1", new_string: "x <- 1 # nodetwo"}}')"
  [ "$(decision)" = ask ]

  hook "$(GUARD)" "$(jq -nc --arg f "$CLAUDE_PROJECT_DIR/code.R" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "b"},
                                          {old_string: "c", new_string: "# nodeone"}]}}')"
  [ "$(decision)" = ask ]
}

@test "passes clean file content" {
  with_host_project
  hook "$(GUARD)" "$(write_payload "$CLAUDE_PROJECT_DIR/code.R" '# runs on a compute node')"
  [ "$(decision)" = none ]
}

## ------------------------------------------------------------- session env --

@test "FORCAST_HOST_PATTERNS works without a policy file" {
  isolate_project
  FORCAST_HOST_PATTERNS='nodeone nodetwo' bash_hook "$(GUARD)" 'git commit -m "on nodetwo"'
  [ "$(decision)" = ask ]
}

@test "FORCAST_HOST_PATTERNS overrides the policy file" {
  with_host_project
  FORCAST_HOST_PATTERNS='nodethree' bash_hook "$(GUARD)" 'git commit -m "on nodeone"'
  [ "$(decision)" = none ]
  FORCAST_HOST_PATTERNS='nodethree' bash_hook "$(GUARD)" 'git commit -m "on nodethree"'
  [ "$(decision)" = ask ]
}
