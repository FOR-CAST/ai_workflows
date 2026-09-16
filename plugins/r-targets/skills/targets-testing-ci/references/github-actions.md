# GitHub Actions for a targets + renv project

## Contents
- First: nobody's timings are real until the job has run
- The workflow, step by step
- setup-r: what it actually configures
- setup-renv: caching, and why a failure throws the build away
- System libraries
- Cold-cache cost
- renv surprises
- Repository access, submodules, forks
- Triggers and concurrency
- Shell gotchas in CI logic

Template: `assets/check.yaml`. Everything below about the actions' internals was verified
against the `r-lib/actions` source.

## First: nobody's timings are real until the job has run

A tests job that triggers only on `main` and pull requests never runs while the work sits on
a feature branch with no PR. In one project the quoted cold and warm times came from a
different, lightweight job. **Trigger the job once with `workflow_dispatch` on the working
branch, record the real cold-cache time, then set `timeout-minutes`.**

## The workflow, step by step

1. **syntax** job -- parses every tracked `.R` file, validates `renv.lock` as JSON and, when
   present, `CITATION.cff` against its schema (`cffconvert --validate`, via `pipx`, which the
   runner image provides), with `R_PROFILE_USER: /dev/null` so renv never starts. Cheap, and
   catches most breakage.
2. **tests** job:
   1. `actions/checkout` -- check the current major version; do not copy one from a guide.
   2. `r-lib/actions/setup-r@v2` with `r-version: renv`.
   3. System libraries derived from `renv.lock` (`assets/ci-sysreqs.R`), run from
      `${{ runner.temp }}`.
   4. `quarto-dev/quarto-actions/setup@v2` -- before anything that defines the pipeline, if
      it uses `tar_quarto()`.
   5. `r-lib/actions/setup-renv@v2` with `bypass-cache: never`.
   6. A warning if the restored library differs from the lockfile.
   7. Tests, then the validator.
   8. A guard that the checkout is untouched, including gitignored data paths.

Prefer the upstream `r-lib/actions` directly over organisation-specific wrapper actions.

## setup-r: what it actually configures

- `r-version: renv` reads R's version from `renv.lock`. Use it instead of a hard-coded
  version that becomes a second place to update.
- `use-public-rspm` defaults to `true` on x86_64 Linux and Windows. setup-r then exports
  `RSPM` and **`RENV_CONFIG_REPOS_OVERRIDE`**, pointing at Posit Package Manager's
  distro-specific binary repository. That override is what makes `renv::restore()` install
  Linux binaries. With it set, renv ignores the per-package `Repository` field in the
  lockfile -- including host-distro-specific URLs recorded on a developer machine. It is a
  single URL; for Bioconductor or r-universe alongside, set the variable yourself in the
  multi-repo form `NAME1=URL1;NAME2=URL2` (renv >= 1.1.6).
- **setup-r writes `options(repos = ...)`, the HTTP user agent and related settings into
  `$HOME/.Rprofile`.** R reads only one user profile: `./.Rprofile` if it exists, otherwise
  `~/.Rprofile`. So:
  - in a project with its own `.Rprofile`, setup-r's repos setting never applies there (renv
    still works, through the environment variable);
  - `R_PROFILE_USER=/dev/null` skips **both** files. Stock R ships `CRAN = @CRAN@`, so a
    non-interactive `install.packages()` then fails with "trying to use CRAN without setting
    a mirror". Pass `repos = Sys.getenv("RSPM", "https://cloud.r-project.org")` explicitly.
    It works locally only because a rig-installed R configures a default mirror.
- `R_PROFILE_USER=/dev/null` also stops renv activating, so it is **incompatible with any
  step that needs the project library**. Scope it to the job or step that needs it; never set
  it at workflow level.

## setup-renv: caching, and why a failure throws the build away

- It runs `actions/cache` itself. **Do not add your own cache step.**
- Cached paths: `${{ runner.temp }}/renv` (exported as `RENV_PATHS_ROOT`) and `renv/library`
  -- the library path relative to the workspace root, not to `working-directory`.
- Key: `<os-version>-<r-version>-<cache-version>-<hash of renv.lock>`; `restore-keys` drop the
  hash, so a changed lockfile warm-starts from the previous cache.
- Inputs, all of them: `profile`, `cache-version`, `bypass-cache`, `working-directory`.
- **With the default `bypass-cache: "false"`, the cache is saved only if the whole job
  succeeds.** A failing test, a timeout, or a cancellation (including by `concurrency`) throws
  away an hour-long cold build, and the retry is cold again. **`bypass-cache: never`** saves
  the cache even on failure.
