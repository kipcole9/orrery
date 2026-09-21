defmodule Dashboard.HexTest do
  use ExUnit.Case, async: true

  alias Dashboard.Hex

  doctest Dashboard.Hex

  test "a real hex payload reduces to the published state" do
    payload =
      Path.join([__DIR__, "..", "support", "fixtures", "hex_localize_person_names.json"])
      |> File.read!()
      |> JSON.decode!()

    summary = Hex.summarise(payload)

    assert summary.published
    assert summary.name == "localize_person_names"
    assert summary.latest == "1.0.0"
    assert summary.latest_at == "2026-07-31T04:09:35.904850Z"
    assert summary.releases == 2
    assert summary.retired == []
    assert summary.downloads == 611
    assert summary.url == "https://hex.pm/packages/localize_person_names"
  end

  test "a payload missing fields still reduces without raising" do
    assert %{
             published: true,
             name: "",
             latest: nil,
             latest_at: nil,
             releases: 0,
             retired: [],
             downloads: nil
           } =
             Hex.summarise(%{})

    assert %{retired: []} = Hex.summarise(%{"retirements" => "odd"})

    assert %{latest_at: nil} =
             Hex.summarise(%{"latest_version" => "1.0.0", "releases" => ["not a map"]})
  end

  test "a package name hex would reject is refused before any request" do
    assert Hex.fetch("Not A Package", System.tmp_dir!()) == {:error, :invalid_name}
    assert Hex.fetch("../etc", System.tmp_dir!()) == {:error, :invalid_name}
    assert Hex.fetch(nil, System.tmp_dir!()) == {:error, :invalid_name}
  end

  test "describe/1 covers every reason" do
    for reason <- [
          :rate_limited,
          :invalid_json,
          :invalid_name,
          {:http, 500},
          {:transport, :timeout},
          {:exception, "x"},
          :other
        ] do
      assert is_binary(Hex.describe(reason))
    end
  end
end
