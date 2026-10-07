#!/usr/bin/env bash
## Install the git hook dispatcher (scripts/git-hooks/dispatch) for every repository of this user:
## copy it to ~/.githooks, link it under every hook name git documents (githooks(5)), and set
## core.hooksPath globally. Re-run after the dispatcher changes. Undo with
## `git config --global --unset core.hooksPath`.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)/dispatch"
dest="$HOME/.githooks"

current="$(git config --global --type=path --get core.hooksPath || true)"
if [ -n "$current" ] && [ "$(readlink -f "$current")" != "$(readlink -f "$dest")" ]; then
  echo "core.hooksPath is already set to '$current'; leaving it alone." >&2
  exit 1
fi

install -d "$dest"
install -m 755 "$src" "$dest/dispatch"
## every hook name in githooks(5) except fsmonitor-watchman, which git runs only when
## core.fsmonitor names it
for h in applypatch-msg pre-applypatch post-applypatch pre-commit pre-merge-commit \
  prepare-commit-msg commit-msg post-commit pre-rebase post-checkout post-merge pre-push \
  pre-receive update proc-receive post-receive post-update reference-transaction \
  push-to-checkout pre-auto-gc post-rewrite sendemail-validate post-index-change \
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
