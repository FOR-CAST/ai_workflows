#!/usr/bin/env bash
# Every plugin sets `version` in its plugin.json, so users receive a change only
# when that version moves. Release tags are {name}--v{version} (`claude plugin tag`).
#
# Fails when a plugin's files differ from the tag of its current version -- the
# version was not bumped -- or when the version is lower than one already released.
# A version with no tag yet is an unreleased bump and passes. Needs tags fetched.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

status=0
fail() {
  status=1
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error file=%s::%s\n' "$1" "$2"
  else
    printf 'ERROR %s: %s\n' "$1" "$2"
  fi
}

for mf in plugins/*/.claude-plugin/plugin.json; do
  dir="${mf%/.claude-plugin/plugin.json}"
  name="$(jq -r .name "$mf")"
  version="$(jq -r .version "$mf")"
  tag="${name}--v${version}"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    if ! git diff --quiet "$tag" -- "$dir"; then
      fail "$mf" "$name changed since $tag but is still $version -- bump \"version\" in $mf"
    else
      echo "$name $version: released, unchanged"
    fi
  else
    latest="$(git tag -l "${name}--v*" | sed "s/^${name}--v//" | sort -V | tail -1)"
    if [ -n "$latest" ] && [ "$(printf '%s\n%s\n' "$latest" "$version" | sort -V | tail -1)" != "$version" ]; then
      fail "$mf" "$name $version is lower than the released $latest"
    else
      echo "$name $version: unreleased${latest:+ (last release $latest)}"
    fi
  fi
done
exit "$status"
