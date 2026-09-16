#!/usr/bin/env bash
# Mechanically enforce citation integrity.
#
# Fabricating a citation or a DOI is the highest-consequence error available here:
# it is not obviously wrong to a reader, it survives review, and it is not
# recoverable once published. The rule is prose in every project; this makes it
# checkable.
#
# For each DOI, resolve it. Report:
#   * DOIs that do not resolve            -> almost certainly fabricated
#   * the title each DOI resolves to      -> a DOI for a DIFFERENT work is visible
#   * bib entries carrying no DOI         -> flag as UNVERIFIED, do not present as verified
#
# Two modes:
#   PostToolUse(Edit|Write) hook -- the payload on stdin; checks the text this edit
#     introduced. Exit 2 => stderr is shown to the model (PostToolUse cannot block).
#   check-citations.sh --file PATH... -- checks citation files that R wrote
#     (grateful, cffr, a manifest-to-bib sync), which the hook never sees. Exit 1
#     only when a DOI does not resolve; entries without a DOI are listed, not failed.
#
# Network failure is reported as "could not verify", never as "fabricated".
set -uo pipefail

online=""
is_online() {
  if [ -z "$online" ]; then
    online=1
    curl -sf --max-time 5 -o /dev/null https://doi.org 2>/dev/null || online=0
  fi
  [ "$online" -eq 1 ]
}

# check_text <file name> <text>
# Sets: report     -- lines to show, empty when there was nothing to check
#       attention  -- 1 when anything needs a person to look
#       unresolved -- 1 when a DOI does not resolve
check_text() {
  local f="$1" text="$2" dois nodoi d code title k
  report=""
  attention=0
  unresolved=0

  dois="$(printf '%s' "$text" |
    grep -oiE '10\.[0-9]{4,9}/[-._;()/:a-z0-9A-Z]+' |
    sed 's/[.,;)}]*$//' | sort -u)"

  nodoi=""
  if [ "${f##*.}" = "bib" ]; then
    nodoi="$(printf '%s' "$text" | awk '
      /^[[:space:]]*@/ { if (key != "" && !hasdoi) print key; key=$0; sub(/^[^{]*\{/,"",key); sub(/,.*$/,"",key); hasdoi=0 }
      tolower($0) ~ /doi[[:space:]]*=/ { hasdoi=1 }
      END { if (key != "" && !hasdoi) print key }')"
  fi

  [ -z "$dois" ] && [ -z "$nodoi" ] && return 0

  if [ -n "$dois" ]; then
    while IFS= read -r d; do
      [ -z "$d" ] && continue
      if ! is_online; then
        report="${report}  ? ${d}  -- could not verify (no network); verify before relying on it
"
        attention=1
        continue
      fi
      code="$(curl -sIL --max-time 12 -o /dev/null -w '%{http_code}' "https://doi.org/${d}" 2>/dev/null || echo 000)"
      case "$code" in
        2*|3*)
          title="$(curl -sL --max-time 12 -H 'Accept: application/vnd.citationstyles.csl+json' \
            "https://doi.org/${d}" 2>/dev/null | jq -r '.title // empty' 2>/dev/null | head -1)"
          if [ -n "$title" ]; then
            report="${report}  ok ${d}
      resolves to: ${title}
"
          else
            report="${report}  ok ${d}  (resolves)
"
          fi
          ;;
        404|000)
          report="${report}  FABRICATED? ${d}  -- DOES NOT RESOLVE (HTTP ${code})
"
          attention=1
          unresolved=1
          ;;
        *)
          report="${report}  ? ${d}  -- unexpected HTTP ${code}; verify manually
"
          attention=1
          ;;
      esac
    done <<<"$dois"
  fi

  if [ -n "$nodoi" ]; then
    report="${report}
  Bib entries with NO doi field:
"
    while IFS= read -r k; do
      [ -n "$k" ] && report="${report}    - ${k}
"
    done <<<"$nodoi"
    report="${report}  A missing DOI is fine ONLY if the work genuinely has none. If an entry was
  not verified against an authoritative source, leave the uncertain fields null
  with a _todo note and tell the user -- do not present it as verified.
"
    attention=1
  fi
}

## ---------------------------------------------------------------- --file --
if [ "${1:-}" = "--file" ]; then
  shift
  rc=0
  for path in "$@"; do
    echo "CITATION CHECK -- ${path}"
    if [ ! -r "$path" ]; then
      echo "  cannot read ${path}"
      rc=1
      continue
    fi
    check_text "$path" "$(cat "$path")"
    if [ -z "$report" ]; then
      echo "  no DOIs or bib entries found"
    else
      printf '%s' "$report"
    fi
    [ "$unresolved" -eq 1 ] && rc=1
  done
  if [ "$rc" -ne 0 ]; then
    echo
    echo "A generated file is only as honest as its source. Fix a DOI that does not"
    echo "resolve where it comes from -- the package's DESCRIPTION or inst/CITATION, the"
    echo "manifest record, or the generator -- and regenerate; do not patch the output."
  fi
  exit "$rc"
fi

## ------------------------------------------------------------------ hook --
payload="$(cat)"
f="$(printf '%s' "$payload" | jq -r '.tool_input.file_path // empty' 2>/dev/null)"
[ -z "$f" ] && exit 0
case "$f" in
  *.bib|*.qmd|*.Rmd|*.rmd|*.md|*.tex|*.json|*.cff|*.R) ;;
  *) exit 0 ;;
esac

text="$(printf '%s' "$payload" | jq -r '
  [.tool_input.content?, .tool_input.new_string?,
   (.tool_input.edits? // [] | .[].new_string?)]
  | map(select(. != null)) | join("\n")' 2>/dev/null)"
[ -z "$text" ] && exit 0

check_text "$f" "$text"
[ -z "$report" ] && exit 0

if [ "$attention" -eq 1 ]; then
  {
    echo "CITATION CHECK -- ${f##*/}"
    echo
    printf '%s' "$report"
    echo
    echo "Rule: never invent a citation or any part of one (authors, year, title, journal,"
    echo "volume, pages, publisher, DOI, URL). Verify against an authoritative source, or"
    echo "leave the field null with a _todo and ASK. It is better to omit a citation than"
    echo "to include an unverified one. A DOI that does not resolve must be removed, not"
    echo "guessed at again."
  } >&2
else
  ## still surface the confirmed resolutions, as evidence
  printf 'CITATION CHECK -- %s\n%s' "${f##*/}" "$report" >&2
fi
exit 2
