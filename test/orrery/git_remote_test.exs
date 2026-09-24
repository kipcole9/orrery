defmodule Orrery.GitRemoteTest do
  use ExUnit.Case, async: true

  alias Orrery.Git

  # Two throwaway repositories under tmp: `upstream` plays origin, `clone` is
  # a clone of it. Committing in `upstream` after cloning puts `clone` behind
  # exactly the way a stale checkout is. Nothing here touches a real remote.
  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        [
          "-C",
          dir,
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.com",
          "-c",
          "commit.gpgsign=false"
        ] ++ args,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp commit!(dir, name) do
    File.write!(Path.join(dir, name), name)
    git!(dir, ["add", name])
    git!(dir, ["commit", "-q", "-m", name])
  end

  setup do
    root = Path.join(System.tmp_dir!(), "dash-remote-#{System.unique_integer([:positive])}")
    upstream = Path.join(root, "upstream")
    clone = Path.join(root, "clone")
    File.mkdir_p!(upstream)
    git!(upstream, ["init", "-q", "-b", "main"])
    commit!(upstream, "one")
    git!(root, ["clone", "-q", upstream, clone])
    on_exit(fn -> File.rm_rf(root) end)
    %{upstream: upstream, clone: clone}
  end

  test "a clone that has everything is not behind", %{clone: clone} do
    assert %{head: head, behind: false} = Git.remote_state(clone)
    assert byte_size(head) == 40
    assert Git.info(clone).behind_upstream == 0
  end

  test "origin moving on is noticed before a fetch, and counted after one", %{
    upstream: upstream,
    clone: clone
  } do
    commit!(upstream, "two")

    assert %{behind: true} = Git.remote_state(clone)
    assert Git.info(clone).behind_upstream == 0, "nothing has been fetched yet"

    git!(clone, ["fetch", "-q"])
    assert Git.info(clone).behind_upstream == 1
    assert %{behind: true} = Git.remote_state(clone)
  end

  test "a repository without an origin has no remote state" do
    dir = Path.join(System.tmp_dir!(), "dash-noremote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    on_exit(fn -> File.rm_rf(dir) end)

    assert Git.remote_state(dir) == nil
    assert Git.info(dir).behind_upstream == nil
  end
end

defmodule Orrery.GitTagForTest do
  use ExUnit.Case, async: true

  defp git!(dir, args) do
    {out, 0} =
      System.cmd(
        "git",
        [
          "-C",
          dir,
          "-c",
          "user.name=t",
          "-c",
          "user.email=t@example.com",
          "-c",
          "commit.gpgsign=false"
        ] ++ args,
        stderr_to_stdout: true
      )

    String.trim(out)
  end

  defp commit!(dir, name) do
    File.write!(Path.join(dir, name), name)
    git!(dir, ["add", name])
    git!(dir, ["commit", "-q", "-m", name])
  end

  # main: A (v1.0.0) — C.  A side branch off A holds B, tagged v2.0.0, which
  # main never merged: the shape of a release tagged on a rebased-away commit.
  setup do
    dir = Path.join(System.tmp_dir!(), "dash-tags-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q", "-b", "main"])
    commit!(dir, "a")
    git!(dir, ["tag", "v1.0.0"])
    git!(dir, ["checkout", "-q", "-b", "side"])
    commit!(dir, "b")
    git!(dir, ["tag", "v2.0.0"])
    git!(dir, ["checkout", "-q", "main"])
    commit!(dir, "c")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "a tag in HEAD's history is reachable", %{dir: dir} do
    assert %{name: "v1.0.0", reachable: true, sha: sha, date: date} =
             Orrery.Git.tag_for(dir, "1.0.0")

    assert byte_size(sha) >= 7
    assert String.starts_with?(date, "20")
  end

  test "a tag off the branch is found but not reachable, where describe misses it", %{dir: dir} do
    assert %{name: "v2.0.0", reachable: false} = Orrery.Git.tag_for(dir, "2.0.0")
    assert Orrery.Git.info(dir).last_tag == "v1.0.0"
  end

  test "no tag, or no version, is nil", %{dir: dir} do
    assert Orrery.Git.tag_for(dir, "3.0.0") == nil
    assert Orrery.Git.tag_for(dir, nil) == nil
  end
end
