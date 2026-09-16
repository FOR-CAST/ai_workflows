#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-destructive.sh"
}

@test "git reset --hard is denied" {
  bash_hook "$G" 'git reset --hard HEAD~1'
  [ "$status" -eq 0 ]
  [ "$(decision)" = deny ]
}

@test "extra whitespace does not evade a deny" {
  bash_hook "$G" 'git   reset    --hard'
  [ "$(decision)" = deny ]
}

@test "whole-tree restore is denied, a named path is not" {
  bash_hook "$G" 'git restore .'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git restore R/fit.R'
  [ "$(decision)" = none ]
}

@test "git clean -fdx is denied, a dry run is not" {
  bash_hook "$G" 'git clean -fdx'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git clean -nd'
  [ "$(decision)" = none ]
}

@test "bare force push is denied in any position" {
  bash_hook "$G" 'git push --force origin main'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git push origin main --force'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git push -f origin main'
  [ "$(decision)" = deny ]
}

@test "force-with-lease is allowed" {
  bash_hook "$G" 'git push --force-with-lease origin main'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "--no-verify is denied" {
  bash_hook "$G" 'git commit --no-verify -m wip'
  [ "$(decision)" = deny ]
}

@test "removing the renv library is denied" {
  bash_hook "$G" 'rm -rf renv/library'
  [ "$(decision)" = deny ]
}

@test "git branch -D is denied, -d is not" {
  bash_hook "$G" 'git branch -D old-feature'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git branch --delete --force old-feature'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git branch -d old-feature'
  [ "$(decision)" = none ]
}

@test "git worktree remove --force is denied, a plain remove is not" {
  bash_hook "$G" 'git worktree remove --force ../wt-feature'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git worktree remove -f ../wt-feature'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'git worktree remove ../wt-feature'
  [ "$(decision)" = none ]
}

@test "creating a branch advises without deciding" {
  bash_hook "$G" 'git checkout -b feature'
  [ "$(decision)" = none ]
  [ -n "$(context)" ]
}

@test "malformed stdin never blocks" {
  run bash -c "printf 'not json' | '$G'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
