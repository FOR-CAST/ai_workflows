#!/usr/bin/env bash
# PreToolUse(Bash): keep credential files out of the transcript and out of git.
#
# 1. Reading. A Read() deny rule in Claude Code settings stops the Read tool, the
#    shell commands Claude Code recognises as file readers (cat, head, tail, sed,
#    tee) and redirections. It does not stop jq, base64, an R or Python process or a
#    recursive grep, and any of those prints a key into the transcript. This guard
#    applies the same rules to every Bash command that names a protected path.
#    Commands that only list, check or set permissions pass, as does a copy into the
#    protected folder or to another machine.
#
#    The rules are read from the project's .claude/settings.json and
#    settings.local.json and the user's ~/.claude/settings.json, so each project keeps
#    one list, which Claude Code also enforces on its own tools. Rule syntax follows
#    Claude Code: //absolute, ~/home, /relative-to-the-settings-source, and bare or
#    ./ patterns relative to the cwd (a bare name matches at any depth; a ! pattern
#    carves out of those).
#
# 2. Committing. A git add or git commit whose files hold a private key or a
#    service-account key is denied. Always on: no project wants either in git, and a
#    file name or .gitignore rule does not stop a renamed copy or `git add -f`. A
#    `git commit <paths>` that bypasses the index is not covered; a pre-commit hook
#    is (the project-config-layout skill ships one).
#
# A tripwire against accidental exposure, not a boundary: a command that reaches the
# file without naming it (a variable, a script file, a copy made earlier) passes. For
# OS-level enforcement, enable Claude Code's sandbox.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0
cwd="$(printf '%s' "$payload" | jq -r '.cwd // empty' 2>/dev/null)"
[ -z "$cwd" ] && cwd="${CLAUDE_PROJECT_DIR:-$PWD}"
HOME="${HOME:-}"
n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "

## ------------------------------------------------------------- committing --
## PEM and PGP private keys, ssh.com keys ([K] keeps this line from matching itself)
## and Google service-account keys
KEY_RE='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----|---- BEGIN SSH2 ENCRYPTED PRIVATE [K]EY ----|"type"[[:space:]]*:[[:space:]]*"service_account"'
MAX=1048576 # keys are small; read at most this much of each file

# has_key: stdin holds a key. Not a pipeline: grep -q exits at the first match, the
# writer dies of SIGPIPE, and pipefail would report a key early in a large file as none.
has_key() { grep -Eq -e "$KEY_RE" < <(head -c "$MAX"); }

keys=""
while IFS= read -r call; do
  [ -z "$call" ] && continue
  dir="$cwd"
  c="$(printf '%s' "$call" | sed -E 's/^ *git +//')"
  case "$c" in
    -C\ *)
      d="$(printf '%s' "$c" | awk '{print $2}' | tr -d "\"'")"
      case "$d" in \~/*) d="$HOME/${d#\~/}" ;; esac
      case "$d" in /*) dir="$d" ;; *) dir="$cwd/$d" ;; esac
      c="$(printf '%s' "$c" | sed -E 's/^-C +[^ ]+ +//')"
      ;;
  esac
  git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || continue

  case "$c" in
    add*)
      ## the files this add would stage: changed or untracked ones, plus ignored
      ## ones under -f, matched by git itself so a folder or glob resolves as it will
      force=0
      args=()
      set -f
      for w in ${c#add}; do
        w="$(printf '%s' "$w" | tr -d "\"'")"
        case "$w" in
          -f | --force | -[!-]*f*) force=1 ;;
          -*) ;;
          *) args+=("$w") ;;
        esac
      done
      set +f
      [ "${#args[@]}" -eq 0 ] && args=(":/")
      i=0
      while IFS= read -r -d '' f; do
        i=$((i + 1))
        [ "$i" -gt 2000 ] && break
        [ -f "$dir/$f" ] && has_key <"$dir/$f" && keys="${keys}  $f
"
      done < <(
        git -C "$dir" ls-files -z -m -o --exclude-standard -- "${args[@]}" 2>/dev/null
        [ "$force" -eq 1 ] && git -C "$dir" ls-files -z -o -i --exclude-standard -- "${args[@]}" 2>/dev/null
      )
      ;;
    commit*)
      while IFS= read -r -d '' f; do
        ## ":0:" names the staged copy; a bare ":$f" misreads a path such as "1:notes"
        has_key < <(git -C "$dir" cat-file -p ":0:$f" 2>/dev/null) && keys="${keys}  $f
"
      done < <(git -C "$dir" diff --cached --name-only --diff-filter=ACMRT -z 2>/dev/null)
      if printf '%s ' "$c" | grep -Eq " (-[a-zA-Z]*a[a-zA-Z]*|--all) "; then
        while IFS= read -r -d '' f; do
          [ -f "$dir/$f" ] && has_key <"$dir/$f" && keys="${keys}  $f
"
        done < <(git -C "$dir" ls-files -z -m 2>/dev/null)
      fi
      ;;
  esac
done < <(printf '%s' "$n" | grep -Eo " git +(-C +[^ ;|&]+ +)?(add|commit)([ ][^;|&]*)?")

if [ -n "$keys" ]; then
  deny "BLOCKED: this would stage or commit a private key or a service-account key:

$(printf '%s' "$keys" | sort -u)
A key in git history can be read by everyone with access to the repository, its
forks and clones. Removing it later means rewriting history and still revoking the
key. Keep keys outside the repository (for example ~/.config/<project>/, folder 700,
file 600) and point to them from a gitignored file.

Unstage it with 'git restore --staged <file>' and tell the user; if it was ever
pushed, they need to revoke the key. If it is a deliberate fake key in a test
fixture, generate it when the test runs instead of committing it."
fi

## ---------------------------------------------------------------- reading --
## Read() deny rules -> anchored EREs. ABS: rules anchored at /, ~ or the settings
## source. REL: cwd-relative rules, which NEG (! patterns) carve out of.
ABS_ERE=()
ABS_RULE=()
REL_ERE=()
REL_RULE=()
NEG_ERE=()

# glob_ere <glob>: the ERE for a gitignore-style glob, unanchored
glob_ere() {
  printf '%s' "$1" | sed -E \
    -e 's/[.+(){}|^$\\]/\\&/g' \
    -e 's#/\*\*/#/%A%#g' -e 's#/\*\*$#%B%#' -e 's#^\*\*/#%A%#' -e 's#\*\*#%C%#g' \
    -e 's#\*#[^/]*#g' -e 's#\?#[^/]#g' \
    -e 's#%A%#(.*/)?#g' -e 's#%B%#(/.*)?#g' -e 's#%C%#.*#g'
}

