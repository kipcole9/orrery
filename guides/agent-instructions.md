# Instructions for your coding assistant

Orrery reads three files from each repository: `STATUS.md`, `TODO.md` and `plans/*.md`. They stay useful only if whoever edits a repository keeps them current, and in practice that is often a coding assistant. This guide is the set of rules the author's own assistant follows to maintain them, in a form you can adopt.

## How to adopt it

* **For every project**, append everything under "The instructions" below to your assistant's user-level instructions: `~/.claude/CLAUDE.md` for Claude Code.

* **For one project**, add it to that repository's `CLAUDE.md`, or `AGENTS.md` for assistants that read that file instead.

* **With a different assistant**, keep the three formats exactly as written, since Orrery's parser depends on them.

* **Existing repositories** do not need converting up front. The rules below tell the assistant to convert a file the next time it touches that repository, and Orrery still reads older conventions (index tables with ✅ / 🟡 / ❌, `~~strikethrough~~`, `**Done**`) in the meantime.

Dates in the examples are illustrative. The formats are what matter: the section names, the checkbox bullets, and the `**Status:**`, `**Next release:**` and `**Blocked on:**` lines.

## The instructions

### Plan and TODO documents

Every repository keeps its work-tracking in exactly two places: one task list, `TODO.md` at the repository root, and design documents under `plans/`. `ROADMAP.md`, `PLAN.md`, `TODO` without an extension, `plan/`, `docs/plans/` and similar are not used — a roadmap is a `plans/` document, and the tasks it produces are `TODO.md` items. Orrery reads both, and the point of the format is that an item's state comes from exactly two signals — its checkbox and the section it sits in — so nothing has to be inferred from prose. When a file in a repository does not follow this format, converting it is part of the next piece of work that touches it.

#### TODO.md

```markdown
# TODO

One paragraph saying what this list covers and where the detail lives. Optional.

## Open

* [ ] **Short title** — what and why, in one or two sentences. Analysis in [plans/topic.md](plans/topic.md).

## In progress

* [ ] **Short title** — the same shape, plus one sentence on what has landed so far.

## Blocked

* [ ] **Short title** — what it needs. Blocked on the `json_schema` 2.0 release.

## Deferred

* [ ] **Short title** — why it is parked and what would revive it.

## Done

* [x] **Short title** — one line on what shipped. 2026-07-15, v0.15.1.
```

The rules, each of which Orrery relies on:

* **Five sections, these names, this order:** `## Open`, `## In progress`, `## Blocked`, `## Deferred`, `## Done`. Omit a section that is empty. No other `##` headings. `###` headings may group items inside a section (`### Optional ML extensions` under Deferred) and carry no state of their own.

* **An item is one top-level checkbox bullet**: `* [ ]` or `* [x]`, then a bold title, an em dash, and one or two sentences. `[x]` is done wherever it sits. `[ ]` is open, in progress, blocked or deferred according to its section. Nothing else marks state: no ✅ / 🟡 / ❌, no `~~strikethrough~~`, no `**Done.**`, no `(implemented)` in a heading, no status words the reader has to hunt for.

* **Short items, long plans.** A few continuation lines indented two spaces are fine; nested bullets are notes, not items, and are not counted. Anything longer than a short paragraph — an analysis, a list of options, a design — goes in `plans/<topic>.md` and the item links to it. Conversely, a `plans/` document does not carry the task list; it gets a one-line item here.

* **Done items stay, one line each, newest first,** with the ISO date and the version that shipped them when there is one. The detail is in the CHANGELOG, not here. Moving an item between sections means moving the line and flipping the checkbox, not rewriting it.

* **Blocked items name the blocker**; deferred items name the reason. Within a section, the most important item comes first.

#### plans/*.md

* One topic per file, kebab-case name (`plans/interval-unit.md`). A plan is a design document: the problem, the options, the decision, the shape of the work.

* The first lines are the title and a status line, exactly this shape:

  ```markdown
  # Interval units

  **Status:** implemented (v0.17.0), 2026-07-11
  ```

  The state is one of `draft`, `planning`, `in progress`, `deferred`, `implemented (vX.Y.Z)`, `superseded by plans/other.md`, `abandoned`, or `reference` (a document that records research or a decision and tracks no work), followed by a comma and the ISO date it was last reviewed. Anything more to say about the standing goes in the paragraph after it, not on the status line. Update the line whenever the document's standing changes; Orrery shows it verbatim.

* A plan that tracks its own work lists it as checkbox items under a `## Tasks` heading, in the same shape as `TODO.md` items, with `### Blocked` / `### Deferred` / `### Done` sub-groups if it needs them. A large matrix (a per-locale or per-spec-section index) may instead be a table with a `Status` column whose cells are `Done`, `In progress`, `Blocked` or `Open`. Everything else in the document is prose, and Orrery counts nothing in it.

#### STATUS.md

Every repository also carries a `STATUS.md` at its root saying what kind of maintenance it gets, so nobody (person or Orrery) has to infer it from commit dates or tags:

```markdown
# Status

**Status:** bug fixes only, 2026-09-21

`my_old_lib` is complete for its purpose and superseded by `my_new_lib`. Defects are fixed and released; no functional work is planned, and `TODO.md` stays empty.
```

The state is one of:

* `active` — a published library under development; functional work is planned and `TODO.md` tracks it.

* `application` — an application, never published to hex, under development (Orrery itself, for example). Release-tag nags do not apply.

* `demo only` — a playground or sample app that will never be released and gets no planned work.

* `bug fixes only` — a published library that is complete or superseded; defects are fixed and released, nothing else. `TODO.md` is empty apart from a sentence pointing here.

* `archived` — retired: no work of any kind, and archived on GitHub as well (`gh repo archive <owner>/<repo>`). Orrery leaves it out entirely, as it does anything GitHub reports as archived.

* `fork` — a clone of someone else's project, kept for contributing upstream. Orrery leaves it out entirely, as it does anything GitHub reports as a fork — unless a `STATUS.md` says otherwise: the file is authoritative over what GitHub infers, which is how a GitHub fork that has become the maintained line and the published package stays `active`.

The date is when the standing was last reviewed. A repository without a `STATUS.md` is read as `active`, which is why the file matters most on the ones that are not.

**Blockers.** When a repository cannot release until something else happens, say so under the status line, one `**Blocked on:**` line per thing, and name the release being held up with `**Next release:**` when `mix.exs` has not been bumped to it yet:

```markdown
**Status:** active, 2026-09-21

**Next release:** 1.3.0
**Blocked on:** my_core_lib ~> 1.3, expected 2026-10
**Blocked on:** the 2.0 specification's final release, expected 2026-10
```

* A blocker that is a hex package name followed by a version requirement (`my_core_lib ~> 1.3`, `req >= 0.5`, `my_core_lib 1.3.0` meaning at least that) is checked automatically: Orrery reads hex's latest version of that package every collection and raises a warning the moment the requirement is met ("blocker cleared"), so the release that was waiting gets made.

* Anything else is text. Give it an expected date (`, expected 2026-10` or `2026-10-15`); once that passes with the blocker still listed, Orrery raises "blocker overdue" so the line gets reviewed rather than rot.

* While blocked, the repository's release nags (awaiting a tag, unreleased work) are informational, not warnings, and Orrery's "Upcoming" panel shows what unblocks what, in date order. Remove the line when the blocker is gone; a cleared blocker left in place keeps warning.
