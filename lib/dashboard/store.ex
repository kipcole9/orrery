defmodule Dashboard.Store do
  @moduledoc """
  Holds the most recent report and keeps it fresh.

  The store collects on a schedule — by default on the hour, every hour from
  05:00 to 20:00 local time — and on demand through `refresh/0`; a collection
  already in flight is reused rather than duplicated. At start-up it collects
  immediately only when a scheduled slot has passed since the persisted
  report was made (or there is no report); otherwise it waits for the next
  slot. A plain interval is available instead of the hourly window.

  Every successful collection is written to `data.json` under `:data_dir`, so
  a restarted service shows the last report immediately while the next one
  is gathered. The GitHub ETag cache lives in the same directory.

  Subscribers to `subscribe/0` receive `{:dashboard, :refreshed, status}` after
  a successful collection and `{:dashboard, :refresh_failed, status}` after a
  failed one, where `status` is the map returned by `status/0`.

  ## Configuration

      config :dashboard, Dashboard.Store,
        schedule: {:hourly, 5..20},
        data_dir: "~/.cache/dashboard",
        collect_on_start: true

  `:schedule` is `{:hourly, first..last}` (on the hour, within that inclusive
  window of local hours) or `{:every, milliseconds}`. `:refresh_interval` is
  accepted as a shorthand for the latter.

  Options passed to `start_link/1` take precedence over the application
  environment. `:collector` names the module whose `collect/1` gathers a
  report; it defaults to `Dashboard.Collector` and exists so tests can
  substitute one.
  """

  use GenServer
  require Logger

  @topic "dashboard"
  @pubsub Dashboard.PubSub
  @default_schedule {:hourly, 5..20}

  @typedoc "When to collect: hourly within a window of local hours, or every so many milliseconds."
  @type schedule :: {:hourly, Range.t()} | {:every, pos_integer()}

  defstruct report: nil,
            json: nil,
            generated_at: nil,
            task: nil,
            collecting_since: nil,
            timer: nil,
            next_refresh_at: nil,
            last_error: nil,
            last_duration_ms: nil,
            schedule: @default_schedule,
            data_dir: nil,
            collect_on_start: true,
            collector: Dashboard.Collector,
            collector_options: []

  @type status :: %{
          ready: boolean(),
          refreshing: boolean(),
          generated_at: String.t() | nil,
          next_refresh_at: String.t() | nil,
          last_error: String.t() | nil,
          last_duration_ms: non_neg_integer() | nil,
          schedule: String.t(),
          data_dir: Path.t()
        }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Starts the store.

  ### Options

  * `:name` registers the process. Defaults to `Dashboard.Store`.

  * `:schedule` is a `t:schedule/0`. Defaults to `{:hourly, 5..20}`.

  * `:refresh_interval`, in milliseconds, is a shorthand for
    `schedule: {:every, milliseconds}` and takes precedence over `:schedule`.

  * `:data_dir` is where `data.json` and the GitHub cache are written.
    Defaults to `~/.cache/dashboard`.

  * `:collect_on_start` collects immediately when no fresh persisted report
    exists. Defaults to `true`.

  * `:collector` is the module whose `collect/1` produces a report.

  * `:collector_options` are passed through to the collector.

  ### Returns

  * `{:ok, pid}` or `{:error, reason}`.

  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options \\ []) do
    {name, options} = Keyword.pop(options, :name, __MODULE__)
    GenServer.start_link(__MODULE__, options, name: name)
  end

  @doc """
  Returns the latest report as a map with string keys, exactly as `data.json`
  holds it.

  ### Returns

  * `{:ok, report}` or `{:error, :not_ready}` before the first collection
    finishes.

  """
  @spec latest(GenServer.server()) :: {:ok, map()} | {:error, :not_ready}
  def latest(server \\ __MODULE__), do: GenServer.call(server, :latest)

  @doc """
  Returns the latest report encoded as JSON.

  ### Returns

  * `{:ok, json}` or `{:error, :not_ready}`.

  """
  @spec latest_json(GenServer.server()) :: {:ok, binary()} | {:error, :not_ready}
  def latest_json(server \\ __MODULE__), do: GenServer.call(server, :latest_json)

  @doc """
  Reports whether a collection is running, when the report was generated and
  when the next scheduled collection is due.

  ### Returns

  * A `t:status/0` map.

  """
  @spec status(GenServer.server()) :: status()
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  Starts a collection now.

  ### Returns

  * `:started`, or `:already_running` when one is in flight; the running
    collection's result will be used.

  """
  @spec refresh(GenServer.server()) :: :started | :already_running
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh)

  @doc """
  Subscribes the calling process to refresh notifications.

  ### Returns

  * `:ok` or `{:error, term}`.

  """
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(@pubsub, @topic)

  @doc """
  Returns the directory reports and caches are written to when none is
  configured.

  ### Returns

  * An absolute path.

  """
  @spec default_data_dir() :: Path.t()
  def default_data_dir, do: Path.expand("~/.cache/dashboard")

  # ------------------------------------------------------------------
  # Callbacks
  # ------------------------------------------------------------------

  @impl true
  def init(options) do
    options = Keyword.merge(Application.get_env(:dashboard, __MODULE__, []), options)

    state = %__MODULE__{
      schedule: schedule_option(options),
      data_dir: Path.expand(Keyword.get(options, :data_dir) || default_data_dir()),
      collect_on_start: Keyword.get(options, :collect_on_start, true),
      collector: Keyword.get(options, :collector, Dashboard.Collector),
      collector_options: Keyword.get(options, :collector_options, [])
    }

    {:ok, load_persisted(state), {:continue, :schedule}}
  end

  # An explicit :refresh_interval wins over :schedule, so a caller (or a
  # test) asking for a plain interval gets one whatever the application
  # environment says.
  defp schedule_option(options) do
    case {Keyword.get(options, :refresh_interval), Keyword.get(options, :schedule)} do
      {ms, _} when is_integer(ms) and ms > 0 -> {:every, ms}
      {_, {:hourly, %Range{}} = schedule} -> schedule
      {_, {:every, ms}} when is_integer(ms) and ms > 0 -> {:every, ms}
      _ -> @default_schedule
    end
  end

  @impl true
  def handle_continue(:schedule, state) do
    cond do
      not due?(state) -> {:noreply, schedule(state, next_delay(state.schedule))}
      state.collect_on_start -> {:noreply, start_collection(state)}
      true -> {:noreply, schedule(state, next_delay(state.schedule))}
    end
  end

  # Has a collection been missed? For an interval: the report is older than
  # it. For the hourly window: the most recent slot is later than the report.
  defp due?(%{generated_at: nil}), do: true

  defp due?(%{schedule: {:every, ms}, generated_at: generated_at}) do
    DateTime.diff(DateTime.utc_now(), generated_at, :millisecond) >= ms
  end

  defp due?(%{schedule: {:hourly, hours}, generated_at: generated_at}) do
    slot = last_slot(hours, NaiveDateTime.local_now())
    NaiveDateTime.compare(slot, local(generated_at)) == :gt
  end

  defp local(%DateTime{} = datetime) do
    # Local wall-clock time of a UTC instant, via the OS's offset for now.
    offset = NaiveDateTime.diff(NaiveDateTime.local_now(), NaiveDateTime.utc_now(), :second)
    datetime |> DateTime.to_naive() |> NaiveDateTime.add(offset, :second)
  end

  @doc """
  Milliseconds until the next scheduled collection.

  ### Arguments

  * `schedule` is a `t:schedule/0`.

  * `now` is the local wall-clock time to count from; defaults to now.

  ### Returns

  * A non-negative integer.

  ### Examples

      iex> Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 09:15:00])
      2_700_000

      iex> Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 20:00:00])
      32_400_000

      iex> Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 03:59:59])
      3_601_000

      iex> Dashboard.Store.next_delay({:every, 60_000}, ~N[2026-09-21 09:15:00])
      60_000

  """
  @spec next_delay(schedule(), NaiveDateTime.t()) :: non_neg_integer()
  def next_delay(schedule, now \\ NaiveDateTime.local_now())
  def next_delay({:every, ms}, _now), do: ms

  def next_delay({:hourly, hours}, now) do
    max(NaiveDateTime.diff(next_slot(hours, now), now, :millisecond), 0)
  end

  # The first on-the-hour slot inside the window strictly after `now`, or the
  # window's first hour tomorrow.
  defp next_slot(first..last//_ = _hours, now) do
    today = NaiveDateTime.to_date(now)

    Enum.find_value(first..last//1, fn hour ->
      slot = NaiveDateTime.new!(today, Time.new!(hour, 0, 0))
      if NaiveDateTime.compare(slot, now) == :gt, do: slot
    end) || NaiveDateTime.new!(Date.add(today, 1), Time.new!(first, 0, 0))
  end

  # The most recent slot at or before `now`: today's, or yesterday's last.
  defp last_slot(first..last//_ = _hours, now) do
    today = NaiveDateTime.to_date(now)

    first..last//1
    |> Enum.map(&NaiveDateTime.new!(today, Time.new!(&1, 0, 0)))
    |> Enum.filter(&(NaiveDateTime.compare(&1, now) != :gt))
    |> List.last() || NaiveDateTime.new!(Date.add(today, -1), Time.new!(last, 0, 0))
  end

  @impl true
  def handle_call(:latest, _from, %{report: nil} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call(:latest, _from, state), do: {:reply, {:ok, state.report}, state}

  def handle_call(:latest_json, _from, %{json: nil} = state),
    do: {:reply, {:error, :not_ready}, state}

  def handle_call(:latest_json, _from, state), do: {:reply, {:ok, state.json}, state}

  def handle_call(:status, _from, state), do: {:reply, status_of(state), state}

  def handle_call(:refresh, _from, %{task: nil} = state),
    do: {:reply, :started, start_collection(state)}

  def handle_call(:refresh, _from, state), do: {:reply, :already_running, state}

  @impl true
  def handle_info(:scheduled_refresh, %{task: nil} = state) do
    {:noreply, start_collection(%{state | timer: nil})}
  end

  def handle_info(:scheduled_refresh, state), do: {:noreply, %{state | timer: nil}}

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, finish(result, state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    {:noreply, finish({:error, {:crashed, reason}}, state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # ------------------------------------------------------------------
  # Collection
  # ------------------------------------------------------------------

  defp start_collection(state) do
    state = cancel_timer(state)
    collector = state.collector

    options =
      Keyword.merge(
        [
          cache_dir: Path.join(state.data_dir, "github"),
          hex_cache_dir: Path.join(state.data_dir, "hex"),
          on_progress: fn {n, total, name} -> Logger.debug("collected #{n}/#{total} #{name}") end
        ],
        state.collector_options
      )

    Logger.info("dashboard: collecting")

    task =
      Task.Supervisor.async_nolink(Dashboard.TaskSupervisor, fn -> collector.collect(options) end)

    %{
      state
      | task: task,
        collecting_since: System.monotonic_time(:millisecond),
        next_refresh_at: nil
    }
  end

  defp finish({:ok, report}, state) when is_map(report) do
    json = JSON.encode!(report)
    normalised = JSON.decode!(json)
    duration = elapsed(state)

    state = %{
      state
      | report: normalised,
        json: json,
        generated_at: parse_time(normalised["generated_at"]) || DateTime.utc_now(),
        last_error: nil,
        last_duration_ms: duration,
        task: nil,
        collecting_since: nil
    }

    persist(state)

    Logger.info(
      "dashboard: collected #{normalised["totals"]["repos"]} repositories in #{div(duration, 1000)}s"
    )

    state = schedule(state, next_delay(state.schedule))
    broadcast(:refreshed, state)
    state
  rescue
    exception -> finish({:error, {:encode, Exception.message(exception)}}, state)
  end

  defp finish({:ok, other}, state), do: finish({:error, {:invalid_report, other}}, state)

  defp finish({:error, reason}, state) do
    message = describe(reason)
    Logger.error("dashboard: collection failed: #{message}")

    state = %{
      state
      | last_error: message,
        last_duration_ms: elapsed(state),
        task: nil,
        collecting_since: nil
    }

    state = schedule(state, next_delay(state.schedule))
    broadcast(:refresh_failed, state)
    state
  end

  defp finish(other, state), do: finish({:error, {:invalid_report, other}}, state)

  defp elapsed(%{collecting_since: nil}), do: nil
  defp elapsed(%{collecting_since: since}), do: System.monotonic_time(:millisecond) - since

  defp describe({:crashed, reason}), do: "collector crashed: " <> Exception.format_exit(reason)
  defp describe({:encode, message}), do: "report could not be encoded: " <> message
  defp describe({:invalid_report, other}), do: "collector returned " <> inspect(other, limit: 5)
  defp describe(reason), do: Dashboard.Projects.describe(reason)

  # ------------------------------------------------------------------
  # Scheduling
  # ------------------------------------------------------------------

  defp schedule(state, delay) do
    state = cancel_timer(state)
    delay = max(delay, 0)
    timer = Process.send_after(self(), :scheduled_refresh, delay)
    next = DateTime.add(DateTime.utc_now(), delay, :millisecond)
    %{state | timer: timer, next_refresh_at: DateTime.truncate(next, :second)}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end

  # ------------------------------------------------------------------
  # Persistence
  # ------------------------------------------------------------------

  defp data_file(state), do: Path.join(state.data_dir, "data.json")

  defp persist(state) do
    file = data_file(state)

    with :ok <- File.mkdir_p(state.data_dir),
         :ok <- File.write(file, Dashboard.Collector.pretty_json(state.report)) do
      :ok
    else
      {:error, reason} ->
        Logger.warning("dashboard: could not write #{file}: #{:file.format_error(reason)}")
    end
  end

  defp load_persisted(state) do
    file = data_file(state)

    with {:ok, raw} <- File.read(file),
         {:ok, %{"generated_at" => generated} = report} <- JSON.decode(raw),
         %DateTime{} = generated_at <- parse_time(generated) do
      Logger.info("dashboard: loaded report from #{file}, generated #{generated}")
      %{state | report: report, json: JSON.encode!(report), generated_at: generated_at}
    else
      {:error, :enoent} ->
        state

      other ->
        Logger.warning("dashboard: ignoring #{file}: #{inspect(other, limit: 3)}")
        state
    end
  end

  defp parse_time(nil), do: nil

  defp parse_time(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp parse_time(_), do: nil

  # ------------------------------------------------------------------
  # Status
  # ------------------------------------------------------------------

  defp status_of(state) do
    %{
      ready: state.json != nil,
      refreshing: state.task != nil,
      generated_at: state.generated_at && DateTime.to_iso8601(state.generated_at),
      next_refresh_at: state.next_refresh_at && DateTime.to_iso8601(state.next_refresh_at),
      last_error: state.last_error,
      last_duration_ms: state.last_duration_ms,
      schedule: describe_schedule(state.schedule),
      data_dir: state.data_dir
    }
  end

  defp describe_schedule({:hourly, first..last//_}),
    do: "hourly, #{pad(first)}:00 to #{pad(last)}:00 local time"

  defp describe_schedule({:every, ms}), do: "every #{div(ms, 60_000)} minutes"

  defp pad(hour), do: hour |> Integer.to_string() |> String.pad_leading(2, "0")

  defp broadcast(event, state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:dashboard, event, status_of(state)})
  end
end
