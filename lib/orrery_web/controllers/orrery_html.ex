defmodule OrreryWeb.OrreryHTML do
  @moduledoc """
  Templates for the dashboard page.

  The page is self-contained: its styles and script are inline and the report
  is embedded as a JSON literal, so the same template also produces the
  static `orrery.html` written by `mix orrery.collect`.
  """

  use OrreryWeb, :html

  embed_templates "orrery_html/*"

  @doc """
  Escapes encoded JSON so it can be embedded directly inside a `<script>`
  element.

  The characters that could close the element or be mis-read by the HTML
  parser are replaced with JSON escape sequences, which JavaScript reads
  back unchanged.

  ### Arguments

  * `json` is a JSON document as a binary.

  ### Returns

  * The escaped binary.

  ### Examples

      iex> OrreryWeb.OrreryHTML.script_safe(~s({"a":"</script><b>&"}))
      ~s({"a":"\\\\u003c/script\\\\u003e\\\\u003cb\\\\u003e\\\\u0026"})

  """
  @spec script_safe(binary()) :: binary()
  def script_safe(json) when is_binary(json) do
    json
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
    |> String.replace("&", "\\u0026")
    |> String.replace(<<0x2028::utf8>>, "\\u2028")
    |> String.replace(<<0x2029::utf8>>, "\\u2029")
  end

  @doc """
  Encodes a term as JSON that is safe to embed inside a `<script>` element.

  ### Arguments

  * `term` is any term `JSON.encode!/1` accepts.

  ### Returns

  * The escaped JSON binary.

  ### Examples

      iex> OrreryWeb.OrreryHTML.script_json(%{note: "<x>"})
      ~s({"note":"\\\\u003cx\\\\u003e"})

  """
  @spec script_json(term()) :: binary()
  def script_json(term) do
    term |> JSON.encode!() |> script_safe()
  end
end
