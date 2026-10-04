defmodule PidroServer.Accounts.GuestNamesTest do
  use PidroServer.DataCase, async: false

  alias PidroServer.Accounts.{ClassicNameReservations, GuestNames, User}
  alias PidroServer.AccountsFixtures

  test "the curated word lists produce valid two-word display names" do
    {adjectives, nouns} = GuestNames.word_lists()

    assert length(adjectives) == 150
    assert length(nouns) == 150

    for adjective <- adjectives, noun <- nouns do
      name = adjective <> " " <> noun
      changeset = User.guest_changeset(%User{}, %{username: "guest_valid", display_name: name})

      assert changeset.valid?, "invalid generated name: #{inspect(name)}"
    end

    assert {:ok, name} = GuestNames.generate()
    assert length(String.split(name)) in [2, 3]
  end

  test "skips reserved Classic names and live public-name look-alikes" do
    assert {:ok, _} = ClassicNameReservations.import([%{id: 101, username: "Lucky Moose"}])
    AccountsFixtures.user_fixture(%{display_name: "Lúcky-Fox"})

    draw_pair = scripted_pairs([{"Lucky", "Moose"}, {"Lucky", "Fox"}, {"Sunny", "Pike"}])

    assert {:ok, "Sunny Pike"} = GuestNames.generate(draw_pair)
  end

  test "only a player's current public name is occupied" do
    AccountsFixtures.user_fixture(%{username: "Lucky Pike", display_name: "Visible Name"})

    assert {:ok, "Lucky Pike"} = GuestNames.generate(fn -> {"Lucky", "Pike"} end)
  end

  test "a username is occupied when the player has no display name" do
    AccountsFixtures.user_fixture(%{username: "Lucky Pike"})

    draw_pair = scripted_pairs([{"Lucky", "Pike"}, {"Sunny", "Pike"}])
    assert {:ok, "Sunny Pike"} = GuestNames.generate(draw_pair)
  end

  test "adds a number and skips occupied or reserved numbered names" do
    AccountsFixtures.user_fixture(%{display_name: "Lucky Moose"})
    AccountsFixtures.user_fixture(%{display_name: "Lucky Moose 2"})
    assert {:ok, _} = ClassicNameReservations.import([%{id: 102, username: "Lucky Moose 3"}])

    assert {:ok, "Lucky Moose 4"} = GuestNames.generate(fn -> {"Lucky", "Moose"} end)
  end

  test "draws new word pairs once every numbered name is taken" do
    reservations =
      ["Lucky Moose" | Enum.map(2..9, &"Lucky Moose #{&1}")]
      |> Enum.with_index(200)
      |> Enum.map(fn {username, id} -> %{id: id, username: username} end)

    assert {:ok, _} = ClassicNameReservations.import(reservations)

    pairs = List.duplicate({"Lucky", "Moose"}, 5) ++ [{"Sunny", "Pike"}]
    assert {:ok, "Sunny Pike"} = GuestNames.generate(scripted_pairs(pairs))
  end

  defp scripted_pairs(pairs) do
    {:ok, agent} = Agent.start_link(fn -> pairs end)

    fn ->
      Agent.get_and_update(agent, fn
        [pair] -> {pair, [pair]}
        [pair | rest] -> {pair, rest}
      end)
    end
  end
end
