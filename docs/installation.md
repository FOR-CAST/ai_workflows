# Installation

## Add the marketplace

Locally, while iterating:

```sh
/plugin marketplace add ~/GitHub/FOR-CAST/ai_workflows
```

From GitHub, once pushed:

```sh
/plugin marketplace add FOR-CAST/ai_workflows
/plugin marketplace update ai-workflows      # refresh later
```

Add the r-lib marketplace too:

```sh
/plugin marketplace add posit-dev/skills
```

`r-package-dev` **depends** on `r-lib@posit-dev-skills`, because its skills are
deltas on top of those and say so. Nothing auto-adds another marketplace: install
`r-package-dev` (or any bundle containing it) without this and it reports r-lib as
not installed, and every bundle above it inherits the error. Once the marketplace
is known, r-lib installs itself as a dependency.

Third-party marketplaces, this one included, have auto-update **off** by default.
Run `/plugin marketplace update ai-workflows`, then `/reload-plugins`, to pick up
changes. A plugin updates only when its `version` in `plugin.json` changes; CI
refuses a change to a plugin's files without that bump.

## What to enable, by project type

### Bundles, for a whole project

A bundle is a plugin that is only a name and a list of dependencies. Enabling one
enables everything under it, transitively, so a project declares a single entry
instead of six.

| Bundle | Pulls in |
| --- | --- |
| `r-bundle-research` | `r-project-core`, `r-geospatial`, `r-reporting`, `r-code-review`, `r-package-dev` (and r-lib through it) |
| `r-bundle-targets` | `r-bundle-research` plus `r-targets` |
| `r-bundle-spades` | `r-bundle-research` plus `r-spades` |
| `r-bundle-landis` | `r-bundle-research` plus `r-landis-ii` |

`r-bundle-research` carries no framework. Add the bundle for each framework the
project actually uses: a SpaDES project run from a `{targets}` pipeline enables
`r-bundle-spades` *and* `r-bundle-targets`, and a project that also drives LANDIS-II
adds `r-bundle-landis`. The shared plugins resolve once. Together they cost roughly 5.5k tokens
of always-on context.

### Individual plugins, for a narrower set

Enable `r-project-core` everywhere. Add the domain plugins the project actually
uses -- every enabled plugin costs context on every turn (`claude plugin details
<name>` prints the figure).

| Project type | Enable |
| --- | --- |
| R package | `r-project-core`, `r-package-dev`, `r-code-review` |
| `{targets}` pipeline | `r-project-core`, `r-targets`, `r-code-review` |
| Spatial / GIS analysis | `r-project-core`, `r-geospatial` |
| SpaDES simulation project | `r-project-core`, `r-spades`, `r-geospatial` |
| LANDIS-II driven project | `r-project-core`, `r-landis-ii`, `r-geospatial` |
| Anything run as a `{targets}` pipeline | add `r-targets` |
| Anything producing reports | add `r-reporting` |

## Per-project settings

Add to the project's `.claude/settings.json` so collaborators get the same setup:

```json
{
  "extraKnownMarketplaces": {
    "ai-workflows": {
      "source": { "source": "github", "repo": "FOR-CAST/ai_workflows" }
    },
    "posit-dev-skills": {
      "source": { "source": "github", "repo": "posit-dev/skills" }
    }
  },
  "enabledPlugins": {
    "r-bundle-spades@ai-workflows": true,
    "r-bundle-targets@ai-workflows": true
  }
}
```

Declare the posit marketplace even though nothing here enables a plugin from it:
it is what lets the r-lib dependency resolve when someone installs.

A plugin from an external source is not installed automatically for a collaborator
by enabling it here -- Claude Code reports it as not installed and shows the
`claude plugin install` command to run. The marketplaces above are registered when
they trust the folder in a session; the `claude plugin` CLI on its own does not
read project settings, so run the install from inside a session in the project.

## The project policy file

Create `.claude/r-project-policy.json` in each repo:

```sh
# in Claude Code
/r-project-core:project-policy
```

| Key | Effect |
| --- | --- |
| `rBinary` | non-blocking note when a bare `Rscript`/`R` is called |
| `packageInstall: "renv"` | denies `install.packages`, `devtools::install*`, `remotes::install_*`, `BiocManager::install`, `pak::pak`/`pkg_install`/`local_install`, `Require::Install`, `setupProject()`, and a bare `renv::snapshot()` (`pak::local_install_dev_deps()` in a vanilla session stays allowed) |
| `noAirFormat: true` | denies `air format` in this repo |
| `publishRequiresApproval: true` | forces a permission prompt (even in auto mode) for `git push`; `gh` writes (`pr`/`issue` create, merge, comment, review, edit, ready, close; release, repo, gist, label, secret and variable changes; `workflow run`); `gh api` with a write method **or with `-f`/`-F`/`--input` and no method**, which gh sends as a POST; `gh extension install`; and MCP tools whose names say they write or run code |
| `controllerHosts` | denies heavy compute on those hosts unless dispatched over `ssh` |
| `hostPatterns` | asks before a machine name reaches a commit message, a PR or issue body, release notes, the staged diff, or a tracked file (`FORCAST_HOST_PATTERNS` overrides it for one session) |
| `longRunPatterns` | what the live-run interlock and session report watch for (`FORCAST_LONGRUN_PATTERNS` overrides it for one session) |
| `heavyCommands` | overrides what counts as heavy for `controllerHosts` |
| `asciiExtensions` | which file types the ASCII guard covers (`FORCAST_ASCII_EXT` overrides it for one session) |

**If the repo keeps infrastructure identity out of version control**, gitignore
this file and commit a `.example` beside it -- `controllerHosts` and `hostPatterns`
name real machines.

## Verify

Start a session in the project. The `SessionStart` hook prints the host, its role,
the policy it loaded, any long-running processes already on the machine, and any
pre-existing uncommitted changes. If it prints nothing about policy, the file was
not found -- check the path and that the repo root resolves as you expect
(`git rev-parse --show-toplevel`).

## A note on symlinked repos

Several repos here are reachable under more than one path. The hooks resolve repo
identity through `git rev-parse --show-toplevel` piped through `readlink -f`, so a
policy lookup gives the same answer either way. If you write your own hooks,
do the same -- matching on the raw working directory will disagree with itself.
