defmodule Orrery.CollectorTest do
  use ExUnit.Case, async: true

  doctest Orrery.Collector

  test "pretty_json/1 round-trips nil and nesting" do
    report = %{"a" => nil, "b" => [1, %{"c" => nil}], "d" => "x"}

    assert report |> Orrery.Collector.pretty_json() |> IO.iodata_to_binary() |> JSON.decode!() ==
             report
  end
end
