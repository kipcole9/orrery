defmodule Mix.Tasks.Orrery.Collect do
  @shortdoc "Collects the report once and writes data.json and orrery.html"

  @moduledoc """
  Collects the state of every project once, without starting the web server,
  and writes `data.json` and a self-contained `orrery.html`.

      mix orrery.collect                 collect everything
      mix orrery.collect --no-github     do not ask GitHub for issues
      mix orrery.collect --no-hex        do not ask hex.pm what is published
      mix orrery.collect --no-remote     do not ask each clone's origin for its HEAD
      mix orrery.collect --only Tempo    one project; repeatable
      mix orrery.collect --open          open the dashboard when it is written
      mix orrery.collect --out DIR       write somewhere other than the data directory
      mix orrery.collect --quiet         no progress output
      mix orrery.collect --projects F    read the registry from F
      mix orrery.collect --root DIR      override the registry root

  The GitHub token is read from `ORRERY_GITHUB_TOKEN`, `GITHUB_TOKEN` or
  `GH_TOKEN`. It is never written to the output or the cache. The ETag cache
  is shared with the running service, under the configured data directory.
  """

  use Mix.Task

  @switches [
    github: :boolean,
    hex: :boolean,
    remote: :boolean,
    only: :keep,
    root: :string,
    out: :string,
    open: :boolean,
    quiet: :boolean,
    projects: :string
  ]
  @aliases [o: :out, q: :quiet]

  @impl Mix.Task
  def run(argv) do
    {options, _rest, invalid} = OptionParser.parse(argv, strict: @switches, aliases: @aliases)

    if invalid != [] do
      Mix.raise("unrecognised option: #{invalid |> Enum.map(&elem(&1, 0)) |> Enum.join(", ")}")
    end

    Mix.Task.run("app.config")
    {:ok, _} = Application.ensure_all_started([:inets, :ssl, :phoenix])

    data_dir = data_dir()
    out_dir = Path.expand(options[:out] || data_dir)
    quiet? = options[:quiet] == true
    github? = Keyword.get(options, :github, true)
    hex? = Keyword.get(options, :hex, true)

    collector_options = [
      projects_file: options[:projects],
      root: options[:root],
      only: Keyword.get_values(options, :only),
      github?: github?,
      cache_dir: Path.join(data_dir, "github"),
      hex?: hex?,
      remote?: Keyword.get(options, :remote, true),
      hex_cache_dir: Path.join(data_dir, "hex"),
      on_progress: progress_fun(quiet?)
    ]

    unless quiet?, do: banner(collector_options, github?)

    started = System.monotonic_time(:millisecond)

    report =
      case Orrery.Collector.collect(collector_options) do
        {:ok, report} -> report
        {:error, reason} -> Mix.raise(Orrery.Projects.describe(reason))
      end

    elapsed = System.monotonic_time(:millisecond) - started

    json = JSON.encode!(report)
    File.mkdir_p!(out_dir)

    data_file = Path.join(out_dir, "data.json")
    File.write!(data_file, Orrery.Collector.pretty_json(report))

    html_file = Path.join(out_dir, "orrery.html")
    File.write!(html_file, render(json))

    unless quiet? do
      Mix.shell().info("")
      summary(report, elapsed)
      Mix.shell().info("")
      Mix.shell().info("  #{data_file}")
      Mix.shell().info("  #{html_file}")
      Mix.shell().info("")
    end

    if options[:open], do: open(html_file)
    :ok
  end

  defp data_dir do
    :orrery
    |> Application.get_env(Orrery.Store, [])
    |> Keyword.get(:data_dir)
    |> Kernel.||(Orrery.Store.default_data_dir())
    |> Path.expand()
  end

  defp render(json) do
    status = %{ready: true, refreshing: false, next_refresh_at: nil, last_error: nil}

    Phoenix.Template.render_to_string(OrreryWeb.OrreryHTML, "index", "html", %{
      data: json,
      status: status,
      mode: :static,
      csrf_token: nil
    })
  end

  defp banner(collector_options, github?) do
    registry_line =
      case Orrery.Projects.load(collector_options[:projects_file]) do
        {:ok, registry} ->
          root = collector_options[:root] || registry.root
          "  root    #{root}\n  projects #{Enum.map_join(registry.groups, ", ", & &1.name)}"

        {:error, _} ->
          "  registry #{collector_options[:projects_file] || Orrery.Projects.file()}"
      end

    Mix.shell().info("")
    Mix.shell().info(IO.ANSI.format([:bright, "Orrery"]))
    Mix.shell().info(registry_line)
    Mix.shell().info("  github  #{github_line(github?)}")

    Mix.shell().info(
      "  hex     #{if collector_options[:hex?], do: "queried for every library", else: "skipped (--no-hex)"}"
    )

    Mix.shell().info("")
  end

  defp github_line(false), do: "skipped (--no-github)"

  defp github_line(true) do
    case Orrery.GitHub.token_source() do
      nil -> "unauthenticated — 60 requests an hour, cached responses fill the gaps"
      var -> "authenticated from $#{var}"
    end
  end

  defp progress_fun(true), do: fn _ -> :ok end

  defp progress_fun(false) do
    fn {n, total, name} ->
      IO.write(
        "\r  #{String.pad_leading(to_string(n), 3)}/#{total}  #{String.pad_trailing(String.slice(name, 0, 40), 42)}"
      )

      if n == total, do: IO.write("\r" <> String.duplicate(" ", 60) <> "\r")
    end
  end

  defp summary(report, elapsed) do
    s = report.summary
    shell = Mix.shell()
    info = &shell.info/1

    info.(
      "  #{report.totals.repos} repositories in #{report.totals.groups} projects, #{div(elapsed, 1000)}s"
    )

    info.(
      "  release   #{s.released} current · #{s.unreleased_work} with unreleased work · #{s.pending_release} awaiting a tag"
    )

    info.(
      "  issues    #{s.open_issues} open · #{s.open_prs} pull requests · #{s.unanswered_issues} unanswered"
    )

    info.("  plans     #{s.plan_open} open items across #{s.plan_documents} documents")

    if report.github.enabled and report.github.remaining do
      info.(
        "  github    #{report.github.calls} requests, #{report.github.remaining} remaining this hour"
      )
    end

    if report.github[:rate_limited] do
      info.("")

      info.(
        IO.ANSI.format([
          :yellow,
          "  Rate limit reached. Issue counts for some repositories are from cache"
        ])
      )

      info.(
        IO.ANSI.format([
          :yellow,
          "  or missing. Set ORRERY_GITHUB_TOKEN and run again for a full pass."
        ])
      )
    end
  end

  defp open(file) do
    command = if :os.type() == {:unix, :darwin}, do: "open", else: "xdg-open"
    System.cmd(command, [file], stderr_to_stdout: true)
    :ok
  rescue
    _ -> :ok
  end
end
