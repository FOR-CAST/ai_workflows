#!/usr/bin/env bats
#
# The git hook dispatcher the project-config-layout skill ships: pre-commit and
# pre-merge-commit refuse a staged private key or service-account key, and every
# hook then runs the repository's own hook of the same name.
#
# Fixture keys are built with printf so that this file holds no key header itself.

load helpers

setup() {
  ASSETS="$REPO_ROOT/plugins/r-project-core/skills/project-config-layout/assets"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  H="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$H"
  cp "$ASSETS/dispatch" "$H/dispatch"
  ln -s dispatch "$H/pre-commit"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q "$R"
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name Test
  git -C "$R" config core.hooksPath "$H"
}

pem() {
  printf -- '-----BEGIN %s-----\nMIIBfake\n-----END %s-----\n' "$1" "$1" > "$2"
}

@test "refuses to commit a private key" {
  pem 'PRIVATE KEY' "$R/notes.txt"
  git -C "$R" add notes.txt
  run git -C "$R" commit -qm notes
  [ "$status" -ne 0 ]
  [[ "$output" == *notes.txt* ]]
}

@test "refuses a service-account key under any name" {
  printf '{"%s": "%s"}\n' type service_account > "$R/1:settings.txt"
  git -C "$R" add -- '1:settings.txt'
  run git -C "$R" commit -qm settings
  [ "$status" -ne 0 ]
}

@test "refuses a PuTTY key" {
  printf '%s-%s: ssh-ed25519\nEncryption: none\n' PuTTY User-Key-File-3 > "$R/id.ppk"
  git -C "$R" add id.ppk
  run git -C "$R" commit -qm ppk
  [ "$status" -ne 0 ]
}

@test "finds a key at the start of a file larger than a pipe buffer" {
  pem 'PRIVATE KEY' "$R/big.txt"
  head -c 200000 /dev/zero | tr '\0' 'x' >> "$R/big.txt"
  git -C "$R" add big.txt
  run git -C "$R" commit -qm big
  [ "$status" -ne 0 ]
}

@test "commits ordinary files and runs the repository's own hook" {
  printf 'x <- 1\n' > "$R/code.R"
  printf '#!/bin/sh\ntouch "%s"\n' "$BATS_TEST_TMPDIR/repo-hook-ran" > "$R/.git/hooks/pre-commit"
  chmod +x "$R/.git/hooks/pre-commit"
  git -C "$R" add code.R
  run git -C "$R" commit -qm code
  [ "$status" -eq 0 ]
  [ -f "$BATS_TEST_TMPDIR/repo-hook-ran" ]
}

@test "neither shipped file matches its own key patterns" {
  run /usr/bin/env grep -Eq \
    -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----' \
    -e '---- BEGIN SSH2 ENCRYPTED PRIVATE [K]EY ----' \
    -e '"type"[[:space:]]*:[[:space:]]*"service_account"' \
    -e '^PuTTY-User-Key-File-[0-9]+:' \
    "$ASSETS/dispatch" "$ASSETS/install.sh" "$CORE/guard-credentials.sh"
  [ "$status" -eq 1 ]
}
