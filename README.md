# Project dashboard

Release status, open issues and plan progress across the open source projects
in `~/Development`, served as a small Phoenix application that collects
everything once a day and on demand.

```
mix setup
mix phx.server
```

Then open [http://localhost:4000](http://localhost:4000). The first visit
shows a waiting page while the initial collection runs; it reloads itself when
the report is ready. After that the page has a **Refresh** button, and the
service collects again every 24 hours on its own.

## What it reports

**Release status** comes from git and the build file first, so it is accurate
for unpublished work, with hex.pm as the second opinion: a clone that has not
been fetched since a release still carries old tags and an old `mix.exs`, and
hex is what says so.

| State | Meaning |
|---|---|
| Current | the newest tag matches the declared version and nothing follows it |
| Unreleased work | commits exist beyond the newest tag |
| Awaiting a tag | the version was bumped but not tagged — usually the last step before publishing |
| Ahead of mix.exs | the newest tag, or the version on hex, is ahead of the declared version: a stale clone or a mistake |
| Never released | the repository has no tags |

Alongside that: commits since the tag, uncommitted and unpushed work, the
current branch when it is not the default, and whether the CHANGELOG has an
`Unreleased` section waiting, with the first few entries. Whether a clone
**needs pulling** is asked of origin directly: `git ls-remote` (read-only, it
fetches nothing) says what origin's HEAD is, and a clone that does not have
that commit is behind, whether or not it has ever fetched. Commits counted
from the last fetch and a release hex knows about are the fallbacks. Each
library is also looked up on hex.pm: the published version is a column of its own, linking to
the package page, and a clone whose newest tag is behind hex is flagged to be
fetched.

**Issues** come from the GitHub REST API: open issues and pull requests
separated, how many have had no reply, how many have gone untouched for 180
days, median and oldest age, and the label mix.

**CI** is the newest workflow run on the default branch, from the GitHub
Actions API: a column linking to the run, a "CI failing" chip, and a warning
flag naming the workflow, branch and commit when the run failed.

**Plan progress** is read from `TODO.md` and `plans/*.md`. The house format,
defined in the system `CLAUDE.md` under "Plan and TODO documents", is what the
parser is built for:

* `TODO.md` has five sections — `## Open`, `## In progress`, `## Blocked`,
  `## Deferred`, `## Done` — and one checkbox bullet per item. `[x]` is done;
  `[ ]` takes the state of its section. Nothing else marks state.
* A `plans/` document opens with `**Status:** state, date`, shown verbatim.
  It counts nothing unless it has a `## Tasks` checkbox list or a table with a
  `Status` column.

**Maintenance status** comes from each repository's `STATUS.md`, whose
`**Status:**` line is one of `active`, `application`, `demo only`, `bug fixes
only`, `archived` or `fork`; a missing file means active. Anything other than
active is shown as a badge beside the name, and the "Active" chip filters to
repositories under development. The status also decides which signals are
raised: a demo or an application is never nagged about release tags, and a
library kept for bug fixes only is not expected to see commits. A fork or an archived repository — by `STATUS.md` or
because GitHub says so — is left out of the report altogether and listed under
`omitted` in `data.json`.

**Blockers** come from `**Blocked on:**` lines in the same file, one per thing
a release is waiting for. A blocker naming a hex package and a version
requirement (`localize ~> 1.3`) is checked against hex's latest version of that
package every collection and raises a warning when it is satisfied; any other
blocker is text with an expected date, and becomes a warning once that date
passes. A blocked repository is badged, its release nags drop to info, the
"Blocked" chip filters to them, and the "Upcoming" panel lists blockers in
date order with the repositories each one unblocks.

The older conventions these repositories used before the format was settled
still parse — index tables marked `✅` / `🟡` / `❌`, bullets annotated with
`✅`, `~~strikethrough~~` or `**Done**`, and section headings that carry a
verdict — so a document that has not been converted yet is still read rather
than dropped. A `plans/` document written as prose is listed as **prose**, with
its status line and headings shown but no item counts invented for it. The
parser refuses to count a plan it cannot actually read, so a number on the
dashboard is always a number someone wrote down.

## Running it as a service

The application needs no database. Configuration is read from the environment
at start-up:

| Variable | Default | Purpose |
|---|---|---|
| `PORT` | `4000` | HTTP port |
| `DASHBOARD_DATA_DIR` | `~/.cache/dashboard` | where `data.json` and the GitHub and hex ETag caches are kept |
| `DASHBOARD_REFRESH_HOURS` | `24` | hours between automatic collections |
| `DASHBOARD_PROJECTS` | `priv/projects.exs` | the registry file to read |
| `GITHUB_DASHBOARD_TOKEN` | — | GitHub token; `GITHUB_TOKEN` and `GH_TOKEN` are also accepted |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER` | — | the usual Phoenix release settings, production only |

The last successful report is persisted to `data.json` in the data directory,
so a restarted service serves it immediately and only collects again when it
is older than the refresh interval.

To build a release:

```
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
PHX_SERVER=true SECRET_KEY_BASE=$(mix phx.gen.secret) _build/prod/rel/dashboard/bin/dashboard start
```

## The token

Set `GITHUB_DASHBOARD_TOKEN` in your shell — it is already in `~/.zshrc`. Only
`public_repo` scope is needed, and a classic token with no scopes at all works
for public repositories. The token is read from the environment only and is
never written to the report, the page or the cache.

Without a token GitHub allows 60 requests an hour, which will not cover every
repository in one pass. Every response is cached with its ETag, so a repeat run
sends `If-None-Match` and an unchanged repository costs nothing against the
limit. An unauthenticated service therefore catches up over a few refreshes;
the dashboard says where the gaps are.

## HTTP API

| Route | Purpose |
|---|---|
| `GET /` | the dashboard |
| `POST /refresh` | start a collection now; answers `202` with the status. Needs the CSRF token the page carries |
| `GET /api/status` | `ready`, `refreshing`, `generated_at`, `next_refresh_at`, `last_error`, `last_duration_ms` |
| `GET /data.json` | the latest report |

Other processes in the VM can subscribe with `Dashboard.Store.subscribe/0` and
receive `{:dashboard, :refreshed, status}` after each collection.

## One-off collection

The report can also be produced without the server, exactly as the original
script did:

```
mix dashboard.collect                 collect everything
mix dashboard.collect --no-github     do not ask GitHub for issues
mix dashboard.collect --no-hex        do not ask hex.pm what is published
mix dashboard.collect --no-remote     do not ask each clone's origin for its HEAD
mix dashboard.collect --only Tempo    one project; repeatable
mix dashboard.collect --open          open the dashboard when it is written
mix dashboard.collect --out DIR       write somewhere other than the data directory
mix dashboard.collect --quiet         no progress output
```

It writes `data.json` and a self-contained `dashboard.html` that opens straight
from disk with no server. The static page has no refresh button.

## Adding a project

A **project** is a family of repositories in one directory under
`~/Development` (Localize, Image, Tempo, …); the dashboard shows one table per
project, and "Other" holds the repositories that belong to none. To add a
repository, clone it into the right project directory: every git working tree
inside one is picked up automatically — no edit needed.

To add a **project**, add an entry to `:groups` in `priv/projects.exs` (the
key keeps its old name so the report format is unchanged). To leave a
repository out, add its path to `:exclude`. Elixir, Erlang, Gleam, LFE and
Node projects are all understood; the version is read from `mix.exs`,
`src/*.app.src`, `gleam.toml` or `package.json`.

## In the dashboard

`/` focuses the filter box; Escape clears it. The chips along the top narrow to
what needs a decision. Each project is a table with one row per repository; clicking
a row opens its detail, and the issue, pull-request and hex counts link to
GitHub and hex.pm in a new tab. "Needs attention" has a "Needs pulling" column
with the reason as its tooltip, and a row there jumps to that project's
detail. Columns are defined in one list in the template, so adding
one is adding an entry. "Table view" adds a table beside each release bar. The
theme follows the system and can be pinned light or dark.

## Layout

```
lib/dashboard/projects.ex     the registry: which projects and repositories are covered
lib/dashboard/store.ex        holds the latest report; 24-hour and on-demand refresh
lib/dashboard/collector.ex    orchestration and derived metrics
lib/dashboard/git.ex          clone state, project version, release state
lib/dashboard/changelog.ex    CHANGELOG parsing
lib/dashboard/plans.ex        plan-document parsing
lib/dashboard/status.ex       STATUS.md parsing
lib/dashboard/github.ex       GitHub REST client
lib/dashboard/hex.ex          hex.pm client
lib/dashboard/http.ex         the HTTP transport and ETag cache both clients share
lib/dashboard_web/            the Phoenix endpoint, router and controller
  controllers/dashboard_html/index.html.heex   the page, with the report inlined
lib/mix/tasks/                mix dashboard.collect
priv/projects.exs             the registry file
```

The page is self-contained — its styles and script are inline — so the same
template serves the application and the static file.

## Development

```
mix test
mix format
mix dialyzer
```

Targets Elixir 1.20 and OTP 29. Enable the formatting pre-commit hook once per
clone with `git config core.hooksPath .githooks`.
