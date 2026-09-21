defmodule Dashboard.GitHub do
  @moduledoc """
  Fetches open issues and pull requests from the GitHub REST API, through
  `Dashboard.HTTP`.

  ## Authentication

  The token is read from the environment, never from a file in this directory
  and never written to the output. These names are tried in order:

      GITHUB_DASHBOARD_TOKEN    GITHUB_TOKEN    GH_TOKEN

  Without a token GitHub allows 60 requests an hour, which is not enough for
  this many repositories in one pass. Every response is therefore cached with
  its ETag: a repeat run sends `If-None-Match` and a `304 Not Modified` costs
  nothing against the rate limit, so an unauthenticated run catches up over a
  few hours and stays current after that.
  """

  @api "https://api.github.com"
  @token_vars ~w[GITHUB_DASHBOARD_TOKEN GITHUB_TOKEN GH_TOKEN]
  @per_page 100
  @max_pages 5

  defmodule Budget do
    @moduledoc "Tracks what the GitHub rate limit has left across the run."
    use Agent

    def start_link(_ \\ []), do: Agent.start_link(fn -> initial() end, name: __MODULE__)

    def note(headers) do
      remaining = header(headers, "x-ratelimit-remaining")
      reset = header(headers, "x-ratelimit-reset")

      Agent.update(__MODULE__, fn state ->
        %{
          state
          | remaining: (remaining && String.to_integer(remaining)) || state.remaining,
            reset: (reset && String.to_integer(reset)) || state.reset,
            calls: state.calls + 1,
            exhausted?: remaining == "0"
        }
      end)
    end

    def state, do: Agent.get(__MODULE__, & &1)

    @doc "Clears the counters at the start of a run."
    def reset, do: Agent.update(__MODULE__, fn _ -> initial() end)

    defp initial, do: %{remaining: nil, reset: nil, calls: 0, exhausted?: false}
    def exhausted?, do: Agent.get(__MODULE__, & &1.exhausted?)

    defp header(headers, name) do
      Enum.find_value(headers, fn {k, v} ->
        if to_string(k) |> String.downcase() == name, do: to_string(v)
      end)
    end
  end

  @doc "Returns the configured token, or `nil`. The value is never logged."
  def token do
    Enum.find_value(@token_vars, fn var ->
      case System.get_env(var) do
        nil -> nil
        "" -> nil
        value -> String.trim(value)
      end
    end)
  end

  @doc "Returns the name of the environment variable the token came from."
  def token_source do
    Enum.find(@token_vars, fn var -> System.get_env(var) not in [nil, ""] end)
  end

  @doc """
  Prepares for a collection run: creates the cache directory, honours any
  proxy settings and resets the rate-limit budget.

  The `:inets` and `:ssl` applications are started with the application, and
  the budget agent is normally supervised; it is started here only when the
  collector runs outside the application, as from a Mix task.

  ### Arguments

  * `cache_dir` is the directory ETag-cached responses are written to.

  ### Returns

  * `:ok`, or `{:error, reason}` when the cache directory cannot be created.

  """
  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(cache_dir) do
    with :ok <- Dashboard.HTTP.prepare(cache_dir),
         :ok <- ensure_budget() do
      Budget.reset()
    end
  end

  defp ensure_budget do
    case Budget.start_link() do
      {:ok, _} -> :ok
      {:error, {:already_started, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Collects the open issues and pull requests for `owner/repo`.

  Returns `{:ok, map}` or `{:error, reason}`; a repository that has been made
  private, renamed or deleted reports `:not_found` rather than failing the run.
  """
  def fetch(owner, repo, cache_dir) do
    with {:ok, meta} <- get_json("/repos/#{owner}/#{repo}", cache_dir),
         {:ok, items} <- all_issues(owner, repo, cache_dir) do
      {issues, prs} = Enum.split_with(items, &(not Map.has_key?(&1, "pull_request")))

      {:ok,
       %{
         description: meta["description"],
         stars: meta["stargazers_count"],
         forks: meta["forks_count"],
         watchers: meta["subscribers_count"],
         archived: meta["archived"],
         fork: meta["fork"] == true,
         fork_of: get_in(meta, ["parent", "full_name"]),
         default_branch: meta["default_branch"],
         pushed_at: meta["pushed_at"],
         license: get_in(meta, ["license", "spdx_id"]),
         homepage: meta["homepage"],
         html_url: meta["html_url"],
         open_issue_count: length(issues),
         open_pr_count: length(prs),
         issues: Enum.map(issues, &issue/1),
         prs: Enum.map(prs, &pull_request/1),
         ci: latest_run(owner, repo, meta["default_branch"], cache_dir)
       }}
    end
  end

  # The newest workflow run on the default branch, or nil when there is none
  # or it could not be fetched: CI is a signal, never a reason to fail a repo.
  defp latest_run(owner, repo, branch, cache_dir) when is_binary(branch) do
    path =
      "/repos/#{owner}/#{repo}/actions/runs?branch=#{URI.encode(branch)}&per_page=1&exclude_pull_requests=true"

    case get_json(path, cache_dir) do
      {:ok, %{"workflow_runs" => [run | _]}} when is_map(run) -> workflow_run(run)
      _ -> nil
    end
  end

  defp latest_run(_owner, _repo, _branch, _cache_dir), do: nil

  @doc """
  Reduces a GitHub workflow-run payload to the fields the dashboard uses.

  ### Arguments

  * `run` is one element of the `workflow_runs` list from the Actions API.

  ### Returns

  * A map with `:workflow`, `:status`, `:conclusion`, `:failed`, `:url`,
    `:sha`, `:branch`, `:title` and `:updated_at`.

  ### Examples

      iex> Dashboard.GitHub.workflow_run(%{"name" => "Elixir CI", "status" => "completed", "conclusion" => "failure", "html_url" => "https://github.com/o/r/actions/runs/1", "head_sha" => "abcdef0123456789", "head_branch" => "main", "display_title" => "Fix", "updated_at" => "2026-09-04T22:43:18Z"})
      %{workflow: "Elixir CI", status: "completed", conclusion: "failure", failed: true, url: "https://github.com/o/r/actions/runs/1", sha: "abcdef0", branch: "main", title: "Fix", updated_at: "2026-09-04T22:43:18Z"}

      iex> Dashboard.GitHub.workflow_run(%{"status" => "in_progress", "conclusion" => nil}).failed
      false

  """
  @spec workflow_run(map()) :: map()
  def workflow_run(run) when is_map(run) do
    conclusion = run["conclusion"]

    %{
      workflow: run["name"],
      status: run["status"],
      conclusion: conclusion,
      failed: conclusion in ["failure", "timed_out", "startup_failure", "action_required"],
      url: run["html_url"],
      sha: run["head_sha"] && String.slice(to_string(run["head_sha"]), 0, 7),
      branch: run["head_branch"],
      title: run["display_title"],
      updated_at: run["updated_at"]
    }
  end

  defp all_issues(owner, repo, cache_dir), do: all_issues(owner, repo, cache_dir, 1, [])

  defp all_issues(owner, repo, cache_dir, page, acc) do
    path =
      "/repos/#{owner}/#{repo}/issues?state=open&per_page=#{@per_page}&sort=updated&direction=desc&page=#{page}"

    case get_json(path, cache_dir) do
      {:ok, items} when is_list(items) ->
        acc = acc ++ items

        if length(items) == @per_page and page < @max_pages do
          all_issues(owner, repo, cache_dir, page + 1, acc)
        else
          {:ok, acc}
        end

      {:ok, _unexpected} ->
        {:ok, acc}

      error ->
        error
    end
  end

  @doc "Reduces a GitHub issue payload to the fields the dashboard uses."
  def issue(i) do
    %{
      number: i["number"],
      title: i["title"],
      url: i["html_url"],
      author: get_in(i, ["user", "login"]),
      labels: Enum.map(i["labels"] || [], & &1["name"]),
      comments: i["comments"],
      created_at: i["created_at"],
      updated_at: i["updated_at"],
      assignee: get_in(i, ["assignee", "login"]),
      milestone: get_in(i, ["milestone", "title"]),
      locked: i["locked"],
      reactions: get_in(i, ["reactions", "total_count"])
    }
  end

  @doc "Reduces a GitHub pull-request payload, keeping its draft state."
  def pull_request(p) do
    p |> issue() |> Map.put(:draft, p["draft"])
  end

  # ------------------------------------------------------------------
  # HTTP with ETag caching, through Dashboard.HTTP
  # ------------------------------------------------------------------

  defp get_json(path, cache_dir) do
    url = @api <> path
    {cache_file, cached} = Dashboard.HTTP.cached(cache_dir, url)

    cond do
      Budget.exhausted?() and cached != nil -> {:ok, cached.body}
      Budget.exhausted?() -> {:error, :rate_limited}
      true -> request(url, cache_file, cached)
    end
  end

  defp request(url, cache_file, cached) do
    headers =
      [{"accept", "application/vnd.github+json"}, {"x-github-api-version", "2022-11-28"}]
      |> maybe_auth()

    case Dashboard.HTTP.get(url, headers, cached) do
      {:ok, 200, resp_headers, body} ->
        Budget.note(resp_headers)

        case Dashboard.HTTP.decode_json(body) do
          {:ok, decoded} ->
            Dashboard.HTTP.store(cache_file, resp_headers, decoded)
            {:ok, decoded}

          {:error, :invalid_json} ->
            from_cache(cached, {:error, :invalid_json})
        end

      {:ok, 304, resp_headers, _body} ->
        Budget.note(resp_headers)
        from_cache(cached, {:error, {:http, 304}})

      {:ok, 404, resp_headers, _body} ->
        Budget.note(resp_headers)
        {:error, :not_found}

      {:ok, 401, _resp_headers, _body} ->
        {:error, :bad_credentials}

      {:ok, status, resp_headers, body} when status in [403, 429] ->
        Budget.note(resp_headers)

        if String.contains?(body, "rate limit"),
          do: from_cache(cached, {:error, :rate_limited}),
          else: {:error, {:http, status}}

      {:ok, status, _resp_headers, _body} ->
        from_cache(cached, {:error, {:http, status}})

      {:error, reason} ->
        from_cache(cached, {:error, reason})
    end
  end

  # A stale cached body beats no answer: the dashboard says where counts are
  # from cache.
  defp from_cache(%{body: body}, _fallback), do: {:ok, body}
  defp from_cache(nil, fallback), do: fallback

  defp maybe_auth(headers) do
    case token() do
      nil -> headers
      value -> [{"authorization", "Bearer " <> value} | headers]
    end
  end
end
