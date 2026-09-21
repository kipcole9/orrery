defmodule Dashboard.StubCollector do
  @moduledoc """
  A collector that returns a fixed report instantly, for the application's
  store in the test environment and for controller tests.
  """

  @doc "Returns a small but complete report."
  def report do
    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      root: "/stub",
      github: %{enabled: false, authenticated: false, token_var: nil, calls: 0, remaining: nil},
      groups: [
        %{
          name: "Stub",
          dir: "stub",
          blurb: "A stub group",
          repos: [],
          summary: summary()
        }
      ],
      summary: summary(),
      totals: %{groups: 1, repos: 0}
    }
  end

  defp summary do
    %{
      repos: 0,
      released: 0,
      unreleased_work: 0,
      pending_release: 0,
      untagged: 0,
      commits_since_tag: 0,
      commits_30d: 0,
      dirty: 0,
      open_issues: 0,
      open_prs: 0,
      unanswered_issues: 0,
      stale_issues: 0,
      plan_documents: 0,
      plan_items: 0,
      plan_open: 0,
      warnings: 0
    }
  end

  @doc "Collects the fixed report."
  def collect(_options), do: {:ok, report()}
end

defmodule Dashboard.ScriptedCollector do
  @moduledoc """
  A collector driven by the test that started it.

  `:reply` in the collector options is a zero-arity function returning the
  collector's result; `:test_pid` receives `{:collecting, pid}` when a
  collection starts so the test can observe or block it.
  """

  @doc "Reports the start of a collection to the test, then returns `reply.()`."
  def collect(options) do
    if pid = options[:test_pid], do: send(pid, {:collecting, self()})
    options[:reply].()
  end
end
