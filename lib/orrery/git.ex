defmodule Orrery.Git do
  @moduledoc """
  Reads the state of a local clone: branch, tags, commits since the last tag,
  working-tree cleanliness and recent commit activity.

  Everything here is read-only. No command fetches, checks out or writes.
  """

  @doc """
  Returns a map describing the repository at `path`, or `nil` if it is not a
  git working tree.
  """
  def info(path) do
    if File.dir?(Path.join(path, ".git")) or File.regular?(Path.join(path, ".git")) do
      branch = one(path, ~w[rev-parse --abbrev-ref HEAD])
      tag = one(path, ~w[describe --tags --abbrev=0])

      %{
        branch: branch,
        default_branch: default_branch(path),
        remote: remote(path),
        tag_count: count_lines(run(path, ~w[tag])),
        last_tag: tag,
        last_tag_date: tag && one(path, ["log", "-1", "--format=%cI", tag]),
        last_tag_version: tag && version_in(tag),
        commits_since_tag: commits_since(path, tag),
        head_sha: one(path, ~w[rev-parse --short HEAD]),
        head_date: one(path, ~w[log -1 --format=%cI]),
        head_subject: one(path, ~w[log -1 --format=%s]),
        dirty_files: count_lines(run(path, ~w[status --porcelain])),
        commits_30d: count_lines(run(path, ~w[log --since=30.days --format=%h])),
        commits_90d: count_lines(run(path, ~w[log --since=90.days --format=%h])),
        contributors: distinct_lines(run(path, ~w[log --format=%ae])),
        unpushed: unpushed(path, branch),
        behind_upstream: behind_upstream(path, branch)
      }
    end
  end

  @doc """
  Identifies the project at `path` and reads its declared version.

  Most of these repositories are Elixir, but the Localize family also has
  Erlang, Gleam and LFE ports, and a couple of repositories are web projects.
  Each build file names the version in its own way.
  """
  def project(path) do
    mix(path) || gleam(path) || erlang(path) || node_package(path) ||
      %{kind: nil, app: nil, version: nil}
  end

  defp mix(path) do
    with {:ok, source} <- read(path, "mix.exs") do
      %{
        kind: "elixir",
        app: captured(source, ~r/app:\s*:([a-z0-9_]+)/),
        version:
          captured(source, ~r/@version\s+"([^"]+)"/) ||
            captured(source, ~r/version:\s*"(\d[^"]*)"/)
      }
    else
      _ -> nil
    end
  end

  defp gleam(path) do
    with {:ok, source} <- read(path, "gleam.toml") do
      %{
        kind: "gleam",
        app: captured(source, ~r/^\s*name\s*=\s*"([^"]+)"/m),
        version: captured(source, ~r/^\s*version\s*=\s*"([^"]+)"/m)
      }
    else
      _ -> nil
    end
  end

  # Erlang and LFE: the version lives in src/<app>.app.src as {vsn, "x.y.z"}.
  defp erlang(path) do
    case Path.wildcard(Path.join(path, "src/*.app.src")) do
      [file | _] ->
        source = File.read!(file)

        %{
          kind: if(File.dir?(Path.join(path, "src")) and lfe?(path), do: "lfe", else: "erlang"),
          app: captured(source, ~r/\{\s*application\s*,\s*([a-z0-9_]+)/),
          version: captured(source, ~r/\{\s*vsn\s*,\s*"([^"]+)"/)
        }

      [] ->
        if File.regular?(Path.join(path, "rebar.config")) do
          %{kind: "erlang", app: Path.basename(path), version: nil}
        end
    end
  end

  defp lfe?(path), do: Path.wildcard(Path.join(path, "src/*.lfe")) != []

  defp node_package(path) do
    with {:ok, source} <- read(path, "package.json") do
      %{
        kind: "node",
        app: captured(source, ~r/"name"\s*:\s*"([^"]+)"/),
        version: captured(source, ~r/"version"\s*:\s*"([^"]+)"/)
      }
    else
      _ -> nil
    end
  end

  defp read(path, name) do
    file = Path.join(path, name)
    if File.regular?(file), do: File.read(file), else: :error
  end

  defp captured(source, regex) do
    case Regex.run(regex, source) do
      [_, value] -> value
      _ -> nil
    end
  end

  @doc """
  Strips a leading `v` and any suffix from a tag so it can be compared with the
  version in `mix.exs`. Returns `nil` when the tag carries no version.
  """
  def version_in(nil), do: nil

  def version_in(tag) do
    case Regex.run(~r/(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.\-]+)?)/, tag) do
      [_, v] -> v
      _ -> nil
    end
  end

  @doc """
  Compares two version strings, returning `:gt`, `:eq`, `:lt`, or `nil` when
  either is unparseable. Falls back to a segment comparison for versions
  `Version.parse/1` rejects, such as the two-part `1.2`.
  """
  def compare(nil, _), do: nil
  def compare(_, nil), do: nil

  def compare(a, b) do
    case {Version.parse(pad(a)), Version.parse(pad(b))} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb)
      _ -> nil
    end
  end

  defp pad(v) do
    case String.split(v, ".") do
      [maj, min] -> "#{maj}.#{min}.0"
      _ -> v
    end
  end

  @doc """
  Derives the release state of a repository from its tags, its `mix.exs`
  version and the commits since the last tag.

    * `:untagged`        — no tags at all
    * `:pending_release` — `mix.exs` is ahead of the newest tag: version bumped
                           but not yet tagged or published
    * `:unreleased_work` — commits exist beyond the newest tag
    * `:released`        — the newest tag matches `mix.exs` and nothing follows it
    * `:retagged`        — the newest tag is ahead of `mix.exs`, which usually
                           means a version was rolled back or a tag misapplied
  """
  def release_state(%{tag_count: 0}, _mix_version), do: :untagged
  def release_state(%{last_tag_version: nil}, _mix_version), do: :untagged

  def release_state(git, mix_version) do
    case compare(mix_version, git.last_tag_version) do
      :gt -> :pending_release
      :lt -> :retagged
      _ when git.commits_since_tag > 0 -> :unreleased_work
      :eq -> :released
      nil when git.commits_since_tag > 0 -> :unreleased_work
      nil -> :released
    end
  end

  @doc """
  Finds the tag for a version anywhere in the repository, reachable from HEAD
  or not.

  `describe` only sees tags in HEAD's history. A release tagged on a commit
  that was later rebased away, or on another branch, still exists — and a
  dashboard that reports it as missing sends someone to re-tag a release that
  is already on hex.

  ### Arguments

  * `path` is the repository directory.

  * `version` is the version from the build file, such as `"2.0.0"`.

  ### Returns

  * `%{name: tag, sha: short_sha, date: iso, reachable: boolean}` for the
    first of `v<version>` or `<version>` that exists.

  * `nil` when there is no such tag, or no version.

  """
  @spec tag_for(Path.t(), String.t() | nil) :: map() | nil
  def tag_for(_path, nil), do: nil

  def tag_for(path, version) do
    Enum.find_value(["v" <> version, version], fn name ->
      case run(path, ["tag", "--list", name]) do
        ^name ->
          sha = one(path, ["rev-parse", "--short", name <> "^{commit}"])

          %{
            name: name,
            sha: sha,
            date: one(path, ["log", "-1", "--format=%cI", name]),
            reachable:
              match?(
                {_, 0},
                System.cmd("git", ["-C", path, "merge-base", "--is-ancestor", name, "HEAD"],
                  stderr_to_stdout: true
                )
              )
          }

        _ ->
          nil
      end
    end)
  rescue
    _ -> nil
  end

  @doc """
  Asks `origin` for its HEAD and says whether this clone has it.

  This is the one command here that touches the network. It is read-only:
  `git ls-remote` fetches nothing and changes nothing in the clone.

  ### Arguments

  * `path` is the repository directory.

  ### Returns

  * `%{head: sha, behind: boolean}` — `behind` is `true` when origin's HEAD
    is not an ancestor of the local HEAD, including when the clone has never
    fetched it.

  * `nil` when there is no `origin` or it could not be reached.

  """
  @spec remote_state(Path.t()) :: %{head: String.t(), behind: boolean()} | nil
  def remote_state(path) do
    case one(
           path,
           ~w[-c core.askPass=true -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=15 ls-remote --quiet origin HEAD]
         ) do
      nil ->
        nil

      line ->
        case String.split(line, ~r/\s+/, parts: 2) do
          [sha | _] when byte_size(sha) == 40 -> %{head: sha, behind: not ancestor?(path, sha)}
          _ -> nil
        end
    end
  end

  # `merge-base --is-ancestor` exits 0 when the commit is in HEAD's history,
  # 1 when it is not, and fails altogether when the clone has never seen it —
  # which is also "not in our history".
  defp ancestor?(path, sha) do
    match?(
      {_, 0},
      System.cmd("git", ["-C", path, "merge-base", "--is-ancestor", sha, "HEAD"],
        stderr_to_stdout: true
      )
    )
  rescue
    _ -> false
  end

  @doc "Splits a GitHub remote URL into `{owner, repo}`, or returns `nil`."
  def owner_repo(nil), do: nil

  def owner_repo(url) do
    case Regex.run(~r{github\.com[:/]+([^/]+)/([^/\s]+?)(?:\.git)?/?$}, String.trim(url)) do
      [_, owner, repo] -> {owner, repo}
      _ -> nil
    end
  end

  # ------------------------------------------------------------------

  defp remote(path) do
    one(path, ~w[config --get remote.origin.url]) ||
      one(path, ~w[config --get remote.upstream.url])
  end

  defp default_branch(path) do
    case one(path, ~w[symbolic-ref --quiet refs/remotes/origin/HEAD]) do
      nil ->
        cond do
          one(path, ~w[rev-parse --verify --quiet refs/heads/main]) -> "main"
          one(path, ~w[rev-parse --verify --quiet refs/heads/master]) -> "master"
          true -> nil
        end

      ref ->
        ref |> String.split("/") |> List.last()
    end
  end

  defp commits_since(_path, nil), do: 0

  defp commits_since(path, tag) do
    case one(path, ["rev-list", "--count", "#{tag}..HEAD"]) do
      nil -> 0
      n -> String.to_integer(n)
    end
  end

  # Commits on the current branch that the tracked remote branch does not have.
  # This reads only what the last fetch left behind; nothing is fetched here.
  # Commits the tracked remote branch has that HEAD does not, as of the last
  # fetch. Nothing is fetched here either.
  defp behind_upstream(_path, nil), do: nil

  defp behind_upstream(path, _branch) do
    case one(path, ["rev-list", "--count", "HEAD..@{upstream}"]) do
      nil -> nil
      n -> String.to_integer(n)
    end
  end

  defp unpushed(_path, nil), do: nil

  defp unpushed(path, _branch) do
    upstream = one(path, ~w[rev-parse --abbrev-ref --symbolic-full-name @{upstream}])

    if upstream do
      case one(path, ["rev-list", "--count", "#{upstream}..HEAD"]) do
        nil -> nil
        n -> String.to_integer(n)
      end
    end
  end

  defp distinct_lines(nil), do: 0

  defp distinct_lines(output) do
    output |> String.split("\n", trim: true) |> Enum.uniq() |> length()
  end

  defp count_lines(nil), do: 0
  defp count_lines(""), do: 0

  defp count_lines(output) do
    output |> String.split("\n", trim: true) |> length()
  end

  defp one(path, args) do
    case run(path, args) do
      nil -> nil
      "" -> nil
      out -> out |> String.split("\n") |> hd() |> String.trim() |> nil_if_empty()
    end
  end

  defp nil_if_empty(""), do: nil
  defp nil_if_empty(s), do: s

  @doc false
  def run(path, args) do
    # `--no-optional-locks` keeps `git status` from refreshing the index, so a
    # collection never takes `.git/index.lock` under a person's `git add`.
    case System.cmd("git", ["-C", path, "--no-optional-locks"] ++ args, stderr_to_stdout: true) do
      {out, 0} -> String.trim_trailing(out)
      _ -> nil
    end
  rescue
    # `git` missing from PATH, or the directory disappeared mid-run.
    _ -> nil
  end
end
