#!/usr/bin/env bash
# Render the cheatsheet to cheatsheet/ai-workflows-cheatsheet.pdf.
#
# The document scans plugins/ and aborts the render when the sheet and the plugin
# tree disagree, so a non-zero exit here means the sheet is out of date, not that
# the toolchain is broken. The message names the entry to add or remove.
#
# Needs quarto (which bundles Typst -- no TeX) and R with yaml, jsonlite, knitr.
set -euo pipefail
cd "$(dirname "$0")"

# Typst stamps the PDF with the wall-clock time, so an unchanged sheet re-rendered a
# minute later is byte-different and dirties the working tree -- noise in a repo
# several sessions share. Normalising the timestamp makes identical content render to
# identical bytes. 1970 is the conventional marker for "deliberately not a real
# timestamp"; a plausible-looking fixed date would be worse, because it would read as
# a real one. Override to stamp a real date.
export SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-0}"

command -v quarto >/dev/null || {
  echo "quarto not found: see https://quarto.org/docs/download/" >&2
  exit 1
}

quarto render ai-workflows-cheatsheet.qmd "$@"
echo "cheatsheet/ai-workflows-cheatsheet.pdf is current with plugins/"
