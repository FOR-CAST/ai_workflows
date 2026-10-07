#!/usr/bin/env bats
#
# guard-credentials.sh: keep credential files out of the transcript and out of git.
#
# 1. The Read() deny rules in Claude Code settings already stop the Read tool and a
#    few shell commands (cat, head, tail, sed). The guard applies them to every Bash
#    command, so jq, base64 or an R process cannot print the file either.
# 2. A git add or git commit whose files hold a private key or a service-account key
#    is denied, whatever its file name or .gitignore says.
#
# Fixture keys are built with printf so that this file holds no key header itself:
# a pre-commit hook that scans for one would otherwise refuse to commit it.

load helpers

GUARD() { echo "$CORE/guard-credentials.sh"; }

setup() {
  isolate_project
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME/.config/proj" "$HOME/.claude"
  K="$HOME/.config/proj/drive-sa.json"
}

# deny_rules <settings file> <rule>...: a settings file whose permissions.deny holds the rules
deny_rules() {
  local f="$1"
  shift
  mkdir -p "$(dirname "$f")"
  jq -n '{permissions: {deny: $ARGS.positional}}' --args "$@" > "$f"
}

project_rule() { deny_rules "$CLAUDE_PROJECT_DIR/.claude/settings.json" "$@"; }

# pem <file>: a file holding a private-key header
pem() {
  printf -- '-----BEGIN %s-----\nMIIBfake\n-----END %s-----\n' "$1" "$1" > "$2"
}

# sa_json <file>: a file shaped like a service-account key
sa_json() {
  printf '{"%s": "%s", "project_id": "demo"}\n' type service_account > "$1"
}

# A git repo in the project dir, with one commit.
with_repo() {
  git -C "$CLAUDE_PROJECT_DIR" init -q
  git -C "$CLAUDE_PROJECT_DIR" config user.email t@example.com
  git -C "$CLAUDE_PROJECT_DIR" config user.name Test
  printf 'x <- 1\n' > "$CLAUDE_PROJECT_DIR/code.R"
  git -C "$CLAUDE_PROJECT_DIR" add code.R
  git -C "$CLAUDE_PROJECT_DIR" commit -qm init
}

## ------------------------------------------------------------- off --

@test "silent without Read deny rules" {
  bash_hook "$(GUARD)" "jq . $K"
  [ "$(decision)" = none ]
}

@test "silent on an empty or malformed payload" {
  project_rule 'Read(~/.config/proj/**)'
  hook "$(GUARD)" ''
  [ "$(decision)" = none ]
  hook "$(GUARD)" 'not json'
  [ "$(decision)" = none ]
}

@test "ignores deny rules for other tools" {
  project_rule 'Bash(rm *)' 'Edit(~/.config/proj/**)' 'WebFetch(domain:example.com)'
  bash_hook "$(GUARD)" "jq . $K"
  [ "$(decision)" = none ]
}

## ------------------------------------------------------ reading a key --

@test "denies commands that would print a protected file" {
  project_rule 'Read(~/.config/proj/**)'
  for c in \
    'jq .project_id ~/.config/proj/drive-sa.json' \
    "base64 $K" \
    'xxd "$HOME/.config/proj/drive-sa.json"' \
    'strings ${HOME}/.config/proj/drive-sa.json' \
    "Rscript-4.6.1 -e 'jsonlite::read_json(\"~/.config/proj/drive-sa.json\")'" \
    "python3 -c \"print(open('$K').read())\"" \
    'grep -r private_key ~/.config/proj' \
    'git status && cat ~/.config/proj/drive-sa.json' \
    'printf "%s" "$(cat ~/.config/proj/drive-sa.json)"' \
    'cd ~/.config/proj && cat drive-sa.json'; do
    bash_hook "$(GUARD)" "$c"
    [ "$(decision)" = deny ] || { echo "not denied: $c"; return 1; }
  done
  [[ "$(reason)" == *'Read(~/.config/proj/**)'* ]]
}

