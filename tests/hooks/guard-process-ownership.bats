#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-process-ownership.sh"
}

@test "pkill and killall are denied" {
  bash_hook "$G" 'pkill -f tar_make'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'killall R'
  [ "$(decision)" = deny ]
}

@test "kill -9 is denied, kill -TERM is not" {
  bash_hook "$G" 'kill -9 12345'
  [ "$(decision)" = deny ]
  bash_hook "$G" 'kill -TERM 12345'
  [ "$(decision)" = none ]
}

@test "docker stop is denied and the reason names the subcommand" {
  bash_hook "$G" 'docker stop landis-run-3'
  [ "$(decision)" = deny ]
  reason | grep -q "'docker stop'"
}

@test "service stops are denied" {
  bash_hook "$G" 'systemctl stop rstudio-server'
  [ "$(decision)" = deny ]
}

@test "an owner-verified marker lets the command through" {
  bash_hook "$G" 'kill -9 12345   # owner-verified: launched by this session'
  [ -z "$output" ]
}

@test "read-only process inspection is allowed" {
  bash_hook "$G" 'ps -o pid,user,lstart,cmd -p 12345'
  [ -z "$output" ]
}