# add_rules <settings file> <directory a /path rule anchors at>
add_rules() {
  local p neg e
  [ -f "$1" ] || return 0
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    neg=0
    case "$p" in !*) neg=1 p="${p#!}" ;; esac
    p="${p%/}"
    if [ "$neg" -eq 0 ]; then
      case "$p" in
        //*) ABS_ERE+=("^$(glob_ere "${p#/}")(/.*)?$") ABS_RULE+=("Read($p)") ; continue ;;
        \~/*) ABS_ERE+=("^$(glob_ere "$HOME/${p#\~/}")(/.*)?$") ABS_RULE+=("Read($p)") ; continue ;;
        /*) ABS_ERE+=("^$(glob_ere "$2$p")(/.*)?$") ABS_RULE+=("Read($p)") ; continue ;;
      esac
    else
      ## Claude Code reads every ! pattern relative to the cwd
      case "$p" in \~/* | /*) p="${p#\~}" p="${p#/}" ;; esac
    fi
    p="${p#./}"
    ## a bare name, or one name plus /**, matches at any depth; anything else is
    ## anchored at the cwd
    case "${p%/\*\*}" in
      */*) e="^$(glob_ere "$cwd/$p")(/.*)?$" ;;
      *) e="^$(glob_ere "$cwd")/(.*/)?$(glob_ere "$p")(/.*)?$" ;;
    esac
    if [ "$neg" -eq 1 ]; then
      NEG_ERE+=("$e")
    else
      REL_ERE+=("$e") REL_RULE+=("Read($p)")
    fi
  done < <(jq -r '.permissions.deny // [] | .[] | strings
    | select(startswith("Read(") and endswith(")")) | .[5:-1]' "$1" 2>/dev/null)
}

