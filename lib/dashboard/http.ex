defmodule Dashboard.HTTP do
  @moduledoc """
  GET requests for JSON APIs over OTP's `:httpc`, with an ETag cache on disk.

  Shared by `Dashboard.GitHub` and `Dashboard.Hex`. Every successful response
  is stored beside its ETag; the next request for the same URL sends
  `If-None-Match`, and a `304 Not Modified` is answered from the cache, which
  costs nothing against either service's rate limit. The two clients keep
  their own status handling — what a 404 or a 429 means differs — and use the
  helpers here for the transport and the cache.
  """

  @user_agent "elixir-project-dashboard"

  @type cached :: %{etag: String.t() | nil, body: term()} | nil

  @doc """
  Prepares a cache directory and honours any proxy settings.

  ### Arguments

  * `cache_dir` is the directory cached responses are written to.

  ### Returns

  * `:ok`, or `{:error, reason}` when the directory cannot be created.

  """
  @spec prepare(Path.t()) :: :ok | {:error, term()}
  def prepare(cache_dir) do
    configure_proxy()
    File.mkdir_p(cache_dir)
  end

  # `:httpc` does not read the proxy environment variables the way curl does.
  # Machines behind a corporate proxy set these, so honour them.
  defp configure_proxy do
    proxy = System.get_env("HTTPS_PROXY") || System.get_env("https_proxy")

    with url when is_binary(url) <- proxy,
         %URI{host: host, port: port} when is_binary(host) <- URI.parse(url) do
      no_proxy =
        (System.get_env("NO_PROXY") || System.get_env("no_proxy") || "")
        |> String.split(",", trim: true)
        |> Enum.map(&(&1 |> String.trim() |> String.to_charlist()))

      :httpc.set_options(https_proxy: {{String.to_charlist(host), port || 443}, no_proxy})
    else
      _ -> :ok
    end
  end

  @doc """
  Locates the cache entry for a URL.

  ### Arguments

  * `cache_dir` is the cache directory.

  * `url` is the request URL.

  ### Returns

  * `{cache_file, cached}` where `cached` is the stored ETag and body, or
    `nil` when nothing is cached or the file is unreadable.

  """
  @spec cached(Path.t(), String.t()) :: {Path.t(), cached()}
  def cached(cache_dir, url) do
    file = Path.join(cache_dir, cache_key(url) <> ".json")
    {file, read_cache(file)}
  end

  @doc """
  Performs a GET, sending `If-None-Match` when a cached ETag exists.

  ### Arguments

  * `url` is the request URL.

  * `headers` are extra request headers as `{name, value}` binaries.

  * `cached` is the entry from `cached/2`.

  ### Returns

  * `{:ok, status, response_headers, body}` for any HTTP response, with the
    body as a binary.

  * `{:error, {:transport, reason}}` when the request could not be made, or
    `{:error, {:exception, message}}` if something raised.

  """
  @spec get(String.t(), [{String.t(), String.t()}], cached()) ::
          {:ok, non_neg_integer(), list(), binary()} | {:error, term()}
  def get(url, headers, cached) do
    # A caller that names its own accept header (GitHub's media type) keeps it.
    accept =
      if List.keymember?(headers, "accept", 0), do: [], else: [{"accept", "application/json"}]

    request_headers =
      [{"user-agent", @user_agent} | accept ++ headers]
      |> Enum.map(fn {name, value} -> header(name, value) end)
      |> maybe_etag(cached)

    case :httpc.request(:get, {String.to_charlist(url), request_headers}, http_opts(),
           body_format: :binary
         ) do
      {:ok, {{_, status, _}, response_headers, body}} -> {:ok, status, response_headers, body}
      {:error, reason} -> {:error, {:transport, reason}}
    end
  rescue
    exception -> {:error, {:exception, Exception.message(exception)}}
  end

  @doc """
  Stores a decoded body with the ETag from its response.

  ### Arguments

  * `cache_file` is the path from `cached/2`.

  * `response_headers` are the headers of the 200 response.

  * `body` is the decoded JSON term.

  ### Returns

  * `:ok`. A cache that cannot be written is silently skipped; it only costs
    rate limit.

  """
  @spec store(Path.t(), list(), term()) :: :ok
  def store(cache_file, response_headers, body) do
    _ =
      File.write(
        cache_file,
        JSON.encode!(%{"etag" => find_header(response_headers, "etag"), "body" => body})
      )

    :ok
  rescue
    _ -> :ok
  end

  @doc """
  Decodes a JSON body.

  ### Arguments

  * `body` is the response body.

  ### Returns

  * `{:ok, term}` or `{:error, :invalid_json}`.

  ### Examples

      iex> Dashboard.HTTP.decode_json(~s({"a": null}))
      {:ok, %{"a" => nil}}

      iex> Dashboard.HTTP.decode_json("<html>")
      {:error, :invalid_json}

  """
  @spec decode_json(binary()) :: {:ok, term()} | {:error, :invalid_json}
  def decode_json(body) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @doc """
  Finds a response header by name, case-insensitively.

  ### Arguments

  * `headers` are `:httpc` response headers.

  * `name` is the lower-case header name.

  ### Returns

  * The value as a binary, or `nil`.

  ### Examples

      iex> Dashboard.HTTP.find_header([{~c"ETag", ~c"abc"}, {~c"X-RateLimit-Remaining", ~c"59"}], "etag")
      "abc"

      iex> Dashboard.HTTP.find_header([], "etag")
      nil

  """
  @spec find_header(list(), String.t()) :: String.t() | nil
  def find_header(headers, name) do
    Enum.find_value(headers, fn {key, value} ->
      if to_string(key) |> String.downcase() == name, do: to_string(value)
    end)
  end

  # ------------------------------------------------------------------

  # `:httpc` wants charlists, and a single-quoted literal is deprecated syntax.
  defp header(name, value), do: {String.to_charlist(name), String.to_charlist(value)}

  defp maybe_etag(headers, %{etag: etag}) when is_binary(etag),
    do: [header("if-none-match", etag) | headers]

  defp maybe_etag(headers, _), do: headers

  defp http_opts do
    [timeout: 30_000, connect_timeout: 15_000, ssl: ssl_opts()]
  end

  defp ssl_opts do
    [
      verify: :verify_peer,
      cacerts: :public_key.cacerts_get(),
      depth: 3,
      customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
    ]
  end

  defp cache_key(url) do
    url
    |> String.replace(~r/^https?:\/\/[^\/]+/, "")
    |> String.replace(~r/[^A-Za-z0-9]+/, "_")
    |> String.trim("_")
    |> String.slice(0, 120)
  end

  defp read_cache(file) do
    with {:ok, raw} <- File.read(file),
         {:ok, %{"etag" => etag, "body" => body}} <- JSON.decode(raw) do
      %{etag: etag, body: body}
    else
      _ -> nil
    end
  end
end
