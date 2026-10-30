defmodule Orrery.CollectorDiscoverTest do
  use ExUnit.Case, async: true

  # A root with one group of freshly initialised git working trees, each with
  # the remote URL given (or none). Nothing is fetched: discovery reads the
  # clone's configuration only.
  defp root(repos) do
    root = Path.join(System.tmp_dir!(), "dash-discover-#{System.unique_integer([:positive])}")

    for {name, remote} <- repos do
      dir = Path.join(root, name)
      File.mkdir_p!(dir)
      {_, 0} = System.cmd("git", ["init", "-q", dir])

      if remote do
        {_, 0} = System.cmd("git", ["-C", dir, "remote", "add", "origin", remote])
      end
    end

    on_exit(fn -> File.rm_rf(root) end)
    root
  end

  defp discover(root, extra) do
    Orrery.Collector.discover(
      Map.merge(%{root: root, groups: [%{name: "Test", dir: "."}], exclude: []}, extra)
    )
  end

  defp names(%{groups: [%{paths: paths}]}), do: Enum.map(paths, &Path.basename/1)
  defp names(%{groups: []}), do: []

  test "without :owners every working tree is kept" do
    root =
      root([
        {"ours", "https://github.com/us/ours.git"},
        {"theirs", "git@github.com:them/theirs.git"},
        {"local", nil}
      ])

    result = discover(root, %{})
    assert names(result) == ["local", "ours", "theirs"]
    assert result.omitted == []
  end

  test ":owners keeps clones under a listed owner and clones with no remote" do
    root =
      root([
        {"ours", "https://github.com/us/ours.git"},
        {"also_ours", "git@github.com:us-too/also_ours.git"},
        {"theirs", "https://github.com/them/theirs"},
        {"elsewhere", "https://gitlab.com/them/elsewhere.git"},
        {"local", nil}
      ])

    result = discover(root, %{owners: ["us", "us-too"]})
    assert names(result) == ["also_ours", "elsewhere", "local", "ours"]

    assert [%{path: "theirs", name: "theirs", reason: reason}] = result.omitted
    assert reason =~ "owned by them on GitHub"
  end

  test ":exclude and :owners both apply, and an empty group is dropped" do
    root =
      root([
        {"theirs", "https://github.com/them/theirs"},
        {"vendored", "https://github.com/us/vendored"}
      ])

    result = discover(root, %{owners: ["us"], exclude: ["vendored"]})
    assert result.groups == []
    assert [%{path: "theirs"}] = result.omitted
  end

  test "a full run reports the owner-filtered clones under omitted" do
    root =
      root([
        {"ours", "https://github.com/us/ours.git"},
        {"theirs", "https://github.com/them/theirs"}
      ])

    registry = %{root: root, groups: [%{name: "Test", dir: "."}], exclude: [], owners: ["us"]}
    report = Orrery.Collector.run(registry, github?: false, hex?: false, remote?: false)

    assert [%{repos: [%{name: "ours"}]}] = report.groups
    assert [%{path: "theirs", reason: "owned by them" <> _}] = report.omitted
  end
end
