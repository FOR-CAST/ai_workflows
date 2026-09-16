#!/usr/bin/env bash
# PostToolUse(Edit|Write) for R sources: give a deterministic pass/fail on the
# file just touched, so a syntax error surfaces in the same turn rather than at
# the next pipeline run, which may be hours later.
#
#   1. parse check  -- always; a file that doesn't parse is reported to Claude.
#   2. air format   -- only when the project opts in with an air.toml.
#
# Exit 2 => stderr is shown to Claude (PostToolUse cannot block, only inform).
set -uo pipefail

payload="$(cat)"
f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$f" ] || [ ! -f "$f" ] && exit 0

case "$f" in
  *.R|*.r) ;;
  *) exit 0 ;;
esac

# Walk up from the file to find the project root (whichever marker comes first).
root="$(cd "$(dirname "$f")" && pwd)"
while [ "$root" != "/" ]; do
  for m in air.toml .git DESCRIPTION; do
    [ -e "$root/$m" ] && break 2
  done
  root="$(dirname "$root")"
done

status=0

# --- 1. parse check ------------------------------------------------------
if command -v Rscript >/dev/null 2>&1; then
  if ! err="$(Rscript --vanilla -e 'q(status = tryCatch({parse(commandArgs(TRUE)[1]); 0L}, error = function(e) {cat(conditionMessage(e), file = stderr()); 1L}))' "$f" 2>&1)"; then
    printf 'R PARSE ERROR in %s\n%s\n' "$f" "$err" >&2
    status=2
  fi
fi

# --- 2. air format (opt-in per project) ----------------------------------
if [ -f "$root/air.toml" ] && command -v air >/dev/null 2>&1 && [ "$status" -eq 0 ]; then
  before="$(cksum < "$f")"
  air format "$f" >/dev/null 2>&1 || true
  after="$(cksum < "$f")"
  if [ "$before" != "$after" ]; then
    printf 'air reformatted %s to match %s/air.toml. Re-read the file before editing it again.\n' "$f" "$root" >&2
    status=2
  fi
fi

exit "$status"