- `profile` is evaluated as an R expression, so it needs nested quotes: `profile: '"ci"'`.
- Caches from a pull request are not visible to the default branch. Seed the cache with a run
  on the default branch. GitHub evicts caches unused for 7 days and caps a repository at 10 GB.

## System libraries

- **Stock distribution packages only. Never add a PPA such as ubuntugis.** Package Manager
  builds its binaries against the distribution's own GDAL/GEOS/PROJ; a PPA changes those
  libraries underneath and every spatial package builds from source. The binaries still link
  the system libraries at run time, so the `-dev` packages are needed even when nothing
  compiles.
- **Derive the list from the lockfile** (`assets/ci-sysreqs.R`) with
  `pak::sysreqs_db_match()`, rather than keeping an apt list that drifts. Run it from outside
  the project directory: inside it, the project `.Rprofile` activates renv, and pak has failed
  there with "Subprocess is busy". `renv::sysreqs()` output was not usable in practice, and
  `pak::pkg_sysreqs()` on lockfile refs can fail to solve.
- pak's pre- and post-install scripts (a rustup download, `R CMD javareconf`) are skipped
  unless asked for; install what you know you need.

## Cold-cache cost

A pinned lockfile records exact versions; Package Manager's `latest` snapshot serves binaries
only for current CRAN versions. Every pinned version that is not current, **and every GitHub
package**, builds from source. Measure before promising a fast pipeline:
`assets/cold-cache-estimate.R renv.lock noble`. Measured examples: 103 of 183 CRAN pins in one
lockfile; 29 CRAN versions plus 31 GitHub packages in another.

Dated snapshots do not rescue this -- a lockfile accretes over time and matches no single
snapshot date. The real fix is deliberately refreshing the lockfile against current CRAN,
which is a decision with its own consequences (every target reaching a changed package's
behaviour may change). Moving a single heavy package from a GitHub pin to its CRAN release is
a cheap partial win. `NOT_CRAN=true` lets an arrow source build download a prebuilt libarrow.

## renv surprises

- **`renv::restore()` may not reproduce the lockfile.** GitHub packages whose DESCRIPTION
  `Remotes:` point at moving branches get rebuilt at other versions, and the restore log ends
  with "The dependency tree was repaired during package installation". CI then tests versions
  the lockfile does not record. The template reports this with `renv::status()`.
- **`renv::restore()` has been observed rewriting `renv/activate.R`** with an unsubstituted
  template placeholder, after which R refuses to start in the project
  (`object '..md5..' not found`). The committed copy is fine. The checkout guard catches it;
  locally, check `git status` after any restore.
- **renv profiles are switched, not layered.** A profile uses only its own lockfile and
  library. If CI needs one, name it with `profile:`; if several must agree on shared package
  versions, a lockfile-only consistency check fits the syntax job.

## Repository access, submodules, forks

- `GITHUB_PAT: ${{ secrets.GITHUB_TOKEN }}` avoids the 60-requests-per-hour anonymous API
  limit, but **`GITHUB_TOKEN` can read only the repository running the workflow**. Check every
  GitHub dependency's visibility first (`gh repo view <owner>/<repo> --json visibility`); a
  private one needs a PAT stored as a secret.
- Do not check out submodules unless the job needs them: co-developed packages restore from
  their GitHub remotes in `renv.lock` (whose SHAs must therefore be pushed). **Never
  `submodules: true` when any submodule is private** -- initialise the needed paths
  explicitly, and fail on undeclared gaps.
- In a fork, `gh run list` and friends quietly query the upstream parent. Pass `-R owner/repo`.

## Triggers and concurrency

- Trigger on the branch you actually integrate on, not only `main`.
- `schedule:` runs only on the default branch.
- A branch with an open PR runs twice (push and pull_request) in different concurrency groups.
- `cancel-in-progress` saves minutes on a private repository, but pair it with
  `bypass-cache: never`.
- Set `timeout-minutes` on every job; a stalled step otherwise holds a runner for 6 hours.

## Shell gotchas in CI logic

- `grep -c` exits 1 on zero matches, so `n=$(grep -c pat file || echo 0)` yields `"0\n0"`.
  Use `grep pat file | wc -l`.
- `pgrep -f <pattern>` inside `ssh '...'` matches its own command line.
- `system2()` goes through a shell: quote a pathspec, or `git ls-files *.R` expands to
  top-level matches only.
