#!/usr/bin/env bats
#
# guard-news-dev-heading.sh: development notes live under one heading.
#
# The guard denies a heading that INTRODUCES a development version number. Carrying
# an existing one through an edit, or removing one while folding the file back into
# shape, has to stay possible -- that repair is the whole point.

load helpers

GUARD() { echo "$PKGDEV/guard-news-dev-heading.sh"; }

DEV_HEADING='# pkg (development version)'

# A package directory with a NEWS.md.
with_package() {
  PKG="$BATS_TEST_TMPDIR/pkg"
  mkdir -p "$PKG"
  printf 'Package: pkg\nVersion: 1.2.0.9027\n' > "$PKG/DESCRIPTION"
  printf '%s\n\n## Bug fixes\n\n* fixed a thing\n\n# pkg 1.2.0\n\n* released\n' "$DEV_HEADING" > "$PKG/NEWS.md"
}

# edit_payload <file> <old_string> <new_string>
edit_payload() {
  jq -nc --arg f "$1" --arg o "$2" --arg n "$3" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $f, old_string: $o, new_string: $n}}'
}

## ------------------------------------------------------------------ denies --

@test "denies a numbered development heading added by an edit" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "$DEV_HEADING" "$DEV_HEADING

# pkg 1.2.0.9028

* new thing")"
  [ "$(decision)" = deny ]
  [[ "$(reason)" == *"1.2.0.9028"* ]]
  [[ "$(reason)" == *"(development version)"* ]]
}

@test "denies a whole-file write that adds one" {
  with_package
  hook "$(GUARD)" "$(write_payload "$PKG/NEWS.md" "# pkg 1.2.0.9028

* new thing

$DEV_HEADING

* fixed a thing")"
  [ "$(decision)" = deny ]
}

@test "denies regardless of heading level or package name" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "x" "## anotherPkg 0.9.1.9000")"
  [ "$(decision)" = deny ]
}

@test "denies in a lowercase news.md" {
  with_package
  mv "$PKG/NEWS.md" "$PKG/news.md"
  hook "$(GUARD)" "$(edit_payload "$PKG/news.md" "x" "# pkg 1.2.0.9028")"
  [ "$(decision)" = deny ]
}

## ----------------------------------------------------------------- allows --

@test "allows a bullet filed under the development heading" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "## Bug fixes" "## Bug fixes

* fixed another thing")"
  [ "$(decision)" = none ]
}

@test "allows an edit that carries an existing numbered heading through" {
  with_package
  printf '# pkg 1.2.0.9027\n\n* old\n' > "$PKG/NEWS.md"
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "# pkg 1.2.0.9027

* old" "# pkg 1.2.0.9027

* old
* newer")"
  [ "$(decision)" = none ]
}

@test "allows folding numbered headings back in" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "# pkg 1.2.0.9027

* old" "* old")"
  [ "$(decision)" = none ]
}

@test "allows a whole-file rewrite that keeps what was already there" {
  with_package
  printf '# pkg 1.2.0.9027\n\n* old\n' > "$PKG/NEWS.md"
  hook "$(GUARD)" "$(write_payload "$PKG/NEWS.md" "# pkg 1.2.0.9027

* old
* newer")"
  [ "$(decision)" = none ]
}

@test "allows a release heading" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "$DEV_HEADING" "# pkg 1.2.1")"
  [ "$(decision)" = none ]
}

@test "allows a development version named inside a bullet" {
  with_package
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "## Bug fixes" "## Bug fixes

* requires pkgB (>= 1.2.0.9027)")"
  [ "$(decision)" = none ]
}

## ----------------------------------------------------------------- scope --

@test "ignores a NEWS.md that is not beside a DESCRIPTION" {
  with_package
  rm "$PKG/DESCRIPTION"
  hook "$(GUARD)" "$(edit_payload "$PKG/NEWS.md" "x" "# pkg 1.2.0.9028")"
  [ "$(decision)" = none ]
}

@test "ignores other files" {
  with_package
  hook "$(GUARD)" "$(write_payload "$PKG/README.md" "# pkg 1.2.0.9028")"
  [ "$(decision)" = none ]
  hook "$(GUARD)" "$(write_payload "$PKG/R/code.R" "## pkg 1.2.0.9028")"
  [ "$(decision)" = none ]
}

@test "covers a multi-edit" {
  with_package
  hook "$(GUARD)" "$(jq -nc --arg f "$PKG/NEWS.md" \
    '{hook_event_name: "PreToolUse", tool_name: "Edit",
      tool_input: {file_path: $f, edits: [{old_string: "a", new_string: "* fine"},
                                          {old_string: "b", new_string: "# pkg 1.2.0.9028"}]}}')"
  [ "$(decision)" = deny ]
}

@test "silent on an empty or malformed payload" {
  hook "$(GUARD)" ''
  [ "$(decision)" = none ]
  hook "$(GUARD)" 'not json'
  [ "$(decision)" = none ]
}
