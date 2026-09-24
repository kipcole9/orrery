# Customising Orrery

This guide is written for a developer, or a developer's coding assistant,
setting the dashboard up for their own repositories. It names every file,
option and convention the dashboard depends on, in the order you will meet
them. Nothing here requires reading the source, but every claim points at
the module that implements it.

## What it is

A Phoenix application that walks a set of local git checkouts and reports,
per repository: release state (from git tags, `mix.exs` and hex.pm), open
issues and pull requests (GitHub), the latest CI run (GitHub Actions),
whether the clone needs pulling (`git ls-remote` against origin), plan
progress (from `TODO.md` and `plans/*.md`), and a maintenance status with
release blockers (from `STATUS.md`). It collects on a schedule and on demand,
keeps the last report on disk, and serves one self-contained HTML page.

It reads. It never writes to a repository: no fetch, no checkout, no commit.
The only network calls are `git ls-remote` to each origin, the GitHub REST API
and the hex.pm API, all read-only.

## Prerequisites

* Elixir 1.20 or later on OTP 27 or later (`.tool-versions` pins what the
  authors run). Earlier versions are not supported.
* `git` on the `PATH`.
* A GitHub token in the environment (see *GitHub* below). Optional, but
  without one the dashboard is limited to 60 GitHub requests an hour.
* Network access to `api.github.com`, `hex.pm` and your git remotes. Each
  can be switched off (see *Switching sources off*).

## Quick start

```bash
mix setup
ORRERY_GITHUB_TOKEN=... mix phx.server
```

Open <http://localhost:4000>. The first visit shows a waiting page while the
first collection runs; it reloads itself when the report is ready.

To produce a static page instead of running a server:

```bash
mix orrery.collect --open
```

## Which repositories are covered

The registry is `priv/projects.exs`, an Elixir map evaluated at collection
time (`Orrery.Projects`):

```elixir
%{
  root: "~/Development",
  groups: [
    %{name: "Localize", dir: "localize", blurb: "CLDR-backed localisation"},
    %{name: "Other", dir: ".", blurb: "Repositories that belong to no project", repos: ["astro", "url"]}
  ],
  exclude: ["localize/icu", "image/libvips"]
}
```

* `root` is the directory everything is relative to; `~` is expanded.
* Each entry in `groups` is a **project** (the page calls them projects; the
  key keeps its historical name). `dir` is a directory under `root`, and
  every git working tree directly inside it is a repository of that project.
  Cloning a new repository into the directory is all it takes to add it.
* A project with a `repos` list covers exactly those paths (relative to
  `root`) instead of scanning its directory. Use this for a catch-all
  project like "Other".
* `exclude` lists paths (relative to `root`) never to show: vendored
  upstream sources, data checkouts, GitHub organisation profile repositories.
* Projects are shown alphabetically; a project named `Other` is always last.

`ORRERY_PROJECTS=/path/to/projects.exs` points the running service at a
registry elsewhere, for example outside the checkout in a deployment.

Repositories can be Elixir, Erlang, Gleam, LFE or Node projects; the version
is read from `mix.exs` (`@version` or `version:`), `src/*.app.src`,
`gleam.toml` or `package.json` (`Orrery.Git.project/1`). Anything else is
still listed, with git state only.

## What each repository should contain

The dashboard reads three optional files from each repository root. All are
plain Markdown, and none is required; the dashboard degrades to git-only
facts without them. The full house rules are in the maintainer's system
`CLAUDE.md`; this is the subset the parser depends on (`Orrery.Status`,
`Orrery.Plans`).

### `STATUS.md`

```markdown
# Status

**Status:** active, 2026-09-21

**Next release:** 1.3.0
**Blocked on:** localize ~> 1.3, expected 2026-10
**Blocked on:** CLDR 49 final release, expected 2026-10

A sentence or two of context.
```

`**Status:**` is one of:

| State | Effect on the dashboard |
|---|---|
| `active` | the default when the file is missing; all signals apply |
| `application` | never published to hex; release-tag nags do not apply |
| `demo only` | a playground or sample; no release or activity nags |
| `bug fixes only` | release nags apply, activity nags do not |
| `archived` | left out of the report entirely (listed under `omitted`) |
| `fork` | left out of the report entirely |

Anything else is shown as a warning ("STATUS.md says …") rather than guessed.
An explicit `STATUS.md` is authoritative over what GitHub reports: a
repository GitHub marks as a fork or archived is omitted only when it has no
`STATUS.md` saying otherwise.

