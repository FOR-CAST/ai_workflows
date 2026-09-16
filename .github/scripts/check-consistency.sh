#!/usr/bin/env bash
# Repository invariants that `claude plugin validate --strict` does not check.
# Runs locally or in CI; prints every problem, then exits 1 if there were any.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

## Several checks run in piped while-loops (subshells), so count errors in a file.
errlog="$(mktemp)"
trap 'rm -f "$errlog"' EXIT
err() {
  echo x >>"$errlog"
  if [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    printf '::error file=%s::%s\n' "$1" "$2"
  else
    printf 'ERROR %s: %s\n' "$1" "$2"
  fi
}

mkt=.claude-plugin/marketplace.json

# frontmatter_name <file>: the `name:` field between the first two `---` lines
frontmatter_name() {
  awk 'NR == 1 && $0 != "---" { exit } NR > 1 && $0 == "---" { exit }
       NR > 1 && /^name:/ { sub(/^name:[[:space:]]*/, ""); gsub(/["'\'']/, ""); print; exit }' "$1"
}

## ------------------------------------------------------------- manifests --
jq -e . "$mkt" >/dev/null || { err "$mkt" "does not parse"; exit 1; }

[ "$(jq -r '."$schema"' "$mkt")" = "https://json.schemastore.org/claude-code-marketplace.json" ] ||
  err "$mkt" "\$schema must be https://json.schemastore.org/claude-code-marketplace.json"

jq -e '[.plugins[].name] as $n | $n == ($n | sort)' "$mkt" >/dev/null ||
  err "$mkt" "plugins are not sorted by name"

jq -r '.plugins[] | select(has("version")) | .name' "$mkt" | while IFS= read -r p; do
  err "$mkt" "entry '$p' sets version; plugin.json is the single source of truth (it silently wins)"
done

listed="$(jq -r '.plugins[].source | ltrimstr("./")' "$mkt" | sort)"
present="$(for d in plugins/*/; do printf '%s\n' "${d%/}"; done | sort)"
[ "$listed" = "$present" ] ||
  err "$mkt" "marketplace sources and plugins/ directories differ: $(diff <(echo "$listed") <(echo "$present") | grep '^[<>]' | tr '\n' ' ')"

jq -r '.plugins[] | [.name, (.source | ltrimstr("./"))] | @tsv' "$mkt" | while IFS=$'\t' read -r name src; do
  mf="$src/.claude-plugin/plugin.json"
  [ -f "$mf" ] || { err "$mkt" "no manifest at $mf"; continue; }
  [ "$(jq -r .name "$mf")" = "$name" ] || err "$mf" "name differs from the marketplace entry '$name'"
  [ "$(jq -r '."$schema"' "$mf")" = "https://json.schemastore.org/claude-code-plugin-manifest.json" ] ||
    err "$mf" "\$schema must be https://json.schemastore.org/claude-code-plugin-manifest.json"
  jq -r '.version // ""' "$mf" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' ||
    err "$mf" "version must be MAJOR.MINOR.PATCH"
  ## hooks/hooks.json loads automatically; naming it again refuses every hook in the plugin
  jq -r '[.hooks // empty] | flatten | .[] | strings' "$mf" | grep -Eq '^(\./)?hooks/hooks\.json$' &&
    err "$mf" "\"hooks\" names the default hooks/hooks.json; remove it (it is loaded automatically, and naming it again fails the load)"
done

## ----------------------------------------------------------- hook scripts --
for hj in plugins/*/hooks/hooks.json; do
  [ -f "$hj" ] || continue
  root="${hj%/hooks/hooks.json}"
  jq -r '.. | .command? // empty' "$hj" |
    grep -oE '\$\{CLAUDE_PLUGIN_ROOT\}"?/[^" ]+' | sed -E 's|^\$\{CLAUDE_PLUGIN_ROOT\}"?/||' |
    while IFS= read -r s; do
      f="$root/$s"
      if [ ! -f "$f" ]; then
        err "$hj" "references missing script $s"
      elif [ ! -x "$f" ]; then
        err "$f" "hook script is not executable"
      elif git ls-files --error-unmatch "$f" >/dev/null 2>&1 &&
        [ "$(git ls-files -s "$f" | cut -d' ' -f1)" != "100755" ]; then
        err "$f" "hook script is tracked without the executable bit (git update-index --chmod=+x)"
      fi
    done
done

## ------------------------------------------------------ skills and agents --
for f in plugins/*/skills/*/SKILL.md; do
  dir="$(basename "$(dirname "$f")")"
  [ "$(frontmatter_name "$f")" = "$dir" ] || err "$f" "frontmatter name does not match directory '$dir'"
done
for f in plugins/*/agents/*.md; do
  [ -f "$f" ] || continue
  [ "$(frontmatter_name "$f")" = "$(basename "$f" .md)" ] || err "$f" "frontmatter name does not match file name"
done

## ------------------------------------------------------------ text files --
files="$(git ls-files -co --exclude-standard | grep -Ev '\.(png|jpg|gif|pdf|ico)$')"
while IFS= read -r f; do
  [ -f "$f" ] || continue
  case "$f" in
    plugins/r-project-core/scripts/guard-ascii.sh) ;;  # matches non-ASCII on purpose
    *) LC_ALL=C grep -q '[^[:print:][:space:]]' "$f" && err "$f" "contains non-ASCII characters" ;;
  esac
  grep -q $'\r' "$f" && err "$f" "has CRLF line endings"
done <<<"$files"

## relative links in the top-level docs resolve
for md in README.md docs/*.md; do
  [ -f "$md" ] || continue
  grep -oE '\]\([^)#[:space:]]+(#[^)]*)?\)' "$md" | sed -E 's/^\]\(//; s/\)$//; s/#.*$//' |
    grep -Ev '^(https?:|mailto:)' | while IFS= read -r link; do
      [ -e "$(dirname "$md")/$link" ] || err "$md" "broken relative link: $link"
    done
done

n="$(wc -l <"$errlog" | tr -d ' ')"
[ "$n" -eq 0 ] && { echo "consistency: OK"; exit 0; }
echo "consistency: $n problem(s)"
exit 1
