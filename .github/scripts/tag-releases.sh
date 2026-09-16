#!/usr/bin/env bash
# Tag each plugin whose current version has no {name}--v{version} tag yet, and push
# the tag. `claude plugin tag` validates the plugin and refuses a dirty tree or an
# existing tag. Run on main after CI passes; needs `claude` on PATH and push access.
#
# Usage: tag-releases.sh [--dry-run]
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

args=(--push -m "%s")
[ "${1:-}" = "--dry-run" ] && args=(--dry-run)

for mf in plugins/*/.claude-plugin/plugin.json; do
  dir="${mf%/.claude-plugin/plugin.json}"
  tag="$(jq -r '.name + "--v" + .version' "$mf")"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    continue
  fi
  claude plugin tag "$dir" "${args[@]}"
done