`**Blocked on:**` lines (any number) name what a release waits for. A line of
the form `<hex package> <version requirement>` (`localize ~> 1.3`,
`unicode_string >= 2.4`, `localize 1.3.0` meaning at least that) is checked
against hex's latest version of that package on every collection and raises
"blocker cleared" when satisfied; that package must itself be one of the
covered repositories, since the dashboard reads its hex state from the report.
Any other text is a note with an optional `, expected YYYY-MM` or
`YYYY-MM-DD`, which becomes "blocker overdue" once the date passes. While
blocked, release nags drop to informational and the repository appears in
the *Upcoming* panel. `**Next release:**` names the version being held up
when `mix.exs` has not been bumped yet.

### `TODO.md`

Five sections in this order, `## Open`, `## In progress`, `## Blocked`,
`## Deferred`, `## Done`, each holding checkbox bullets:

```markdown
## Open

* [ ] **Short title** — one or two sentences.

## Done

* [x] **Short title** — what shipped. 2026-07-15, v0.15.1.
```

State is the checkbox plus the section: `[x]` is done anywhere; `[ ]` is
open, in progress, blocked or deferred by section. Only top-level bullets
count. The dashboard shows open counts per repository and the first thirty
open items in the detail view.

### `plans/*.md`

Design documents. The first lines are a title and `**Status:** state, date`
(`draft`, `planning`, `in progress`, `deferred`, `implemented (vX.Y.Z)`,
`superseded by …`, `abandoned`, `reference`), shown verbatim. A plan counts
items only if it has a `## Tasks` checkbox list or a table with a `Status`
column whose cells are `Done`, `In progress`, `Blocked` or `Open`; otherwise
it is listed as prose.

Older conventions still parse (index tables marked ✅ / 🟡 / ❌, bullets with
`~~strikethrough~~` or `**Done**`, headings carrying a verdict), so a
repository that has not adopted the format is read rather than dropped.

## GitHub

The token is read from the first of `ORRERY_GITHUB_TOKEN`, `GITHUB_TOKEN`,
`GH_TOKEN` that is set (`Orrery.GitHub.token/0`). A fine-grained token
with read access to metadata, issues and actions, or a classic token with
`public_repo`, is enough for public repositories; a classic token with no
scopes also works for public data. The token is never written to the report,
the page, the cache or a log.

Per repository and collection, the dashboard makes three kinds of request:
the repository record (`fork`, `archived`, default branch, stars), the open
issues and pull requests (paged, 100 at a time, up to five pages), and the
newest workflow run on the default branch. Every response is cached with its
ETag under the data directory, and a repeat request sends `If-None-Match`; a
`304 Not Modified` costs nothing against the rate limit. An unauthenticated
service therefore fills in over a few collections rather than failing.

Which repository to ask about comes from the clone's `origin` (or
`upstream`) remote URL; only `github.com` remotes are understood. A
repository without a remote is reported with a warning and no GitHub data.

## Hex

Each library (kind Elixir, Erlang, Gleam or LFE; status `active`, `bug fixes
only` or unknown) is looked up at `https://hex.pm/api/packages/<app>`, where
`<app>` is the `app:` name from `mix.exs`. This is what lets the dashboard
tell "never released" from "released, but this clone has not fetched the
tag", and what resolves package blockers. Responses are ETag-cached; hex
allows 100 unauthenticated requests a minute.

## Origin

For each clone, `git ls-remote origin HEAD` asks origin for its HEAD and the
dashboard checks whether that commit exists locally. If not, the clone
"needs pulling", whether or not it has ever fetched. It fetches nothing. This
is about a second per repository over the network.

## Switching sources off

| Source | Mix task flag | Store option (`Orrery.Store` `collector_options`) |
|---|---|---|
| GitHub | `--no-github` | `github?: false` |
| hex.pm | `--no-hex` | `hex?: false` |
| origin HEAD | `--no-remote` | `remote?: false` |

With all three off, a collection is local git plus the three Markdown files
and takes a few seconds for sixty repositories.

## Schedule and environment

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `4000` | HTTP port |
| `ORRERY_SCHEDULE` | `5-20` | on the hour within that window of local hours; or `every 90m` / `every 6h` |
| `ORRERY_DATA_DIR` | `~/.cache/orrery` | `data.json` and the GitHub and hex ETag caches |
| `ORRERY_PROJECTS` | `priv/projects.exs` | the registry file |
| `ORRERY_GITHUB_TOKEN` | — | GitHub token (also `GITHUB_TOKEN`, `GH_TOKEN`) |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER` | — | standard Phoenix release settings, production only |

The store (`Orrery.Store`) persists every successful report to
`data.json`. On start it serves that report immediately and collects at once
only if a scheduled slot has passed since the report was made, or the
registry file is newer than it; otherwise it waits for the next slot. The
page's **Refresh** button starts a full collection; the ↻ button on a row
collects only that repository and splices it into the report, which is the
cheap way to re-check one repository after fixing something.

## Running as a service

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
PHX_SERVER=true SECRET_KEY_BASE=$(mix phx.gen.secret) \
  ORRERY_GITHUB_TOKEN=... ORRERY_PROJECTS=/etc/dashboard/projects.exs \
  _build/prod/rel/dashboard/bin/dashboard start
```

