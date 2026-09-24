defmodule Orrery.StubCollector do
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
      failures: [],
      omitted: [],
      totals: %{groups: 1, repos: 0, failed: 0, omitted: 0}
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

  @doc "A minimal repository in the Stub group, as `collect_one/2` would return it."
  def repo(path) do
    %{
      name: Path.basename(path),
      group: "Stub",
      path: path,
      app: Path.basename(path),
      kind: "elixir",
      version: "0.1.0",
      git: nil,
      release_state: nil,
      changelog: nil,
      plans: [],
      plan_summary: %{
        documents: 0,
        tracked: 0,
        narrative: 0,
        items: 0,
        open: 0,
        done: 0,
        percent_done: nil
      },
      status: nil,
      status_state: :active,
      hex: nil,
      hex_error: nil,
      version_tag: nil,
      next_release: nil,
      remote: nil,
      github: nil,
      github_error: nil,
      owner: nil,
      repo_url: nil,
      issue_summary: nil,
      pull: %{
        needed: false,
        reason: nil,
        behind_upstream: nil,
        remote_checked: false,
        remote_behind: nil
      }
    }
  end

  @doc "Collects one stub repository."
  def collect_one(path, _options), do: {:ok, repo(path)}
end

defmodule Orrery.ScriptedCollector do
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

  @doc "Reports a single-repository collection to the test, then returns a stub repo."
  def collect_one(path, options) do
    if pid = options[:test_pid], do: send(pid, {:collecting_one, path, self()})
    {:ok, Orrery.StubCollector.repo(path)}
  end
end

defmodule Orrery.UnknownRepoCollector do
  @moduledoc "Collects the stub report but knows no individual repository."

  def collect(options), do: Orrery.ScriptedCollector.collect(options)
  def collect_one(path, _options), do: {:error, {:unknown_repo, path}}
end
