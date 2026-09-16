#!/usr/bin/env bash
# Run agent-ecosystem/skill-validator over every skill in every plugin.
#
# --allow-extra-frontmatter: when_to_use, paths, argument-hint, allowed-tools and
#   disable-model-invocation are valid Claude Code fields outside the base spec.
# --allow-dirs=selftest: targets-testing-ci ships a self-test fixture project.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

flags=(check --strict --allow-extra-frontmatter --allow-dirs=selftest)
[ "${GITHUB_ACTIONS:-}" = "true" ] && flags+=(--emit-annotations)

status=0
for s in plugins/*/skills/*/; do
  skill-validator "${flags[@]}" "$s" || status=1
done
exit "$status"
