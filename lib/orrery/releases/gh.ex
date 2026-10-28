defmodule Orrery.Releases.Gh do
  @moduledoc """
  Reads a repository's tags, releases and files, and creates releases,
  through `git` and the GitHub CLI `gh`.

  `gh` carries the user's GitHub login, which may create releases;
  Orrery's own token (`Orrery.GitHub`) is for reading. Tags are read from
  origin (`git ls-remote`), so a tag that was never pushed has no release
  planned for it, and a file is read at the tag from GitHub, so a clone
  that has not fetched the tag reads it all the same.

  `missing/1` plans a repository's missing releases with
  `Orrery.Releases.plan/2`, each with its title and its notes, and
  `create/2` creates one. Every function returns an error or skip tuple
  rather than raising when `git` or `gh` fails.

  """

  alias Orrery.Releases

  @writers ~w(ADMIN MAINTAIN WRITE)
  @mix_name ~r/^\s*name:\s*"([^"]+)"/m
  @titled ~r/^(.+) version \S+$/

  @typedoc "A planned release with its title and notes."
  @type entry :: %{
          tag: String.t(),
          version: String.t(),
          prerelease?: boolean(),
          latest?: boolean(),
          title: String.t(),
          notes: {:ok, String.t()} | {:error, term()}
        }

  @typedoc "What `missing/1` found for one repository."
  @type found :: %{path: Path.t(), slug: String.t(), releases: [entry()]}

  @doc """
  The releases a repository's tags are missing.

  ### Arguments

  * `path` is the path of a git working tree whose origin is on GitHub.

  ### Returns

  * `{:ok, found}`, a `t:found/0` whose `:releases` is empty when every
    version tag has its release,

  * `{:skip, reason}` when the repository is not one to release: origin
    is not on GitHub, the login cannot write to it, it is archived, or it
    is a fork that its `STATUS.md` does not claim, or

  * `{:error, reason}` when `git` or `gh` fails.

  """
  @spec missing(Path.t()) :: {:ok, found()} | {:skip, String.t()} | {:error, String.t()}
  def missing(path) when is_binary(path) do
    with {:ok, slug} <- slug(path),
         :ok <- releasable(path, slug),
         {:ok, tags} <- tags(path),
         {:ok, released} <- released(slug) do
      name = released_name(released)

      releases =
        tags
        |> Releases.plan(Enum.map(released, & &1.tag))
        |> Enum.map(&described(slug, name, &1))

      {:ok, %{path: path, slug: slug, releases: releases}}
    end
  end

  @doc """
  Creates one release on GitHub.

  ### Arguments

  * `slug` is the repository, `"owner/name"`.

  * `entry` is a `t:entry/0` from `missing/1`.

  ### Returns

  * `:ok`, or

  * `{:error, reason}` when the entry has no notes or `gh` refuses.

  """
  @spec create(String.t(), entry()) :: :ok | {:error, String.t()}
  def create(slug, %{notes: {:ok, notes}} = entry) when is_binary(slug) do
    file = Path.join(System.tmp_dir!(), "orrery-release-#{System.unique_integer([:positive])}.md")

    with :ok <- written(file, notes) do
      result = gh(create_arguments(slug, entry, file))
      File.rm(file)

      case result do
        {:ok, _output} -> :ok
        {:error, output} -> {:error, output}
      end
    end
  end

  def create(_slug, %{notes: {:error, _reason}}) do
    {:error, "no CHANGELOG section for this version"}
  end

  defp written(file, notes) do
    case File.write(file, notes) do
      :ok -> :ok
      {:error, reason} -> {:error, "cannot write the notes: #{:file.format_error(reason)}"}
    end
  end

  defp create_arguments(slug, entry, file) do
    prerelease =
      if entry.prerelease? do
        ["--prerelease"]
      else
        []
      end

    ["release", "create", entry.tag, "--repo", slug, "--title", entry.title] ++
      ["--notes-file", file, "--verify-tag", "--latest=#{entry.latest?}"] ++ prerelease
  end

  # ------------------------------------------------------------------
  # What a repository is

  defp slug(path) do
    url =
      case git(path, ["config", "--get", "remote.origin.url"]) do
        {:ok, url} -> url
        {:error, _output} -> nil
      end

    case Orrery.Git.owner_repo(url) do
      {owner, name} -> {:ok, "#{owner}/#{name}"}
      nil -> {:skip, "origin is not on GitHub"}
    end
  end

  defp releasable(path, slug) do
    with {:ok, json} <- gh(["repo", "view", slug, "--json", "viewerPermission,isArchived,isFork"]),
         {:ok, repo} <- decoded(json) do
      status = Orrery.Status.info(path)
      why_not(repo, status, Orrery.Status.state(status))
    end
  end

  defp decoded(json) do
    case JSON.decode(json) do
      {:ok, %{} = repo} -> {:ok, repo}
      _other -> {:error, "gh returned no repository"}
    end
  end

  defp why_not(%{"viewerPermission" => permission}, _status, _state)
       when permission not in @writers do
    {:skip, "this login cannot write to it"}
  end

  defp why_not(%{"isArchived" => true}, _status, _state) do
    {:skip, "archived on GitHub"}
  end

  defp why_not(_repo, _status, state) when state in [:fork, :archived] do
    {:skip, "STATUS.md says #{state}"}
  end

  defp why_not(%{"isFork" => true}, nil, _state) do
    {:skip, "a fork on GitHub"}
  end

  defp why_not(_repo, _status, _state) do
    :ok
  end

  # ------------------------------------------------------------------
  # Tags, releases and files

  defp tags(path) do
    with {:ok, output} <- git(path, ["ls-remote", "--tags", "origin"]) do
      tags =
        output
        |> String.split("\n", trim: true)
        |> Enum.map(fn line -> line |> String.split("refs/tags/") |> List.last() end)
        |> Enum.map(&String.replace_suffix(&1, "^{}", ""))
        |> Enum.uniq()

      {:ok, tags}
    end
  end

  defp released(slug) do
    arguments = ["release", "list", "--repo", slug, "--limit", "1000", "--json", "tagName,name"]

    with {:ok, json} <- gh(arguments) do
      case JSON.decode(json) do
        {:ok, releases} when is_list(releases) -> {:ok, Enum.map(releases, &release_of/1)}
        _other -> {:error, "gh returned no release list for #{slug}"}
      end
    end
  end

  defp release_of(release) do
    %{tag: release["tagName"], title: release["name"] || ""}
  end

  # The name the earlier releases went by ("Localize Phone Number" where
  # mix.exs says Localize.PhoneNumber), so a repository's releases stay
  # titled alike: the name most of them use, the newest's on a tie, so one
  # mistyped title is not copied. nil when none is titled
  # "<Name> version <version>".
  defp released_name(released) do
    titled =
      for %{tag: tag, title: title} <- released,
          {:ok, version} <- [Releases.version(tag)],
          [_title, name] <- [Regex.run(@titled, title)] do
        {version, name}
      end

    counts = Enum.frequencies_by(titled, fn {_version, name} -> name end)

    titled
    |> Enum.sort_by(fn {version, _name} -> version end, {:desc, Version})
    |> Enum.max_by(fn {_version, name} -> counts[name] end, fn -> {nil, nil} end)
    |> elem(1)
  end

  defp described(slug, name, release) do
    title = Releases.title(name || project_name(slug, release.tag), release.version)
    Map.merge(release, %{title: title, notes: notes(slug, release)})
  end

  # The changelog as it was at the tag, else as it is now, for a section
  # written after the tag was made.
  defp notes(slug, release) do
    case section_at(slug, release.tag, release.version) do
      {:ok, section} -> {:ok, section}
      {:error, _reason} -> section_at(slug, nil, release.version)
    end
  end

  defp section_at(slug, ref, version) do
    with {:ok, changelog} <- file_at(slug, ref, "CHANGELOG.md") do
      Releases.section(changelog, version)
    end
  end

  defp project_name(slug, tag) do
    mix =
      case file_at(slug, tag, "mix.exs") do
        {:ok, text} -> text
        {:error, _reason} -> ""
      end

    case Regex.run(@mix_name, mix) do
      [_match, name] -> String.replace(name, ".", " ")
      nil -> slug |> String.split("/") |> List.last()
    end
  end

  defp file_at(slug, ref, file) do
    query =
      if is_nil(ref) do
        ""
      else
        "?ref=" <> URI.encode_www_form(ref)
      end

    gh([
      "api",
      "-H",
      "Accept: application/vnd.github.raw+json",
      "repos/#{slug}/contents/#{file}#{query}"
    ])
  end

  # ------------------------------------------------------------------
  # Commands

  defp git(path, arguments) do
    run("git", ["-C", path | arguments])
  end

  defp gh(arguments) do
    run("gh", arguments)
  end

  defp run(command, arguments) do
    case System.cmd(command, arguments, stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, _status} -> {:error, String.trim(output)}
    end
  end
end
