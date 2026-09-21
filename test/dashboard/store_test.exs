defmodule Dashboard.StoreTest do
  use ExUnit.Case, async: false

  alias Dashboard.ScriptedCollector
  alias Dashboard.Store
  alias Dashboard.StubCollector

  @day :timer.hours(24)

  setup do
    data_dir =
      Path.join(System.tmp_dir!(), "dashboard-store-#{System.unique_integer([:positive])}")

    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf(data_dir) end)
    :ok = Store.subscribe()
    %{data_dir: data_dir}
  end

  defp start_store(data_dir, replies, options \\ []) do
    {:ok, queue} = Agent.start_link(fn -> replies end)

    reply = fn ->
      Agent.get_and_update(queue, fn
        [head | rest] -> {head, rest ++ [head]}
        [] -> {{:ok, StubCollector.report()}, []}
      end)
    end

    name = :"store_#{System.unique_integer([:positive])}"

    options =
      Keyword.merge(
        [
          name: name,
          data_dir: data_dir,
          collector: ScriptedCollector,
          collector_options: [reply: reply, test_pid: self()],
          refresh_interval: @day
        ],
        options
      )

    start_supervised!({Store, options})
    name
  end

  defp write_report(data_dir, generated_at) do
    report = %{StubCollector.report() | generated_at: DateTime.to_iso8601(generated_at)}
    File.write!(Path.join(data_dir, "data.json"), JSON.encode!(report))
  end

  test "collects on start, persists the report and broadcasts", %{data_dir: data_dir} do
    store = start_store(data_dir, [{:ok, StubCollector.report()}])

    assert_receive {:collecting, _pid}
    assert_receive {:dashboard, :refreshed, status}

    assert status.ready
    refute status.refreshing
    assert status.last_error == nil
    assert is_binary(status.generated_at)
    assert is_binary(status.next_refresh_at)

    assert {:ok, %{"totals" => %{"repos" => 0}, "generated_at" => generated}} =
             Store.latest(store)

    assert {:ok, json} = Store.latest_json(store)
    assert %{"generated_at" => ^generated} = JSON.decode!(json)

    assert %{"generated_at" => ^generated} =
             JSON.decode!(File.read!(Path.join(data_dir, "data.json")))
  end

  test "is not ready before the first collection", %{data_dir: data_dir} do
    store = start_store(data_dir, [], collect_on_start: false)

    refute_receive {:collecting, _}, 100
    assert Store.latest(store) == {:error, :not_ready}
    assert Store.latest_json(store) == {:error, :not_ready}
    assert %{ready: false, refreshing: false, next_refresh_at: next} = Store.status(store)
    assert is_binary(next)
  end

  test "a fresh persisted report is served without collecting", %{data_dir: data_dir} do
    write_report(data_dir, DateTime.utc_now())
    store = start_store(data_dir, [])

    refute_receive {:collecting, _}, 100
    assert {:ok, %{"root" => "/stub"}} = Store.latest(store)
    assert %{ready: true, refreshing: false} = Store.status(store)
  end

  test "a persisted report older than the interval is replaced at start", %{data_dir: data_dir} do
    write_report(data_dir, DateTime.add(DateTime.utc_now(), -2 * @day, :millisecond))
    store = start_store(data_dir, [{:ok, StubCollector.report()}])

    assert {:ok, %{"root" => "/stub"}} = Store.latest(store), "old report is served meanwhile"
    assert_receive {:collecting, _}
    assert_receive {:dashboard, :refreshed, %{ready: true}}
  end

  @tag capture_log: true
  test "a corrupt persisted report is ignored", %{data_dir: data_dir} do
    File.write!(Path.join(data_dir, "data.json"), "{not json")
    store = start_store(data_dir, [], collect_on_start: false)

    assert Store.latest(store) == {:error, :not_ready}
  end

  test "refresh on demand, and a refresh already running is reused", %{data_dir: data_dir} do
    test_pid = self()

    blocking = fn ->
      receive do
        :go -> {:ok, StubCollector.report()}
      end
    end

    store =
      start_store(data_dir, [],
        collect_on_start: false,
        collector_options: [reply: blocking, test_pid: test_pid]
      )

    assert Store.refresh(store) == :started
    assert_receive {:collecting, collector}
    assert %{refreshing: true} = Store.status(store)
    assert Store.refresh(store) == :already_running

    send(collector, :go)
    assert_receive {:dashboard, :refreshed, %{refreshing: false}}
    assert {:ok, _} = Store.latest(store)
  end

  @tag capture_log: true
  test "a failed collection keeps the previous report and records the error", %{
    data_dir: data_dir
  } do
    store =
      start_store(data_dir, [
        {:ok, StubCollector.report()},
        {:error, {:missing_file, "/x/projects.exs"}}
      ])

    assert_receive {:dashboard, :refreshed, _}
    assert :started = Store.refresh(store)

    assert_receive {:dashboard, :refresh_failed,
                    %{last_error: "registry file not found: /x/projects.exs"}}

    assert {:ok, _} = Store.latest(store)

    assert %{
             ready: true,
             refreshing: false,
             last_error: "registry file not found: /x/projects.exs"
           } = Store.status(store)
  end

  @tag capture_log: true
  test "a crashing collector is reported, not fatal", %{data_dir: data_dir} do
    crash = fn -> raise "boom" end
    store = start_store(data_dir, [], collector_options: [reply: crash, test_pid: self()])

    assert_receive {:dashboard, :refresh_failed, %{last_error: "collector crashed: " <> detail}}
    assert detail =~ "boom"
    assert Process.alive?(Process.whereis(store))
  end

  test "collects again when the interval elapses", %{data_dir: data_dir} do
    start_store(data_dir, [{:ok, StubCollector.report()}], refresh_interval: 60)

    assert_receive {:collecting, _}
    assert_receive {:dashboard, :refreshed, _}
    assert_receive {:collecting, _}, 1_000
    assert_receive {:dashboard, :refreshed, _}, 1_000
  end
end

defmodule Dashboard.StoreScheduleTest do
  use ExUnit.Case, async: true

  doctest Dashboard.Store

  test "the hourly window wraps to the next morning and never goes negative" do
    assert Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 20:30:00]) ==
             8 * 3_600_000 + 1_800_000

    assert Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 05:00:00]) == 3_600_000
    assert Dashboard.Store.next_delay({:hourly, 5..20}, ~N[2026-09-21 04:59:59]) == 1_000
    assert Dashboard.Store.next_delay({:hourly, 0..23}, ~N[2026-09-21 23:30:00]) == 1_800_000
  end
end
