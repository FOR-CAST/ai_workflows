#!/usr/bin/env bash
# PreToolUse(Edit|Write|NotebookEdit): enforce an ASCII-only rule for code and
# reports. Rationale:
#   * reports rendered through pdflatex fail hard on an undeclared glyph (a
#     \DeclareUnicodeCharacter block is a backstop, not a licence);
#   * a smart quote or non-breaking space pasted into code is invisible in review
#     and produces errors far from where it was introduced.
# Scoped to code + reports + bib. Prose .md (CLAUDE.md, design notes) is exempt.
#
# Covered extensions: FORCAST_ASCII_EXT (space separated, no dot) for this session,
# else asciiExtensions in .claude/r-project-policy.json, else R r qmd Rmd rmd bib.
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

payload="$(cat)"
f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0

ext="${f##*.}"
exts="${FORCAST_ASCII_EXT:-}"
[ -z "$exts" ] && exts="$(policy_list '.asciiExtensions' | tr '\n' ' ')"
[ -z "${exts// /}" ] && exts='R r qmd Rmd rmd bib'
covered=0
for e in $exts; do [ "$ext" = "$e" ] && covered=1; done
[ "$covered" -eq 0 ] && exit 0

# The text this call would introduce (Write=content, Edit=new_string, Notebook=new_source).
text="$(printf '%s' "$payload" | jq -r '
  [.tool_input.content?, .tool_input.new_string?, .tool_input.new_source?,
   (.tool_input.edits? // [] | .[].new_string?)]
  | map(select(. != null)) | join("\n")' 2>/dev/null)"
[ -z "$text" ] && exit 0

# One line per offending character:  <char> <TAB> <count> <TAB> <first line no>
findings="$(printf '%s' "$text" | perl -CSD -ne '
  while (/([^\x00-\x7F])/g) { $n{$1}++; $l{$1} //= $. }
  END { print "$_\t$n{$_}\t$l{$_}\n" for sort keys %n }' 2>/dev/null)"
[ -z "$findings" ] && exit 0

say() { printf '%s\n' "$1"; }

suggest() {
  # shellcheck disable=SC1111  # the curly quotes below are the characters being matched
  case "$1" in
    "—") say '--' ;;   "–") say '-' ;;   "―") say '--' ;;
    "→") say '->        (in .qmd prose: $\rightarrow$)' ;;
    "←") say '<-        (in .qmd prose: $\leftarrow$)' ;;
    "↔") say '<->       (in .qmd prose: $\leftrightarrow$)' ;;
    "×") say 'x         (in .qmd prose: $\times$)' ;;
    "≥") say '>=        (in .qmd prose: $\geq$)' ;;
    "≤") say '<=        (in .qmd prose: $\leq$)' ;;
    "±") say '+/-       (in .qmd prose: $\pm$)' ;;
    "≈") say '~         (in .qmd prose: $\approx$)' ;;
    "•") say '*         (in .qmd prose: \textbullet)' ;;
    "…") say '...' ;;
    "“"|"”") say 'a plain double quote  "' ;;
    "‘"|"’") say "a plain apostrophe    '" ;;
    "°") say 'deg       (in .qmd prose: $^\circ$)' ;;
    "µ"|"μ") say 'u         (in .qmd prose: $\mu$)' ;;
    "²") say '^2        (in .qmd prose: $^2$)' ;;
    "½") say '1/2' ;;
    " ") say 'a NORMAL SPACE -- this is a non-breaking space (U+00A0)' ;;
    "‑") say 'a NORMAL HYPHEN -- this is a non-breaking hyphen (U+2011)' ;;
    *)   echo 'an ASCII equivalent, or LaTeX math if the symbol is needed in a report' ;;
  esac
}

table=""
while IFS=$'\t' read -r ch count line; do
  [ -z "$ch" ] && continue
  cp="$(printf '%s' "$ch" | perl -CSD -ne 'printf "U+%04X", ord($_)' 2>/dev/null)"
  table="${table}$(printf '  %-3s %-8s x%-3s first at line %-5s ->  %s' "$ch" "$cp" "$count" "$line" "$(suggest "$ch")")"$'\n'
done <<< "$findings"

reason="BLOCKED: non-ASCII characters in ${f##*/}

ASCII-only is enforced for code and reports here. Reports render through pdflatex,
where an undeclared glyph is a hard render failure, and invisible characters
(smart quotes, non-breaking spaces) cause errors far from where they were pasted.

${table}
Rewrite using the ASCII forms above, then retry. If a report genuinely needs the
symbol, use LaTeX math (\$\\geq\$) rather than the raw glyph.

Covered extensions: ${exts}. Prose .md files (CLAUDE.md, design notes) are exempt."

jq -n --arg r "$reason" '{hookSpecificOutput: {
  hookEventName: "PreToolUse",
  permissionDecision: "deny",
  permissionDecisionReason: $r}}'
exit 0