proj="${CLAUDE_PROJECT_DIR:-$cwd}"
add_rules "$proj/.claude/settings.json" "$proj"
add_rules "$proj/.claude/settings.local.json" "$proj"
add_rules "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json" "$HOME/.claude"
[ $((${#ABS_ERE[@]} + ${#REL_ERE[@]})) -eq 0 ] && exit 0
NEG_ALL=""
for e in ${NEG_ERE[@]+"${NEG_ERE[@]}"}; do NEG_ALL="${NEG_ALL:+$NEG_ALL|}($e)"; done

# protected <paths, one per line>: "path<TAB>rule" for each path a rule protects.
# One grep per rule, not per path: a long heredoc has hundreds of words.
protected() {
  local i
  for ((i = 0; i < ${#ABS_ERE[@]}; i++)); do
    printf '%s\n' "$1" | grep -E "${ABS_ERE[$i]}" | awk -v r="${ABS_RULE[$i]}" '{ print $0 "\t" r }'
  done
  for ((i = 0; i < ${#REL_ERE[@]}; i++)); do
    printf '%s\n' "$1" | grep -E "${REL_ERE[$i]}" |
      { if [ -n "$NEG_ALL" ]; then grep -Ev "$NEG_ALL"; else cat; fi; } |
      awk -v r="${REL_RULE[$i]}" '{ print $0 "\t" r }'
  done
}

# paths <text>: each word of text as an absolute path, one per line
paths() {
  printf '%s' "$1" | sed -e "s#\${HOME}#$HOME#g" -e "s#\$HOME#$HOME#g" |
    tr "\"'()=,@<>{}\`[:space:]" '\n' |
    awk -v home="$HOME" -v cwd="$cwd" '
      $0 == "" || /^-/ { next }
      { w = $0
        if (w == "~") w = home; else if (substr(w, 1, 2) == "~/") w = home substr(w, 2)
        if (substr(w, 1, 1) != "/") w = cwd "/" w
        while (gsub(/\/\.\//, "/", w)) {}
        gsub(/\/+/, "/", w); sub(/\/\.$/, "", w)
        if (length(w) > 1) sub(/\/$/, "", w)
        print w }'
}

hit=""      # the protected path the segment being checked names
hit_rule="" # and the rule that protects it

# check <command text>: 1 (with hit set) when a segment reads a protected path
check() {
  local text="$1" seg words last m verb onlylast rest
  while IFS= read -r seg; do
    [ -z "${seg// /}" ] && continue
    words="$(paths "$seg")"
    m="$(protected "$words")"
    hit=""
    [ -z "$m" ] && continue
    hit="$(printf '%s\n' "$m" | head -1 | cut -f1)"
    hit_rule="$(printf '%s\n' "$m" | head -1 | cut -f2)"
    last="$(printf '%s\n' "$words" | tail -1)"
    onlylast=1
    printf '%s\n' "$m" | cut -f1 | grep -qvxF -- "$last" && onlylast=0

    set -f
    # shellcheck disable=SC2046 # split the segment into words on purpose
    set -- $(printf '%s' "$seg" | tr -d "\"'({")
    set +f
    while [ "$#" -gt 0 ]; do
      case "$1" in
        sudo | env | command | exec | time | nice | nohup | builtin | [A-Za-z_]*=*) shift ;;
        *) break ;;
      esac
    done
    verb="${1##*/}"
    case "$verb" in
      ls | stat | test | "[" | "[[" | file | du | tree | wc | chmod | chown | chgrp | getfacl | setfacl | \
        mkdir | rmdir | rm | touch | echo | printf | realpath | readlink | dirname | basename)
        hit="" ;;
      find)
        printf ' %s ' "$*" | grep -Eq ' -(exec|execdir|ok|okdir) ' || hit="" ;;
      git)
        printf ' %s ' "$*" | grep -Eq ' --no-index ' || hit="" ;;
      cp | mv | install | ln | rsync | scp)
        ## into the protected folder, or out to another machine with the same layout
        for rest; do :; done
        { [ "$onlylast" -eq 1 ] || printf '%s' "$rest" | grep -Eq '^[^/~.][^/]*:'; } && hit="" ;;
      ssh)
        ## check the command it runs remotely
        shift
        while [ "$#" -gt 0 ]; do
          case "$1" in
            -[BbcDEeFIiJLlmOoPpQRSWw]) shift; [ "$#" -gt 0 ] && shift ;;
            -*) shift ;;
            *) shift; break ;;
          esac
        done
        hit=""
        [ "$#" -gt 0 ] && ! check "$*" && return 1
        ;;
    esac
    [ -n "$hit" ] && return 1
  done < <(printf '%s\n' "$text" | awk '{ gsub(/&&|\|\||\$\(|[;|&`]/, "\n"); print }')
  return 0
}

## most commands name no protected path: one pass over all their words settles it
[ -z "$(protected "$(paths "$cmd")")" ] && exit 0
check "$cmd" && exit 0

deny "BLOCKED: this command names ${hit}, which a Read() deny rule in your Claude Code
settings protects: ${hit_rule}.

Claude Code applies that rule to the Read tool and to cat, head, tail and sed, but
not to jq, base64, an R or Python process or a recursive grep. Any of those would
print the file into the transcript, which is sent to the model provider and kept in
the session log. A copy outside the protected folder is no longer covered by the rule.

Instead:
  - check that the file exists, or its size and permissions: ls -l, stat, test -f;
  - let the program that needs it read it, without printing it (a pipeline finds a
    service-account key through the environment variable that points to it);
  - for something inside it, such as the account name, ask the user to run the
    command and tell you.

If the path appears only as text, as in a PR body, write the text to a gitignored
file and pass it with --body-file or -F."
