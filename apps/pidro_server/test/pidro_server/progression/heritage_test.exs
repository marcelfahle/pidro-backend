defmodule PidroServer.Progression.HeritageTest do
  use ExUnit.Case, async: true

  alias PidroServer.Progression.Heritage

  doctest PidroServer.Progression.Heritage

  test "empty map -> []" do
    assert Heritage.display(%{}) == []
  end

  test "nil -> []" do
    assert Heritage.display(nil) == []
  end

  test "string-keyed boolean flag -> one badge" do
    assert Heritage.display(%{"played_pidro_one" => true}) == [
             %{key: :played_pidro_one, label: "Played Pidro 1", value: true}
           ]
  end

  test "atom-keyed multiple flags in stable vocabulary order" do
    badges = Heritage.display(%{founding_member: true, played_pidro_one: true})

    assert Enum.map(badges, & &1.key) == [:played_pidro_one, :founding_member]
  end

  test "falsy flag is skipped" do
    assert Heritage.display(%{played_pidro_one: false}) == []
  end

  test "legacy_level value badge carries the integer" do
    assert Heritage.display(%{"legacy_level" => 73}) == [
             %{key: :legacy_level, label: "Legacy Level", value: 73}
           ]
  end

  test "legacy_accolades value badge carries the list" do
    assert Heritage.display(%{"legacy_accolades" => ["Champion", "Founder"]}) == [
             %{key: :legacy_accolades, label: "Legacy Accolades", value: ["Champion", "Founder"]}
           ]
  end

  test "legacy_premium truthy -> premium badge (PID-53)" do
    assert Heritage.display(%{"legacy_premium" => true}) == [
             %{key: :legacy_premium, label: "Pidro 1 Premium", value: true}
           ]
  end

  test "legacy_premium false / absent -> no premium badge (PID-53)" do
    assert Heritage.display(%{"legacy_premium" => false}) == []
    assert Heritage.display(%{}) == []
  end

  test "full mixed map keeps vocabulary order" do
    flags = %{
      "legacy_accolades" => ["Champion"],
      "played_pidro_one" => true,
      "legacy_level" => 73,
      "founding_member" => true
    }

    assert Enum.map(Heritage.display(flags), & &1.key) ==
             [:played_pidro_one, :founding_member, :legacy_level, :legacy_accolades]
  end
end
