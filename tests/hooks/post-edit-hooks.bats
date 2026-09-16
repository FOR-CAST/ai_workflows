#!/usr/bin/env bats
#
# PostToolUse and Stop hooks: check-citations.sh, r-format-and-parse.sh,
# rbuildignore-claude.sh, check-doc-sync.sh. These report on stderr with exit 2.

load helpers

setup() {
  isolate_project
}

## ------------------------------------------------------- check-citations --
## A fake curl on PATH keeps these tests off the network.

fake_curl() {
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/curl" <<'EOF'
#!/usr/bin/env bash
url="${*: -1}"
[ "$url" = "https://doi.org" ] && exit "${FAKE_OFFLINE:-0}"
case " $* " in
  *" -w "*) printf '%s' "${FAKE_CODE:-200}" ;;
  *"Accept: application/vnd.citationstyles.csl+json"*) printf '{"title": "A Real Paper"}' ;;
esac
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/curl"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
}

@test "a resolving DOI is reported with the title it resolves to" {
  fake_curl
  hook "$CORE/check-citations.sh" "$(write_payload refs.bib '@article{a, doi = {10.1234/real.5}}')"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'ok 10.1234/real.5'
  echo "$output" | grep -q 'A Real Paper'
}

@test "a DOI that does not resolve is flagged" {
  fake_curl
  export FAKE_CODE=404
  hook "$CORE/check-citations.sh" "$(write_payload report.qmd 'see doi:10.1234/made.up')"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'FABRICATED? 10.1234/made.up'
}

@test "offline, a DOI is 'could not verify', never 'fabricated'" {
  fake_curl
  export FAKE_OFFLINE=7
  hook "$CORE/check-citations.sh" "$(write_payload report.qmd 'doi:10.1234/real.5')"
  echo "$output" | grep -q 'could not verify'
  ! echo "$output" | grep -q 'FABRICATED'
}

@test "a new bib entry with no DOI is listed as unverified" {
  fake_curl
  hook "$CORE/check-citations.sh" "$(write_payload refs.bib '@book{nodoi2020, title = {A Book}}')"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'nodoi2020'
}

@test "files outside the covered extensions are ignored" {
  hook "$CORE/check-citations.sh" "$(write_payload script.py 'doi 10.1234/x.y')"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

## --file mode: check citation files that R wrote (grateful, cffr, manifest sync),
## which the Edit/Write hook never sees. Exit 1 only for DOIs that do not resolve.

@test "--file passes a generated bib whose DOIs resolve" {
  fake_curl
  f="$BATS_TEST_TMPDIR/r-packages.bib"
  printf '@Manual{sf, title = {sf}, doi = {10.32614/CRAN.package.sf}}\n' > "$f"
  run "$CORE/check-citations.sh" --file "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ok 10.32614/CRAN.package.sf'
}

@test "--file fails when a DOI in a generated file does not resolve" {
  fake_curl
  export FAKE_CODE=404
  f="$BATS_TEST_TMPDIR/CITATION.cff"
  printf 'cff-version: 1.2.0\ndoi: 10.32614/CRAN.package.notonCRAN\n' > "$f"
  run "$CORE/check-citations.sh" --file "$f"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'FABRICATED? 10.32614/CRAN.package.notonCRAN'
}

@test "--file lists entries without a DOI but does not fail on them" {
  fake_curl
  f="$BATS_TEST_TMPDIR/r-packages.bib"
  printf '@Manual{LandR, title = {LandR}, url = {https://github.com/PredictiveEcology/LandR}}\n' > "$f"
  run "$CORE/check-citations.sh" --file "$f"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'LandR'
}

@test "--file checks every file given" {
  fake_curl
  export FAKE_CODE=404
  good="$BATS_TEST_TMPDIR/a.bib"; bad="$BATS_TEST_TMPDIR/b.bib"
  printf 'no dois here\n' > "$good"
  printf '@Misc{x, doi = {10.1234/missing}}\n' > "$bad"
  run "$CORE/check-citations.sh" --file "$good" "$bad"
  [ "$status" -eq 1 ]
}

## ---------------------------------------------------- r-format-and-parse --

@test "an R file that does not parse is reported" {
  command -v Rscript >/dev/null || skip "Rscript not installed"
  f="$BATS_TEST_TMPDIR/bad.R"
  printf 'f <- function( {\n' > "$f"
  hook "$CORE/r-format-and-parse.sh" "$(write_payload "$f" '')"
  [ "$status" -eq 2 ]
  echo "$output" | grep -q 'R PARSE ERROR'
}

## ---------------------------------------------------- rbuildignore-claude --

@test ".claude is added to .Rbuildignore once, beside a DESCRIPTION" {
  pkg="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$pkg/.claude"
  printf 'Package: demo\n' > "$pkg/DESCRIPTION"
  printf '^data-raw$' > "$pkg/.Rbuildignore"
  hook "$PKGDEV/rbuildignore-claude.sh" "$(write_payload "$pkg/.claude/settings.json" '{}')"
  [ "$status" -eq 2 ]
  [ "$(grep -c '^\^\\\.claude\$$' "$pkg/.Rbuildignore")" -eq 1 ]
  grep -qx '\^data-raw\$' "$pkg/.Rbuildignore"
  hook "$PKGDEV/rbuildignore-claude.sh" "$(write_payload "$pkg/.claude/settings.json" '{}')"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\^\\\.claude\$$' "$pkg/.Rbuildignore")" -eq 1 ]
}

@test ".Rbuildignore is left alone outside a package" {
  d="$BATS_TEST_TMPDIR/notpkg"
  mkdir -p "$d/.claude"
  hook "$PKGDEV/rbuildignore-claude.sh" "$(write_payload "$d/.claude/settings.json" '{}')"
  [ "$status" -eq 0 ]
  [ ! -e "$d/.Rbuildignore" ]
}

## --------------------------------------------------------- check-doc-sync --

make_pkg_repo() {
  pkg="$BATS_TEST_TMPDIR/docpkg"
  mkdir -p "$pkg/R" "$pkg/man"
  printf 'Package: demo\n' > "$pkg/DESCRIPTION"
  printf "#' Fit\n#' @export\nfit <- function() 1\n" > "$pkg/R/fit.R"
  printf 'export(fit)\n' > "$pkg/NAMESPACE"
  git -C "$pkg" init -q
  git -C "$pkg" -c user.name=t -c user.email=t@t add DESCRIPTION R/fit.R NAMESPACE
  git -C "$pkg" -c user.name=t -c user.email=t@t commit -qm init
  export CLAUDE_PROJECT_DIR="$pkg"
}

@test "a roxygen change without regenerated docs blocks the stop and names the file" {
  make_pkg_repo
  printf "#' Fit a model\n#' @export\nfit <- function() 1\n" > "$pkg/R/fit.R"
  run "$PKGDEV/check-doc-sync.sh" </dev/null
  [ "$status" -eq 2 ]
  echo "$output" | grep -qx '  R/fit.R'
}

@test "a code-only change does not block the stop" {
  make_pkg_repo
  printf "#' Fit\n#' @export\nfit <- function() 2\n" > "$pkg/R/fit.R"
  run "$PKGDEV/check-doc-sync.sh" </dev/null
  [ "$status" -eq 0 ]
}
