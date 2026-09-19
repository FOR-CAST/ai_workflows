#!/usr/bin/env bash
# Warn when the plugin tree changed but the committed cheatsheet PDF did not.
#
# This never fails the build. The render job already fails hard when a skill, hook
# or subagent has no entry on the sheet. What it cannot see is a sheet whose
# *source* is current while the *committed PDF* was never re-rendered, because
# nothing inside the document knows what is checked in. That is what this catches.
#
# Takes an optional git range; otherwise compares against the PR base, or HEAD~1.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 0

pdf=cheatsheet/ai-workflows-cheatsheet.pdf
range="${1:-}"

if [ -z "$range" ]; then
  if [ -n "${GITHUB_BASE_REF:-}" ] && git rev-parse -q --verify "origin/${GITHUB_BASE_REF}" >/dev/null; then
    range="origin/${GITHUB_BASE_REF}...HEAD"
  elif git rev-parse -q --verify HEAD~1 >/dev/null; then
    range="HEAD~1..HEAD"
  else
    echo "cheatsheet freshness: no comparison point, skipped"
    exit 0
  fi
fi

sources="$(git diff --name-only "$range" -- plugins docs/installation.md 2>/dev/null)"
rendered="$(git diff --name-only "$range" -- "$pdf" 2>/dev/null)"

if [ -n "$sources" ] && [ -z "$rendered" ]; then
  msg="the plugin tree changed in $range but $pdf was not re-rendered -- run ./cheatsheet/render.sh and commit the PDF"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::warning file=%s::%s\n' "$pdf" "$msg"
  else
    printf 'WARNING: %s\n' "$msg"
  fi
else
  echo "cheatsheet freshness: ok"
fi
exit 0
