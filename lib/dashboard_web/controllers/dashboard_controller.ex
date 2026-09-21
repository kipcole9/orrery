defmodule DashboardWeb.DashboardController do
  @moduledoc """
  Serves the dashboard page and the small JSON API behind its refresh button.

  * `GET /` renders the page with the latest report inlined, or a waiting
    page that reloads itself once the first collection has finished.

  * `POST /refresh` starts a collection now and returns `202 Accepted`.

  * `GET /api/status` reports whether a collection is running, when the
    report was generated and when the next one is due.

  * `GET /data.json` returns the latest report.
  """

  use DashboardWeb, :controller

  alias Dashboard.Store

  @doc "Renders the dashboard, or a waiting page before the first report exists."
  def index(conn, _params) do
    status = Store.status()

    conn = put_root_layout(conn, false)

    case Store.latest_json() do
      {:ok, json} ->
        render(conn, :index,
          data: json,
          status: status,
          mode: :server,
          csrf_token: get_csrf_token()
        )

      {:error, :not_ready} ->
        render(conn, :waiting, status: status)
    end
  end

  @doc "Starts a collection and answers `202 Accepted` with the current status."
  def refresh(conn, _params) do
    result = Store.refresh()
    send_json(conn, 202, %{result: result, status: Store.status()})
  end

  @doc "Returns the store's status."
  def status(conn, _params) do
    send_json(conn, 200, Store.status())
  end

  @doc "Returns the latest report as JSON, or `503` before the first collection."
  def data(conn, _params) do
    case Store.latest_json() do
      {:ok, json} ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, json)

      {:error, :not_ready} ->
        send_json(conn, 503, %{error: "no report has been collected yet", status: Store.status()})
    end
  end

  defp send_json(conn, status, term) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, JSON.encode!(term))
  end
end
