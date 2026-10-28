defmodule Mix.Tasks.Orrery.Releases do
  @shortdoc "Lists, and with --create creates, the GitHub releases tags are missing"

  @moduledoc """
  Finds every version tag on origin that has no GitHub release, across the
  repositories in the registry, and with `--create` creates the release:
  titled `"<Name> version <version>"`, with the tag's `CHANGELOG.md`
  section as its notes.

      mix orrery.releases                    list what is missing; changes nothing
      mix orrery.releases --create           create the missing releases
      mix orrery.releases --only Tempo       one project; repeatable
      mix orrery.releases --repo PATH        one repository; repeatable
      mix orrery.releases --notes            print each release's notes in full
      mix orrery.releases --projects F       read the registry from F
      mix orrery.releases --root DIR         override the registry root

  A tag is a version tag when it is written `v` and a semantic version
  (`v2.1.1`, `v1.0.0-rc.7`); a pre-release becomes a GitHub pre-release.
  Releases are created oldest version first, and only the highest stable
  version is marked latest, and only when it is among those created, so a
  backfill never moves the latest release back.

  A tag whose changelog has no section for it is listed and never
  released with empty notes. A repository is skipped, with the reason,
  when origin is not on GitHub, the `gh` login cannot write to it, it is
  archived, or it is a fork its `STATUS.md` does not claim.

  It needs the GitHub CLI `gh`, logged in as someone who can create
  releases; it reads files from GitHub at the tag, so a clone need not
  have fetched the tags.
  """

  use Mix.Task

  alias Orrery.Releases.Gh

  @switches [
    create: :boolean,
    only: :keep,
    repo: :keep,
    notes: :boolean,
    projects: :string,
    root: :string
  ]

  @impl Mix.Task
  def run(argv) do
    {options, _rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if match?([_ | _], invalid) do
      Mix.raise("unrecognised option: #{Enum.map_join(invalid, ", ", &elem(&1, 0))}")
    end

    if is_nil(System.find_executable("gh")) do
      Mix.raise("the GitHub CLI `gh` is needed: https://cli.github.com")
    end

    Mix.Task.run("app.config")

    create? = options[:create] == true

    counts =
      Enum.reduce(
        groups(options),
        %{missing: 0, created: 0, failed: 0},
        &group(&1, &2, create?, options)
      )

    summary(counts, create?)
  end

  # The repositories to look at, by project: those named with --repo, else
  # the registry's, narrowed by --only.
  defp groups(options) do
    case Keyword.get_values(options, :repo) do
      [] -> registry_groups(options)
      paths -> [%{name: "Repositories", paths: Enum.map(paths, &Path.expand/1)}]
    end
  end

  defp registry_groups(options) do
    case registry(options) do
      {:ok, registry} -> Orrery.Collector.discover(registry).groups
      {:error, reason} -> Mix.raise(Orrery.Projects.describe(reason))
    end
  end

  defp registry(options) do
    with {:ok, registry} <- Orrery.Projects.load(options[:projects]),
         {:ok, registry} <- Orrery.Projects.only(registry, Keyword.get_values(options, :only)) do
      {:ok, rooted(registry, options[:root])}
    end
  end

  defp rooted(registry, nil) do
    registry
  end

  defp rooted(registry, root) do
    %{registry | root: root}
  end

  defp group(%{name: name, paths: paths}, counts, create?, options) do
    Mix.shell().info([:bright, name, :reset])
    Enum.reduce(paths, counts, &repository(&1, &2, create?, options))
  end

  defp repository(path, counts, create?, options) do
    label = Path.basename(path)

    case Gh.missing(path) do
      {:ok, %{releases: []}} ->
        Mix.shell().info("  #{label}: every version tag has its release")
        counts

      {:ok, %{slug: slug, releases: releases}} ->
        Mix.shell().info("  #{label} (#{slug}): #{length(releases)} without a release")
        Enum.reduce(releases, counts, &release(slug, &1, &2, create?, options))

      {:skip, reason} ->
        Mix.shell().info("  #{label}: skipped, #{reason}")
        counts

      {:error, reason} ->
        Mix.shell().error("  #{label}: #{first_line(reason)}")
        counts
    end
  end

  defp release(slug, entry, counts, create?, options) do
    Mix.shell().info("    #{entry.tag}  #{entry.title}#{marks(entry)}")
    show_notes(entry.notes, options[:notes] == true)
    counts = %{counts | missing: counts.missing + 1}

    if create? do
      created(Gh.create(slug, entry), counts)
    else
      counts
    end
  end

  defp created(:ok, counts) do
    Mix.shell().info("      created")
    %{counts | created: counts.created + 1}
  end

  defp created({:error, reason}, counts) do
    Mix.shell().error("      not created: #{first_line(reason)}")
    %{counts | failed: counts.failed + 1}
  end

  defp marks(entry) do
    [
      {entry.latest?, "latest"},
      {entry.prerelease?, "pre-release"},
      {match?({:error, _}, entry.notes), "NO CHANGELOG SECTION"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> parenthesised()
  end

  defp parenthesised([]) do
    ""
  end

  defp parenthesised(marks) do
    "  (" <> Enum.join(marks, ", ") <> ")"
  end

  defp show_notes({:ok, notes}, true) do
    notes
    |> String.split("\n")
    |> Enum.each(&Mix.shell().info("      " <> &1))
  end

  defp show_notes(_notes, _full?) do
    :ok
  end

  defp summary(counts, true) do
    Mix.shell().info(
      "\n#{counts.created} created, #{counts.failed} not created, of #{counts.missing} missing."
    )
  end

  defp summary(counts, false) do
    Mix.shell().info(
      "\n#{releases(counts.missing)} missing. Nothing was changed; run with --create to create them."
    )
  end

  defp releases(1) do
    "1 release"
  end

  defp releases(count) do
    "#{count} releases"
  end

  defp first_line(text) do
    text
    |> String.split("\n")
    |> hd()
  end
end
