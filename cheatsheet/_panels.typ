// Typst helpers for the ai_workflows cheatsheet.
//
// Palette note. Eight per-plugin hues were tried first and rejected on evidence:
// shown together, as a cheatsheet shows them, they fail colourblind separation
// (worst all-pairs Delta E 3.2, floor 8) and the normal-vision floor (7.1, floor
// 15), and their greyscale luminances span 0.16-0.22, so a B&W print collapses
// them into one grey. What survives is one structural accent plus two status
// colours that never appear without a glyph beside them. Colour here is
// decoration; a glyph, a column header or a panel title always carries meaning.

#let ink = rgb("#1a1a19")
#let ink2 = rgb("#55554e")
#let hair = rgb("#d5d5cd")
#let wash = rgb("#f3f3ef")
#let accent = rgb("#1f5081")   // FOR-CAST blue
#let blocked = rgb("#e34948")
#let safe = rgb("#008300")

#let body-font = ("PT Sans Caption", "Noto Sans", "DejaVu Sans")
#let mono-font = ("Inconsolata", "Noto Sans Mono", "DejaVu Sans Mono")

// Applied once at the top of the body: the Quarto template justifies by default,
// which opens rivers in narrow columns, and hyphenation breaks names mid-word.
// `doc` last, so this can be applied with `#show: doc => sheet-typography(..., doc)`.
#let sheet-typography(colophon-left: none, colophon-right: none, doc) = {
  set page(
    numbering: none,
    // Distance from the text block down to the colophon. Typst anchors the footer
    // low in the margin by default, which put it inside the unprintable edge.
    footer-descent: 0pt,
    // A colophon in the page margin, so it sits at the foot of both sides
    // regardless of how far the content happens to reach down the columns.
    footer: if colophon-left == none { none } else {
      block(width: 100%, {
        line(length: 100%, stroke: 0.4pt + hair)
        v(2.2pt)
        grid(
          columns: (1fr, auto),
          align: (left + horizon, right + horizon),
          text(size: 0.76em, fill: ink2)[#colophon-left],
          text(size: 0.76em, fill: ink2)[#colophon-right],
        )
      })
    },
  )
  set smartquote(enabled: false)
  set par(justify: false, leading: 0.58em, spacing: 0.55em)
  set text(hyphenate: false)
  // Code is set at the same size as the body. Inconsolata's x-height is 89% of
  // PT Sans Caption's at equal size, which is a normal pairing difference; making
  // it smaller as well read as a different, shrunken typeface and misaligned the
  // baselines in every name/description row.
  // Inline code sits mid-sentence, where an 11% x-height deficit reads as a
  // shrunken font; 1.1em puts Inconsolata's x-height at 98% of the body face.
  // mono() stays at 1em because the name columns are width-bound.
  show raw: set text(font: mono-font, size: 1.1em)
  // Identifiers are full of hyphens, slashes, colons and at-signs, and Typst
  // treats every one as a break opportunity: "r-package-dev" split as "r-" /
  // "package-dev", and "/r-project-core:project-policy" split after the slash.
  // Boxing each identifier makes it atomic.
  show regex("[./]?[A-Za-z0-9][A-Za-z0-9_.]*(?:[-/:@][A-Za-z0-9_.]+)+"): it => box(it)
  doc
}

#let mono(s) = text(font: mono-font, size: 1em, fill: ink)[#s]
#let note(s) = text(fill: ink2)[#s]
#let scoped = text(fill: accent, size: 0.62em, baseline: -0.18em)[#sym.circle.filled]

// A titled panel; `count` sits right-aligned in the header bar.
#let panel(title, count: none, body) = block(width: 100%, breakable: false, below: 6pt, {
  block(
    width: 100%, fill: accent, inset: (x: 4pt, y: 2.4pt), radius: 1.2pt,
    grid(
      columns: (1fr, auto), align: (left + horizon, right + horizon),
      text(fill: white, weight: "bold", size: 1.0em, tracking: 0.35pt)[#upper(title)],
      if count == none { [] } else { text(fill: rgb("#cfe0f7"), size: 0.85em)[#count] },
    ),
  )
  v(2.2pt)
  body
})

// A group heading inside a panel, with a rule running out to an optional count.
#let subhead(t, count: none) = block(width: 100%, above: 6.5pt, below: 2.2pt, grid(
  columns: (auto, 1fr, auto), column-gutter: 3.5pt,
  align: (left + horizon, center + horizon, right + horizon),
  text(weight: "bold", size: 0.97em, fill: accent)[#t],
  line(length: 100%, stroke: 0.4pt + hair),
  if count == none { [] } else { text(size: 0.82em, fill: ink2)[#count] },
))

// Name/description rows: one grid per group, so names align down the column.
#let rows2(..cells) = grid(
  columns: (auto, 1fr), column-gutter: 4pt, row-gutter: 1.7pt,
  align: (left + top, left + top),
  ..cells,
)

#let no(s) = text(fill: blocked, weight: "bold", size: 0.95em)[#sym.times] + h(2.6pt) + mono(s)
#let yes(s) = text(fill: safe, weight: "bold", size: 0.95em)[#sym.arrow.r] + h(2.6pt) + mono(s)

// One blocked/instead pair, stacked so it fits a narrow column.
#let guardrow(bad, good) = block(below: 2.9pt, width: 100%, {
  no(bad)
  linebreak()
  h(9.4pt)
  yes(good)
})

