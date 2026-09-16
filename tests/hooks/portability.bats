#!/usr/bin/env bats
#
# Static checks that keep the hook scripts runnable on macOS (bash 3.2, BSD
# userland) as well as Linux. Behaviour is covered by the other test files; the
# macOS CI leg runs those too. These catch the constructs that fail there.

load helpers

scripts() {
  ls "$CORE"/*.sh "$PKGDEV"/*.sh
}

# code_lint <ERE>: fail listing every non-comment line that matches.
code_lint() {
  local hits
  hits="$(grep -nE "$1" $(scripts) | grep -Ev '^[^:]+:[0-9]+:[[:space:]]*#' || true)"
  [ -z "$hits" ] || { echo "$hits"; return 1; }
}

@test "every hook script is executable and uses env bash" {
  for f in $(scripts); do
    [ -x "$f" ] || { echo "not executable: $f"; return 1; }
    [ "$(head -1 "$f")" = '#!/usr/bin/env bash' ] || { echo "bad shebang: $f"; return 1; }
  done
}

@test "no bash-4-only builtins (mapfile, readarray, declare -A, case modification)" {
  code_lint '(^|[^[:alnum:]_])(mapfile|readarray)([^[:alnum:]_]|$)|declare +-A|\$\{[A-Za-z_]+(,,|\^\^)'
}

@test "no GNU-only tool flags (pgrep -a, sed -i, grep -P, date -d, stat -c)" {
  code_lint 'pgrep +-[a-zA-Z]*a|sed +-i|grep +-[a-zA-Z]*P|date +-d|stat +-c'
}

@test "no GNU regex escapes (\\b \\s \\w) in patterns" {
  code_lint '\\[bsw][^a-zA-Z]'
}

@test "USER is never expanded without a fallback (set -u aborts where it is unset)" {
  code_lint '\$USER([^[:alnum:]_]|$)|\$\{USER\}'
}

@test "shellcheck is clean" {
  command -v shellcheck >/dev/null || skip "shellcheck not installed"
  run shellcheck -x $(scripts)
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
}
