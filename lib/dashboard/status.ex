defmodule Dashboard.Status do
  @moduledoc """
  Reads a repository's `STATUS.md`: what kind of maintenance it gets.

  The file opens with a title and a status line in the same shape plan
  documents use:

      # Status

      **Status:** bug fixes only, 2026-09-21

      **Next release:** 1.3.0
      **Blocked on:** localize ~> 1.3, expected 2026-10
      **Blocked on:** CLDR 49 final release, expected 2026-10

      A sentence or two of context.

  Each `**Blocked on:**` line is one thing the repository cannot release
  without. When it names a hex package and a version requirement, the
  dashboard checks hex's latest version of that package and reports when the
  requirement is met; anything else is text, with the expected date as the
  only thing to check. `**Next release:**` names the version the blockers are
  holding up, for when `mix.exs` has not been bumped yet. The state is one of `active`, `application`, `demo only`, `bug fixes only`,
  `archived` or `fork`. A repository without the file is `:active`; a state the file
  spells some other way is `:unknown`, with the text kept so the dashboard can
  show it rather than guess.
  """

  @type state ::
          :active | :application | :demo_only | :bug_fixes_only | :archived | :fork | :unknown

  @type blocker :: %{
          text: String.t(),
          package: String.t() | nil,
          requirement: String.t() | nil,
          expected: String.t() | nil
        }

  @type t :: %{
          state: state(),
          label: String.t(),
          date: String.t() | nil,
          note: String.t() | nil,
          next_release: String.t() | nil,
          blockers: [blocker()]
        }

  @states [
    {"active", :active},
    {"application", :application},
    {"demo only", :demo_only},
    {"bug fixes only", :bug_fixes_only},
    {"archived", :archived},
    {"fork", :fork}
  ]

  @labels Map.new(@states, fn {text, state} -> {state, text} end)

  @status_line ~r/^\s*>?\s*\*\*Status:?\*\*:?\s*(\S.*?)\s*$/i
  @blocked_line ~r/^\s*\*\*Blocked on:?\*\*:?\s*(\S.*?)\s*$/i
  @next_release_line ~r/^\s*\*\*Next release:?\*\*:?\s*v?(\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)\s*$/i
  @expected ~r/^(.*?)(?:,\s*expected\s+(\d{4}-\d{2}(?:-\d{2})?))?\.?$/i
  @package_requirement ~r/^([a-z][a-z0-9_]*)\s+((?:~>|>=|==|=)?\s*\d+\.\d+(?:\.\d+)?(?:[-+][0-9A-Za-z.-]+)?)$/

  @doc """
  Reads `STATUS.md` in the repository at `path`.

  ### Arguments

  * `path` is the repository's root directory.

  ### Returns

  * A `t:t/0` map, or `nil` when the file is missing or has no status line.

  """
  @spec info(Path.t()) :: t() | nil
  def info(path) do
    file = Path.join(path, "STATUS.md")

    with true <- File.regular?(file),
         {:ok, source} <- File.read(file) do
      parse(source)
    else
      _ -> nil
    end
  end

  @doc """
  Parses the contents of a `STATUS.md`.

  ### Arguments

  * `source` is the file's text.

  ### Returns

  * A `t:t/0` map, or `nil` when there is no status line.

  ### Examples

      iex> Dashboard.Status.parse("# Status\\n\\n**Status:** bug fixes only, 2026-09-21\\n\\nSuperseded by Localize.\\n")
      %{state: :bug_fixes_only, label: "bug fixes only", date: "2026-09-21", note: "Superseded by Localize.", next_release: nil, blockers: []}

      iex> Dashboard.Status.parse("# Status\\n\\n**Status:** Demo Only\\n")
      %{state: :demo_only, label: "demo only", date: nil, note: nil, next_release: nil, blockers: []}

      iex> Dashboard.Status.parse("# Status\\n\\n**Status:** on hiatus, 2026-01-01\\n")
      %{state: :unknown, label: "on hiatus", date: "2026-01-01", note: nil, next_release: nil, blockers: []}

      iex> %{blockers: blockers, note: note, next_release: next} = Dashboard.Status.parse("# Status\\n\\n**Status:** active, 2026-09-21\\n\\n**Next release:** 1.3.0\\n**Blocked on:** localize ~> 1.3, expected 2026-10\\n**Blocked on:** CLDR 49 final release, expected 2026-10-31\\n\\nWaiting on the CLDR 49 cycle.\\n")
      iex> blockers
      [%{text: "localize ~> 1.3", package: "localize", requirement: "~> 1.3", expected: "2026-10"}, %{text: "CLDR 49 final release", package: nil, requirement: nil, expected: "2026-10-31"}]
      iex> {note, next}
      {"Waiting on the CLDR 49 cycle.", "1.3.0"}

      iex> Dashboard.Status.parse("# Status\\n\\nNothing here.\\n")
      nil

  """
  @spec parse(binary()) :: t() | nil
  def parse(source) when is_binary(source) do
    lines = String.split(source, "\n")

    case Enum.find_index(lines, &Regex.match?(@status_line, &1)) do
      nil ->
        nil

      index ->
        [_, text] = Regex.run(@status_line, Enum.at(lines, index))
        {state_text, date} = split_date(text)
        {state, label} = classify(state_text)

        rest = Enum.drop(lines, index + 1)

        %{
          state: state,
          label: label,
          date: date,
          note:
            rest
            |> Enum.reject(
              &(Regex.match?(@blocked_line, &1) or Regex.match?(@next_release_line, &1))
            )
            |> note(),
          next_release:
            Enum.find_value(
              rest,
              &(Regex.run(@next_release_line, &1) |> List.wrap() |> Enum.at(1))
            ),
          blockers: blockers(rest)
        }
    end
  end

  def parse(_), do: nil

  @doc """
  Returns the state to use for a repository, treating a missing file as
  `:active`.

  ### Arguments

  * `status` is the map from `info/1`, or `nil`.

  ### Returns

  * A `t:state/0`.

  ### Examples

      iex> Dashboard.Status.state(nil)
      :active

      iex> Dashboard.Status.state(%{state: :archived})
      :archived

  """
  @spec state(t() | nil) :: state()
  def state(nil), do: :active
  def state(%{state: state}), do: state

  @doc """
  Returns the human-readable label for a state.

  ### Arguments

  * `state` is a `t:state/0`.

  ### Returns

  * A string.

  ### Examples

      iex> Dashboard.Status.label(:bug_fixes_only)
      "bug fixes only"

  """
  @spec label(state()) :: String.t()
  def label(state), do: Map.get(@labels, state, "unknown")

  # ------------------------------------------------------------------

  defp split_date(text) do
    case Regex.run(~r/^(.*?)\s*,\s*(\d{4}-\d{2}-\d{2})\s*\.?$/, text) do
      [_, state_text, date] -> {state_text, date}
      _ -> {String.trim_trailing(text, "."), nil}
    end
  end

  defp classify(text) do
    normalised = text |> String.downcase() |> String.replace(~r/[\s_-]+/, " ") |> String.trim()

    case List.keyfind(@states, normalised, 0) do
      {label, state} -> {state, label}
      nil -> {:unknown, String.trim(text)}
    end
  end

  defp blockers(lines) do
    lines
    |> Enum.flat_map(fn line ->
      case Regex.run(@blocked_line, line) do
        [_, text] -> [blocker(text)]
        _ -> []
      end
    end)
  end

  @doc """
  Parses one `**Blocked on:**` value.

  ### Arguments

  * `text` is the text after the label, such as `"localize ~> 1.3, expected 2026-10"`.

  ### Returns

  * A `t:blocker/0`. `:package` and `:requirement` are set only when the text
    is a hex package name followed by a version requirement `Version` accepts;
    a bare version means "at least that version".

  ### Examples

      iex> Dashboard.Status.blocker("localize 1.3.0, expected 2026-10-15")
      %{text: "localize 1.3.0", package: "localize", requirement: ">= 1.3.0", expected: "2026-10-15"}

      iex> Dashboard.Status.blocker("unicode_string >= 2.4")
      %{text: "unicode_string >= 2.4", package: "unicode_string", requirement: ">= 2.4.0", expected: nil}

      iex> Dashboard.Status.blocker("a decision from the CLDR TC")
      %{text: "a decision from the CLDR TC", package: nil, requirement: nil, expected: nil}

  """
  @spec blocker(String.t()) :: blocker()
  def blocker(text) do
    [_, what, expected] =
      case Regex.run(@expected, String.trim(text)) do
        [_, what, expected] -> [nil, what, expected]
        [_, what] -> [nil, what, nil]
        _ -> [nil, String.trim(text), nil]
      end

    what = String.trim(what)

    case Regex.run(@package_requirement, what) do
      [_, package, requirement] ->
        case normalise_requirement(requirement) do
          nil ->
            %{text: what, package: nil, requirement: nil, expected: expected}

          normalised ->
            %{text: what, package: package, requirement: normalised, expected: expected}
        end

      _ ->
        %{text: what, package: nil, requirement: nil, expected: expected}
    end
  end

  # "1.3" and ">= 1.3" become ">= 1.3.0"; "~> 1.3" is already a requirement.
  defp normalise_requirement(requirement) do
    {operator, version} =
      case Regex.run(~r/^(~>|>=|==|=)?\s*(.+)$/, String.trim(requirement)) do
        [_, "", version] -> {">=", version}
        [_, "=", version] -> {"==", version}
        [_, operator, version] -> {operator, version}
      end

    version =
      case String.split(version, ".") do
        [major, minor] when operator != "~>" -> "#{major}.#{minor}.0"
        _ -> version
      end

    candidate = operator <> " " <> version

    case Version.parse_requirement(candidate) do
      {:ok, _} -> candidate
      :error -> nil
    end
  end

  # The first paragraph after the status line, as plain text.
  defp note(lines) do
    lines
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> Enum.take_while(&(String.trim(&1) != ""))
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.join(" ")
    |> Dashboard.Text.plain()
    |> Dashboard.Text.truncate(300)
    |> case do
      "" -> nil
      text -> text
    end
  end
end
