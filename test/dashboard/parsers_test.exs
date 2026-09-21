defmodule Dashboard.ChangelogTest do
  use ExUnit.Case, async: true
  alias Dashboard.Changelog

  defp write(contents) do
    dir = Path.join(System.tmp_dir!(), "dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "CHANGELOG.md"), contents)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "Keep a Changelog headings" do
    info =
      write("""
      # Changelog

      ## [Unreleased]

      ### Added

      * Something new.
      * Something else.

      ### Fixed

      * A defect.

      ## [1.2.0] — August 16th, 2026

      * Earlier work.
      """)
      |> Changelog.info()

    assert info.unreleased == true
    assert info.unreleased_entries == 3
    assert info.unreleased_categories == ["Added", "Fixed"]
    assert info.latest_version == "1.2.0"
    assert info.latest_date == "2026-08-16"
  end

  test "the house style, where the newest heading names the released version" do
    info =
      write("""
      # Changelog

      ## Money v6.2.1

      This is the changelog for Money v6.2.1 released on August 4th, 2026.

      ### Bug Fixes

      * `Money.round/2` no longer crashes for nil `:iso_digits`.
      """)
      |> Changelog.info()

    assert info.unreleased == false
    assert info.latest_version == "6.2.1"
    assert info.latest_date == "2026-08-04"
    assert info.latest_heading == "Money v6.2.1"
  end

  test "the spelled-out variants of the same style" do
    for {heading, version} <- [
          {"## Astro version 2.5.0", "2.5.0"},
          {"## Unicode Set 1.9.0", "1.9.0"},
          {"## URL v2.0.1", "2.0.1"},
          {"## [0.44.0] - 2026-01-02", "0.44.0"}
        ] do
      info = write(heading <> "\n\n* An entry.\n") |> Changelog.info()
      assert info.latest_version == version, "expected #{version} from #{heading}"
    end
  end

  test "an unreleased heading with no entries under it does not count as pending" do
    info = write("## Unreleased\n\n## Tempo 1.6.4\n\n* Shipped.\n") |> Changelog.info()
    assert info.unreleased == false
    assert info.latest_version == "1.6.4"
  end

  test "continuation lines are not counted as separate entries" do
    info =
      write("""
      ## Unreleased

      * One entry that runs
        across two source lines.
      * A second entry.
      """)
      |> Changelog.info()

    assert info.unreleased_entries == 2
  end

  test "no changelog at all" do
    dir = Path.join(System.tmp_dir!(), "dash-empty-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    assert Changelog.info(dir) == nil
  end
end

defmodule Dashboard.PlansTest do
  use ExUnit.Case, async: true
  alias Dashboard.Plans

  defp items(text), do: text |> String.split("\n") |> Plans.items()

  describe "index tables" do
    test "marker column, with unmarked rows counting as open" do
      {items, style} =
        items("""
        # CLDR 49 upgrade plan

        | #  | Item                  | API impact | Breaking risk |
        |----|-----------------------|------------|---------------|
        | 1  | Pipeline migration    | None       | None — ✅ Done |
        | 2  | Translators guide     | None       | None — ✅ Done |
        | 11 | localize_emoji        | New lib    | Not yet started |
        | 12 | Conformance fixtures  | Tests only | ✅ Done |
        """)

      assert style == :table
      assert length(items) == 4
      assert Enum.count(items, &(&1.state == :done)) == 3

      assert [open] = Enum.filter(items, &(&1.state != :done))
      assert open.ref == "11"
      assert open.title == "localize_emoji"
    end

    test "a word status column, where a leading verdict governs the whole cell" do
      {items, :table} =
        items("""
        | Wave | Languages | Status |
        |---|---|---|
        | 0 | en, es | DONE (173/173) |
        | 1 | fr, de | DONE: all gates clean. Lists DEFERRED pending a decision. |
        | 8 | sr | BLOCKED on upstream PR #198 merging. |
        | 9 | de, da | NOT SCHEDULED. Prerequisite subsystem never ported. |
        """)

      assert Enum.map(items, & &1.state) == [:done, :done, :blocked, :blocked]
    end

    test "a table split by a blank line is one table" do
      {items, :table} =
        items("""
        | Wave | Item | Status |
        |---|---|---|
        | 0 | first | DONE |
        | 1 | second | DONE |

        | 2 | third | BLOCKED on upstream |
        """)

      assert length(items) == 3
      assert Enum.count(items, &(&1.state == :blocked)) == 1
    end

    test "sibling tables sharing a header are one index" do
      {items, :table} =
        items("""
        ## Pricing

        | # | Pattern | Support |
        |---|---------|---------|
        | P1 | Single price | ✅ Done |
        | P2 | Price range | 🟡 Partial |
        | P3 | Sale pair | ❌ Missing |

        ## Stock

        | # | Pattern | Support |
        |---|---------|---------|
        | E1 | Out of stock | 📝 Translation |
        | E2 | Backorder | 📝 Translation |
        """)

      assert length(items) == 5
      assert Enum.count(items, &(&1.state == :open)) == 2
    end

    test "a reference table is not an index, even with a column headed Status" do
      {items, style} =
        items("""
        Prose describing the options.

        | Value | Meaning | Status |
        |-------|---------|--------|
        | `:short` | Standard CLDR style | Existing |
        | `:yMMMd` | Field-skeleton match | Existing |
        | `%Skeleton{}` | Full TR35 | New in CLDR 49 work |
        """)

      assert items == []
      assert style == :narrative
    end

    test "an illustrative table with no statuses is ignored" do
      {items, :narrative} =
        items("""
        | Allen 1983 | Tempo today |
        |---|---|
        | The 13 relations | complete |
        | Composition table | complete |
        """)

      assert items == []
    end
  end

  describe "checkboxes" do
    test "checked and unchecked" do
      {items, :checkbox} =
        items("""
        * [ ] Left to right association of set operations
        * [x] Already handled
        - [ ] Intersection of string ranges
        """)

      assert length(items) == 3
      assert Enum.count(items, &(&1.state == :open)) == 2
    end
  end

  describe "annotated bullets" do
    test "a marked list counts, with unmarked siblings open" do
      {items, :annotated} =
        items("""
        # TODO

        All Tier 2 items have been implemented:

        * ✅ Rendering intents in `Color.convert/2,3,4`
        * ✅ Black point compensation
        * ✅ Spectral reflectance
        * ✅ `Color.luminance/1`

        ## Tier 3 — domain-specific or niche

        ### Soft-proofing

        Simulate a target device on an RGB display.

        ### Device link profiles

        Single-profile shortcut that bypasses the PCS.
        """)

      assert length(items) == 6
      assert Enum.count(items, &(&1.state == :done)) == 4

      assert Enum.map(Enum.filter(items, &(&1.state == :open)), & &1.title) ==
               ["Soft-proofing", "Device link profiles"]
    end

    test "strikethrough marks an item done, including across source lines" do
      {items, :annotated} =
        items("""
        * ~~**Explicit-form qualifiers**~~ **Done.**
        * ~~**Rendering the map on output**~~ **Done.**
        * ~~**iCal import of zero-duration events vs. the
          no-degenerate-intervals rule**~~ **Done.**
        * Cron parser — AST gaps identified during implementation.
        """)

      assert Enum.map(items, & &1.state) == [:done, :done, :done, :open]
    end

    test "prose with a handful of annotations is narrative, not a task list" do
      bullets = for n <- 1..40, do: "* A paragraph of explanation numbered #{n} that is prose."
      marked = ["* ✅ One thing done.", "* ✅ Another thing done.", "* ✅ A third."]

      {items, style} = items(Enum.join(bullets ++ marked, "\n"))

      assert items == []
      assert style == :narrative
    end

    test "level-2 headings are sections, not items" do
      {items, :annotated} =
        items("""
        ## Nice to have — all implemented

        * ✅ Performance benchmarks
        * ✅ Property-based tests
        * ✅ Batch conversion API

        ## Tier 4 — skip unless requested

        - Display calibration needs colorimeter hardware.
        """)

      refute Enum.any?(items, &String.starts_with?(&1.title, "Nice to have"))
      refute Enum.any?(items, &String.starts_with?(&1.title, "Tier 4"))
      assert length(items) == 4
    end

    test "indented sub-points are not counted separately" do
      {items, :annotated} =
        items("""
        * ✅ A finished parent item
          * a sub-point
          * another sub-point
        * ✅ A second finished item
        * ✅ A third finished item
        * An open parent item
          * with its own sub-point
        """)

      assert length(items) == 4
    end
  end

  describe "section headings that carry the verdict" do
    defp task_items(text), do: text |> String.split("\n") |> Plans.items(task_file?: true)

    test "a TODO file's bullets are items even when nobody annotated them" do
      {items, :sectioned} =
        task_items("""
        # TODO

        ## Pending release

        * The corrected version map needs a package release, not just a docs publish.

        ## Collation inventory

        * Treat the bundled snapshot as a floor, never a ceiling.
        * Make the inventory a runtime fact.

        ## Blocked on Localize

        * Localize records no Unicode version anywhere.
        """)

      assert length(items) == 4
      assert Enum.count(items, &(&1.state == :open)) == 3
      assert Enum.count(items, &(&1.state == :blocked)) == 1
    end

    test "items inherit a Done heading rather than reading as open" do
      {items, :sectioned} =
        task_items("""
        # TODO

        ## Done — pure-BEAM additions (2026-04-29)

        * `Text.Syllable` — vowel-group heuristic syllable counter.
        * `Text.Readability` — Flesch, Flesch-Kincaid, Gunning-Fog.

        ## Still to do

        * A Portuguese frequency list.
        """)

      assert Enum.map(items, & &1.state) == [:done, :done, :open]
    end

    test "an item's own marker beats the section it sits in" do
      {items, :sectioned} =
        task_items("""
        ## Completed

        * ❌ Actually this one was dropped.
        * Shipped alongside the rest.
        """)

      assert Enum.map(items, & &1.state) == [:blocked, :done]
    end

    test "a struck-through section heading is itself a finished item" do
      {items, :sectioned} =
        task_items("""
        # TODO

        ## ~~Add `Image.FaceDetection`~~ — shipped in v0.3.0

        The original recommendation notes, kept for context:

        * ONNX export, loaded via Ortex.
        * Hosted under a stable namespace.
        """)

      assert Enum.count(items, &(&1.state == :done)) == 3
      assert Enum.count(items, &(&1.state != :done)) == 0
    end

    test "a heading that states nothing leaves its items alone" do
      {items, :sectioned} =
        task_items("""
        ## Tier 3 — domain-specific or niche

        ### Soft-proofing

        ### Device link profiles
        """)

      assert Enum.map(items, & &1.state) == [:open, :open]
    end

    test "a prose plan is still narrative, task-file rules not applied" do
      text =
        Enum.map_join(1..30, "\n", &"* A paragraph of prose numbered #{&1} explaining things.")

      assert {[], :narrative} = items(text)
    end
  end

  describe "narrative documents" do
    test "a prose plan yields no items and no invented counts" do
      {items, style} =
        items("""
        # Implementing Allen's formalisms

        ## Where we are

        Allen's 1983 paper has four parts. Tempo implements two of them.

        ## Stage 1 — Relation-set algebra

        A new module over subsets of the thirteen relations.

        ## Stage 2 — Qualitative constraint network

        A pairwise matrix of relation sets plus propagation.
        """)

      assert items == []
      assert style == :narrative
    end
  end

  describe "classify/1" do
    test "recognised states" do
      assert Plans.classify("✅ Done. Shipped in 0.44.0") == :done
      assert Plans.classify("🟡 Partial — works for the common case") == :partial
      assert Plans.classify("❌ Missing — no library support") == :blocked
      assert Plans.classify("~~Old plan~~ replaced") == :done
      assert Plans.classify("BLOCKED on upstream PR #198") == :blocked
      assert Plans.classify("DONE: everything green, lists DEFERRED") == :done
      assert Plans.classify("Spin up a sibling library") == :open
    end
  end
end

defmodule Dashboard.GitVersionTest do
  use ExUnit.Case, async: true
  alias Dashboard.Git

  test "version extraction from tags" do
    assert Git.version_in("v2.2.0") == "2.2.0"
    assert Git.version_in("2.0.1") == "2.0.1"
    assert Git.version_in("release-1.4") == "1.4"
    assert Git.version_in("v1.0.0-rc.1") == "1.0.0-rc.1"
    assert Git.version_in("latest") == nil
    assert Git.version_in(nil) == nil
  end

  test "comparison, including two-part versions" do
    assert Git.compare("2.0.1", "2.0.0") == :gt
    assert Git.compare("2.0.0", "2.0.0") == :eq
    assert Git.compare("1.9.0", "2.0.0") == :lt
    assert Git.compare("1.4", "1.4.0") == :eq
    assert Git.compare(nil, "1.0.0") == nil
  end

  test "release state" do
    tagged = %{tag_count: 5, last_tag: "v2.0.0", last_tag_version: "2.0.0", commits_since_tag: 0}

    assert Git.release_state(tagged, "2.0.0") == :released
    assert Git.release_state(%{tagged | commits_since_tag: 40}, "2.0.0") == :unreleased_work
    assert Git.release_state(%{tagged | commits_since_tag: 4}, "2.0.1") == :pending_release
    assert Git.release_state(tagged, "1.9.0") == :retagged
    assert Git.release_state(%{tag_count: 0}, "0.1.0") == :untagged
  end

  test "owner and repo from every remote form in use" do
    assert Git.owner_repo("https://github.com/elixir-image/image") == {"elixir-image", "image"}

    assert Git.owner_repo("https://github.com/elixir-image/image.git") ==
             {"elixir-image", "image"}

    assert Git.owner_repo("git@github.com:kipcole9/astro.git") == {"kipcole9", "astro"}
    assert Git.owner_repo("https://github.com/ex-money/money_sql/") == {"ex-money", "money_sql"}
    assert Git.owner_repo("https://gitlab.com/someone/thing") == nil
    assert Git.owner_repo(nil) == nil
  end
end

defmodule Dashboard.IssueSummaryTest do
  use ExUnit.Case, async: true

  @now ~U[2026-09-21 00:00:00Z]

  setup do
    payload =
      Path.join([__DIR__, "..", "support", "fixtures", "image_issues.json"])
      |> File.read!()
      |> JSON.decode!()

    {issues, prs} = Enum.split_with(payload, &(not Map.has_key?(&1, "pull_request")))

    github = %{
      issues: Enum.map(issues, &Dashboard.GitHub.issue/1),
      prs: Enum.map(prs, &Dashboard.GitHub.pull_request/1)
    }

    %{summary: Dashboard.Collector.issue_summary(github, @now), github: github}
  end

  test "issues and pull requests are separated", %{summary: s} do
    assert s.open == 5
    assert s.prs == 1
    assert s.draft_prs == 0
  end

  test "attention counts match the repository", %{summary: s} do
    assert s.unanswered == 1
    assert s.stale == 4
    assert s.fresh_30d == 0
    assert s.assigned == 0
  end

  test "age statistics", %{summary: s} do
    assert s.oldest_days == 1373
    assert s.median_age_days == 528
  end

  test "label histogram", %{summary: s} do
    assert s.labels == [%{name: "enhancement", count: 1}, %{name: "help wanted", count: 1}]
  end

  test "issue fields survive the reshaping", %{github: github} do
    issue = Enum.find(github.issues, &(&1.number == 31))
    assert issue.title == "Add Image smart cell for Livebook"
    assert issue.author == "kipcole9"
    assert issue.comments == 2
    assert issue.labels == ["enhancement", "help wanted"]
    assert issue.url =~ "elixir-image/image/issues/31"
  end
end

defmodule Dashboard.StandardTodoTest do
  use ExUnit.Case, async: true

  # The house format from the system CLAUDE.md: five fixed sections, one
  # checkbox bullet per item, state from the checkbox and the section only.
  @todo """
  # TODO

  One paragraph saying what this list covers.

  ## Open

  * [ ] **Intervallic protocol** — let user structs take part in Allen comparisons. Analysis in [plans/design-notes.md](plans/design-notes.md).
  * [ ] **Astro events** — a way to express Easter and lunar phases; mostly a question of representation.
    A continuation line that is not an item.
    * a nested note, not an item

  ## In progress

  ### Backends

  * [ ] **Lazy busy-list splice** — needs a sorted stream merge.

  ## Blocked

  * [ ] **Serbian declensions** — Blocked on upstream PR #198.

  ## Deferred

  * [ ] **Germanic decompounder** — 31 MB of dictionaries; revisit on demand.

  ## Done

  * [x] **Duration parse entry point** — `Tempo.parse_duration/1`. 2026-09-02.
  * [ ] **A mistake** — an unchecked box under Done is still open.
  """

  test "state comes from the checkbox and the section" do
    {items, :checkbox} = Dashboard.Plans.items(String.split(@todo, "\n"), task_file?: true)

    assert Enum.map(items, &{&1.title, &1.state}) == [
             {"Intervallic protocol — let user structs take part in Allen comparisons. Analysis in plans/design-notes.md.",
              :open},
             {"Astro events — a way to express Easter and lunar phases; mostly a question of representation.",
              :open},
             {"Lazy busy-list splice — needs a sorted stream merge.", :partial},
             {"Serbian declensions — Blocked on upstream PR #198.", :blocked},
             {"Germanic decompounder — 31 MB of dictionaries; revisit on demand.", :blocked},
             {"Duration parse entry point — Tempo.parse_duration/1. 2026-09-02.", :done},
             {"A mistake — an unchecked box under Done is still open.", :open}
           ]
  end

  test "a plan with a Tasks section is tracked, and its prose is not" do
    plan = """
    # Interval units

    **Status:** in progress, 2026-07-11

    Long prose with * asterisks and 1. numbered arguments that are not tasks.

    ## Tasks

    * [x] **Phase 0** — accessors. 2026-07-27.
    * [ ] **Phase 4** — holiday generator sources.

    ### Deferred

    * [ ] **Lazy set algebra** — union of generators.
    """

    {items, :checkbox} = Dashboard.Plans.items(String.split(plan, "\n"))
    assert Enum.map(items, & &1.state) == [:done, :open, :blocked]
  end
end