The dashboard has no authentication of its own. It is meant to run on a
workstation or behind something that already authenticates; do not expose it
directly on the public internet, because `POST /refresh` lets anyone trigger
collections against your GitHub budget.

## HTTP API

| Route | Purpose |
|---|---|
| `GET /` | the page |
| `GET /data.json` | the full report, as the page receives it |
| `GET /api/status` | `ready`, `refreshing`, `refreshing_repo`, `generated_at`, `next_refresh_at`, `schedule`, `last_error` |
| `POST /refresh` | full collection; `202` with the status; needs the CSRF token the page carries |
| `POST /refresh` with `repo=<path>` | one repository, by its path relative to `root` |

Elixir code in the same VM can subscribe with `Orrery.Store.subscribe/0`
and receive `{:orrery, :refreshed, status}` after each collection.

## Changing what the page shows

The page is one template,
`lib/orrery_web/controllers/orrery_html/index.html.heex`, with its
CSS and JavaScript inline so the same template renders the static file.

* **Columns.** Each project table is driven by the `COLUMNS` array in the
  template; "Needs attention" by `ATTENTION`; "Upcoming" by `UPCOMING`. An
  entry is `{ label, cls, cell: r => node }`. Adding a column is adding an
  entry; the data available to `cell` is one repository from `data.json`.
* **Filter chips** are the `FILTERS` array: `{ key, label, test: r => bool }`.
* **Release-state labels** are `STATE_LABEL` and `STATES`.
* **Signals** ("flags") are computed server-side in
  `Orrery.Collector.flags/1`, one `flag(condition, severity, category,
  message)` per line; `:warn` puts a repository in "Needs attention", `:info`
  shows only in its detail. Add a new signal there, and a test in
  `test/dashboard/collector_flags_test.exs`, which builds throwaway
  repositories under the system temp directory.
* **Summary tiles** read `report.summary`, computed in
  `Orrery.Collector.summarise/1`.

Report keys must be valid JavaScript identifiers (`failed`, not `failed?`);
a bad one breaks the whole page script. `node --check` on the extracted
`<script>` catches this before a refresh does.

## Where the data goes

The data directory holds `data.json` (the latest report, pretty-printed for
diffing), `github/` and `hex/` (ETag caches, one JSON file per request,
safe to delete). Nothing else is written anywhere. The report contains
repository paths under `root`, commit subjects, issue titles and labels, and
plan item text; treat `data.json` and the static page as containing whatever
your repositories contain.

## Renaming the application

The OTP application is `:orrery` with modules under `Orrery` and
`OrreryWeb`, the Mix task is `mix orrery.collect`, the environment
variables are `ORRERY_*`, and the default data directory is
`~/.cache/orrery`. To rename, change all four consistently: `mix.exs`
(`app:`), the module names (a search-and-replace of `Orrery` and
`dashboard` under `lib/`, `test/` and `config/`), `config/runtime.exs` for
the variables, and `Orrery.Store.default_data_dir/0`.

## Troubleshooting

* **"GitHub rate limit reached — some counts are cached"** in the subtitle:
  no token, or the token is not in the environment of the process running
  the server (a token set in an interactive shell profile is not seen by a
  launchd or systemd service). Cached responses still fill in.
* **A repository shows "Never released" but is on hex:** the clone has not
  fetched since the release. The dashboard says so ("hex has vX but the
  newest local tag is …") and flags it as needing a pull.
* **A tag exists but the dashboard says the version is not tagged:** the tag
  points at a commit not in the branch's history (a rebased-away release
  commit). The warning names the commit; `git tag -f` it onto the branch.
* **A repository is missing:** check `omitted` in `/data.json`. Forks and
  archived repositories are left out unless their `STATUS.md` says
  otherwise; paths in `exclude` never appear.
* **Changes to the registry do not show:** the running service collects on
  its schedule; press Refresh, or restart (the registry being newer than the
  saved report triggers an immediate collection).
* **The page stops rendering after a template change:** open the browser
  console; a JavaScript error in the inline script blanks the page. Run
  `node --check` on the script as above.
