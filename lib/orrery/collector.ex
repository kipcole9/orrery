defmodule Orrery.Collector do
  @moduledoc """
  Walks the registry, gathers the state of every repository and assembles the
  document the dashboard renders.
  """

  @doc """
  Discovers the repositories described by `registry`.

  A repository is any directory inside a group directory that is a git working
  tree. Adding a project therefore means cloning it into the right group — no
  edit to the registry is needed. `:exclude` removes one by its path relative
  to the root.
  """
  def discover(registry) do
    root = Path.expand(registry.root)
    excluded = MapSet.new(registry[:exclude] || [])

    groups =
      Enum.map(registry.groups, fn group ->
        dir = Path.join(root, group.dir)

        repos =
          case group[:repos] do
            nil ->
              dir
              |> Path.join("*")
              |> Path.wildcard()
              |> Enum.filter(&git_repo?/1)
              |> Enum.sort()

            names ->
              names |> Enum.map(&Path.join(root, &1)) |> Enum.filter(&git_repo?/1)
          end

        repos =
          Enum.reject(repos, fn path ->
            MapSet.member?(excluded, Path.relative_to(path, root))
          end)

        Map.put(group, :paths, repos)
      end)

    %{root: root, groups: Enum.reject(groups, &(&1.paths == []))}
  end

  defp git_repo?(path) do
    File.dir?(path) and
      (File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git")))
  end

  @doc """
  Loads the registry and collects a full report.

  ### Options

  * `:projects_file` is the registry file to read. Defaults to
    `Orrery.Projects.file/0`.

  * `:root` overrides the registry root directory.

  * `:only` is a list of group names to restrict the run to.

  * `:github?`, `:cache_dir`, `:hex?`, `:hex_cache_dir`, `:remote?` and
    `:on_progress` are passed to `run/2`.

  ### Returns

  * `{:ok, report}` or `{:error, reason}` when the registry cannot be read;
    `Orrery.Projects.describe/1` turns the reason into a message.

  """
  @spec collect(keyword()) :: {:ok, map()} | {:error, term()}
  def collect(options \\ []) do
    with {:ok, registry} <- Orrery.Projects.load(Keyword.get(options, :projects_file)),
         {:ok, registry} <- Orrery.Projects.only(registry, Keyword.get(options, :only, [])) do
      registry = if root = options[:root], do: %{registry | root: root}, else: registry
      {:ok, run(registry, options)}
    end
  end

  @doc """
  Collects one repository again, for splicing into an existing report with
  `replace/2`.

  Only that repository's git state, changelog, plans, `STATUS.md`, GitHub
  issues, workflow run and hex state are fetched; everything else in the
  report is left as it was. That keeps a "refresh this one" cheap for GitHub.

  ### Arguments

  * `path` is the repository's path relative to the registry root, as the
    report's `path` field has it.

  * `options` are as for `collect/1`.

  ### Returns

  * `{:ok, repo}` — a repository map without `:blocked` and `:flags`, which
    `replace/2` computes against the rest of the report.

  * `{:error, {:unknown_repo, path}}` when no such repository is in the
    registry, `{:error, {:collect, message}}` when collecting it raised, or a
    registry error from `Orrery.Projects`.

  """
  @spec collect_one(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def collect_one(path, options \\ []) when is_binary(path) do
    with {:ok, registry} <- Orrery.Projects.load(Keyword.get(options, :projects_file)) do
      registry = if root = options[:root], do: %{registry | root: root}, else: registry
      %{root: root, groups: groups} = discover(registry)
      context = context(options)

      found =
        Enum.find_value(groups, fn group ->
          Enum.find_value(group.paths, fn abs ->
            if Path.relative_to(abs, root) == path, do: {group, abs}
          end)
        end)

      case found do
        nil ->
          {:error, {:unknown_repo, path}}

        {group, abs} ->
          if context.github?, do: _ = Orrery.GitHub.prepare(context.cache_dir)
          if context.hex?, do: _ = Orrery.HTTP.prepare(context.hex_cache_dir)

          case repo(group, abs, root, context) do
            {:error, message} -> {:error, {:collect, message}}
            repo -> {:ok, repo}
          end
      end
    end
  end

  @doc """
  Replaces one repository in a report and rebuilds everything derived from
  it: blockers, flags, project and overall summaries, the omitted list and
  the timestamp.

  ### Arguments

  * `report` is a report from `run/2` or an earlier `replace/2`.

  * `repo` is a repository from `collect_one/2`.

  ### Returns

  * The new report.

  """
  @spec replace(map(), map()) :: map()
  def replace(report, repo) do
    groups = Enum.map(report.groups, &Map.take(&1, [:name, :blurb, :dir]))

    repos =
      report.groups
      |> Enum.flat_map(& &1.repos)
      |> Enum.reject(&(&1.path == repo.path))
      |> Enum.concat([repo])

    failures = Enum.reject(report.failures, &(&1.path == repo.path))
    omitted = Enum.reject(report.omitted, &(&1.path == repo.path))
    assemble(report.root, groups, repos, failures, omitted, report.github.enabled)
  end

  defp context(options) do
    data_dir = Orrery.Store.default_data_dir()

    %{
      github?: Keyword.get(options, :github?, true),
      cache_dir: Keyword.get(options, :cache_dir, Path.join(data_dir, "github")),
      hex?: Keyword.get(options, :hex?, true),
      hex_cache_dir: Keyword.get(options, :hex_cache_dir, Path.join(data_dir, "hex")),
      remote?: Keyword.get(options, :remote?, true)
    }
  end

  @doc """
  Collects every repository, in parallel, and returns the full report.

  `options` accepts `:github?` (default `true`), `:cache_dir`, `:hex?` (default
  `true`), `:hex_cache_dir`, `:remote?` (default `true`: ask each clone's
  origin for its HEAD with `git ls-remote`) and `:on_progress`.
  """
  def run(registry, options \\ []) do
    %{root: root, groups: groups} = discover(registry)
    context = context(options)
    github? = context.github?
    progress = Keyword.get(options, :on_progress, fn _ -> :ok end)

    # A cache directory that cannot be created only costs rate limit: fetches
    # still work, and Orrery.HTTP.store/3 tolerates the failure.
    if github?, do: _ = Orrery.GitHub.prepare(context.cache_dir)
    if context.hex?, do: _ = Orrery.HTTP.prepare(context.hex_cache_dir)

    tasks =
      for group <- groups, path <- group.paths do
        {group, path}
      end

    total = length(tasks)

    repos =
      tasks
      |> Task.async_stream(
        fn {group, path} ->
          repo(group, path, root, context)
        end,
        max_concurrency: if(github?, do: 6, else: 12),
        timeout: 180_000,
        on_timeout: :kill_task,
        ordered: true
      )
      |> Stream.with_index(1)
      |> Enum.map(fn
        {{:ok, {:error, _} = failure}, n} ->
          progress.({n, total, "failed"})
          failure

        {{:ok, repo}, n} ->
          progress.({n, total, repo.name})
          repo

        {{:exit, :timeout}, n} ->
          progress.({n, total, "timed out"})
          {:error, "collection timed out after 180s"}

        {{:exit, reason}, n} ->
          progress.({n, total, "failed"})
          {:error, Exception.format_exit(reason)}
      end)

    failures =
      repos
      |> Enum.zip(tasks)
      |> Enum.flat_map(fn
        {{:error, message}, {_group, path}} ->
          [%{path: Path.relative_to(path, root), error: message}]

        _ ->
          []
      end)

    repos = Enum.reject(repos, &match?({:error, _}, &1))
    assemble(root, groups, repos, failures, [], github?)
  end

  # Everything derived from the collected repositories: omission, blockers,
  # flags, per-project and overall summaries. Shared by a full run and by
  # replace/2, which re-derives all of it after swapping one repository in.
  defp assemble(root, groups, repos, failures, previous_omitted, github?) do
    # A fork of someone else's project is not ours to release or triage, and an
    # archived one gets no work at all. Both are left out of every count and
    # listed so nobody wonders where they went.
    {left_out, repos} = Enum.split_with(repos, &(omit_reason(&1) != nil))

    omitted =
      previous_omitted ++
        Enum.map(left_out, &%{path: &1.path, name: &1.name, reason: omit_reason(&1)})

    # Blockers name other packages, so they can only be resolved once every
    # repository's hex state is known; flags depend on the answer.
    repos =
      repos
      |> resolve_blockers()
      |> Enum.map(&Map.put(&1, :flags, flags(&1)))

    grouped =
      Enum.map(groups, fn group ->
        members = Enum.filter(repos, &(&1.group == group.name))

        group
        |> Map.take([:name, :blurb])
        |> Map.put(:dir, group.dir)
        |> Map.put(:repos, members)
        |> Map.put(:summary, summarise(members))
      end)

    %{
      generated_at: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(),
      root: root,
      github: github_status(github?),
      groups: grouped,
      summary: summarise(repos),
      failures: failures,
      omitted: omitted,
      totals: %{
        groups: length(grouped),
        repos: length(repos),
        failed: length(failures),
        omitted: length(omitted)
      }
    }
  end

  defp github_status(false),
    do: %{enabled: false, authenticated: false, token_var: nil, calls: 0, remaining: nil}

  defp github_status(true) do
    budget = Orrery.GitHub.Budget.state()

    %{
      enabled: true,
      authenticated: Orrery.GitHub.token() != nil,
      token_var: Orrery.GitHub.token_source(),
      calls: budget.calls,
      remaining: budget.remaining,
      reset_at: budget.reset && DateTime.from_unix!(budget.reset) |> DateTime.to_iso8601(),
      rate_limited: budget.exhausted?
    }
  end

  # ------------------------------------------------------------------

  # One repository that cannot be read must not take the whole run down. A
  # failure is reported in the report's `failures` list instead.
  defp repo(group, path, root, context) do
    collect_repo(group, path, root, context)
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp collect_repo(group, path, root, context) do
    git = Orrery.Git.info(path)
    project = Orrery.Git.project(path)
    changelog = Orrery.Changelog.info(path)
    plans = Orrery.Plans.scan(path)
    status = Orrery.Status.info(path)
    status_state = Orrery.Status.state(status)
    owner_repo = Orrery.Git.owner_repo(git && git.remote)

    {github, github_error} =
      if context.github? and owner_repo do
        {owner, name} = owner_repo

        case Orrery.GitHub.fetch(owner, name, context.cache_dir) do
          {:ok, data} -> {data, nil}
          {:error, reason} -> {nil, to_string_reason(reason)}
        end
      else
        {nil, nil}
      end

    remote = if context.remote? and git, do: Orrery.Git.remote_state(path)
    version_tag = if git, do: Orrery.Git.tag_for(path, project.version)

    {hex, hex_error} =
      if context.hex? and hex_package?(project, status_state) do
        case Orrery.Hex.fetch(project.app, context.hex_cache_dir) do
          {:ok, data} -> {data, nil}
          {:error, reason} -> {nil, Orrery.Hex.describe(reason)}
        end
      else
        {nil, nil}
      end

    state =
      git &&
        git
        |> Orrery.Git.release_state(project.version)
        |> hex_release_state(hex, project.version)
        |> stray_tag_state(version_tag)

    base = %{
      name: Path.basename(path),
      group: group.name,
      path: Path.relative_to(path, root),
      app: project.app,
      kind: project.kind,
      version: project.version,
      git: git,
      release_state: state,
      changelog: changelog,
      plans: plans,
      plan_summary: plan_summary(plans),
      status: status,
      status_state: status_state,
      hex: hex,
      hex_error: hex_error,
      version_tag: version_tag,
      next_release: status && status.next_release,
      remote: remote,
      github: github,
      github_error: github_error,
      owner: owner_repo && elem(owner_repo, 0),
      repo_url: owner_repo && "https://github.com/#{elem(owner_repo, 0)}/#{elem(owner_repo, 1)}",
      issue_summary: issue_summary(github)
    }

    Map.put(base, :pull, pull(base))
  end

  # Whether the clone needs pulling, and the strongest reason it does: origin's
  # HEAD missing from local history beats a count from the last fetch, which
  # beats hex knowing a release the clone has no tag for.
  defp pull(repo) do
    git = repo.git || %{}
    behind = Map.get(git, :behind_upstream)

    reason =
      cond do
        repo.remote != nil and repo.remote.behind ->
          "origin has commits this clone does not"

        is_integer(behind) and behind > 0 ->
          "#{behind} commit(s) behind #{upstream_name(git)} as of the last fetch"

        # Only when origin could not be asked: a release hex knows and the
        # clone does not is then the best available hint.
        repo.remote == nil and behind_hex?(repo) ->
          "hex has v#{repo.hex.latest}, newest local tag #{Map.get(git, :last_tag) || "none"}"

        true ->
          nil
      end

    %{
      needed: reason != nil,
      reason: reason,
      behind_upstream: behind,
      remote_checked: repo.remote != nil,
      remote_behind: repo.remote && repo.remote.behind
    }
  end

  defp upstream_name(%{default_branch: branch}) when is_binary(branch), do: "origin/" <> branch
  defp upstream_name(_git), do: "upstream"

  # Only libraries are looked up on hex; a playground or an application is
  # never published, and asking would only spend rate limit.
  defp hex_package?(%{kind: kind, app: app}, status)
       when is_binary(app) and kind in ["elixir", "erlang", "gleam", "lfe"] and
              status in [:active, :bug_fixes_only, :unknown],
       do: true

  defp hex_package?(_project, _status), do: false

  # A clone with no tags is "never released" only if hex agrees. When hex has
  # the package, compare mix.exs with the published version instead.
  defp hex_release_state(:untagged, %{published: true, latest: latest}, version)
       when is_binary(latest) do
    case Orrery.Git.compare(version, latest) do
      :gt -> :pending_release
      :lt -> :retagged
      :eq -> :released
      nil -> :untagged
    end
  end

  # mix.exs is ahead of every reachable tag, but hex has that very version:
  # it was released. Whether the tag is missing or stray is flagged separately.
  defp hex_release_state(:pending_release, %{published: true, latest: latest}, version)
       when is_binary(latest) and is_binary(version) do
    if Orrery.Git.compare(version, latest) == :eq, do: :released, else: :pending_release
  end

  defp hex_release_state(state, _hex, _version), do: state

  # The version's tag exists but is not in HEAD's history: the release
  # happened, the tag just is not where `describe` looks.
  defp stray_tag_state(:pending_release, %{reachable: false}), do: :released
  defp stray_tag_state(state, _tag), do: state

  # ------------------------------------------------------------------
  # Blockers
  # ------------------------------------------------------------------

  @doc """
  Resolves each repository's `STATUS.md` blockers against what hex has.

  A blocker naming a package the dashboard covers is resolved when hex's
  latest version of that package satisfies the requirement. Any blocker with
  an expected date is overdue once that date has passed unresolved; a month
  alone means the end of the month.

  ### Arguments

  * `repos` are collected repositories, each with `:status` and `:hex`.

  * `today` is the date to judge expected dates against.

  ### Returns

  * The repositories with a `:blocked` map: `active` (any blocker still open)
    and `blockers`, each with `resolved` (`true`, `false`, or `nil` when the
    package is not one the dashboard covers), `latest` and `overdue`.

  ### Examples

      iex> repos = [
      ...>   %{name: "localize", status: nil, hex: %{published: true, name: "localize", latest: "1.2.0"}},
      ...>   %{name: "t", status: %{blockers: [%{text: "localize ~> 1.3", package: "localize", requirement: "~> 1.3", expected: "2026-10"}]}, hex: nil}
      ...> ]
      iex> [_, t] = Orrery.Collector.resolve_blockers(repos, ~D[2026-09-21])
      iex> t.blocked
      %{active: true, blockers: [%{text: "localize ~> 1.3", package: "localize", requirement: "~> 1.3", expected: "2026-10", resolved: false, latest: "1.2.0", overdue: false}]}
      iex> [_, t] = Orrery.Collector.resolve_blockers(repos, ~D[2026-11-01])
      iex> hd(t.blocked.blockers).overdue
      true

  """
  @spec resolve_blockers([map()], Date.t()) :: [map()]
  def resolve_blockers(repos, today \\ Date.utc_today()) do
    published =
      Map.new(
        for %{hex: %{published: true, name: name, latest: latest}} <- repos,
            is_binary(latest),
            do: {name, latest}
      )

    Enum.map(repos, fn repo ->
      blockers =
        repo.status
        |> case do
          %{blockers: blockers} -> blockers
          _ -> []
        end
        |> Enum.map(&resolve_blocker(&1, published, today))

      Map.put(repo, :blocked, %{
        active: Enum.any?(blockers, &(&1.resolved != true)),
        blockers: blockers
      })
    end)
  end

  defp resolve_blocker(blocker, published, today) do
    latest = blocker.package && Map.get(published, blocker.package)

    resolved =
      case {latest, blocker.requirement} do
        {nil, _} -> nil
        {latest, requirement} when is_binary(requirement) -> version_match?(latest, requirement)
        _ -> nil
      end

    overdue = resolved != true and expected_passed?(blocker.expected, today)
    Map.merge(blocker, %{resolved: resolved, latest: latest, overdue: overdue})
  end

  defp version_match?(version, requirement) do
    Version.match?(version, requirement)
  rescue
    _ -> nil
  end

  defp expected_passed?(nil, _today), do: false

  defp expected_passed?(expected, today) do
    deadline =
      case String.split(expected, "-") do
        [year, month] -> end_of_month(String.to_integer(year), String.to_integer(month))
        _ -> Date.from_iso8601(expected)
      end

    case deadline do
      {:ok, date} -> Date.compare(today, date) == :gt
      _ -> false
    end
  rescue
    _ -> false
  end

  defp end_of_month(year, month) do
    with {:ok, first} <- Date.new(year, month, 1) do
      {:ok, Date.new!(year, month, Date.days_in_month(first))}
    end
  end

  # An explicit STATUS.md is authoritative; what GitHub reports only decides
  # for repositories that have no STATUS.md. A fork that became the maintained
  # line (tz_world) says `active` and stays in.
  defp omit_reason(%{status_state: :fork}), do: "STATUS.md says fork"
  defp omit_reason(%{status_state: :archived}), do: "STATUS.md says archived"
  defp omit_reason(%{status: status}) when status != nil, do: nil

  defp omit_reason(%{github: %{fork: true, fork_of: parent}}) when is_binary(parent),
    do: "fork of #{parent} on GitHub"

  defp omit_reason(%{github: %{fork: true}}), do: "fork on GitHub"
  defp omit_reason(%{github: %{archived: true}}), do: "archived on GitHub"
  defp omit_reason(_repo), do: nil

  defp to_string_reason(:not_found),
    do: "repository not found on GitHub (private, renamed or deleted)"

  defp to_string_reason(:rate_limited), do: "GitHub rate limit reached"
  defp to_string_reason(:bad_credentials), do: "GitHub rejected the token"
  defp to_string_reason({:http, status}), do: "GitHub returned HTTP #{status}"
  defp to_string_reason({:transport, reason}), do: "network error: #{inspect(reason)}"
  defp to_string_reason({:exception, message}), do: "error: #{message}"
  defp to_string_reason(:invalid_json), do: "GitHub returned a response that is not JSON"

  @doc """
  Encodes a report as indented JSON, for a `data.json` people can read and
  diff.

  `JSON` has no pretty printer, so this uses `:json.format/3` from OTP with
  one adjustment: `nil` is written as `null` rather than the string `"nil"`.

  ### Arguments

  * `report` is a report from `run/2`, or the string-keyed form of one.

  ### Returns

  * Iodata.

  ### Examples

      iex> Orrery.Collector.pretty_json(%{"a" => nil}) |> IO.iodata_to_binary()
      "{ \\"a\\": null }\\n"

  """
  @spec pretty_json(map()) :: iodata()
  def pretty_json(report), do: :json.format(report, &format_value/3, %{})

  defp format_value(nil, _encode, _state), do: "null"
  defp format_value(other, encode, state), do: :json.format_value(other, encode, state)

  # ------------------------------------------------------------------
  # Derived views
  # ------------------------------------------------------------------

  defp plan_summary([]),
    do: %{documents: 0, tracked: 0, narrative: 0, items: 0, open: 0, done: 0, percent_done: nil}

  defp plan_summary(plans) do
    tracked = Enum.filter(plans, & &1.tracked)
    items = Enum.sum(Enum.map(tracked, & &1.total))
    done = Enum.sum(Enum.map(tracked, & &1.done))
    partial = Enum.sum(Enum.map(tracked, & &1.partial))

    %{
      documents: length(plans),
      tracked: length(tracked),
      narrative: length(plans) - length(tracked),
      items: items,
      open: Enum.sum(Enum.map(tracked, & &1.open)),
      done: done,
      percent_done: if(items > 0, do: round((done + partial * 0.5) / items * 100))
    }
  end

  @doc """
  Summarises a repository's open issues. `now` is injectable so the age-based
  counts can be tested against a fixed date.
  """
  def issue_summary(github, now \\ nil)
  def issue_summary(nil, _now), do: nil

  def issue_summary(github, now) do
    issues = github.issues
    now = now || DateTime.utc_now()

    %{
      open: length(issues),
      prs: length(github.prs),
      draft_prs: Enum.count(github.prs, & &1.draft),
      unanswered: Enum.count(issues, &(&1.comments == 0 and age(&1.created_at, now) > 14)),
      stale: Enum.count(issues, &(age(&1.updated_at, now) > 180)),
      fresh_30d: Enum.count(issues, &(age(&1.created_at, now) <= 30)),
      assigned: Enum.count(issues, &(&1.assignee != nil)),
      oldest_days: issues |> Enum.map(&age(&1.created_at, now)) |> max_or_nil(),
      median_age_days: median(Enum.map(issues, &age(&1.created_at, now))),
      labels: label_counts(issues)
    }
  end

  defp label_counts(issues) do
    issues
    |> Enum.flat_map(& &1.labels)
    |> Enum.frequencies()
    |> Enum.sort_by(fn {label, n} -> {-n, label} end)
    |> Enum.take(12)
    |> Enum.map(fn {label, n} -> %{name: label, count: n} end)
  end

  defp max_or_nil([]), do: nil
  defp max_or_nil(values), do: Enum.max(values)

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    n = length(sorted)
    mid = div(n, 2)

    if rem(n, 2) == 1,
      do: Enum.at(sorted, mid),
      else: div(Enum.at(sorted, mid - 1) + Enum.at(sorted, mid), 2)
  end

  @doc false
  def age(nil, _now), do: 0

  def age(iso, now) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> max(DateTime.diff(now, dt, :second), 0) |> div(86_400)
      _ -> 0
    end
  end

  # Signals worth surfacing, each with a severity the dashboard sorts on.
  # What counts as a signal depends on the repository's STATUS.md: a demo or
  # an application is never nagged about release tags, and a library kept
  # for bug fixes only is not expected to see commits.
  defp flags(repo) do
    git = repo.git
    changelog = repo.changelog
    issues = repo.issue_summary
    status = repo.status_state
    releases? = status in [:active, :bug_fixes_only, :unknown]
    activity? = status in [:active, :application, :unknown]
    # A repository that cannot release yet is not nagged about releasing.
    nag = if repo.blocked.active, do: :info, else: :warn

    [
      flag(
        releases? and repo.release_state == :pending_release,
        nag,
        "release",
        "v#{repo.version} in mix.exs is not tagged (newest tag #{git && git.last_tag})"
      ),
      stray_tag_flag(repo),
      flag(
        releases? and published_untagged?(repo),
        :warn,
        "release",
        "v#{repo.version} is on hex but has no tag on #{(git && git.branch) || "this branch"}"
      ),
      flag(
        releases? and repo.release_state == :retagged and not behind_hex?(repo),
        :warn,
        "release",
        "tag #{git && git.last_tag} is ahead of v#{repo.version} in mix.exs"
      ),
      flag(
        (releases? and changelog) && changelog.unreleased && git && git.commits_since_tag > 0,
        :info,
        "release",
        "#{changelog && changelog.unreleased_entries} unreleased changelog entries over #{git && git.commits_since_tag} commits"
      ),
      flag(
        (releases? and git) && git.commits_since_tag >= 25,
        :info,
        "release",
        "#{git && git.commits_since_tag} commits since #{git && git.last_tag}"
      ),
      flag(
        git && git.dirty_files > 0,
        :info,
        "working tree",
        "#{git && git.dirty_files} uncommitted file(s)"
      ),
      flag(
        git != nil and git.remote == nil,
        :warn,
        "working tree",
        "no git remote: nothing is pushed anywhere"
      ),
      flag(
        git && git.unpushed && git.unpushed > 0,
        :warn,
        "working tree",
        "#{git && git.unpushed} commit(s) not pushed"
      ),
      flag(
        git && git.default_branch && git.branch && git.branch != git.default_branch,
        :info,
        "working tree",
        "on branch #{git && git.branch}, not #{git && git.default_branch}"
      ),
      flag(
        issues && issues.unanswered > 0,
        :warn,
        "issues",
        "#{issues && issues.unanswered} issue(s) with no reply"
      ),
      flag(
        issues && issues.stale > 0,
        :info,
        "issues",
        "#{issues && issues.stale} issue(s) untouched for 180+ days"
      ),
      flag(
        issues && issues.prs - issues.draft_prs > 0,
        :warn,
        "issues",
        "#{issues && issues.prs - issues.draft_prs} pull request(s) awaiting review"
      ),
      flag(
        activity? and git != nil and git.commits_90d == 0 and not archived?(repo),
        :info,
        "activity",
        "no commits in 90 days (last #{git && short_date(git.head_date)})"
      ),
      flag(
        (releases? and repo.release_state == :untagged and repo.kind != nil and git) &&
          git.commits_since_tag == 0,
        :info,
        "release",
        "no release tags yet"
      ),
      flag(
        status != :archived and repo.plan_summary.open > 0,
        :info,
        "plans",
        "#{repo.plan_summary.open} open plan item(s)"
      ),
      flag(repo.github_error != nil, :warn, "github", repo.github_error),
      flag(archived?(repo), :info, "github", "archived on GitHub"),
      flag(
        repo.pull.needed,
        :warn,
        "working tree",
        "needs pulling: #{repo.pull.reason}"
      ),
      flag(
        repo.remote == nil and behind_hex?(repo) and not repo.pull.needed,
        :warn,
        "release",
        "hex has v#{repo.hex && repo.hex.latest} but the newest local tag is #{(git && git.last_tag) || "none"} — fetch the clone"
      ),
      flag(
        repo.hex != nil and not repo.hex.published and status == :active and repo.version != nil,
        :info,
        "release",
        "not published on hex"
      ),
      flag(repo.hex_error != nil, :info, "hex", repo.hex_error),
      ci_flag(repo),
      flag(status not in [:active, :unknown], :info, "status", Orrery.Status.label(status)),
      flag(
        status == :unknown,
        :warn,
        "status",
        "STATUS.md says #{repo.status && repo.status.label}"
      )
    ]
    |> Enum.concat(blocker_flags(repo))
    |> Enum.reject(&is_nil/1)
  end

  defp archived?(repo), do: repo.github != nil and repo.github.archived == true

  defp blocker_flags(%{blocked: %{blockers: blockers}}) do
    Enum.map(blockers, fn blocker ->
      cond do
        blocker.resolved == true ->
          flag(
            true,
            :warn,
            "blocked",
            "blocker cleared: #{blocker.text} — hex has #{blocker.latest}"
          )

        blocker.overdue ->
          flag(
            true,
            :warn,
            "blocked",
            "blocker overdue: #{blocker.text} was expected by #{blocker.expected}"
          )

        true ->
          flag(
            true,
            :info,
            "blocked",
            "blocked on #{blocker.text}" <>
              if(blocker.latest, do: " (hex has #{blocker.latest})", else: "") <>
              if(blocker.expected, do: ", expected #{blocker.expected}", else: "")
          )
      end
    end)
  end

  defp blocker_flags(_repo), do: []

  defp ci_failed?(%{github: %{ci: %{failed: true}}}), do: true
  defp ci_failed?(_repo), do: false

  # Built separately so the message is only assembled when there is a run.
  defp ci_flag(%{github: %{ci: %{failed: true} = ci}}) do
    flag(
      true,
      :warn,
      "ci",
      "CI failed: #{ci.workflow} on #{ci.branch} at #{ci.sha} (#{short_date(ci.updated_at)})"
    )
  end

  defp ci_flag(_repo), do: nil

  # Hex knows a newer release than any local tag: the clone has not been
  # fetched since it was published.
  # A tag for hex's version that exists but is not reachable from HEAD still
  # counts as having it — there is nothing to pull.
  defp behind_hex?(%{hex: %{published: true, latest: latest}, git: git} = repo)
       when is_binary(latest) and is_map(git) do
    has_hex_tag? =
      match?(%{name: _}, repo.version_tag) and Orrery.Git.compare(repo.version, latest) == :eq

    not has_hex_tag? and
      (git.last_tag_version == nil or Orrery.Git.compare(git.last_tag_version, latest) == :lt)
  end

  defp behind_hex?(_repo), do: false

  defp stray_tag_flag(%{version_tag: %{reachable: false} = tag, git: git}) do
    flag(
      true,
      :warn,
      "release",
      "tag #{tag.name} points at #{tag.sha} (#{short_date(tag.date)}), which is not in #{(git && git.branch) || "this branch"}'s history"
    )
  end

  defp stray_tag_flag(_repo), do: nil

  # Published on hex at exactly mix.exs's version, but no tag anywhere.
  defp published_untagged?(%{
         hex: %{published: true, latest: latest},
         version: version,
         version_tag: nil
       })
       when is_binary(latest) and is_binary(version),
       do: Orrery.Git.compare(version, latest) == :eq

  defp published_untagged?(_repo), do: false

  defp short_date(nil), do: "unknown"
  defp short_date(iso), do: String.slice(iso, 0, 10)

  defp flag(true, severity, category, message),
    do: %{severity: severity, category: category, message: message}

  defp flag(_, _, _, _), do: nil

  # ------------------------------------------------------------------

  defp summarise(repos) do
    with_git = Enum.filter(repos, & &1.git)
    with_issues = Enum.filter(repos, & &1.issue_summary)

    %{
      repos: length(repos),
      released: Enum.count(repos, &(&1.release_state == :released)),
      unreleased_work: Enum.count(repos, &(&1.release_state == :unreleased_work)),
      pending_release: Enum.count(repos, &(&1.release_state in [:pending_release, :retagged])),
      untagged: Enum.count(repos, &(&1.release_state == :untagged)),
      commits_since_tag: with_git |> Enum.map(& &1.git.commits_since_tag) |> Enum.sum(),
      commits_30d: with_git |> Enum.map(& &1.git.commits_30d) |> Enum.sum(),
      dirty: Enum.count(with_git, &(&1.git.dirty_files > 0)),
      open_issues: with_issues |> Enum.map(& &1.issue_summary.open) |> Enum.sum(),
      open_prs: with_issues |> Enum.map(& &1.issue_summary.prs) |> Enum.sum(),
      unanswered_issues: with_issues |> Enum.map(& &1.issue_summary.unanswered) |> Enum.sum(),
      stale_issues: with_issues |> Enum.map(& &1.issue_summary.stale) |> Enum.sum(),
      plan_documents: repos |> Enum.map(& &1.plan_summary.documents) |> Enum.sum(),
      plan_items: repos |> Enum.map(& &1.plan_summary.items) |> Enum.sum(),
      plan_open: repos |> Enum.map(& &1.plan_summary.open) |> Enum.sum(),
      warnings:
        repos |> Enum.map(fn r -> Enum.count(r.flags, &(&1.severity == :warn)) end) |> Enum.sum(),
      status_counts: Enum.frequencies_by(repos, & &1.status_state),
      on_hex: Enum.count(repos, &(&1.hex != nil and &1.hex.published)),
      blocked: Enum.count(repos, & &1.blocked.active),
      ci_failing: Enum.count(repos, &ci_failed?/1)
    }
  end
end
