defmodule Dashboard.CollectorFlagsTest do
  use ExUnit.Case, async: true

  # A registry with one group containing freshly initialised git working trees,
  # each with a mix.exs and, optionally, a STATUS.md. No commits are needed:
  # an empty repository is "untagged" with "no commits in 90 days", which is
  # exactly the pair of signals STATUS.md is meant to silence.
  defp registry(repos) do
    root = Path.join(System.tmp_dir!(), "dash-flags-#{System.unique_integer([:positive])}")

    for {name, status} <- repos do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      File.write!(
        Path.join(dir, "mix.exs"),
        ~s|defmodule X.MixProject do\n  @version "0.1.0"\nend\n|
      )

      if status,
        do:
          File.write!(
            Path.join(dir, "STATUS.md"),
            "# Status\n\n**Status:** #{status}, 2026-09-21\n"
          )
    end

    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, groups: [%{name: "Test", dir: "."}], exclude: []}
  end

  defp collect(repos) do
    report =
      Dashboard.Collector.run(registry(repos), github?: false, cache_dir: System.tmp_dir!())

    [group] = report.groups
    {report, Map.new(group.repos, &{&1.name, &1})}
  end

  defp messages(repo), do: Enum.map(repo.flags, & &1.message)

  test "an active repository is nagged about tags and activity" do
    {_report, %{"lib" => repo}} = collect([{"lib", nil}])

    # A freshly initialised repository has no remote; that is worth saying.
    assert %{severity: :warn, message: "no git remote: nothing is pushed anywhere"} =
             Enum.find(
               repo.flags,
               &(&1.category == "working tree" and &1.message =~ "no git remote")
             )

    assert repo.status == nil
    assert repo.status_state == :active
    assert "no release tags yet" in messages(repo)
    assert Enum.any?(messages(repo), &String.starts_with?(&1, "no commits in 90 days"))
    refute Enum.any?(repo.flags, &(&1.category == "status"))
  end

  test "a demo-only repository is not nagged about releases or activity, and carries its status" do
    {_report, %{"play" => repo}} = collect([{"play", "demo only"}])

    assert repo.status_state == :demo_only
    refute "no release tags yet" in messages(repo)
    refute Enum.any?(messages(repo), &String.starts_with?(&1, "no commits in 90 days"))
    assert %{severity: :info, category: "status", message: "demo only"} in repo.flags
  end

  test "an application is nagged about activity but not releases" do
    {_report, %{"app" => repo}} = collect([{"app", "application"}])

    refute "no release tags yet" in messages(repo)
    assert Enum.any?(messages(repo), &String.starts_with?(&1, "no commits in 90 days"))
  end

  test "a bug-fixes-only library is nagged about releases but not activity" do
    {_report, %{"old" => repo}} = collect([{"old", "bug fixes only"}])

    assert "no release tags yet" in messages(repo)
    refute Enum.any?(messages(repo), &String.starts_with?(&1, "no commits in 90 days"))
    assert %{severity: :info, category: "status", message: "bug fixes only"} in repo.flags
  end

  test "an unrecognised status is surfaced as a warning rather than guessed" do
    {_report, %{"odd" => repo}} = collect([{"odd", "on hiatus"}])

    assert repo.status_state == :unknown

    assert %{severity: :warn, category: "status", message: "STATUS.md says on hiatus"} in repo.flags
  end

  test "an archived repository is left out of the report" do
    {report, repos} = collect([{"gone", "archived"}, {"here", nil}])

    assert Map.keys(repos) == ["here"]
    assert [%{name: "gone", reason: "STATUS.md says archived"}] = report.omitted
  end

  test "the summary counts repositories by status" do
    {report, _} =
      collect([{"a", nil}, {"b", "demo only"}, {"c", "bug fixes only"}, {"d", "bug fixes only"}])

    assert report.summary.status_counts == %{active: 1, demo_only: 1, bug_fixes_only: 2}
  end
end

