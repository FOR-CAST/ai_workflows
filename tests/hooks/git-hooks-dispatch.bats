#!/usr/bin/env bats
#
# The git hook dispatcher the project-config-layout skill ships: pre-commit and
# pre-merge-commit refuse a staged private key or service-account key, pre-push refuses
# to publish a commit that adds one, and every hook then runs the repository's own hook
# of the same name.
#
# Fixture keys are built with printf so that this file holds no key header itself.

load helpers

setup() {
  ASSETS="$REPO_ROOT/plugins/r-project-core/skills/project-config-layout/assets"
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  H="$BATS_TEST_TMPDIR/hooks"
  mkdir -p "$H"
  cp "$ASSETS/dispatch" "$H/dispatch"
  for h in pre-commit pre-merge-commit pre-push; do ln -s dispatch "$H/$h"; done
  REMOTE="$BATS_TEST_TMPDIR/remote.git"
  git init -q --bare "$REMOTE"
  R="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$R"
  git -C "$R" config user.email t@example.com
  git -C "$R" config user.name Test
  git -C "$R" config core.hooksPath "$H"
  git -C "$R" remote add origin "$REMOTE"
  ZERO=0000000000000000000000000000000000000000
}

pem() {
  printf -- '-----BEGIN %s-----\nMIIBfake\n-----END %s-----\n' "$1" "$1" > "$2"
}

# commit_file <file> <text>
commit_file() {
  printf '%s\n' "$2" > "$R/$1"
  git -C "$R" add "$1"
  git -C "$R" commit -qm "$1"
}

# commit_key <file>: commit a private key past the pre-commit check
commit_key() {
  pem 'PRIVATE KEY' "$R/$1"
  git -C "$R" add "$1"
  git -C "$R" commit -q --no-verify -m "$1"
}

# import <n> [<k>]: n commits on main, by fast-import; commit k adds a key at the start
# of a 200 KB file
import() {
  local n=$1 k=${2:-0} i from=""
  git -C "$R" rev-parse -q --verify refs/heads/main >/dev/null && from="from refs/heads/main^0"
  for ((i = 1; i <= n; i++)); do
    printf 'commit refs/heads/main\ncommitter T <t@example.com> %d +0000\ndata <<EOM\nc%d\nEOM\n' \
      $((1700000000 + i)) "$i"
    [ "$i" -eq 1 ] && [ -n "$from" ] && printf '%s\n' "$from"
    printf 'M 644 inline notes.txt\ndata <<EOM\nline %d\nEOM\n' "$i"
    if [ "$i" -eq "$k" ]; then
      printf 'M 644 inline deep/big.bin\ndata <<EOM\n'
      printf -- '-----BEGIN %s-----\n' 'PRIVATE KEY'
      head -c 200000 /dev/zero | tr '\0' 'x'
      printf '\nEOM\n'
    fi
    printf '\n'
  done | git -C "$R" fast-import --quiet
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

## --------------------------------------------------------------- pre-push --

@test "pre-push hands git's ref lines and arguments on to the repository's own hook" {
  commit_file a.txt a
  printf '#!/bin/sh\necho "$1 $2" > "%s/args"\ncat > "%s/refs"\n' "$BATS_TEST_TMPDIR" "$BATS_TEST_TMPDIR" \
    > "$R/.git/hooks/pre-push"
  chmod +x "$R/.git/hooks/pre-push"
  run git -C "$R" push -q origin main
  [ "$status" -eq 0 ]
  [ "$(cat "$BATS_TEST_TMPDIR/args")" = "origin $REMOTE" ]
  [ "$(cat "$BATS_TEST_TMPDIR/refs")" = "refs/heads/main $(git -C "$R" rev-parse HEAD) refs/heads/main $ZERO" ]
}

@test "pre-push refuses a key committed with --no-verify" {
  commit_file a.txt a
  commit_key id_rsa
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *id_rsa* ]]
  ! git -C "$REMOTE" rev-parse -q --verify refs/heads/main
}

@test "pre-push refuses a key that arrived by a fast-forward merge" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  git -C "$R" switch -q -c side
  commit_key side.key
  git -C "$R" switch -q main
  git -C "$R" merge -q --ff-only side
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
}

