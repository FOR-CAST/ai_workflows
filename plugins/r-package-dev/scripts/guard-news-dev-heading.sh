#!/usr/bin/env bash
# PreToolUse(Edit|Write): in NEWS.md, development notes live under ONE heading.
#
# `usethis::use_version()` retitles exactly one heading at release:
#   # <pkg> (development version)   ->   # <pkg> 1.2.1
# A heading written per version bump (`# <pkg> 1.2.0.9027`) survives that retitle
# untouched and is left ABOVE the release heading, so the shipped NEWS.md advertises
# versions that were never released and their bullets fall outside the section for
# the version that actually shipped. Bump DESCRIPTION's Version as usual; file the
# bullet under the development heading, in New features / Enhancements / Bug fixes.
#
# Only an edit that INTRODUCES such a heading is denied. Carrying an existing one
# through, and removing one while folding the file back into shape, both pass --
# that repair is the point, and blocking it would strand the mistake in place.
set -uo pipefail

payload="$(cat)"
[ -z "$payload" ] && exit 0

f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0
case "$(basename "$f")" in
  NEWS.md|news.md|News.md) ;;
  *) exit 0 ;;
esac

# Package convention, package scope: a NEWS.md elsewhere answers to its own repo.
[ -f "$(dirname "$f")/DESCRIPTION" ] || exit 0

# A heading naming a four-part (development) version. Three-part release headings
# are what use_version() itself writes, so they are none of this hook's business.
dev_heading='^#+[[:space:]]+.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'

# What this call would introduce, against what it replaces: Write replaces the whole
# file, each Edit replaces its own old_string.
if [ -n "$(printf '%s' "$payload" | jq -r '.tool_input.content // empty' 2>/dev/null)" ]; then
  new="$(printf '%s' "$payload" | jq -r '.tool_input.content' 2>/dev/null)"
  old="$(cat "$f" 2>/dev/null)"
  pairs="$(printf '%s\n' "$new")"
  olds="$old"
else
  pairs="$(printf '%s' "$payload" | jq -r '
    [(.tool_input | select(.new_string != null) | {o: (.old_string // ""), n: .new_string}),
     (.tool_input.edits? // [] | .[] | {o: (.old_string // ""), n: .new_string})]
    | map(.n) | join("\n")' 2>/dev/null)"
  olds="$(printf '%s' "$payload" | jq -r '
    [(.tool_input | select(.new_string != null) | .old_string // ""),
     (.tool_input.edits? // [] | .[] | .old_string // "")]
    | join("\n")' 2>/dev/null)"
fi
[ -z "$pairs" ] && exit 0

added=""
while IFS= read -r line; do
  [ -z "$line" ] && continue
  printf '%s\n' "$olds" | grep -Fxq -- "$line" && continue
  added="${added}  ${line}
"
done <<EOF
$(printf '%s\n' "$pairs" | grep -E "$dev_heading" | head -10)
EOF
[ -z "$added" ] && exit 0

reason="BLOCKED: this adds a NEWS.md heading per version bump --

${added}
Development notes accumulate under a single heading:

  # <pkg> (development version)
  ## New features / ## Enhancements / ## Bug fixes

At release, use_version() retitles exactly that one heading (to '# <pkg> 1.2.1').
A numbered development heading survives the retitle and ends up above the release
heading, so the published NEWS advertises versions that never shipped and their
bullets sit outside the released section.

Keep bumping Version in DESCRIPTION -- that part is right. File this bullet in the
matching subsection under the development heading instead. If the file has no such
heading, add one above the newest release heading.

If numbered development headings are already in the file, do not copy them: fold
them back in (move each bullet into the matching subsection, delete the heading) on
one branch only, since it rewrites lines every open pull request also touches."

jq -n --arg r "$reason" '{hookSpecificOutput: {
  hookEventName: "PreToolUse",
  permissionDecision: "deny",
  permissionDecisionReason: $r}}'
exit 0
