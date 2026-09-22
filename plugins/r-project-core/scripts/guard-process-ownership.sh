#!/usr/bin/env bash
# PreToolUse(Bash): never signal or remove a process, container, or screen session
# that this session did not start.
#
# This is the most expensive class of mistake in the record: an agent killed a
# multi-day calibration belonging to a DIFFERENT project on a shared node. These
# are shared machines; a stray pkill costs someone else days of compute.
#
# The command is allowed when it carries an explicit ownership marker, which you
# add only AFTER verifying the owner:
#     ps -o pid,user,lstart,cmd -p <pid>        # verify first
#     kill -TERM <pid>   # owner-verified: started by this session
set -uo pipefail
. "$(dirname "$0")/_policy.sh"

cmd="$(cat | jq -r '.tool_input.command // empty' 2>/dev/null)"
[ -z "$cmd" ] && exit 0
n=" $(printf '%s' "$cmd" | tr '\n' ';' | tr -s '[:space:]' ' ') "

# Escape hatch: an explicit, deliberate marker.
printf '%s' "$n" | grep -q 'owner-verified' && exit 0

hit=""
printf '%s' "$n" | grep -Eq " (pkill|killall)$B"                        && hit="pkill/killall"
printf '%s' "$n" | grep -Eq " kill +(-9|-KILL|-s +(9|KILL))$B"          && hit="kill -9"
docker="$(printf '%s' "$n" | grep -Eo " docker +(kill|stop|rm|system +prune)$B" | head -1)"
[ -n "$docker" ] && hit="$(printf '%s' "$docker" | tr -cs '[:alnum:]' ' ' | sed 's/^ *//; s/ *$//')"
printf '%s' "$n" | grep -Eq ' screen +-X +-S +[^ ]+ +quit'              && hit="screen quit"
printf '%s' "$n" | grep -Eq " (systemctl|supervisorctl) +(stop|kill|restart)$B" && hit="service stop"
[ -z "$hit" ] && exit 0

deny "BLOCKED: '$hit' can signal a process this session did not start.

These are shared machines. A stray pkill/docker stop has previously killed another
project's multi-day calibration run mid-flight.

Before signalling anything:
  1. identify the exact PID and confirm who started it and when:
       ps -o pid,user,lstart,etime,cmd -p <pid>
       docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}'
  2. confirm it belongs to THIS session's work;
  3. if it does, re-issue the command with an explicit marker, e.g.
       kill -TERM 12345   # owner-verified: launched by this session at 14:02

If the process is NOT yours: report it to the user and stop. Do not signal it,
even if it appears stuck or is blocking your work.

Note also that ending a screen does NOT stop a run whose child R processes (callr,
workers) survive it and keep their locks. See the hpc-cluster-runs skill for the
correct ordered shutdown."