@test "pre-push refuses a key that only a merge commit adds" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  git -C "$R" switch -q -c side
  commit_file s.txt s
  git -C "$R" switch -q main
  commit_file b.txt b
  git -C "$R" merge -q --no-commit side
  pem 'PRIVATE KEY' "$R/merge.key"
  git -C "$R" add merge.key
  git -C "$R" commit -q --no-verify --no-edit
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *merge.key* ]]
}

@test "pre-push refuses a key amended into a force-push" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  pem 'PRIVATE KEY' "$R/k.txt"
  git -C "$R" add k.txt
  git -C "$R" commit -q --amend --no-verify --no-edit
  run git -C "$R" push -q --force origin main
  [ "$status" -ne 0 ]
}

@test "pre-push checks a pushed tag" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  commit_key t.key
  git -C "$R" tag -a -m v1 v1
  run git -C "$R" push -q origin v1
  [ "$status" -ne 0 ]
}

@test "pre-push finds a key in a large file deep in a 200-commit push" {
  ## as on CI runners, where an early-exiting reader leaves the writer an error to report
  trap '' PIPE
  commit_file a.txt a
  git -C "$R" push -q origin main
  import 200 37
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *deep/big.bin* ]]
}

@test "pre-push checks only what the remote lacks, on a new branch too" {
  commit_key old.key
  git -C "$R" push -q --no-verify origin main
  git -C "$R" fetch -q origin
  git -C "$R" switch -q -c feature
  commit_file a.txt a
  run git -C "$R" push -q origin feature
  [ "$status" -eq 0 ]
}

@test "pre-push lets a branch deletion through" {
  commit_file a.txt a
  git -C "$R" push -q origin main main:gone
  run git -C "$R" push -q origin :gone
  [ "$status" -eq 0 ]
}

@test "pre-push sees a root commit's diff whatever log.showRoot says" {
  git -C "$R" config log.showRoot false
  commit_key first.key
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
}

@test "pre-push sees a merge-only key whatever log.diffMerges says" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  git -C "$R" switch -q -c side
  commit_file s.txt s
  git -C "$R" switch -q main
  commit_file b.txt b
  git -C "$R" merge -q --no-commit side
  printf '%s-%s: ssh-ed25519\nEncryption: none\n' PuTTY User-Key-File-3 > "$R/merge.ppk"
  git -C "$R" add merge.ppk
  git -C "$R" commit -q --no-verify --no-edit
  for m in off combined dense-combined; do
    git -C "$R" config log.diffMerges "$m"
    run git -C "$R" push -q origin main
    [ "$status" -ne 0 ] || { echo "pushed under log.diffMerges=$m"; return 1; }
  done
}

@test "pre-push checks the commit a push sends, not a replacement" {
  commit_file a.txt a
  git -C "$R" push -q origin main
  commit_key k.key
  clean="$(git -C "$R" commit-tree "$(git -C "$R" rev-parse 'HEAD~1^{tree}')" -p HEAD~1 -m clean)"
  git -C "$R" replace HEAD "$clean"
  run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
}

@test "pre-push refuses when the scan itself fails" {
  commit_file a.txt a
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  printf '#!/bin/sh\ncat >/dev/null\nexit 2\n' > "$BATS_TEST_TMPDIR/bin/awk"
  chmod +x "$BATS_TEST_TMPDIR/bin/awk"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" run git -C "$R" push -q origin main
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not check"* ]]
}

@test "pre-push finds a key on the second of two new branches" {
  commit_file a.txt a
  git -C "$R" switch -q -c side
  commit_key side.key
  git -C "$R" switch -q main
  run git -C "$R" push -q origin main side
  [ "$status" -ne 0 ]
  [[ "$output" == *side.key* ]]
}

@test "pre-push lets 1000 clean commits through quickly" {
  commit_file a.txt a
  import 1000
  start=$SECONDS
  run git -C "$R" push -q origin main
  [ "$status" -eq 0 ]
  [ $((SECONDS - start)) -lt 30 ]
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
