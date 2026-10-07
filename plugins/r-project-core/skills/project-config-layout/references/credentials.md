# Credentials: service-account keys and other secrets

A project that reads Google Drive, a cloud bucket or an API needs a credential that
every machine running the pipeline can read, and that never reaches git or a Claude
transcript. The pattern below is written for a Google service-account key used by
`googledrive`; the storage, git and transcript parts apply to any key.

## Where the key lives

- **Outside the repository**, readable only by its owner:
  ```sh
  install -d -m 700 ~/.config/<project>
  install -m 600 <downloaded-key>.json ~/.config/<project>/drive-sa.json
  ```
  `ls -l` should show `-rw-------` with no trailing `+`; a `+` means an ACL grants
  someone else access. A key left in a project root with mode 664 can be read by
  every user of a shared machine.
- **A gitignored pointer** in the project root, `<Project>.Renviron`, holding the
  path, not the secret: `GOOGLEDRIVE_AUTH=~/.config/<project>/drive-sa.json`.
- **On every machine that runs the pipeline.** Node-sync scripts carry tracked code
  only, so copy both yourself, once and again whenever the key is replaced:
  ```sh
  rsync -a --chmod=D700,F600 ~/.config/<project>/ <node>:.config/<project>/
  rsync -a <Project>.Renviron <node>:<projdir>/
  ```

## `.Rprofile`: the service account, and nothing else

Rules, each learned from a failure:

1. **`options(gargle_oauth_email = FALSE)` in non-interactive sessions, before any
   login.** Otherwise, when the service-account login fails (no key on that node, the
   wrong key), the next Drive call runs `drive_auth()`, and gargle silently uses a
   cached personal token from `~/.cache/gargle` ("Using an auto-discovered, cached
   token"). The pipeline then runs as a person, not as the project.
2. **Clear `GOOGLEDRIVE_AUTH`, `GARGLE_SERVICE_ACCOUNT` and
   `GOOGLE_APPLICATION_CREDENTIALS` before reading the project's Renviron**, so a
   key set in `~/.Renviron` for another project is never used here.
3. **Check that the key belongs to the project**: its `project_id`, or its
   `client_email` where two projects use keys from one Google Cloud project.
4. **Never `message()` a JSON parse error from the key file.** It quotes key text.
   Report a fixed message instead.
5. **Log in when `googledrive` loads, with the service-account credential function
   only**, rather than at every R start.
6. **Do all of this after `source("renv/activate.R")`**, which can reset the process
   environment.

```r
## Non-interactive sessions never use a cached personal token; interactive sessions
## use your own login (run googledrive::drive_auth() once).
if (!interactive()) options(gargle_oauth_email = FALSE)

Sys.unsetenv(c("GOOGLEDRIVE_AUTH", "GARGLE_SERVICE_ACCOUNT", "GOOGLE_APPLICATION_CREDENTIALS"))
if (file.exists("<Project>.Renviron")) {
  readRenviron("<Project>.Renviron")
  local({
    key <- Sys.getenv("GOOGLEDRIVE_AUTH")
    if (!nzchar(key)) {
      return(invisible())
    }
    ## absolute, so it still resolves after a helper setwd()s elsewhere
    key <- normalizePath(path.expand(key), mustWork = FALSE)
    ## a fixed message on a bad key file: a JSON parse error would quote part of the key
    info <- if (file.exists(key)) tryCatch(jsonlite::read_json(key), error = function(e) NULL)
    problem <- if (!file.exists(key)) {
      paste("no key file at", key)
    } else if (is.null(info)) {
      "the key file could not be read as JSON"
    } else if (!identical(info$project_id, "<gcp-project-id>")) {
      "the key is not from the <gcp-project-id> project"
    }
    if (!is.null(problem)) {
      Sys.unsetenv("GOOGLEDRIVE_AUTH")
      message("<Project>: not using the Drive service account: ", problem)
      return(invisible())
    }
    Sys.setenv(GOOGLEDRIVE_AUTH = key)
    if (!interactive()) {
      setHook(packageEvent("googledrive", "onLoad"), function(...) {
        tryCatch(
          gargle::with_cred_funs(
            list(credentials_service_account = gargle::credentials_service_account),
            googledrive::drive_auth(path = key)
          ),
          error = function(e) {
            message("<Project>: Drive service-account login failed: ", conditionMessage(e))
          }
        )
      })
    }
  })
}
```

A Drive file that reports "not found" or 404 in a pipeline run usually means that
machine has no key, or the file is not shared with the service account.

## Keep it out of git

- **`.gitignore`**: list the key's usual names (`<gcp-project-id>-*.json`,
  `drive-sa*.json`) and `*.Renviron` in the secrets group, **after** its `!`
  entries, so no allowlist entry can re-include a stray copy.
- **A pre-commit hook** that refuses a staged private key or service-account key,
  whatever its name or `.gitignore` says: [`assets/dispatch`](../assets/dispatch),
  installed by [`assets/install.sh`](../assets/install.sh). Copy both into the
  project's `scripts/git-hooks/`, and have each person run
  `bash scripts/git-hooks/install.sh` once per machine. It installs to `~/.githooks`
  and sets `core.hooksPath` for all of that user's repositories, then runs each
  repository's own `.git/hooks/<name>`. A repository that sets its own
  `core.hooksPath` (husky, the pre-commit framework) bypasses it.
- **In a Claude session**, r-project-core's `guard-credentials.sh` refuses a
  `git add` or `git commit` whose files hold a key, before anything is staged.
- **On GitHub**, secret scanning and push protection are free on public
  repositories only.

If a key was ever pushed, revoke it in the cloud console and issue a new one.
Rewriting history does not undo a copy someone already fetched.

## Keep it out of the transcript

In the project's tracked `.claude/settings.json`:

```json
"permissions": { "deny": ["Read(~/.config/<project>/**)"] }
```

Claude Code applies that rule to its Read, Grep and Glob tools, to `cat`, `head`,
`tail`, `sed` and `tee`, and to redirections. `guard-credentials.sh` applies the
same rule to every other Bash command that names the path, such as `jq`, `base64`,
or an `Rscript` or Python process that would print the key. Listing the folder,
`stat`, `test -f`, `chmod`, and copying into the folder or to another machine still
pass. A pipeline that reads the key through `GOOGLEDRIVE_AUTH` never prints it, so
it runs normally. To learn something inside a key, such as its account, ask the user.

## Looking for stray keys

In Claude Code's Bash tool, `grep` is a wrapper that skips gitignored files, which
is where a stray key usually sits. Search with `/usr/bin/grep` or `find`:

```sh
/usr/bin/grep -rlE --exclude-dir=.git --exclude-dir=renv \
  -e '-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY' \
  -e '"type"[[:space:]]*:[[:space:]]*"service_account"' .
```
