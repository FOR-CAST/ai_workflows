#!/usr/bin/env bash
# PreToolUse(Bash|Edit|Write|NotebookEdit): keep machine names out of anything
# published.
#
# Machine and network names are infrastructure identity. Once one lands in a commit
# message, a PR body, an issue comment or a committed file, it is public and
# permanent, and it says nothing useful anyway -- where a command ran does not make
# a result reproducible; the R version, the lockfile and the toolchain do. Names
# belong in gitignored config (a _hosts.R and its shipped .example), which is how
# the config-layout skill already splits them.
#
# OFF unless the repo opts in, because only the project knows its own names:
#   FORCAST_HOST_PATTERNS     space-separated ERE fragments, this session only
#   .claude/r-project-policy.json -> "hostPatterns": ["nodeone", "nodetwo"]
#
# ASK, never deny: machine names are often ordinary words in the domain -- a genus,
# a place, a person -- so a match is a question for a human, not a verdict. A deny
# cannot be approved from the prompt, which would make a legitimate species name
# unwritable.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

payload="$(cat)"
[ -z "$payload" ] && exit 0

pats="${FORCAST_HOST_PATTERNS:-}"
[ -z "$pats" ] && pats="$(policy_list '.hostPatterns' | tr '\n' ' ')"
[ -z "${pats// /}" ] && exit 0

alt=""
for p in $pats; do alt="${alt:+$alt|}$p"; done
alt="($alt)"

# Which names a piece of text actually mentions, for the prompt the user reads.
names_in() {
  printf '%s' "$1" | grep -Eio "$alt" 2>/dev/null | sort -u | head -5 | tr '\n' ' '
}

why="Names come from ${FORCAST_HOST_PATTERNS:+FORCAST_HOST_PATTERNS}"
[ -z "${FORCAST_HOST_PATTERNS:-}" ] && why="Names come from hostPatterns in .claude/r-project-policy.json"

tool="$(printf '%s' "$payload" | jq -r '.tool_name // empty' 2>/dev/null)"

## ------------------------------------------------------------------ Bash --
if [ "$tool" = "Bash" ]; then
  cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
  [ -z "$cmd" ] && exit 0
  n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "

  # 1. Message or body text carried on the command line. Read from the FIRST such
  # flag onward, so an `ssh <node> ...` prefix -- a destination, not a published
  # name -- stays out of the comparison, while every later flag stays in.
  if printf '%s' "$n" | grep -Eq " (git +(commit|tag|notes)|gh +(pr|issue|release|gist|repo))$B"; then
    msg="$(printf '%s' "$n" | awk '{
      i = match($0, /(-m|--message|-F|--file|--body|--body-file|--notes|--notes-file|--title)/)
      if (i > 0) print substr($0, i)
    }')"
    if [ -n "$msg" ]; then
      found="$(names_in "$msg")"
      if [ -n "$found" ]; then
        ask_user "ASK: this message names a machine -- ${found}

Commit messages, PR and issue bodies, release notes and tag messages are
published and permanent. Where a command ran is not evidence of anything: the R
version, the lockfile and the toolchain are what let someone reproduce a result.

Say 'the control node' or 'a compute node' instead, and keep real names in
gitignored config (_hosts.R).

Approve only if this word is genuinely not a machine here -- a species, a place, a
person. ${why}."
      fi
    fi
  fi

  # 2. What a commit would actually record. Catches content that arrived by any
  # route, including an editor or a file the model never wrote itself. Gitignored
  # files are absent from the staged diff by construction.
  if printf '%s' "$n" | grep -Eq " git +commit$B"; then
    root="$(repo_root)"
    if git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
      added="$(git -C "$root" diff --cached -U0 2>/dev/null | grep -E '^\+' | grep -v '^+++')"
      found="$(names_in "$added")"
      if [ -n "$found" ]; then
        files=""
        while IFS= read -r f; do
          [ -z "$f" ] && continue
          if git -C "$root" diff --cached -U0 -- "$f" 2>/dev/null |
             grep -E '^\+' | grep -v '^+++' | grep -Eiq "$alt"; then
            files="${files}  ${f}
"
          fi
        done < <(git -C "$root" diff --cached --name-only 2>/dev/null | head -200)

        ask_user "ASK: the staged changes name a machine -- ${found}

In:
${files}
A commit is permanent and public. Machine names belong in gitignored config
(_hosts.R, shipped as _hosts.R.example), not in tracked files; detect a role by
capability rather than by matching a name.

Unstage or reword those lines, or approve if the word is genuinely not a machine
here -- a species, a place, a person. ${why}."
      fi
    fi
  fi
  exit 0
fi

## ------------------------------------------- Edit | Write | NotebookEdit --
f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0

text="$(printf '%s' "$payload" | jq -r '
  [.tool_input.content?, .tool_input.new_string?, .tool_input.new_source?,
   (.tool_input.edits? // [] | .[].new_string?)]
  | map(select(. != null)) | join("\n")' 2>/dev/null)"
[ -z "$text" ] && exit 0

found="$(names_in "$text")"
[ -z "$found" ] && exit 0

# A file outside a repository, or one git already ignores, is never published.
d="$(dirname "$f")"
while [ ! -d "$d" ] && [ "$d" != "/" ] && [ -n "$d" ]; do d="$(dirname "$d")"; done
git -C "$d" rev-parse --git-dir >/dev/null 2>&1 || exit 0
git -C "$d" check-ignore -q -- "$f" 2>/dev/null && exit 0

ask_user "ASK: this writes a machine name -- ${found} -- into a file git tracks

  ${f}

Tracked files are published. Keep real names in gitignored config (_hosts.R, with
a _hosts.R.example in the repo), and have code find its role by capability rather
than by matching a name -- a hostname match is also fragile when a node is renamed
or added.

Approve if the word is genuinely not a machine here -- a species, a place, a
person. ${why}."
