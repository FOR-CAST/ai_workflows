#!/usr/bin/env bash
# PreToolUse(Bash) guardrail.
#   deny   -> the command destroys uncommitted work, rewrites shared history,
#             or bypasses a verification gate. There is always a safe variant.
#   advise -> the command is legitimate but has bitten this codebase before;
#             pass a note to Claude without blocking.
# Contract: JSON decision on stdout, exit 0 always. Never block on hook error.
set -uo pipefail

payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0

deny() {
  jq -n --arg r "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r}}'
  exit 0
}
advise() {
  jq -n --arg c "$1" '{hookSpecificOutput: {
    hookEventName: "PreToolUse",
    additionalContext: $c}}'
  exit 0
}

# Collapse whitespace and newlines so `git   reset  --hard` still matches.
n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "
# Portable word boundary for grep -E (see _policy.sh); use only at a pattern's end.
B='([^[:alnum:]_]|$)'

## ---------- deny: destroys uncommitted work ----------
case "$n" in
  *"git reset --hard"*)
    deny "BLOCKED: 'git reset --hard' irreversibly discards uncommitted work. Use 'git stash push -m <why>' (recoverable) or reset specific paths. If the user explicitly asked to throw the changes away, say so and ask them to run it themselves." ;;
  *"git checkout -- ."*|*"git checkout ."*|*"git restore ."*)
    deny "BLOCKED: whole-tree checkout/restore discards every uncommitted edit. Restore named paths instead: 'git restore <path>'." ;;
esac

printf '%s' "$n" | grep -Eq 'git +clean +([^;|&]*-[a-zA-Z]*f|[^;|&]*--force)' && \
  deny "BLOCKED: 'git clean -fd*' deletes untracked files. Research projects routinely keep multi-GB caches, inputs/ and outputs/ untracked, and they are not cheaply reproducible. Run 'git clean -nd' first and show the user what would go."

printf '%s' "$n" | grep -Eq " git +branch +([^;|&]* )?(-[a-zA-Z]*D[a-zA-Z]*|--delete +--force|--force +--delete|-d +-f|-f +-d)$B" && \
  deny "BLOCKED: 'git branch -D' deletes a branch even when its commits exist nowhere else. Use 'git branch -d <branch>', which refuses unless the branch is merged. If it refuses, show the user 'git log --oneline <upstream>..<branch>' and let them decide."

printf '%s' "$n" | grep -Eq " git +worktree +remove +([^;|&]* )?(--force|-[a-zA-Z]*f[a-zA-Z]*)$B" && \
  deny "BLOCKED: 'git worktree remove --force' deletes the worktree's uncommitted and untracked files, and another session may be working in it. Run 'git -C <worktree> status --short' first, then 'git worktree remove <worktree>', which refuses while the worktree is dirty."

## ---------- deny: rewrites shared history ----------
if printf '%s' "$n" | grep -Eq " git +push$B"; then
  printf '%s' "$n" | grep -Eq '(--force( |$)|--force[^-]| -[a-zA-Z]*f[a-zA-Z]* )' \
    && ! printf '%s' "$n" | grep -q 'force-with-lease' \
    && deny "BLOCKED: bare 'git push --force' can erase a collaborator's commits. Use 'git push --force-with-lease'."
fi

## ---------- deny: bypasses a verification gate ----------
printf '%s' "$n" | grep -Eq 'git +(commit|merge|push) [^;|&]*--no-verify' && \
  deny "BLOCKED: '--no-verify' skips the pre-commit hooks that keep formatting and generated docs in sync. Fix the hook failure rather than bypassing it."

## ---------- deny: environment / provenance destruction ----------
printf '%s' "$n" | grep -Eq 'rm +-[a-zA-Z]*r[a-zA-Z]*[^;|&]*(renv/library|renv\.lock)' && \
  deny "BLOCKED: removing the renv library or lockfile destroys the reproducible environment. Use 'renv::restore()' or 'renv::rebuild()'."

printf '%s' "$n" | grep -Eq 'git +submodule +(deinit|foreach[^;|&]*reset)' && \
  deny "BLOCKED: forcible submodule operations silently move submodule pointers. Inspect with 'git submodule status' and move one module at a time."

## ---------- advise: legitimate but historically costly ----------
## (whole-tree staging is handled by guard-staging.sh)

printf '%s' "$n" | grep -Eq 'git +checkout +-b|git +switch +-c' && \
  advise "NOTE: creating a branch here. Confirm the base branch is current ('git fetch && git status') before branching."

exit 0