defmodule Dashboard.CollectorForksTest do
  use ExUnit.Case, async: true

  test "a fork is left out of the report and listed as omitted" do
    root = Path.join(System.tmp_dir!(), "dash-forks-#{System.unique_integer([:positive])}")

    for {name, status} <- [{"ours", "active"}, {"theirs", "fork"}] do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      File.write!(
        Path.join(dir, "mix.exs"),
        ~s|defmodule X.MixProject do\n  @version "0.1.0"\nend\n|
      )

      File.write!(Path.join(dir, "STATUS.md"), "# Status\n\n**Status:** #{status}, 2026-09-21\n")
    end

    on_exit(fn -> File.rm_rf(root) end)

    report =
      Dashboard.Collector.run(%{root: root, groups: [%{name: "T", dir: "."}], exclude: []},
        github?: false,
        hex?: false
      )

    assert [%{name: "theirs", reason: "STATUS.md says fork"}] = report.omitted
    assert report.totals == %{groups: 1, repos: 1, failed: 0, omitted: 1}
    assert [%{repos: [%{name: "ours"}]}] = report.groups
  end
end

defmodule Dashboard.CollectorBlockersTest do
  use ExUnit.Case, async: true

  defp collect(status_files) do
    root = Path.join(System.tmp_dir!(), "dash-blocked-#{System.unique_integer([:positive])}")

    for {name, status} <- status_files do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      File.write!(
        Path.join(dir, "mix.exs"),
        ~s|defmodule X.MixProject do\n  @version "2.0.0"\nend\n|
      )

      File.write!(Path.join(dir, "STATUS.md"), status)
    end

    on_exit(fn -> File.rm_rf(root) end)

    report =
      Dashboard.Collector.run(%{root: root, groups: [%{name: "T", dir: "."}], exclude: []},
        github?: false,
        hex?: false,
        remote?: false
      )

    [group] = report.groups
    {report, Map.new(group.repos, &{&1.name, &1})}
  end

  test "a blocked repository is nagged about releases only informationally" do
    {report, %{"waiting" => waiting, "free" => free}} =
      collect([
        {"waiting",
         "# Status\n\n**Status:** active, 2026-09-21\n\n**Blocked on:** other ~> 9.0, expected 2099-12\n"},
        {"free", "# Status\n\n**Status:** active, 2026-09-21\n"}
      ])

    assert waiting.blocked.active

    assert [%{package: "other", requirement: "~> 9.0", resolved: nil, overdue: false}] =
             waiting.blocked.blockers

    # Both are "untagged" with a version in mix.exs; only the free one warns.
    tag_flag = fn repo -> Enum.find(repo.flags, &(&1.message == "no release tags yet")) end
    assert tag_flag.(waiting).severity == :info
    assert tag_flag.(free).severity == :info or tag_flag.(free) == nil

    assert %{
             severity: :info,
             category: "blocked",
             message: "blocked on other ~> 9.0, expected 2099-12"
           } in waiting.flags

    refute Enum.any?(free.flags, &(&1.category == "blocked"))
    assert report.summary.blocked == 1
  end

  test "an overdue blocker warns" do
    {_report, %{"late" => late}} =
      collect([
        {"late",
         "# Status\n\n**Status:** active, 2026-09-21\n\n**Blocked on:** a decision, expected 2020-01\n"}
      ])

    assert [%{overdue: true}] = late.blocked.blockers

    assert %{
             severity: :warn,
             category: "blocked",
             message: "blocker overdue: a decision was expected by 2020-01"
           } in late.flags
  end

  test "a blocker satisfied by hex is reported as cleared" do
    repos = [
      %{name: "dep", status: nil, hex: %{published: true, name: "dep", latest: "1.3.1"}},
      %{name: "app", status: %{blockers: [Dashboard.Status.blocker("dep ~> 1.3")]}, hex: nil}
    ]

    [_, app] = Dashboard.Collector.resolve_blockers(repos, ~D[2026-09-21])
    assert [%{resolved: true, latest: "1.3.1", overdue: false}] = app.blocked.blockers
    refute app.blocked.active
  end
end
