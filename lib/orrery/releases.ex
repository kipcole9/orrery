defmodule Orrery.Releases do
  @moduledoc """
  Plans the GitHub releases a repository's tags are missing.

  A version tag (`v2.1.1`, `v1.0.0-rc.7`) pushed to origin with no GitHub
  release gets one: titled `"<Name> version <version>"`, as the releases
  made by hand were, with the tag's section of `CHANGELOG.md` as its notes.

  `section/2` finds a version's section in a changelog: from the `##`
  heading whose first version-like token is the version, to the next `##`
  heading. That one rule reads every heading shape the libraries use —
  `## [v2.1.1] — 2026-10-28`, `## [1.4.3] - 2026-10-01`, `## v0.3.0 (2026-07-01)`,
  `## [1.0.0-rc.7] — July 28th, 2026` and the rest.

  `plan/3` decides which tags become releases, which of them are
  pre-releases, and which one, if any, is marked latest. Reading tags,
  releases and files, and creating releases, is `Orrery.Releases.Gh`'s.

  """

  @version ~r/\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?/
  @version_tag ~r/^v(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)$/

  @typedoc "A release to create for one tag."
  @type release :: %{
          tag: String.t(),
          version: String.t(),
          prerelease?: boolean(),
          latest?: boolean()
        }

  @doc """
  The section of a changelog for one version, heading included.

  ### Arguments

  * `changelog` is the text of a `CHANGELOG.md`.

  * `version` is a version without its `v`, such as `"2.1.1"`.

  ### Returns

  * `{:ok, section}`, the lines from the version's `##` heading to the
    next `##` heading, trailing blank lines removed, or

  * `{:error, :no_section}` when no `##` heading names the version.

  ### Examples

      iex> changelog = "# Changelog\\n\\n## [v2.1.1] — 2026-10-28\\n\\n### Fixed\\n\\n* A fix.\\n\\n## [v2.1.0] — 2026-10-27\\n"
      iex> Orrery.Releases.section(changelog, "2.1.1")
      {:ok, "## [v2.1.1] — 2026-10-28\\n\\n### Fixed\\n\\n* A fix."}

      iex> Orrery.Releases.section("## [Unreleased]\\n", "2.1.1")
      {:error, :no_section}

  """
  @spec section(String.t(), String.t()) :: {:ok, String.t()} | {:error, :no_section}
  def section(changelog, version) when is_binary(changelog) and is_binary(version) do
    lines = String.split(changelog, "\n")
    from_heading = Enum.drop_while(lines, &(not heading_for?(&1, version)))
    section_lines(from_heading)
  end

  defp section_lines([]) do
    {:error, :no_section}
  end

  defp section_lines([heading | rest]) do
    body = Enum.take_while(rest, &(not String.starts_with?(&1, "## ")))

    text =
      [heading | body]
      |> Enum.join("\n")
      |> String.trim_trailing()

    {:ok, text}
  end

  defp heading_for?("## " <> text, version) do
    match?([^version], Regex.run(@version, text))
  end

  defp heading_for?(_line, _version) do
    false
  end

  @doc """
  The version a release tag names.

  ### Arguments

  * `tag` is a tag name.

  ### Returns

  * `{:ok, version}`, the `t:Version.t/0` of a tag written `v` and a
    semantic version, or

  * `:error` for any other tag.

  ### Examples

      iex> Orrery.Releases.version("v2.1.1")
      {:ok, Version.parse!("2.1.1")}

      iex> Orrery.Releases.version("cldr/48-0-0")
      :error

  """
  @spec version(String.t()) :: {:ok, Version.t()} | :error
  def version(tag) when is_binary(tag) do
    case Regex.run(@version_tag, tag) do
      [_tag, version] -> Version.parse(version)
      nil -> :error
    end
  end

  @doc """
  The title of a release, as the releases made by hand were titled.

  ### Arguments

  * `name` is the project's name, the `:name` in its `mix.exs`.

  * `version` is the version, without its `v`.

  ### Returns

  * The title.

  ### Examples

      iex> Orrery.Releases.title("Tempo", "2.1.1")
      "Tempo version 2.1.1"

  """
  @spec title(String.t(), String.t()) :: String.t()
  def title(name, version) when is_binary(name) and is_binary(version) do
    "#{name} version #{version}"
  end

  @doc """
  The releases to create for the tags that have none.

  A tag that is no version (`cldr/48-0-0`) is left alone. The rest are
  planned in version order. A pre-release is marked one, and only the
  highest stable version is marked latest, and only when it is among those
  being created, so a backfill never moves the latest release back.

  ### Arguments

  * `tags` is every tag on origin.

  * `released` is the tags that already have a GitHub release.

  ### Returns

  * A list of `t:release/0`, oldest version first.

  ### Examples

      iex> Orrery.Releases.plan(["v1.6.4", "v2.0.0", "v2.1.0", "v2.1.0-rc.1"], ["v1.6.4"])
      [
        %{tag: "v2.0.0", version: "2.0.0", prerelease?: false, latest?: false},
        %{tag: "v2.1.0-rc.1", version: "2.1.0-rc.1", prerelease?: true, latest?: false},
        %{tag: "v2.1.0", version: "2.1.0", prerelease?: false, latest?: true}
      ]

  """
  @spec plan([String.t()], [String.t()]) :: [release()]
  def plan(tags, released) when is_list(tags) and is_list(released) do
    released = MapSet.new(released)
    versions = Enum.flat_map(tags, &tagged_version/1)
    newest = newest_stable(versions)

    versions
    |> Enum.reject(fn {tag, _version} -> MapSet.member?(released, tag) end)
    |> Enum.sort_by(fn {_tag, version} -> version end, Version)
    |> Enum.map(fn {tag, version} ->
      %{
        tag: tag,
        version: to_string(version),
        prerelease?: match?([_ | _], version.pre),
        latest?: tag == newest
      }
    end)
  end

  defp tagged_version(tag) do
    case version(tag) do
      {:ok, version} -> [{tag, version}]
      :error -> []
    end
  end

  defp newest_stable(versions) do
    stable = Enum.filter(versions, fn {_tag, version} -> Enum.empty?(version.pre) end)

    case Enum.max_by(stable, fn {_tag, version} -> version end, Version, fn -> nil end) do
      {tag, _version} -> tag
      nil -> nil
    end
  end
end
