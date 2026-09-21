defmodule Dashboard.Hex do
  @moduledoc """
  Asks hex.pm what is published for a package.

  Release state is derived from git tags first, because that is accurate for
  work that has not been published yet. Hex is the second opinion: a clone
  that has not been fetched since a release still has old tags and an old
  `mix.exs`, and without this check the dashboard would report a published
  library as never released. Responses are cached with their ETag through
  `Dashboard.HTTP`; hex allows 100 requests a minute unauthenticated, which
  the cache keeps well clear of.
  """

  @api "https://hex.pm/api/packages/"
  @name ~r/^[a-z][a-z0-9_]*$/

  @type t :: %{
          published: boolean(),
          name: String.t(),
          latest: String.t() | nil,
          latest_at: String.t() | nil,
          releases: non_neg_integer(),
          retired: [String.t()],
          downloads: non_neg_integer() | nil,
          url: String.t() | nil
        }

  @doc """
  Fetches the published state of a package.

  ### Arguments

  * `package` is the hex package name, normally the `:app` from `mix.exs`.

  * `cache_dir` is where ETag-cached responses are kept.

  ### Returns

  * `{:ok, summary}` with `published: false` when hex has no such package.

  * `{:error, reason}` when hex could not be asked and nothing is cached;
    `describe/1` turns the reason into a message.

  """
  @spec fetch(String.t(), Path.t()) :: {:ok, t()} | {:error, term()}
  def fetch(package, cache_dir) when is_binary(package) do
    if Regex.match?(@name, package) do
      url = @api <> package
      {cache_file, cached} = Dashboard.HTTP.cached(cache_dir, url)

      case Dashboard.HTTP.get(url, [], cached) do
        {:ok, 200, headers, body} ->
          case Dashboard.HTTP.decode_json(body) do
            {:ok, decoded} ->
              Dashboard.HTTP.store(cache_file, headers, decoded)
              {:ok, summarise(decoded)}

            {:error, :invalid_json} ->
              from_cache(cached, {:error, :invalid_json})
          end

        {:ok, 304, _headers, _body} ->
          from_cache(cached, {:error, {:http, 304}})

        {:ok, 404, _headers, _body} ->
          {:ok, unpublished(package)}

        {:ok, 429, _headers, _body} ->
          from_cache(cached, {:error, :rate_limited})

        {:ok, status, _headers, _body} ->
          from_cache(cached, {:error, {:http, status}})

        {:error, reason} ->
          from_cache(cached, {:error, reason})
      end
    else
      {:error, :invalid_name}
    end
  end

  def fetch(_package, _cache_dir), do: {:error, :invalid_name}

  defp from_cache(%{body: body}, _fallback) when is_map(body), do: {:ok, summarise(body)}
  defp from_cache(_cached, fallback), do: fallback

  @doc """
  Reduces a hex package payload to the fields the dashboard uses.

  ### Arguments

  * `payload` is the decoded JSON from `GET /api/packages/:name`.

  ### Returns

  * A `t:t/0` map with `published: true`.

  ### Examples

      iex> Dashboard.Hex.summarise(%{
      ...>   "name" => "tempo",
      ...>   "latest_stable_version" => "1.6.4",
      ...>   "latest_version" => "1.7.0-rc.1",
      ...>   "html_url" => "https://hex.pm/packages/tempo",
      ...>   "releases" => [%{"version" => "1.7.0-rc.1", "inserted_at" => "2026-09-01T00:00:00Z"}, %{"version" => "1.6.4", "inserted_at" => "2026-08-16T10:00:00Z"}],
      ...>   "retirements" => %{"1.6.3" => %{"reason" => "security"}},
      ...>   "downloads" => %{"all" => 12}
      ...> })
      %{published: true, name: "tempo", latest: "1.6.4", latest_at: "2026-08-16T10:00:00Z", releases: 2, retired: ["1.6.3"], downloads: 12, url: "https://hex.pm/packages/tempo"}

  """
  @spec summarise(map()) :: t()
  def summarise(payload) when is_map(payload) do
    releases = List.wrap(payload["releases"])
    latest = payload["latest_stable_version"] || payload["latest_version"]

    latest_at =
      Enum.find_value(releases, fn release ->
        if is_map(release) and release["version"] == latest, do: release["inserted_at"]
      end)

    %{
      published: true,
      name: to_string(payload["name"]),
      latest: latest,
      latest_at: latest_at,
      releases: length(releases),
      retired: payload["retirements"] |> map_keys() |> Enum.sort(),
      downloads: get_in(payload, ["downloads", "all"]),
      url: payload["html_url"]
    }
  end

  defp map_keys(%{} = map), do: Map.keys(map)
  defp map_keys(_), do: []

  defp unpublished(package) do
    %{
      published: false,
      name: package,
      latest: nil,
      latest_at: nil,
      releases: 0,
      retired: [],
      downloads: nil,
      url: nil
    }
  end

  @doc """
  Describes a fetch error in one line.

  ### Arguments

  * `reason` is the second element of an `{:error, reason}` from `fetch/2`.

  ### Returns

  * A string.

  ### Examples

      iex> Dashboard.Hex.describe(:rate_limited)
      "hex rate limit reached"

  """
  @spec describe(term()) :: String.t()
  def describe(:rate_limited), do: "hex rate limit reached"
  def describe(:invalid_json), do: "hex returned a response that is not JSON"
  def describe(:invalid_name), do: "not a valid hex package name"
  def describe({:http, status}), do: "hex returned HTTP #{status}"
  def describe({:transport, reason}), do: "network error: #{inspect(reason)}"
  def describe({:exception, message}), do: "error: #{message}"
  def describe(other), do: inspect(other)
end
