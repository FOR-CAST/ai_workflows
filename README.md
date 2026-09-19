# ai_workflows

Standardized agentic AI tooling for R-based research software: Claude Code
**skills**, **subagents** and **hooks**, packaged as a plugin marketplace.

The content is distilled from the git histories and session transcripts of a set of
production research projects -- simulation pipelines, geospatial analyses and R
packages. Everything here is general-purpose: the *lessons* are kept, the projects
they came from are not named.

## What is here

Eight plugins, organized by the kind of work they support:

| Plugin | For | Contents |
| --- | --- | --- |
| **r-project-core** | every R research project | R style, ASCII-only, citation integrity, config layout, commit discipline, design logs, project policy -- plus 11 guardrail hooks |
| **r-package-dev** | R package development | the development -> CI -> main -> project-install workflow, plus only the deltas over the `r-lib` skills: per-package overrides, dependency declaration, roxygen/NAMESPACE drift hook |
| **r-targets** | `{targets}` pipelines | tests + static validator + CI for pipeline projects, silent-staleness auditing, project structure, debugging, cluster runs |
| **r-geospatial** | GIS / spatial analysis | terra and sf across process boundaries, geometry hygiene, large-raster strategies |
| **r-spades** | SpaDES module development | the module metadata contract, `.inputObjects` timing, caching lessons |
| **r-landis-ii** | LANDIS-II integration | input preflight validation, output-reading rules |
| **r-reporting** | reports, provenance | writing for a stated audience (always asks who), summary-first structure, plain language; Quarto path traps, deriving numbers from the pipeline, manifests and receipts |
| **r-code-review** | software review | four read-only review subagents, plus the verification method |

Skills load on demand, so they cost nothing until they are relevant. Several are
scoped with `paths:` so they activate only when you are working on matching files.

## Install

```sh
# from within Claude Code, in any project
/plugin marketplace add ~/GitHub/FOR-CAST/ai_workflows
/plugin install r-project-core@ai-workflows
```

Or, once this repo is pushed:

```sh
/plugin marketplace add FOR-CAST/ai_workflows
```

To enable a set of plugins for a project and everyone working on it, add them to
the project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "ai-workflows": { "source": { "source": "github", "repo": "FOR-CAST/ai_workflows" } }
  },
  "enabledPlugins": {
    "r-project-core@ai-workflows": true,
    "r-targets@ai-workflows": true,
    "r-geospatial@ai-workflows": true
  }
}
```

See [docs/installation.md](docs/installation.md) for a per-project recommendation.

## Configure per project

The guardrails ship the *mechanism*; each repo declares its own *policy* in
`.claude/r-project-policy.json`. That split is deliberate -- these projects
genuinely disagree with one another about `air format`, R version pinning and
package installation, so hardcoding either side would be wrong somewhere.

```json
{
  "rBinary": "Rscript-4.6.1",
  "packageInstall": "renv",
  "noAirFormat": false,
  "publishRequiresApproval": true,
  "controllerHosts": ["control-node-name"]
}
```

Run `/r-project-core:project-policy` to generate one. Without the file, only the
universally-safe guards stay active.

## Documentation

- [**cheatsheet**](cheatsheet/ai-workflows-cheatsheet.pdf) -- the whole marketplace
  on two printed sides: what each plugin is for, which to enable, when each skill
  fires, what every hook blocks and what to do instead. It is a PDF, so the pages
  below remain the accessible text equivalent
- [docs/installation.md](docs/installation.md) -- what to enable where
- [docs/hooks.md](docs/hooks.md) -- every hook, what it prevents, how to disable it
- [docs/third-party.md](docs/third-party.md) -- third-party skills and plugins by workflow stage, and which to avoid
- [docs/traps.md](docs/traps.md) -- the failure catalogue the tooling was built from
- [docs/maintaining.md](docs/maintaining.md) -- checks, CI, and releasing a plugin version

## Design notes

- **Skills over CLAUDE.md.** A bloated `CLAUDE.md` gets ignored; skills load only
  when relevant. Keep project `CLAUDE.md` files short and let these carry the depth.
- **Hooks over instructions** for anything that must happen every time. An
  instruction is advisory; a hook is deterministic.
- **Deny with a way forward.** Every blocking hook names the safe alternative, so a
  block redirects rather than stalls.
- **No duplication of `r-lib`.** The `r-lib` skills cover R package development and
  dataviz well; `r-package-dev` carries only what those skills cannot know.
