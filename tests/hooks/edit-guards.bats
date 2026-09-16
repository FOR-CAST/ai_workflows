#!/usr/bin/env bats
#
# PreToolUse(Edit|Write) guards: guard-ascii.sh and guard-generated-files.sh

load helpers

setup() {
  isolate_project
}

## ------------------------------------------------------------ guard-ascii --

@test "non-ASCII in an R file is denied with the code point" {
  hook "$CORE/guard-ascii.sh" "$(write_payload R/fit.R "x <- 1 $(printf '\xe2\x80\x94') 2")"
  [ "$(decision)" = deny ]
  reason | grep -q 'U+2014'
}

@test "ASCII-only R is allowed" {
  hook "$CORE/guard-ascii.sh" "$(write_payload R/fit.R 'x <- 1 -- 2')"
  [ -z "$output" ]
}

@test "prose markdown is exempt from the ASCII rule" {
  hook "$CORE/guard-ascii.sh" "$(write_payload notes.md "a $(printf '\xe2\x80\x94') b")"
  [ -z "$output" ]
}

## -------------------------------------------------- guard-generated-files --

@test "hand-edits to roxygen output are denied" {
  hook "$CORE/guard-generated-files.sh" "$(write_payload pkg/man/fit.Rd 'x')"
  [ "$(decision)" = deny ]
  hook "$CORE/guard-generated-files.sh" "$(write_payload pkg/NAMESPACE 'x')"
  [ "$(decision)" = deny ]
}

@test "hand-edits to renv.lock and the targets store are denied" {
  hook "$CORE/guard-generated-files.sh" "$(write_payload proj/renv.lock '{}')"
  [ "$(decision)" = deny ]
  hook "$CORE/guard-generated-files.sh" "$(write_payload proj/_targets/meta/meta 'x')"
  [ "$(decision)" = deny ]
}

@test "README.md is guarded only when a knitted source sits beside it" {
  d="$BATS_TEST_TMPDIR/readme"
  mkdir -p "$d"
  hook "$CORE/guard-generated-files.sh" "$(write_payload "$d/README.md" 'x')"
  [ -z "$output" ]
  touch "$d/README.Rmd"
  hook "$CORE/guard-generated-files.sh" "$(write_payload "$d/README.md" 'x')"
  [ "$(decision)" = deny ]
}

@test "ordinary R sources are not guarded" {
  hook "$CORE/guard-generated-files.sh" "$(write_payload pkg/R/fit.R 'x')"
  [ -z "$output" ]
}

## ---------------------------------------------------- advise-bash-hygiene --

@test "a leading cd gets a note" {
  bash_hook "$CORE/advise-bash-hygiene.sh" 'cd R && ls'
  context | grep -q "starts with 'cd'"
}

@test "a long command on the default timeout gets a note; in the background it does not" {
  bash_hook "$CORE/advise-bash-hygiene.sh" "Rscript -e 'targets::tar_make()'"
  context | grep -q 'long-running'
  hook "$CORE/advise-bash-hygiene.sh" "$(jq -nc '{tool_name: "Bash", tool_input: {command: "Rscript -e targets::tar_make()", run_in_background: true}}')"
  [ -z "$output" ]
}

@test "asciiExtensions in the project policy sets which files are covered" {
  with_policy '{"asciiExtensions": ["md"]}'
  hook "$CORE/guard-ascii.sh" "$(write_payload notes.md "a $(printf '\xe2\x80\x94') b")"
  [ "$(decision)" = deny ]
  hook "$CORE/guard-ascii.sh" "$(write_payload R/fit.R "a $(printf '\xe2\x80\x94') b")"
  [ -z "$output" ]
}
