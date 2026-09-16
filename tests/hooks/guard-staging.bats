#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-staging.sh"
}

@test "whole-tree staging is denied" {
  for c in 'git add -A' 'git add --all' 'git add .' 'git add -u' 'git add --update'; do
    bash_hook "$G" "$c"
    [ "$(decision)" = deny ] || { echo "not denied: $c"; return 1; }
  done
}

@test "commit -a and -am are denied" {
  bash_hook "$G" 'git commit -a -m wip'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git commit -am wip'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git commit --all -m wip'
  [ "$(decision)" = deny ]
}

@test "staging named paths and plain commits are allowed" {
  bash_hook "$G" 'git add R/fit.R tests/testthat/test-fit.R'
  [ -z "$output" ]
  bash_hook "$G" 'git commit -m "add all the things"'
  [ -z "$output" ]
  bash_hook "$G" 'git commit --amend --no-edit'
  [ -z "$output" ]
}
