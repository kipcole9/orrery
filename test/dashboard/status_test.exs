defmodule Dashboard.StatusTest do
  use ExUnit.Case, async: true

  alias Dashboard.Status

  doctest Dashboard.Status

  defp repo_with(contents) do
    dir = Path.join(System.tmp_dir!(), "dash-status-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    if contents, do: File.write!(Path.join(dir, "STATUS.md"), contents)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  test "a repository without STATUS.md is active" do
    assert Status.info(repo_with(nil)) == nil
    assert Status.state(nil) == :active
  end

  test "every state is recognised regardless of case and spacing" do
    for {text, state} <- [
          {"active", :active},
          {"Application", :application},
          {"demo-only", :demo_only},
          {"Bug fixes only", :bug_fixes_only},
          {"ARCHIVED", :archived}
        ] do
      assert %{state: ^state} = Status.parse("# Status\n\n**Status:** #{text}, 2026-09-21\n"),
             "expected #{state} from #{text}"
    end
  end

  test "the note is the first paragraph after the status line, as plain text" do
    info =
      Status.info(
        repo_with("""
        # Status

        **Status:** demo only, 2026-09-21

        A **Phoenix** playground for `localize`; never
        published to hex.

        ## More

        Ignored.
        """)
      )

    assert info.state == :demo_only
    assert info.date == "2026-09-21"
    assert info.note == "A Phoenix playground for localize; never published to hex."
  end

  test "garbage does not raise" do
    assert Status.parse("") == nil
    assert Status.parse("**Status:**") == nil
    assert Status.parse(<<0xFF, 0xFE>>) == nil
    assert Status.parse(nil) == nil
    assert Status.info("/nonexistent/repo") == nil
  end
end
