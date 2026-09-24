defmodule OrreryWeb.OrreryControllerTest do
  use OrreryWeb.ConnCase, async: false

  alias Orrery.Store

  # The application's store uses Orrery.StubCollector in the test
  # environment and does not collect at start, so the first test to need a
  # report asks for one.
  defp ensure_report do
    :ok = Store.subscribe()

    case Store.latest_json() do
      {:ok, _} ->
        :ok

      {:error, :not_ready} ->
        Store.refresh()
        assert_receive {:orrery, :refreshed, _}, 5_000
        :ok
    end
  end

  test "GET / renders the dashboard with the report inlined and a refresh button", %{conn: conn} do
    ensure_report()
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ ~s(<h1 id="title">Orrery</h1>)
    assert body =~ ~s(id="refresh")
    assert body =~ ~s(name="csrf-token")
    assert body =~ ~s(const DATA = {)
    assert body =~ ~s("root":"/stub")
    assert body =~ ~s(const STATUS = {)
  end

  test "GET /data.json returns the report", %{conn: conn} do
    ensure_report()
    conn = get(conn, ~p"/data.json")

    assert %{"root" => "/stub", "totals" => %{"groups" => 1}} = json_response(conn, 200)
  end

  test "GET /api/status reports the store's state", %{conn: conn} do
    ensure_report()
    conn = get(conn, ~p"/api/status")

    assert %{
             "ready" => true,
             "refreshing" => false,
             "generated_at" => generated,
             "schedule" => schedule
           } =
             json_response(conn, 200)

    assert is_binary(generated)
    assert schedule =~ "hourly"
  end

  test "POST /refresh starts a collection and answers 202", %{conn: conn} do
    ensure_report()
    conn = conn |> put_req_header("accept", "application/json") |> post(~p"/refresh")

    assert %{"result" => result, "status" => %{"ready" => true}} = json_response(conn, 202)
    assert result in ["started", "already_running"]
    assert_receive {:orrery, :refreshed, _}, 5_000
  end

  test "the waiting page shows the last error and polls for readiness" do
    status = %{ready: false, refreshing: true, last_error: "GitHub rejected the token"}

    body =
      Phoenix.Template.render_to_string(OrreryWeb.OrreryHTML, "waiting", "html", %{
        status: status
      })

    assert body =~ "Collecting the first report"
    assert body =~ "GitHub rejected the token"
    assert body =~ ~s(fetch("/api/status")

    body =
      Phoenix.Template.render_to_string(OrreryWeb.OrreryHTML, "waiting", "html", %{
        status: %{status | last_error: nil}
      })

    refute body =~ "The last collection failed"
  end

  test "the static rendering has no refresh button and no CSRF token" do
    json = Orrery.StubCollector.report() |> JSON.encode!() |> IO.iodata_to_binary()

    body =
      Phoenix.Template.render_to_string(OrreryWeb.OrreryHTML, "index", "html", %{
        data: json,
        status: %{ready: true, refreshing: false, next_refresh_at: nil, last_error: nil},
        mode: :static,
        csrf_token: nil
      })

    refute body =~ ~s(id="refresh")
    refute body =~ ~s(<meta name="csrf-token")
    assert body =~ ~s("root":"/stub")
  end

  test "report data is escaped so it cannot close the script element" do
    json = ~s|{"title":"</script><img src=x onerror=alert(1)>"}|

    body =
      Phoenix.Template.render_to_string(OrreryWeb.OrreryHTML, "index", "html", %{
        data: json,
        status: %{},
        mode: :static,
        csrf_token: nil
      })

    refute body =~ "</script><img"
    assert body =~ ~s(\\u003c/script\\u003e)
  end
end

defmodule OrreryWeb.OrreryControllerRepoRefreshTest do
  use OrreryWeb.ConnCase, async: false

  alias Orrery.Store

  test "POST /refresh with a repo collects that repository only", %{conn: conn} do
    :ok = Store.subscribe()
    if match?({:error, _}, Store.latest_json()), do: Store.refresh()

    if match?({:error, _}, Store.latest_json()),
      do: assert_receive({:orrery, :refreshed, _}, 5_000)

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post(~p"/refresh", JSON.encode!(%{repo: "stub/one"}))

    assert %{"result" => result, "repo" => "stub/one"} = json_response(conn, 202)
    assert result in ["started", "already_running"]
    assert_receive {:orrery, :refreshed, _}, 5_000
    assert {:ok, %{"groups" => [%{"repos" => repos}]}} = Store.latest()
    assert Enum.any?(repos, &(&1["path"] == "stub/one"))
  end

  test "an absurd repo value is refused before reaching the store", %{conn: conn} do
    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> post(~p"/refresh", %{"repo" => String.duplicate("x", 500)})

    # Falls through to the plain refresh clause: no repo echoed back.
    assert %{"result" => _} = body = json_response(conn, 202)
    refute Map.has_key?(body, "repo")
  end
end
