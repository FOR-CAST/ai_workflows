---
name: hpc-cluster-runs
description: "Running long pipelines and heavy work on shared machines and clusters: what counts as heavy on a control node (including package tests, checks, source builds and data probes), launching runs that survive IDE memory kills (systemd-run, not screen or nohup), the ordered shutdown that actually stops a targets run, keeping worker checkouts in sync, and never touching a process you did not start."
when_to_use: Launching a long or multi-day run; stopping one; syncing code or packages across cluster nodes; a run is stuck or orphaned; deciding where to execute something on a shared machine; configuring crew or crew.ssh controllers.
paths:
  - "**/_hosts.R"
  - "**/_hosts.R.example"
  - "**/_targets.R"
  - "**/scripts/**"
---

# Long runs on shared machines

## Where work runs

The control node schedules work and hosts the user's interactive session. **Do not
run heavy work on it.** This is the most repeated correction in the session record
-- dozens of turns, several in capitals -- and the incidents behind it include
multi-day runs killed mid-flight and the user's IDE killed along with every session
inside it.

"Heavy" is broader than it looks. Each of these has taken a control node down:

- `tar_make()` on anything but light orchestration, renders (`quarto render`,
  `rmarkdown::render`), `tar_make(callr_function = NULL)` on a real target;
- **package work**: `devtools::test()`, `devtools::check()`, `R CMD check`, source
  builds from `renv::install` or `pak`;
- **data probing**: an unfiltered `sf::st_read()` of a multi-GB layer, `fread()` of a
  large CSV, a full-table `ogrinfo` scan, `terra::rasterize()`, concurrent large
  downloads -- "just a quick look" at a new data source is not exempt;
- ad-hoc scratch scripts. One line with the wrong units in a probe
  (`terra::densify(..., flat = FALSE)` on lon/lat reads the interval in metres)
  built 30 million vertices and peaked at 27 GB.

Light orchestration is fine on the control node: git, `tar_progress()`,
`tar_manifest()`, `tar_meta()`, `tar_outdated()`, `tar_validate()`, `tar_read()` of
small objects, and the node-sync script. When in doubt, it is heavy.

**Preflight before the first heavy thing in a session:**

```sh
hostname -s                                         # where am I? sessions open on any node
free -g
ps -eo pid,rss,etime,cmd --sort=-rss | head         # what is already resident?
```

Detect the role by capability, not by hostname string:

```r
if (file.exists("_hosts.R")) { ... }   ## robust to the cluster being renamed
```

Set `controllerHosts` in `.claude/r-project-policy.json` and the guard in
`r-project-core` will refuse heavy commands there.

**Dispatch instead.** Home directories are often local per node, so a compute node
has its own clone: bring it up to date, or stage the working tree on shared storage,
then run the work there:

```sh
ssh <compute-node> 'bash -s' < _tmp/job.sh
```

**If something genuinely must run on the control node, cap it**, so a runaway dies
alone instead of taking the IDE with it:

```sh
systemd-run --user --scope -p MemoryMax=4G -p MemorySwapMax=0 Rscript-4.6.1 -e '...'
```

## Why `nohup`, `setsid` and `screen` do not protect a run

`systemd-oomd` kills **cgroups**, not process trees. Anything launched from an IDE
terminal or from an agent's shell lives in the IDE's cgroup scope, and `nohup`,
`setsid`, `disown` and `screen` only detach it from the terminal -- they do not move
it out of that scope. When memory pressure crosses the threshold, oomd kills the
whole scope: the user's R sessions, every agent session, and every "detached" run
launched from them. In one incident a 5-day calibration died this way while a
sibling run survived, because only the survivor had been launched into its own unit.

Check where a process lives:

```sh
sed 's|.*/||' /proc/<pid>/cgroup     # must NOT be the IDE's app-*.scope
```

Agent background tasks die with the IDE too, so they cannot be the durable monitor
for a multi-day run. Use a systemd user timer for anything that must outlive the
session.

## Never touch a process you did not start

These are shared machines and several projects run on them at once. An agent once
killed another project's multi-day calibration, and a separate "cleanup" in one
project killed a sibling project's run with a global `docker rm -f $(docker ps -aq)`.
Before signalling anything:

```sh
ps -o pid,user,lstart,etime,cmd -p <pid>
docker ps --format '{{.ID}}\t{{.Names}}\t{{.Status}}'
```

If it is not yours, report it and stop. Scope any cleanup to your own project's
containers by name or pool id. The `SessionStart` hook lists what was already
running when your session began, precisely so you can tell the difference.

## Launching a long run

```sh
pgrep -af "tar_make|DEoptim"          ## preflight: is anything already running?
systemd-run --user --unit=<name> --collect \
  --working-directory="$PWD" bash _tmp/run_<name>.sh
systemctl --user status <name>
journalctl --user -u <name> -f        ## or tail the log the wrapper writes
```

The wrapper frames the run so the log is self-describing:

```bash
{ echo "=== <name> launch $(date -Is) ==="
  Rscript-4.6.1 -e 'targets::tar_make(callr_function = NULL)'
  echo "=== EXIT=$? $(date -Is) ==="
} > "$LOG" 2>&1
```

`callr_function = NULL` because the outer callr wrapper crashes under heavy
optimiser and container load.

Use `screen` only when you need to attach interactively, and launch the screen
itself through `systemd-run --user` if the run must survive memory pressure.

