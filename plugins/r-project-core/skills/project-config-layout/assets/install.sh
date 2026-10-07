#!/usr/bin/env bash
## Install the git hook dispatcher (scripts/git-hooks/dispatch) for every repository of this user:
## copy it to ~/.githooks, link it under the hook names git documents (githooks(5)), and set
## core.hooksPath globally. Re-run after the dispatcher changes. Undo with
## `git config --global --unset core.hooksPath`.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)/dispatch"
dest="$HOME/.githooks"

## read every config source (system, both global files, includes); `cd /` keeps a repo value out
current="$(cd / && { git config --type=path --get core.hooksPath || true; })"
if [ -n "$current" ] && [ "$(readlink -f "$current")" != "$(readlink -f "$dest")" ]; then
  echo "core.hooksPath is already set to '$current'; leaving it alone." >&2
  exit 1
fi

install -d "$dest"
install -m 755 "$src" "$dest/dispatch"
## Every hook name in githooks(5) except these, which are left unlinked:
## - fsmonitor-watchman, proc-receive and push-to-checkout change what git does merely by existing
##   (push-to-checkout replaces the working-tree update of a push to a checked-out branch);
## - reference-transaction and post-index-change run hundreds of times per rebase or checkout, so a
##   dispatcher on them slowed rebases about 90-fold, and few per-repository tools use them.
## A link left by an earlier install under one of these names is removed.
for h in fsmonitor-watchman proc-receive push-to-checkout reference-transaction post-index-change; do
  if [ -L "$dest/$h" ] && [ "$(readlink "$dest/$h")" = "dispatch" ]; then
    rm -- "$dest/$h"
  fi
done
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit \
  prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push \
  pre-receive update post-receive post-update pre-auto-gc post-rewrite sendemail-validate \
  p4-changelist p4-prepare-changelist p4-post-changelist p4-pre-submit; do
  if [ -L "$dest/$h" ] && [ "$(readlink "$dest/$h")" = "dispatch" ]; then
    continue
  fi
  if [ -e "$dest/$h" ] || [ -L "$dest/$h" ]; then
    echo "skipping $dest/$h: something other than the dispatcher is already there" >&2
    continue
  fi
  ln -s dispatch "$dest/$h"
done
git config --global core.hooksPath "$dest"
echo "git hooks installed in $dest (core.hooksPath set globally)"
