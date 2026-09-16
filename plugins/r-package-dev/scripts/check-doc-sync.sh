#!/usr/bin/env bash
# Stop: if roxygen comments changed in R/ but man/ and NAMESPACE were not
# regenerated, say so before the turn ends.
#
# Roughly twenty standalone catch-up commits in the corpus exist only to run
# document() after the fact ("redoc", "rebuild documentation", "with prev").
# Exit 2 blocks the stop and tells the model what to do.
set -uo pipefail
root="${CLAUDE_PROJECT_DIR:-$PWD}"
[ -f "$root/DESCRIPTION" ] || exit 0
grep -q '^Package:' "$root/DESCRIPTION" 2>/dev/null || exit 0
git -C "$root" rev-parse --git-dir >/dev/null 2>&1 || exit 0

changed="$(git -C "$root" status --porcelain -- 'R/*.R' 2>/dev/null | awk '{print $NF}')"
[ -z "$changed" ] && exit 0

# Did any of those edits touch a roxygen line?
roxy=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  if git -C "$root" diff -U0 -- "$f" 2>/dev/null | grep -qE "^[+-][[:space:]]*#'"; then roxy=1; break; fi
done <<< "$changed"
[ "$roxy" -eq 0 ] && exit 0

gen="$(git -C "$root" status --porcelain -- NAMESPACE man 2>/dev/null)"
[ -n "$gen" ] && exit 0

{
  echo "Roxygen comments changed in R/ but man/ and NAMESPACE are unmodified."
  echo
  echo "Changed:"
  printf '%s\n' "$changed" | sed 's/^/  /'
  echo
  echo "Run:  Rscript -e 'devtools::document()'"
  echo
  echo "First confirm the installed roxygen2 matches what DESCRIPTION pins -- a newer"
  echo "roxygen2 rewrites the entire NAMESPACE and buries the real change:"
  echo "  grep -E 'RoxygenNote|Config/roxygen2' DESCRIPTION"
  echo "  Rscript -e 'packageVersion(\"roxygen2\")'"
  echo "If they disagree, say so rather than committing the churn."
} >&2
exit 2
