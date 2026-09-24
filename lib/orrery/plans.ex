defmodule Orrery.Plans do
  @moduledoc """
  Finds plan documents in a repository and works out which of their items are
  still open.

  These projects track progress in five ways, and the parser reads all of them
  rather than imposing a new convention:

    * an index table with a status column, marked either with ✅ / 🟡 / ❌ or
      with words such as `DONE` and `BLOCKED`
    * task-list checkboxes, `* [ ]` and `* [x]`
    * bullets or headings annotated with ✅, ~~strikethrough~~ or **Done**
    * a section heading that carries the verdict for everything under it —
      `## Done — pure-BEAM additions`, `## Blocked on Localize`,
      `## ~~Add Image.FaceDetection~~ — shipped in v0.3.0`
    * a `**Status:**` line summarising the whole document

  The hard part is not finding items but refusing to invent them. A plan
  written as prose has hundreds of bullets and no tasks, so a parser that
  counts every bullet reports a hundred phantom items. Three rules prevent
  that:

    * a table counts only when it looks like an index — a status column whose
      values really are statuses, or several rows already carrying markers.
      Tables that merely illustrate a point are skipped, and so are the
      reference tables sitting alongside an index in the same document.
    * a file named TODO, ROADMAP or PLAN is a task list by definition, so its
      bullets are items whether or not anyone annotated them.
    * anywhere else, bullets count only when a good share of them are
      annotated. Below that threshold the document is reported as narrative:
      `tracked` is false, no counts are given, and the dashboard shows its
      `**Status:**` line and headings instead of a number it cannot stand
      behind.
  """

  @plan_dirs ~w[plans plan docs/plans doc/plans]
  @loose_names ~w[TODO.md ROADMAP.md PLAN.md TODO ROADMAP]

  @done_markers ["✅", "☑", "✔", "✔️"]
  @partial_markers ["🟡", "🚧", "⏳", "🟠"]
  @blocked_markers ["❌", "⛔", "🔴"]

  # A bullet list is a task list only when this share of its items is annotated.
  @annotation_threshold 0.30
  @minimum_annotations 3

  @status_headers ~r/^(status|support|state|progress|done)$/i

  # A status column has to contain statuses. A reference table with a column
  # headed "Status" whose values read "Existing" and "New" is not an index.
  @status_column_share 0.5

  @doc "Returns a list of plan-document maps for the repository at `path`."
  def scan(path) do
    path
    |> files()
    |> Enum.map(&document(&1, path))
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(&{-&1.open, &1.file})
  end

  @doc false
  def files(path) do
    from_dirs =
      @plan_dirs
      |> Enum.map(&Path.join(path, &1))
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir -> dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort() end)

    loose =
      @loose_names
      |> Enum.map(&Path.join(path, &1))
      |> Enum.filter(&File.regular?/1)

    (from_dirs ++ loose) |> Enum.uniq()
  end

  # TODO, ROADMAP and PLAN are task lists by name; a document under plans/ has
  # to show that it is one.
  defp task_file?(file) do
    Regex.match?(~r/^(TODO|ROADMAP|PLAN)(\.\w+)?$/i, Path.basename(file))
  end

  defp document(file, repo_path) do
    case File.read(file) do
      {:ok, source} -> analyse(file, repo_path, source)
      _ -> nil
    end
  end

  defp analyse(file, repo_path, source) do
    lines = String.split(source, "\n")
    {items, style} = items(lines, task_file?: task_file?(file))
    open_items = Enum.filter(items, &(&1.state in [:open, :partial, :blocked]))

    %{
      file: Path.relative_to(file, repo_path),
      title: title(lines, file),
      status_line: status_line(lines),
      tracked: items != [],
      style: style,
      total: length(items),
      done: Enum.count(items, &(&1.state == :done)),
      partial: Enum.count(items, &(&1.state == :partial)),
      blocked: Enum.count(items, &(&1.state == :blocked)),
      open: length(open_items),
      percent_done: percent(items),
      open_items: Enum.take(open_items, 30),
      headings: headings(lines),
      words: source |> String.split(~r/\s+/, trim: true) |> length(),
      modified: modified(file, repo_path)
    }
  end

  defp percent([]), do: nil

  defp percent(items) do
    done = Enum.count(items, &(&1.state == :done))
    partial = Enum.count(items, &(&1.state == :partial))
    round((done + partial * 0.5) / length(items) * 100)
  end

  # ------------------------------------------------------------------
  # Item extraction
  # ------------------------------------------------------------------

  @doc """
  Returns `{items, style}` for a document's lines. `style` is one of `:table`,
  `:checkbox`, `:annotated`, `:sectioned` or `:narrative`.

  Pass `task_file?: true` for a file named `TODO`, `ROADMAP` or `PLAN`. Such a
  file is a task list by definition, so its bullets are items whether or not
  anyone annotated them — where a plan written as prose has to earn that
  reading by annotating a good share of its bullets.
  """
  def items(lines, options \\ []) do
    checkboxes = checkbox_items(lines)
    task_file? = Keyword.get(options, :task_file?, false)

    cond do
      (rows = table_items(lines)) != [] ->
        {rows ++ checkboxes, :table}

      checkboxes != [] ->
        {checkboxes, :checkbox}

      (bullets = annotated_items(lines, task_file?)) != [] ->
        {bullets, if(task_file?, do: :sectioned, else: :annotated)}

      true ->
        {[], :narrative}
    end
  end

  # ---- index tables ------------------------------------------------

  defp table_items(lines) do
    blocks = table_blocks(lines)
    qualifying = Enum.filter(blocks, & &1.qualifies?)

    # A document often repeats one index table under several headings — the
    # same columns, split by section. If one of them qualifies, its siblings
    # are the same index and qualify too, even where a section happens to have
    # few marked rows.
    signatures = qualifying |> Enum.map(& &1.signature) |> MapSet.new()

    blocks
    |> Enum.filter(&(&1.qualifies? or MapSet.member?(signatures, &1.signature)))
    |> Enum.flat_map(&block_items/1)
  end

  defp table_blocks(lines) do
    lines
    |> Enum.chunk_by(&table_line?/1)
    |> Enum.filter(&table_line?(hd(&1)))
    |> Enum.map(&block/1)
    |> Enum.reject(&is_nil/1)
    |> merge_continuations()
  end

  # A blank line inside a long index table splits it in the source but not in
  # meaning. A following block with no header of its own and the same column
  # count is the same table continued.
  defp merge_continuations(blocks) do
    Enum.reduce(blocks, [], fn block, acc ->
      case acc do
        [previous | rest] when block.header == nil ->
          if columns(previous) == columns(block) do
            [%{previous | body: previous.body ++ block.body} | rest]
          else
            [block | acc]
          end

        _ ->
          [block | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp columns(%{header: nil, body: [row | _]}), do: length(row)
  defp columns(%{header: header}), do: length(header)
  defp columns(_), do: 0

  defp table_line?(line), do: Regex.match?(~r/^\s*\|.*\|\s*$/, line)
  defp separator?(line), do: Regex.match?(~r/^\s*\|[\s:|\-]+\|\s*$/, line)

  defp block(block_lines) do
    rows = block_lines |> Enum.reject(&separator?/1) |> Enum.map(&cells/1)
    has_separator? = Enum.any?(block_lines, &separator?/1)

    {header, body} =
      case rows do
        [first | rest] when has_separator? -> {first, rest}
        _ -> {nil, rows}
      end

    body = Enum.reject(body, &(Enum.join(&1) |> String.trim() == ""))

    if body != [] do
      candidate =
        header &&
          Enum.find_index(header, &Regex.match?(@status_headers, Orrery.Text.plain(&1)))

      status_column = if status_like?(body, candidate), do: candidate
      marked = Enum.count(body, &row_marker/1)

      %{
        header: header,
        signature: header && Enum.map_join(header, "|", &String.downcase(Orrery.Text.plain(&1))),
        body: body,
        status_column: status_column,
        # A single row is never enough evidence on its own; it can still join
        # the table above it as a continuation.
        qualifies?:
          length(body) >= 2 and
            (status_column != nil or marked >= 2 or marked / length(body) >= 0.5)
      }
    end
  end

  defp status_like?(_body, nil), do: false

  defp status_like?(body, column) do
    recognised =
      Enum.count(body, fn row ->
        case Enum.at(row, column) do
          nil -> false
          cell -> classify(cell) != :open
        end
      end)

    recognised / length(body) >= @status_column_share
  end

  defp cells(line) do
    line
    |> String.trim()
    |> String.trim_leading("|")
    |> String.trim_trailing("|")
    |> String.split("|")
    |> Enum.map(&String.trim/1)
  end

  defp row_marker(cells), do: Enum.find_value(cells, &marker/1)

  defp block_items(block) do
    block.body
    |> Enum.map(&table_item(&1, block.status_column))
    |> Enum.reject(&is_nil/1)
  end

  defp table_item(cells, status_column) do
    {ref, rest} = split_reference(cells)
    title = rest |> Enum.map(&Orrery.Text.plain/1) |> Enum.find(&(&1 != ""))

    status_text =
      case status_column && Enum.at(cells, status_column) do
        nil -> Enum.join(cells, " ")
        "" -> Enum.join(cells, " ")
        text -> text
      end

    if title do
      %{
        ref: ref,
        title: Orrery.Text.truncate(title, 140),
        note: status_text |> Orrery.Text.plain() |> Orrery.Text.truncate(200),
        state: classify(status_text)
      }
    end
  end

  # A leading cell that is only a number or short code ("3", "16a", "P2") is the
  # item's reference, not its title.
  defp split_reference([first | rest] = cells) do
    plain = Orrery.Text.plain(first)

    if plain != "" and String.length(plain) <= 4 and
         Regex.match?(~r/^[A-Z]?[\d.]+[a-z]?$/i, plain) do
      {plain, rest}
    else
      {nil, cells}
    end
  end

  defp split_reference([]), do: {nil, []}

  # ---- checkboxes --------------------------------------------------

  # A checked box is done wherever it sits. An unchecked box takes the state
  # of the section it is in — `## In progress`, `## Blocked`, `## Deferred` —
  # and is otherwise open, unless its own text says something more specific.
  # Only top-level boxes are items; an indented box is a note under one.
  defp checkbox_items(lines) do
    {_h2, _h3, items} =
      Enum.reduce(lines, {nil, nil, []}, fn line, {h2, h3, acc} ->
        cond do
          match?({:heading, 1}, line_kind(line)) ->
            {nil, nil, acc}

          match?({:heading, 2}, line_kind(line)) ->
            {section_state(line), nil, acc}

          match?({:heading, _}, line_kind(line)) ->
            {h2, heading_state(line), acc}

          Regex.match?(~r/^[*\-]\s+\[[ xX]\]/, line) ->
            {h2, h3, [checkbox_item(line, h3 || h2) | acc]}

          true ->
            {h2, h3, acc}
        end
      end)

    Enum.reverse(items)
  end

  # `## Open` is one of the five standard sections and says so explicitly:
  # an unchecked item there is open whatever words its text happens to use.
  defp section_state(line) do
    if Regex.match?(~r/^##\s+open\s*$/i, line), do: :open, else: heading_state(line)
  end

  defp checkbox_item(line, section_state) do
    done? = Regex.match?(~r/^[*\-]\s+\[[xX]\]/, line)
    text = Regex.replace(~r/^[*\-]\s+\[[ xX]\]\s*/, line, "")

    state =
      cond do
        done? -> :done
        section_state in [:open, :partial, :blocked] -> section_state
        true -> classify_words(text)
      end

    %{
      ref: nil,
      title: text |> Orrery.Text.plain() |> Orrery.Text.truncate(140),
      note: "",
      state: state
    }
  end

  # ---- annotated bullets and headings ------------------------------

  defp annotated_items(lines, task_file?) do
    candidates = Enum.filter(lines, &candidate_line?/1)
    annotated = Enum.count(candidates, &annotated?/1)

    qualifies? =
      task_file? or
        (annotated >= @minimum_annotations and
           annotated / max(length(candidates), 1) >= @annotation_threshold)

    if qualifies?, do: walk(lines), else: []
  end

  # Walks the document in order so that an item can inherit the state of the
  # section it sits under. These files routinely put the verdict in the heading
  # — "## Done — pure-BEAM additions", "## Blocked on Localize", "## ~~Add
  # Image.FaceDetection~~ — shipped in v0.3.0" — and leave the bullets beneath
  # it unmarked. Reading the bullets alone would report finished work as open.
  defp walk(lines) do
    {_h2, _h3, items} =
      Enum.reduce(lines, {nil, nil, []}, fn line, {h2, h3, acc} ->
        case line_kind(line) do
          {:heading, 1} ->
            {nil, nil, acc}

          {:heading, 2} ->
            state = heading_state(line)
            acc = if annotated?(line), do: [item(line, state || :open) | acc], else: acc
            {state, nil, acc}

          {:heading, level} when level >= 3 ->
            state = heading_state(line)
            {h2, state, [item(line, state || h3 || h2 || :open) | acc]}

          :item ->
            own = marker(line) || (struck?(line) && :done) || nil
            {h2, h3, [item(line, own || h3 || h2 || classify(line)) | acc]}

          :other ->
            {h2, h3, acc}
        end
      end)

    items
    |> Enum.reverse()
    |> Enum.reject(&(String.length(&1.title) < 8))
  end

  defp item(line, state) do
    text = Regex.replace(~r/^\s*(?:[*\-]\s+|\d+[.)]\s+|\#{1,6}\s+)/, line, "")

    %{
      ref: nil,
      title: text |> Orrery.Text.plain() |> Orrery.Text.truncate(140),
      note: "",
      state: state
    }
  end

  # A heading states the section's verdict only when it says one. "## Scope" and
  # "## Tier 3 — domain-specific or niche" say nothing, so their items keep
  # whatever state they carry themselves.
  defp heading_state(line) do
    text = Regex.replace(~r/^\#{1,6}\s+/, line, "")

    case classify(text) do
      :open -> nil
      state -> state
    end
  end

  # Only top-level items. An indented bullet is a sub-point of the one above,
  # and counting both double-counts the work. Level-2 headings are section
  # titles, not tasks; level 3 and deeper often are tasks.
  defp line_kind(line) do
    cond do
      match = Regex.run(~r/^(\#{1,6})\s+\S/, line) -> {:heading, String.length(Enum.at(match, 1))}
      Regex.match?(~r/^\s*[*\-]\s+\[[ xX]\]/, line) -> :other
      Regex.match?(~r/^[*\-]\s+\S/, line) -> :item
      Regex.match?(~r/^\d+[.)]\s+\S/, line) -> :item
      true -> :other
    end
  end

  defp candidate_line?(line) do
    case line_kind(line) do
      :item -> true
      {:heading, level} when level >= 3 -> true
      _ -> false
    end
  end

  defp annotated?(line), do: marker(line) != nil or struck?(line)

  # ---- classification ----------------------------------------------

  defp marker(text) do
    cond do
      String.contains?(text, @done_markers) -> :done
      String.contains?(text, @partial_markers) -> :partial
      String.contains?(text, @blocked_markers) -> :blocked
      true -> nil
    end
  end

  # A completed bullet is struck through. The strike often runs over several
  # source lines, so an opening `~~` at the head of the text counts on its own.
  defp struck?(line) do
    Regex.match?(~r/~~[^~]+~~/, line) or
      Regex.match?(~r/^\s*(?:[*\-]\s+|\d+[.)]\s+|\#{1,6}\s+)?~~/, line)
  end

  @doc "Classifies one item's text as `:done`, `:partial`, `:blocked` or `:open`."
  def classify(text) do
    marker(text) || (struck?(text) && :done) || classify_words(text)
  end

  defp classify_words(text) do
    plain = Orrery.Text.plain(text)

    cond do
      # A verdict at the head of a status cell governs the rest of it: "DONE:
      # … lists DEFERRED pending a decision" is done, not deferred.
      Regex.match?(
        ~r/^\W*(done|complete[d]?|closed|shipped|landed|implemented|resolved|yes)\b/i,
        plain
      ) ->
        :done

      Regex.match?(~r/^\W*(todo|open|pending|planned)\b/i, plain) ->
        :open

      Regex.match?(
        ~r/\b(blocked|not scheduled|not started|won'?t (do|fix)|abandoned|deferred|missing)\b/i,
        plain
      ) ->
        :blocked

      Regex.match?(
        ~r/\b(partial(ly)?|in flight|in progress|underway|substantially|mostly)\b/i,
        plain
      ) ->
        :partial

      Regex.match?(~r/\*\*\s*(done|complete[d]?|closed|shipped)\b/i, text) ->
        :done

      true ->
        :open
    end
  end

  # ---- document metadata -------------------------------------------

  defp title(lines, file) do
    Enum.find_value(lines, Path.basename(file, ".md"), fn line ->
      case Regex.run(~r/^#\s+(\S.*)$/, line) do
        [_, t] -> Orrery.Text.plain(t)
        _ -> nil
      end
    end)
  end

  defp status_line(lines) do
    Enum.find_value(lines, fn line ->
      case Regex.run(~r/^\s*>?\s*\*\*Status:?\*\*:?\s*(\S.*)$/, line) do
        [_, t] -> t |> Orrery.Text.plain() |> Orrery.Text.truncate(260)
        _ -> nil
      end
    end)
  end

  defp headings(lines) do
    lines
    |> Enum.filter(&Regex.match?(~r/^##\s+\S/, &1))
    |> Enum.map(&(&1 |> String.replace(~r/^#+\s+/, "") |> Orrery.Text.plain()))
    |> Enum.take(20)
  end

  defp modified(file, repo_path) do
    relative = Path.relative_to(file, repo_path)

    case Orrery.Git.run(repo_path, ["log", "-1", "--format=%cI", "--", relative]) do
      nil -> nil
      "" -> nil
      date -> date |> String.split("\n") |> hd() |> String.trim()
    end
  end
end
