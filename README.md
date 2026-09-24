# Orrery

Release status, open issues, CI results and plan progress across a family of repositories, collected from local git checkouts, GitHub and hex.pm and served as a single page by a small Phoenix application.

Orrery is for a maintainer with many related repositories checked out side by side. It answers "what needs my attention?" across all of them at once: which versions are bumped but not tagged, which clones are behind origin, which issues have had no reply, which CI runs failed, and which releases are waiting on something else to ship first. It only reads: it never fetches, checks out or writes to any repository.

## Features

* **Release state from git first, hex second** — the newest tag, the version in `mix.exs` and the commits since the tag decide whether a repository is current, has unreleased work or is awaiting a tag. hex.pm is the second opinion, so a clone that has not fetched since a release is reported as stale rather than "never released".

* **Needs pulling** — `git ls-remote` asks each clone's origin for its HEAD and checks whether the clone has that commit, whether or not it has ever fetched. Nothing is fetched.

* **Issues, pull requests and CI** — open issues and pull requests from the GitHub REST API, with how many have had no reply and how many have gone stale, plus the newest workflow run on the default branch.

* **Plan progress** — open items counted from each repository's `TODO.md` and `plans/*.md`, in a simple checkbox-and-section format described in the [customising guide](guides/customising.md).

* **Maintenance status and blockers** — a `STATUS.md` per repository marks it active, an application, demo only, bug fixes only, archived or a fork, and names what a release is blocked on. A blocker naming a hex package (`localize ~> 1.3`) is checked on every collection and reported the moment it clears; an "Upcoming" panel lists what unblocks what, in date order.

* **Needs attention** — every warning across every repository in one table, each row with a button to re-collect just that repository once the problem is fixed.

* **Scheduled and on-demand collection** — on the hour within a window of local hours (05:00 to 20:00 by default), from a Refresh button, or for a single repository. Every GitHub and hex response is cached with its ETag, so an unchanged repository costs nothing against the rate limits.

* **A static page too** — `mix orrery.collect` writes the same page as a self-contained HTML file that opens from disk with no server.

## Supported Elixir and OTP versions

Orrery requires **Elixir 1.20+** and **Erlang/OTP 27+**. Earlier Elixir releases are not supported. It also needs `git` on the `PATH`.

## Installation

Orrery is an application, not a library. Clone it and fetch its dependencies:

```sh
git clone https://github.com/kipcole9/orrery.git
cd orrery
mix setup
```

## Quick start

The registry in `priv/projects.exs` says which repositories to cover. The one in this repository is the author's own; replace it with yours:

```elixir
%{
  root: "~/Development",
  groups: [
    %{name: "Localize", dir: "localize", blurb: "CLDR-backed localisation"},
    %{name: "Other", dir: ".", blurb: "Repositories that belong to no project", repos: ["astro", "url"]}
  ],
  exclude: ["localize/icu"]
}
```

Each entry in `groups` is a project: every git working tree inside its `dir` is picked up automatically, or exactly the paths in `repos` when that key is present. Paths in `exclude` never appear.

Then start the server with a GitHub token in the environment:

```sh
ORRERY_GITHUB_TOKEN=<token> mix phx.server
```

Open [http://localhost:4000](http://localhost:4000). The first visit shows a waiting page while the first collection runs, and reloads itself when the report is ready.

## Configuration

Everything is read from the environment at start-up:

| Variable | Default | Purpose |
|---|---|---|
| `ORRERY_GITHUB_TOKEN` | none | GitHub token. `GITHUB_TOKEN` and `GH_TOKEN` are also accepted, in that order. |
| `ORRERY_PROJECTS` | `priv/projects.exs` | The registry file. |
| `ORRERY_SCHEDULE` | `5-20` | On the hour within that window of local hours, or `every 90m` / `every 6h`. |
| `ORRERY_DATA_DIR` | `~/.cache/orrery` | Where the latest report and the GitHub and hex caches are kept. |
| `PORT` | `4000` | HTTP port. |
| `SECRET_KEY_BASE`, `PHX_HOST`, `PHX_SERVER` | none | The usual Phoenix release settings, production only. |

A classic token with no scopes, or a fine-grained token with read-only access to public repositories, is enough for public repositories. The token is read from the environment only and is never written to the report, the page or the caches. Without one, GitHub allows 60 requests an hour; the ETag cache means an unauthenticated service fills in over a few collections rather than failing.

The latest report is persisted to `data.json` in the data directory. On start, Orrery serves it at once and collects immediately only if a scheduled slot has passed since it was made, or the registry file is newer than it.

## Repository conventions

Orrery reads three optional Markdown files from each repository root. None is required; without them a repository is reported from git, GitHub and hex alone.

* **`STATUS.md`** — the maintenance status, and any `**Blocked on:**` lines.

* **`TODO.md`** — five sections (`## Open`, `## In progress`, `## Blocked`, `## Deferred`, `## Done`) of checkbox items; an item's state is its checkbox plus its section.

* **`plans/*.md`** — design documents, each opening with a `**Status:** state, date` line that the page shows verbatim.

The [customising guide](guides/customising.md) describes each format in full, and [instructions for your coding assistant](guides/agent-instructions.md) give an assistant the rules for keeping all three current.

## Running as a service

```sh
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
PHX_SERVER=true SECRET_KEY_BASE=$(mix phx.gen.secret) ORRERY_GITHUB_TOKEN=<token> \
  _build/prod/rel/orrery/bin/orrery start
```

Orrery has no authentication of its own. Run it on a workstation or behind something that already authenticates; exposed directly, anyone could trigger collections against your GitHub rate limit.

## HTTP API

| Route | Purpose |
|---|---|
| `GET /` | The page. |
| `GET /data.json` | The latest report, as the page receives it. |
| `GET /api/status` | Whether a collection is running, when the report was made and when the next is due. |
| `POST /refresh` | Starts a full collection and answers `202`. Needs the CSRF token the page carries. |
| `POST /refresh` with `repo=<path>` | Collects one repository again and splices it into the report. |

Elixir code in the same VM can call `Orrery.Store.subscribe/0` to receive `{:orrery, :refreshed, status}` after each collection.

## One-off collection

The same report can be produced without the server:

```sh
mix orrery.collect --open
```

It writes `data.json` and a self-contained `orrery.html`. The options are:

* **`--only NAME`** — one project; repeatable.

* **`--no-github`**, **`--no-hex`**, **`--no-remote`** — skip GitHub, hex.pm or the origin check. With all three, a collection is local-only and takes a few seconds.

* **`--out DIR`** — write somewhere other than the data directory.

* **`--open`** — open the page when it is written.

* **`--quiet`** — no progress output.

## Development

```sh
mix test
mix format
mix dialyzer
```

Enable the formatting pre-commit hook once per clone with `git config core.hooksPath .githooks`.

## Documentation

* [`guides/customising.md`](guides/customising.md) — configuring Orrery for your own repositories, written so that a coding assistant can follow it: the registry, the repository conventions, GitHub and hex access, the schedule, adding columns and signals, and troubleshooting.

* [`guides/agent-instructions.md`](guides/agent-instructions.md) — paste-ready rules that make a coding assistant maintain `STATUS.md`, `TODO.md` and `plans/` in every repository it touches.

## License

Apache License 2.0. See the [LICENSE](LICENSE.md) file for details.
