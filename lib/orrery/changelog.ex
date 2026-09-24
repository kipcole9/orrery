defmodule Orrery.Changelog do
  @moduledoc """
  Reads a repository's CHANGELOG and reports the newest released version and
  whether unreleased entries are waiting.

  Two heading conventions appear across these projects and both are handled:

      ## [Unreleased]                       Keep a Changelog
      ## [1.2.0] - 2026-08-16

      ## Unreleased                         the house style
      ## Money v6.2.1
      ## Astro version 2.5.0
      ## Unicode Set 1.9.0
  """

  @names ~w[CHANGELOG.md CHANGELOG CHANGES.md HISTORY.md]

  @doc """
  Returns a map describing the changelog at `path`, or `nil` when there is none.
  """
  def info(path) do
    with file when not is_nil(file) <- find(path),
         {:ok, source} <- File.read(file) do
      sections = sections(source)
      unreleased = Enum.find(sections, & &1.unreleased)
      latest = Enum.find(sections, &(not &1.unreleased and &1.version != nil))

      %{
        file: Path.relative_to(file, path),
        latest_version: latest && latest.version,
        latest_date: latest && latest.date,
        latest_heading: latest && latest.heading,
        unreleased: unreleased != nil and unreleased.entries > 0,
        unreleased_entries: (unreleased && unreleased.entries) || 0,
        unreleased_categories: (unreleased && unreleased.categories) || [],
        unreleased_preview: (unreleased && unreleased.preview) || []
      }
    else
      _ -> nil
    end
  end

  defp find(path) do
    Enum.find_value(@names, fn name ->
      file = Path.join(path, name)
      if File.regular?(file), do: file
    end)
  end

  @doc false
  def sections(source) do
    source
    |> String.split("\n")
    |> chunk_by_h2()
    |> Enum.map(&section/1)
  end

  # Groups the file into `{heading, body_lines}` pairs, one per level-2 heading.
  defp chunk_by_h2(lines) do
    lines
    |> Enum.reduce([], fn line, acc ->
      if h2?(line) do
        [{line, []} | acc]
      else
        case acc do
          [{h, body} | rest] -> [{h, [line | body]} | rest]
          [] -> []
        end
      end
    end)
    |> Enum.map(fn {h, body} -> {h, Enum.reverse(body)} end)
    |> Enum.reverse()
  end

  defp h2?(line), do: Regex.match?(~r/^##\s+\S/, line) and not Regex.match?(~r/^###/, line)

  defp section({heading, body}) do
    title = heading |> String.replace_prefix("##", "") |> String.trim()
    unreleased? = Regex.match?(~r/^\[?unreleased\]?$/i, strip_links(title))

    %{
      heading: title,
      unreleased: unreleased?,
      version: if(not unreleased?, do: version_in(title)),
      date: date_in(title) || date_in(Enum.join(Enum.take(body, 6), " ")),
      entries: count_entries(body),
      categories: categories(body),
      preview: preview(body)
    }
  end

  defp strip_links(s), do: Regex.replace(~r/\[([^\]]*)\]\([^)]*\)/, s, "\\1")

  @doc false
  def version_in(title) do
    case Regex.run(~r/(?:^|[\s\[vV])v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.\-]+)?)/, title) do
      [_, v] -> v
      _ -> nil
    end
  end

  @months ~w[January February March April May June July August September October November December]

  @doc false
  def date_in(text) do
    iso = Regex.run(~r/(\d{4})-(\d{2})-(\d{2})/, text)

    long =
      Regex.run(
        ~r/(#{Enum.join(@months, "|")})\s+(\d{1,2})(?:st|nd|rd|th)?,?\s+(\d{4})/,
        text
      )

    cond do
      iso ->
        [_, y, m, d] = iso
        "#{y}-#{m}-#{d}"

      long ->
        [_, month, d, y] = long
        m = Enum.find_index(@months, &(&1 == month)) + 1
        "#{y}-#{pad2(m)}-#{pad2(String.to_integer(d))}"

      true ->
        nil
    end
  end

  defp pad2(n), do: n |> Integer.to_string() |> String.pad_leading(2, "0")

  # A changelog entry is a top-level bullet. Continuation lines are indented and
  # must not be counted twice.
  defp count_entries(body) do
    body |> Enum.count(&Regex.match?(~r/^[*\-]\s+\S/, &1))
  end

  defp categories(body) do
    body
    |> Enum.filter(&Regex.match?(~r/^###\s+\S/, &1))
    |> Enum.map(&(&1 |> String.replace_prefix("###", "") |> String.trim()))
  end

  # The first few entries, trimmed, so the dashboard can show what is waiting
  # to ship without opening the file.
  defp preview(body) do
    body
    |> Enum.filter(&Regex.match?(~r/^[*\-]\s+\S/, &1))
    |> Enum.take(5)
    |> Enum.map(fn line ->
      line
      |> String.replace(~r/^[*\-]\s+/, "")
      |> Orrery.Text.plain()
      |> Orrery.Text.truncate(180)
    end)
  end
end

defmodule Orrery.Text do
  @moduledoc "Small helpers shared by the changelog and plan parsers."

  @doc "Reduces inline Markdown to readable plain text."
  def plain(text) do
    text
    |> String.replace(~r/!\[[^\]]*\]\([^)]*\)/, "")
    |> String.replace(~r/\[([^\]]*)\]\([^)]*\)/, "\\1")
    |> String.replace(~r/`([^`]*)`/, "\\1")
    |> String.replace(~r/\*\*([^*]*)\*\*/, "\\1")
    |> String.replace(~r/(?<!\w)\*([^*]+)\*(?!\w)/, "\\1")
    |> String.replace(~r/~~([^~]*)~~/, "\\1")
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
  end

  @doc "Truncates to `limit` graphemes on a word boundary where possible."
  def truncate(text, limit) do
    if String.length(text) <= limit do
      text
    else
      head = String.slice(text, 0, limit)

      case String.split(head, " ") do
        parts when length(parts) > 1 -> Enum.drop(parts, -1) |> Enum.join(" ") |> Kernel.<>("…")
        _ -> head <> "…"
      end
    end
  end
end
