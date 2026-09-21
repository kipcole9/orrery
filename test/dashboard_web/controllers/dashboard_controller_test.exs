defmodule DashboardWeb.DashboardControllerTest do
  use DashboardWeb.ConnCase, async: false

  alias Dashboard.Store

  # The application's store uses Dashboard.StubCollector in the test
  # environment and does not collect at start, so the first test to need a
  # report asks for one.
  defp ensure_report do
    :ok = Store.subscribe()

    case Store.latest_json() do
      {:ok, _} ->
        :ok

      {:error, :not_ready} ->
        Store.refresh()
        assert_receive {:dashboard, :refreshed, _}, 5_000
        :ok
    end
  end

  test "GET / renders the dashboard with the report inlined and a refresh button", %{conn: conn} do
    ensure_report()
    conn = get(conn, ~p"/")
    body = html_response(conn, 200)

    assert body =~ ~s(<h1 id="title">Project Dashboard</h1>)
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
             "refresh_interval_ms" => interval
           } =
             json_response(conn, 200)

    assert is_binary(generated)
    assert is_integer(interval)
  end

  test "POST /refresh starts a collection and answers 202", %{conn: conn} do
    ensure_report()
    conn = conn |> put_req_header("accept", "application/json") |> post(~p"/refresh")

    assert %{"result" => result, "status" => %{"ready" => true}} = json_response(conn, 202)
    assert result in ["started", "already_running"]
    assert_receive {:dashboard, :refreshed, _}, 5_000
  end

  test "the waiting page shows the last error and polls for readiness" do
    status = %{ready: false, refreshing: true, last_error: "GitHub rejected the token"}

    body =
      Phoenix.Template.render_to_string(DashboardWeb.DashboardHTML, "waiting", "html", %{
        status: status
      })

    assert body =~ "Collecting the first report"
    assert body =~ "GitHub rejected the token"
    assert body =~ ~s(fetch("/api/status")

    body =
      Phoenix.Template.render_to_string(DashboardWeb.DashboardHTML, "waiting", "html", %{
        status: %{status | last_error: nil}
      })

    refute body =~ "The last collection failed"
  end

  test "the static rendering has no refresh button and no CSRF token" do
    json = Dashboard.StubCollector.report() |> JSON.encode!() |> IO.iodata_to_binary()

    body =
      Phoenix.Template.render_to_string(DashboardWeb.DashboardHTML, "index", "html", %{
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
      Phoenix.Template.render_to_string(DashboardWeb.DashboardHTML, "index", "html", %{
        data: json,
        status: %{},
        mode: :static,
        csrf_token: nil
      })

    refute body =~ "</script><img"
    assert body =~ ~s(\\u003c/script\\u003e)
  end
end
