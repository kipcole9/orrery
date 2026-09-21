defmodule DashboardWeb.DashboardHTMLTest do
  use ExUnit.Case, async: true

  alias DashboardWeb.DashboardHTML

  doctest DashboardWeb.DashboardHTML

  test "script_safe/1 leaves ordinary JSON alone" do
    json = ~s({"name":"tempo","open":3,"note":"ü ✅"})
    assert DashboardHTML.script_safe(json) == json
  end

  test "script_safe/1 escapes the line separators JavaScript rejects in string literals" do
    assert DashboardHTML.script_safe(<<"\"a", 0x2028::utf8, "b\"">>) == ~s("a\\u2028b")
    assert DashboardHTML.script_safe(<<"\"a", 0x2029::utf8, "b\"">>) == ~s("a\\u2029b")
  end

  test "script_json/1 encodes and escapes in one step" do
    assert DashboardHTML.script_json(%{"k" => "<&>"}) == ~s({"k":"\\u003c\\u0026\\u003e"})
    assert JSON.decode!(DashboardHTML.script_json(%{"k" => "<&>"})) == %{"k" => "<&>"}
  end
end
