#!/usr/bin/env bash
# Install every plugin in this marketplace into a throwaway Claude Code config, then
# fail if any of them reports a load error.
#
# `claude plugin validate --strict` and `--plugin-dir` both miss errors that only
# appear on a real marketplace install. A plugin.json "hooks" entry naming the
# default hooks/hooks.json validates cleanly, then refuses every hook in the plugin.
#
# Usage: check-plugin-loading.sh [marketplace-root]   (needs `claude` on PATH; no login)
set -euo pipefail

root="${1:-$(git rev-parse --show-toplevel)}"
root="$(cd "$root" && pwd)"
mkt_file="$root/.claude-plugin/marketplace.json"
mkt="$(jq -r .name "$mkt_file")"

## Never touch the real config: always a fresh, disposable one.
CLAUDE_CONFIG_DIR="$(mktemp -d)"
export CLAUDE_CONFIG_DIR
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT

claude plugin marketplace add "$root" >/dev/null
expected="$(jq -r '.plugins[].name' "$mkt_file")"
while IFS= read -r p; do
  claude plugin install "$p@$mkt" >/dev/null
done <<<"$expected"

list="$(claude plugin list --json | jq --arg m "@$mkt" '[.[] | select(.id | endswith($m))]')"
printf '%s\n' "$list" | jq -r '.[] | "\(.id)  \(if (.errors // []) == [] then "loaded" else "ERRORS" end)"'

status=0
installed="$(printf '%s\n' "$list" | jq -r '.[].id | sub("@.*$"; "")' | sort)"
if [ "$installed" != "$(printf '%s\n' "$expected" | sort)" ]; then
  echo "Installed plugins differ from the marketplace listing:"
  diff <(printf '%s\n' "$expected" | sort) <(printf '%s\n' "$installed") || true
  status=1
fi

bad="$(printf '%s\n' "$list" | jq -r '.[] | select((.errors // []) != []) | "\(.id): \(.errors | join("; "))"')"
if [ -n "$bad" ]; then
  while IFS= read -r line; do
    if [ "${GITHUB_ACTIONS:-}" = "true" ]; then echo "::error::$line"; else echo "ERROR $line"; fi
  done <<<"$bad"
  status=1
fi
exit "$status"