#let codeline(s) = block(above: 2pt, below: 2pt, width: 100%, mono(s))

// A prose paragraph inside a panel. note() is inline, for grid cells; this is the
// block form, and it is what keeps prose off the code line above it.
#let notepara(s) = block(width: 100%, above: 8pt, below: 5pt, text(fill: ink2)[#s])

#let cols3(a, b, c) = grid(
  columns: (1fr, 1fr, 1fr), column-gutter: 9pt, align: top,
  a, b, c,
)

// The strip across the top of each side.
#let titlebar(title, sub, meta) = block(width: 100%, below: 6.5pt, {
  grid(
    columns: (auto, 1fr), align: (left + bottom, right + bottom),
    {
      text(size: 1.85em, weight: "bold", fill: ink)[#title]
      h(5pt)
      text(size: 1.05em, fill: ink2)[#sub]
    },
    text(size: 0.72em, fill: ink2)[#meta],
  )
  v(2.2pt)
  line(length: 100%, stroke: 1.1pt + accent)
})

#let footnote-strip(s) = block(width: 100%, above: 4pt, {
  line(length: 100%, stroke: 0.4pt + hair)
  v(2pt)
  text(size: 0.85em, fill: ink2)[#s]
})

// Name / description / count rows, for the plugin map.
#let rows3(..cells) = grid(
  columns: (auto, 1fr, auto), column-gutter: 4pt, row-gutter: 1.9pt,
  align: (left + top, left + top, right + top),
  ..cells,
)

#let cols2(a, b) = grid(
  columns: (1fr, 1fr), column-gutter: 11pt, align: top,
  a, b,
)

// One grid for a whole panel, so names align down the panel rather than per
// group; subheads span both columns via span2().
#let rowsg(..cells) = grid(
  columns: (auto, 1fr), column-gutter: 7pt, row-gutter: 3.2pt,
  align: (left + top, left + top),
  ..cells,
)

#let span2(c) = grid.cell(colspan: 2, c)

#let dot = text(fill: accent)[#sym.bullet]

// A workflow stage label: the same treatment as a subhead, used as a row label.
#let stage(s) = text(fill: accent, weight: "bold")[#s]

// A dimmer continuation line, for a bundle's contents under its name.
#let subnote(s) = text(fill: ink2, size: 0.88em)[#s]