@test "lets through commands that only list, check or set permissions" {
  project_rule 'Read(~/.config/proj/**)'
  for c in \
    'ls -l ~/.config/proj' \
    "stat $K" \
    "test -f $K && echo ok" \
    'chmod 600 ~/.config/proj/drive-sa.json' \
    'install -d -m 700 ~/.config/proj' \
    'install -m 600 ~/Downloads/key.json ~/.config/proj/drive-sa.json' \
    'rsync -a --chmod=D700,F600 ~/.config/proj/ node1:.config/proj/' \
    "echo 'GOOGLEDRIVE_AUTH=~/.config/proj/drive-sa.json' > proj.Renviron" \
    'git commit -m "the key lives in ~/.config/proj"' \
    'find ~/.config/proj -name "*.json"'; do
    bash_hook "$(GUARD)" "$c"
    [ "$(decision)" = none ] || { echo "denied: $c"; return 1; }
  done
}

@test "denies copying a protected file out to a local path" {
  project_rule 'Read(~/.config/proj/**)'
  bash_hook "$(GUARD)" 'cp ~/.config/proj/drive-sa.json ./key.json'
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" 'rsync -a ~/.config/proj/ /tmp/proj/'
  [ "$(decision)" = deny ]
}

@test "denies find -exec on a protected folder" {
  project_rule 'Read(~/.config/proj/**)'
  bash_hook "$(GUARD)" 'find ~/.config/proj -name "*.json" -exec cat {} +'
  [ "$(decision)" = deny ]
}

@test "reads the command an ssh call runs remotely" {
  project_rule 'Read(~/.config/proj/**)'
  bash_hook "$(GUARD)" "ssh node1 'cat ~/.config/proj/drive-sa.json'"
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" "ssh -p 2222 -o BatchMode=yes node1 'ls -l ~/.config/proj'"
  [ "$(decision)" = none ]
}

@test "a long heredoc is checked in one pass" {
  project_rule 'Read(~/.config/proj/**)'
  body="$(for i in $(seq 1 2000); do echo "line $i of notes/with/paths.txt and words"; done)"
  start=$SECONDS
  bash_hook "$(GUARD)" "cat > notes.md <<'EOF'
$body
EOF"
  [ "$(decision)" = none ]
  [ $((SECONDS - start)) -lt 5 ]
}

@test "commands that do not name a protected path pass" {
  project_rule 'Read(~/.config/proj/**)'
  bash_hook "$(GUARD)" "Rscript-4.6.1 -e 'targets::tar_make()'"
  [ "$(decision)" = none ]
  bash_hook "$(GUARD)" 'cat ~/.config/proj-other/notes.txt'
  [ "$(decision)" = none ]
}

## ----------------------------------------------------- rule semantics --

@test "a rule naming a folder covers the files in it" {
  project_rule 'Read(~/.config/proj)'
  bash_hook "$(GUARD)" "jq . $K"
  [ "$(decision)" = deny ]
}

@test "single-segment globs stay within their segment" {
  deny_rules "$HOME/.claude/settings.json" 'Read(~/.ssh/id_*)'
  bash_hook "$(GUARD)" 'base64 ~/.ssh/id_ed25519'
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" 'base64 ~/.ssh/config'
  [ "$(decision)" = none ]
}

@test "reads user settings as well as project and local settings" {
  deny_rules "$HOME/.claude/settings.json" 'Read(//srv/keys/**)'
  bash_hook "$(GUARD)" 'jq . /srv/keys/a.json'
  [ "$(decision)" = deny ]
  deny_rules "$CLAUDE_PROJECT_DIR/.claude/settings.local.json" 'Read(~/.aws/credentials)'
  bash_hook "$(GUARD)" 'awk 1 ~/.aws/credentials'
  [ "$(decision)" = deny ]
}

@test "a /path rule in project settings anchors at the project" {
  project_rule 'Read(/secrets/**)'
  bash_hook "$(GUARD)" "jq . $CLAUDE_PROJECT_DIR/secrets/a.json"
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" 'jq . /secrets/a.json'
  [ "$(decision)" = none ]
}

@test "relative rules match by name at any depth, minus ! carve-outs" {
  project_rule 'Read(*.pem)' 'Read(!test-*.pem)'
  bash_hook "$(GUARD)" 'openssl x509 -in certs/server.pem -noout -text'
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" 'openssl x509 -in certs/test-server.pem -noout -text'
  [ "$(decision)" = none ]
}

## -------------------------------------------------- committing a key --

@test "denies a commit whose staged files hold a private key" {
  with_repo
  pem 'PRIVATE KEY' "$CLAUDE_PROJECT_DIR/notes.txt"
  git -C "$CLAUDE_PROJECT_DIR" add notes.txt
  bash_hook "$(GUARD)" 'git commit -m "add notes"'
  [ "$(decision)" = deny ]
  [[ "$(reason)" == *notes.txt* ]]
}

