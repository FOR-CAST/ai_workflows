#!/usr/bin/env bats

load helpers

setup() {
  isolate_project
  G="$CORE/guard-policy.sh"
}

## ---------------------------------------------------------------- installs --

@test "without a policy, installs are not policed" {
  bash_hook "$G" "Rscript -e 'install.packages(\"sf\")'"
  [ "$(decision)" = none ]
}

@test "renv policy denies install.packages and remotes" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript -e 'install.packages(\"sf\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'remotes::install_github(\"r-spatial/sf\")'"
  [ "$(decision)" = deny ]
}

@test "renv policy allows renv::install" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript -e 'renv::install(\"r-spatial/sf@main\", lock = TRUE, prompt = FALSE)'"
  [ "$(decision)" = none ]
}

@test "renv policy denies pak installs into the project library" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript -e 'pak::pak(\"sf\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'pak::pkg_install(\"sf\")'"
  [ "$(decision)" = deny ]
}

@test "renv policy still allows the recommended pak::local_install_dev_deps" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript --vanilla -e 'pak::local_install_dev_deps()'"
  [ "$(decision)" = none ]
}

@test "renv policy denies Require and SpaDES.project installs" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript -e 'Require::Install(\"PredictiveEcology/LandR@development\")'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'SpaDES.project::setupProject(paths = list())'"
  [ "$(decision)" = deny ]
}

@test "renv policy denies a bare snapshot, not an explicit one" {
  with_policy '{"packageInstall": "renv"}'
  bash_hook "$G" "Rscript -e 'renv::snapshot()'"
  [ "$(decision)" = deny ]
  bash_hook "$G" "Rscript -e 'renv::snapshot(packages = \"sf\")'"
  [ "$(decision)" = none ]
}

## ------------------------------------------------------------- air format --

@test "noAirFormat denies air format" {
  with_policy '{"noAirFormat": true}'
  bash_hook "$G" 'air format R/fit.R'
  [ "$(decision)" = deny ]
}

@test "air format --exclude is always denied" {
  bash_hook "$G" 'air format . --exclude R/old.R'
  [ "$(decision)" = deny ]
}

## ------------------------------------------------------------- publishing --

@test "without publishRequiresApproval, a push is not asked about" {
  bash_hook "$G" 'git push origin main'
  [ "$(decision)" = none ]
}

@test "publish policy asks before git push and gh pr create" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'git push origin main'
  [ "$(decision)" = ask ]
  bash_hook "$G" 'gh pr create --fill'
  [ "$(decision)" = ask ]
}

@test "publish policy asks before gh api with -X POST" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh api -X POST repos/o/r/issues -f title=x'
  [ "$(decision)" = ask ]
}

@test "publish policy asks before gh api with --method POST" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh api --method POST repos/o/r/issues'
  [ "$(decision)" = ask ]
  bash_hook "$G" 'gh api --method=PATCH repos/o/r/issues/1'
  [ "$(decision)" = ask ]
}

@test "publish policy asks before gh api with fields and no method (implicit POST)" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh api repos/o/r/pulls/1/comments/2/replies -f body=thanks'
  [ "$(decision)" = ask ]
  bash_hook "$G" 'gh api graphql -F query=@mutation.graphql'
  [ "$(decision)" = ask ]
  bash_hook "$G" 'gh api repos/o/r/issues --input body.json'
  [ "$(decision)" = ask ]
}

@test "publish policy does not ask for read-only gh api calls" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh api repos/o/r/pulls --jq .[].number'
  [ "$(decision)" = none ]
  bash_hook "$G" 'gh api -X GET search/issues -f q=repo:o/r'
  [ "$(decision)" = none ]
}

@test "publish policy asks before gh pr ready and gh extension install" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh pr ready 12'
  [ "$(decision)" = ask ]
  bash_hook "$G" 'gh extension install agynio/gh-pr-review'
  [ "$(decision)" = ask ]
}

@test "publish policy does not ask for gh reads" {
  with_policy '{"publishRequiresApproval": true}'
  bash_hook "$G" 'gh pr view 12 --json state'
  [ "$(decision)" = none ]
  bash_hook "$G" 'gh run list --limit 5'
  [ "$(decision)" = none ]
}

## ------------------------------------------------------- compute location --

@test "heavy compute on a listed control node is denied" {
  with_policy "{\"controllerHosts\": [\"elsewhere\", \"$(hostname -s)\"]}"
  bash_hook "$G" "Rscript -e 'targets::tar_make()'"
  [ "$(decision)" = deny ]
}

@test "light orchestration, ssh and capped scopes are allowed on a control node" {
  with_policy "{\"controllerHosts\": [\"$(hostname -s)\"]}"
  bash_hook "$G" 'git status'
  [ "$(decision)" = none ]
  bash_hook "$G" "ssh compute-node 'Rscript -e \"targets::tar_make()\"'"
  [ "$(decision)" = none ]
  bash_hook "$G" "systemd-run --user --scope -p MemoryMax=4G Rscript -e 'targets::tar_make()'"
  [ "$(decision)" = none ]
}

@test "heavy compute on a host not in controllerHosts is allowed" {
  with_policy '{"controllerHosts": ["some-other-host"]}'
  bash_hook "$G" "Rscript -e 'targets::tar_make()'"
  [ "$(decision)" = none ]
}

## ---------------------------------------------------------- R binary pin --

@test "rBinary advises on a bare Rscript and is silent on the pinned one" {
  with_policy '{"rBinary": "Rscript-4.6.1"}'
  bash_hook "$G" "Rscript -e '1'"
  [ -n "$(context)" ]
  bash_hook "$G" "Rscript-4.6.1 -e '1'"
  [ -z "$output" ]
}
