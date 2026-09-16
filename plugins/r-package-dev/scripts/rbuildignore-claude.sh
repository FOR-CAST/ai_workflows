#!/usr/bin/env bash
# PostToolUse(Edit|Write): keep `.claude` out of the built package.
#
# `R CMD check ... NOTE: Found the following hidden files and directories: .claude`
# appears 28 times in the session record. Self-inflicted, and a one-line fix.
set -uo pipefail
f="$(cat | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0
case "$f" in */.claude/*|.claude/*) ;; *) exit 0 ;; esac

# Walk up to the .claude parent; act only if it sits beside a DESCRIPTION.
d="$(cd "$(dirname "$f")" 2>/dev/null && pwd)" || exit 0
while [ "$d" != "/" ] && [ "$(basename "$d")" != ".claude" ]; do d="$(dirname "$d")"; done
[ "$d" = "/" ] && exit 0
root="$(dirname "$d")"
[ -f "$root/DESCRIPTION" ] || exit 0
grep -q '^Package:' "$root/DESCRIPTION" 2>/dev/null || exit 0

rbi="$root/.Rbuildignore"
if [ -f "$rbi" ] && grep -qF '^\.claude$' "$rbi" 2>/dev/null; then exit 0; fi
[ -f "$rbi" ] && [ -n "$(tail -c1 "$rbi" 2>/dev/null)" ] && printf '\n' >> "$rbi"
printf '^\\.claude$\n' >> "$rbi"
echo "Added '^\\.claude\$' to ${rbi#"$root"/} -- without it R CMD check reports a hidden-file NOTE." >&2
exit 2
