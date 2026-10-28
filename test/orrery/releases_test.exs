defmodule Orrery.ReleasesTest do
  use ExUnit.Case, async: true

  alias Orrery.Releases

  doctest Orrery.Releases

  describe "section/2 reads every heading shape the libraries use" do
    # One heading of each shape found across the Tempo and Localize
    # families on 2026-10-28, each followed by another release.
    @shapes [
      {"tempo", "## [v2.1.1] — 2026-10-28", "2.1.1"},
      {"calendrical", "## [2.2.0] — 2026-10-27", "2.2.0"},
      {"intl", "## [0.4.0] - 2026-09-30", "0.4.0"},
      {"localize", "## [1.4.3] — October 12th, 2026", "1.4.3"},
      {"ical", "## v3.2.0", "3.2.0"},
      {"localize_erl", "## 0.1.0", "0.1.0"},
      {"localize_lua", "## 0.1.0 — 2026-09-30", "0.1.0"},
      {"unity", "## v0.6.0 (2026-09-10)", "0.6.0"},
      {"date-holidays", "## [1.4.14](https://example.com/compare/1.4.13...1.4.14) (2025-01-02)",
       "1.4.14"},
      {"pre-release", "## [1.0.0-rc.7] — July 28th, 2026", "1.0.0-rc.7"}
    ]

    for {name, heading, version} <- @shapes do
      @heading heading
      @version version

      test "#{name}: #{heading}" do
        changelog =
          "# Changelog\n\n#{@heading}\n\n### Fixed\n\n* One.\n\n## [v0.0.1] — 2020-01-01\n\n* Old.\n"

        assert Releases.section(changelog, @version) ==
                 {:ok, "#{@heading}\n\n### Fixed\n\n* One."}
      end
    end
  end

  describe "section/2" do
    test "the last section runs to the end of the file" do
      changelog = "## [v1.1.0] — 2026-02-01\n\n* New.\n\n## [v1.0.0] — 2026-01-01\n\n* First.\n\n"
      assert Releases.section(changelog, "1.0.0") == {:ok, "## [v1.0.0] — 2026-01-01\n\n* First."}
    end

    test "a version named only in another section's body is no heading" do
      changelog = "## [v1.1.0] — 2026-02-01\n\n* Fixes what 1.0.0 got wrong.\n"
      assert Releases.section(changelog, "1.0.0") == {:error, :no_section}
    end

    test "a pre-release is not its release" do
      changelog = "## [1.0.0-rc.1] — 2026-01-01\n\n* Candidate.\n"
      assert Releases.section(changelog, "1.0.0") == {:error, :no_section}
    end

    test "a version is not a prefix of a longer one" do
      changelog = "## [v1.0.10] — 2026-01-01\n\n* Ten.\n"
      assert Releases.section(changelog, "1.0.1") == {:error, :no_section}
    end
  end

  describe "plan/2" do
    test "a backfill under a newer release marks none latest" do
      assert [%{tag: "v1.0.0", latest?: false}] = Releases.plan(["v1.0.0", "v2.0.0"], ["v2.0.0"])
    end

    test "a tag that names no version is left alone" do
      assert Releases.plan(["cldr/48-0-0", "release-77-1", "main"], []) == []
    end

    test "nothing is planned when every tag has its release" do
      assert Releases.plan(["v1.0.0", "v1.1.0"], ["v1.0.0", "v1.1.0"]) == []
    end

    test "a pre-release is never marked latest, even alone" do
      assert [%{prerelease?: true, latest?: false}] = Releases.plan(["v1.0.0-rc.1"], [])
    end
  end
end