**Rename the log with a failure suffix when a run dies** -- it makes the failure
mode greppable months later: `.died_79of80`, `.oom-9gib`, `.gen5_prereboot`.

## Stopping a run -- order matters

**Launched as a systemd unit:** `systemctl --user stop <name>` signals every process
in the unit's cgroup, including the `callr` child. Then confirm nothing survived and
clear the lock if it remains:

```sh
ps -u "$USER" -o pid,etime,cmd | grep -E 'callr|exec/R' | grep -v grep
Rscript-4.6.1 -e 'targets::tar_unblock_process(store = "_targets")'
```

**Launched under `screen`:** ending the screen does **not** stop the run.
`tar_make()` wraps the pipeline in a `callr` child that does not receive SIGHUP; it
survives and keeps holding the store lock.

```sh
## 1. kill any retry loop FIRST, or it treats the dead R process as a crash
##    and relaunches everything
## 2. end the screen (the callr child survives this)
screen -X -S <name> quit
## 3. find and kill the surviving callr child
ps -u "$USER" -o pid,etime,cmd | grep -E 'callr|exec/R' | grep -v grep
kill -TERM <pid>
## 4. release the store lock
Rscript-4.6.1 -e 'targets::tar_unblock_process(store = "_targets")'
```

**Either way, then reap containers on every compute host.** Neither SSH nor the
scheduler reaps a worker's container children, and orphaned per-container workers
**restart** their containers. Kill the workers before the containers, or
`docker stop` is whack-a-mole. Rebooting the control node has the same effect as
killing the controller: remote workers keep running with nothing to report to.

## Keeping nodes in sync

The most common cluster footgun is mismatched code across nodes.

```sh
## 1. locally
git add <paths> && git commit && git push
## 2. on EACH worker node
ssh nodeN 'cd <project> && git pull && git submodule update --init --recursive'
## 3. only if the lockfile changed
ssh nodeN 'cd <project> && Rscript-4.6.1 -e "renv::restore(prompt = FALSE)"'
```

Three constraints worth automating into a `sync-nodes.R`:

- **Worker checkouts must stay clean.** A dirty tree blocks the `git merge --ff-only`
  that the sync relies on. Any target writing a git-tracked path must therefore be
  `deployment = "main"`.
- **Group hosts by OS codename and warm one per group first.** The package cache is
  keyed by codename, so parallel cold restores across nodes sharing a network cache
  cause redundant compilation and cache contention.
- **Check version *and* commit.** A node reporting the right package version can
  still be on a different commit; compare the recorded SHA against the lockfile, not
  just the version string.

**Never sync or install while a run is live** -- it swaps the library out from
under the active workers, and a lazy-load failure surfaces hours into a target with an
error pointing at the package rather than the cause. A hook in `r-project-core` blocks
this. If the renv cache is shared between machines, note the asymmetry: **installing** on
one machine only writes a new cache entry, which is safe for the others; the dangerous
step is the **restore** that re-points a library. To prepare an updated library while a
run is live, stage it in a second clone with `renv::isolate()` or
`options(renv.config.cache.symlinks = FALSE)`.

## Know what is shared between machines

Check rather than assume, with `ls -ld` and `df`. A common layout: home directories --
code, the renv library, sometimes the store -- are **local disk on every host**, and only
data and store directories are shared network mounts. Two consequences:

- **Code reaches a host only through commit, push, pull.** Editing locally and launching
  elsewhere silently runs the old code.
- **A `format = "file"` target whose file lives in a host-local directory** makes a shared
  store reference a file that exists on one machine. `tar_outdated()` from any other host
  then reports that target and its entire downstream cone as outdated. That is survivable
  only if the file is **deterministic** -- regenerated byte-identically, so hashes match and
  nothing downstream reruns. Check anything a file target writes for embedded timestamps,
  absolute paths and process IDs.

**One store cannot host two concurrent `tar_make()` calls.** On NFS, a *refused* second
`tar_make()` still compacts and replaces `_targets/meta/meta` before refusing, orphaning
the running pipeline's open handle. Check for a live run and launch in a single command,
never as two steps someone else can interleave.

## Controller sizing

- Size the local fallback pool so all branches run in one wave, but remember
  `terra` memory fractions are **per process**: N workers can collectively exceed
  RAM. Cap terra memory at `memfrac * node_RAM / n_workers`, and scope the cap to
  the stage that needs it so a retune does not invalidate cached work.
- Some backends need hard caps for reasons unrelated to RAM -- a Java-backed
  service capped at 6 workers because more caused socket errors, and it must be
  process-based rather than forked because forking corrupts its sockets.
- Raise `crashes_max` when running many workers; the default trips on a race.
- Set an explicit retry count for container execs. The default is 0, and one
  transient failure otherwise discards everything since the last checkpoint.
- Checkpoint every generation, not every N.

## Do not co-run two heavy projects on the same nodes

Documented after a control node hard-locked doing exactly that, and again after
four compute nodes went down in one night. The second mechanism is worth knowing:
two projects declared identical per-node worker caps sized for light workers, and a
report-render stage whose workers each needed 75-130 GB fanned out across them.
Worker caps must be sized to the heaviest stage that will use the pool, and a node
running one project's long calibration must be kept out of every other project's
pool. Check what is already running before launching, and say what you found.