@test "denies a commit whose staged files hold a service-account key" {
  with_repo
  sa_json "$CLAUDE_PROJECT_DIR/settings.json"
  git -C "$CLAUDE_PROJECT_DIR" add settings.json
  bash_hook "$(GUARD)" 'git commit -m "add settings"'
  [ "$(decision)" = deny ]
}

@test "recognises OpenSSH, encrypted and PGP private keys" {
  with_repo
  for kind in 'OPENSSH PRIVATE KEY' 'ENCRYPTED PRIVATE KEY' 'PGP PRIVATE KEY BLOCK'; do
    pem "$kind" "$CLAUDE_PROJECT_DIR/k.txt"
    git -C "$CLAUDE_PROJECT_DIR" add k.txt
    bash_hook "$(GUARD)" 'git commit -m k'
    [ "$(decision)" = deny ] || { echo "not denied: $kind"; return 1; }
  done
}

@test "recognises ssh.com private keys" {
  with_repo
  printf -- '---- BEGIN SSH2 ENCRYPTED %s ----\nAAAA\n' 'PRIVATE KEY' > "$CLAUDE_PROJECT_DIR/k.txt"
  git -C "$CLAUDE_PROJECT_DIR" add k.txt
  bash_hook "$(GUARD)" 'git commit -m k'
  [ "$(decision)" = deny ]
}

@test "recognises PuTTY private keys" {
  with_repo
  printf '%s-%s: ssh-ed25519\nEncryption: none\n' PuTTY User-Key-File-3 > "$CLAUDE_PROJECT_DIR/id.ppk"
  bash_hook "$(GUARD)" 'git add id.ppk'
  [ "$(decision)" = deny ]
}

@test "finds a key at the start of a file larger than a pipe buffer" {
  with_repo
  pem 'PRIVATE KEY' "$CLAUDE_PROJECT_DIR/big.txt"
  head -c 200000 /dev/zero | tr '\0' 'x' >> "$CLAUDE_PROJECT_DIR/big.txt"
  bash_hook "$(GUARD)" 'git add big.txt'
  [ "$(decision)" = deny ]
  git -C "$CLAUDE_PROJECT_DIR" add big.txt
  bash_hook "$(GUARD)" 'git commit -m big'
  [ "$(decision)" = deny ]
}

@test "reads a staged path that looks like an index stage" {
  with_repo
  sa_json "$CLAUDE_PROJECT_DIR/1:notes"
  git -C "$CLAUDE_PROJECT_DIR" add -- '1:notes'
  bash_hook "$(GUARD)" 'git commit -m notes'
  [ "$(decision)" = deny ]
}

@test "denies staging a key in the same command as the commit" {
  with_repo
  printf '*.json\n' > "$CLAUDE_PROJECT_DIR/.gitignore"
  sa_json "$CLAUDE_PROJECT_DIR/drive-sa.json"
  bash_hook "$(GUARD)" 'git add -f drive-sa.json && git commit -m "add key"'
  [ "$(decision)" = deny ]
  bash_hook "$(GUARD)" "git -C $CLAUDE_PROJECT_DIR add --force ."
  [ "$(decision)" = deny ]
}

@test "follows git -C to a repository under ~" {
  git init -q "$HOME/repo"
  printf '*.json\n' > "$HOME/repo/.gitignore"
  sa_json "$HOME/repo/drive-sa.json"
  bash_hook "$(GUARD)" 'git -C ~/repo add -f drive-sa.json'
  [ "$(decision)" = deny ]
}

@test "a plain git add of a folder skips an ignored key" {
  with_repo
  printf '*.json\n' > "$CLAUDE_PROJECT_DIR/.gitignore"
  sa_json "$CLAUDE_PROJECT_DIR/drive-sa.json"
  bash_hook "$(GUARD)" 'git add .'
  [ "$(decision)" = none ]
}

@test "ordinary staging and commits pass" {
  with_repo
  printf 'y <- 2\n' >> "$CLAUDE_PROJECT_DIR/code.R"
  bash_hook "$(GUARD)" 'git add code.R && git commit -m "change code"'
  [ "$(decision)" = none ]
  git -C "$CLAUDE_PROJECT_DIR" add code.R
  bash_hook "$(GUARD)" 'git commit -m "change code"'
  [ "$(decision)" = none ]
}
