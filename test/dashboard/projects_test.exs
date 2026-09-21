defmodule Dashboard.ProjectsTest do
  use ExUnit.Case, async: true

  alias Dashboard.Projects

  doctest Dashboard.Projects

  defp write(contents) do
    file = Path.join(System.tmp_dir!(), "projects-#{System.unique_integer([:positive])}.exs")
    File.write!(file, contents)
    on_exit(fn -> File.rm(file) end)
    file
  end

  test "the shipped registry loads" do
    assert {:ok, %{root: root, groups: groups, exclude: exclude}} = Projects.load()
    assert Path.type(root) == :absolute
    assert Enum.any?(groups, &(&1.name == "Tempo"))
    assert is_list(exclude)
  end

  test "the root is expanded and :exclude defaults to an empty list" do
    file = write(~s(%{root: "~/Development", groups: [%{name: "A", dir: "a"}]}))
    assert {:ok, %{root: root, exclude: []}} = Projects.load(file)
    refute String.starts_with?(root, "~")
  end

  test "a file that is not a registry is rejected without raising" do
    assert {:error, {:invalid, message}} = Projects.load(write("[1, 2, 3]"))
    assert message =~ "expected a map"

    assert {:error, {:invalid, message}} =
             Projects.load(write(~s(%{root: "/x", groups: [%{name: "A"}]})))

    assert message =~ "without a :name and :dir"

    assert {:error, {:invalid, _}} = Projects.load(write("%{root: "))
  end

  test "describe/1 covers every error" do
    assert Projects.describe({:missing_file, "/p"}) =~ "not found"
    assert Projects.describe({:invalid, "why"}) == "invalid registry: why"

    assert Projects.describe({:unknown_groups, ["X"], ["A", "B"]}) ==
             "no group matches X; known groups: A, B"

    assert Projects.describe(:other) == ":other"
  end
end
