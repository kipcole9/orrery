defmodule Dashboard.Store do
  @moduledoc """
  Holds the most recent report and keeps it fresh.

  The store collects once at start-up, unless a report persisted by a previous
  run is still younger than the refresh interval, and then again every
  `:refresh_interval` (24 hours by default). `refresh/0` starts a collection
  on demand; a collection already in flight is reused rather than duplicated.

  Every successful collection is written to `data.json` under `:data_dir`, so
  a restarted service shows the last report immediately while the next one
  is gathered. The GitHub ETag cache lives in the same directory.

  Subscribers to `subscribe/0` receive `{:dashboard, :refreshed, status}` after
  a successful collection and `{:dashboard, :refresh_failed, status}` after a
  failed one, where `status` is the map returned by `status/0`.

  ## Configuration

      config :dashboard, Dashboard.Store,
        refresh_interval: :timer.hours(24),
        data_dir: "~/.cache/dashboard",
        collect_on_start: true

  Options passed to `start_link/1` take precedence over the application
  environment. `:collector` names the module whose `collect/1` gathers a
  report; it defaults to `Dashboard.Collector` and exists so tests can
  substitute one.
  """

  use GenServer
  require Logger

  @topic "dashboard"
  @pubsub Dashboard.PubSub
  @default_interval :timer.hours(24)

  defstruct report: nil,
            json: nil,
            generated_at: nil,
            task: nil,
            collecting_since: nil,
            timer: nil,
            next_refresh_at: nil,
            last_error: nil,
            last_duration_ms: nil,
            interval: @default_interval,
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
          refresh_interval_ms: pos_integer(),
          data_dir: Path.t()
        }

  # ------------------------------------------------------------------
  # Public API
  # ------------------------------------------------------------------

  @doc """
  Starts the store.

  ### Options

  * `:name` registers the process. Defaults to `Dashboard.Store`.

  * `:refresh_interval` is the time between collections in milliseconds.
    Defaults to 24 hours.

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
      interval: Keyword.get(options, :refresh_interval, @default_interval),
      data_dir: Path.expand(Keyword.get(options, :data_dir) || default_data_dir()),
      collect_on_start: Keyword.get(options, :collect_on_start, true),
      collector: Keyword.get(options, :collector, Dashboard.Collector),
      collector_options: Keyword.get(options, :collector_options, [])
    }

    {:ok, load_persisted(state), {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    age =
      state.generated_at && DateTime.diff(DateTime.utc_now(), state.generated_at, :millisecond)

    cond do
      age && age < state.interval -> {:noreply, schedule(state, state.interval - age)}
      state.collect_on_start -> {:noreply, start_collection(state)}
      true -> {:noreply, schedule(state, state.interval)}
    end
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

    state = schedule(state, state.interval)
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

    state = schedule(state, state.interval)
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
      refresh_interval_ms: state.interval,
      data_dir: state.data_dir
    }
  end

  defp broadcast(event, state) do
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:dashboard, event, status_of(state)})
  end
end
