defmodule PidroServer.Accounts.GuestNames do
  @moduledoc """
  Generates friendly two-word public names for guests.

  Names are best-effort unique among current public names and never use a
  reserved Classic name. The database deliberately has no uniqueness rule for
  display names, so concurrent guest creation may still choose the same name.
  """

  import Ecto.Query

  alias PidroServer.Accounts.{ClassicNameReservations, User}
  alias PidroServer.Repo

  @random_attempts 5

  @adjectives ~w(
    Agile Airy Alert Alpine Amber Arctic Awake Azure Balmy Beaming Breezy Bright
    Brisk Bubbly Calm Careful Cheery Cherry Clever Cloudy Cozy Crisp Dapper
    Daring Dawn Dear Deep Dewy Eager Early Sunlit Fair Fancy Festive Fiery Fine
    Fleet Floral Fluffy Flying Fond
    Forest Fresh Friendly Frosty Funny Gentle Glad Gleaming Golden Good Grand
    Green Happy Hardy Hazel Hearty Helpful Heroic Honest Honey Hopeful
    Icy Jolly Joyful Keen Kind Lively Lucky Lunar Merry Mighty Misty Mellow Neat
    Nimble Noble Nordic Peachy Kindly Pine Pink Plucky Polite Proud Quick Quiet
    Radiant Ready Red Rosy Royal Shiny Silky Silver Sincere Smart Snappy Snowy
    Soft Solar Speedy Spry Starry Steady Sunny Swift Teal Tender Tidy Tiny Toasty
    True Velvet Vivid Warm Wavy White Wild Wise Witty Wooden Zesty Blue Bold
    Chipper Cool Coral Cosmic Curly Dreamy Emerald Fuzzy Glowing Grassy Lilac
    Lofty Maple Mild Minty Playful Purple Rustic Sandy Serene Smooth Snug Sparkly
    Sweet Twinkly
  )

  @nouns ~w(
    Acorn Alder Apple Aspen Aurora Badger Bay Bean Bear Berry Birch Bison Bloom
    Bluejay Boat Bobcat Brook Bunny Cabin Candle Canoe Cedar Chanter Cloud Clover
    Coast Comet Crane Creek Crown Daisy Dawn Deer
    Dove Eagle Elm Falcon Fern Finch Fir Fjord Flame Flower Fox Frost Gull Hare
    Hazel Hearth Heron Hill Honey Ice Jay Juniper Kite Lake Lark Leaf Light
    Lilac Lily Lynx Maple Meadow Minnow Moon Moose Moss Moth Mountain Mouse
    Otter Owl Paddle Pearl Pebble Perch Petal Pike Pine Pipit Plum Pond Puffin
    Rabbit Rainbow Raven Reed Ridge Robin Rose Rowan Salmon Sauna Seal Shell
    Shore Siskin Sky Snow Sparrow Spruce Star Stone Stream Sun Swan Table Teal
    Tern Thrush Trout Tulip Valley Wave Willow Wind Wing Wolf Wren Yarrow
    Bluebell Bonfire Breeze Brooklet Caribou Cloudlet Daylight Dewdrop Drift
    Feather Firefly Foxglove Glow Island Lantern Lingon Mittens Oar Pinecone
    Raindrop Ripple Sail Snowdrop Snowfall Songbird Sunbeam Treetop Woodwind
  )

  @doc "Returns a friendly available guest name."
  @spec generate() :: {:ok, String.t()}
  def generate do
    generate(fn -> {Enum.random(@adjectives), Enum.random(@nouns)} end)
  end

  @doc false
  def generate(draw_pair) when is_function(draw_pair, 0) do
    pairs =
      Stream.repeatedly(draw_pair)
      |> Stream.reject(fn {adjective, noun} -> adjective == noun end)
      |> Enum.take(@random_attempts)

    names = Enum.map(pairs, fn {adjective, noun} -> adjective <> " " <> noun end)
    last_name = List.last(names)
    candidates = names ++ Enum.map(2..9, &"#{last_name} #{&1}")
    taken = taken_name_keys(pairs)

    case Enum.find(candidates, &available?(&1, taken)) do
      nil -> {:ok, "#{last_name} #{Enum.random(10..99)}"}
      name -> {:ok, name}
    end
  end

  @doc false
  def word_lists, do: {@adjectives, @nouns}

  defp available?(name, taken) do
    not MapSet.member?(taken, User.name_key(name)) and
      not ClassicNameReservations.reserved?(name)
  end

  # Only players whose public name contains a candidate noun can collide, so
  # the database narrows the rows before `User.name_key/1` compares them.
  defp taken_name_keys(pairs) do
    matches_a_noun =
      pairs
      |> Enum.map(fn {_adjective, noun} -> "%" <> noun <> "%" end)
      |> Enum.uniq()
      |> Enum.reduce(dynamic(false), fn pattern, matches ->
        dynamic([user], ^matches or ilike(coalesce(user.display_name, user.username), ^pattern))
      end)

    User
    |> where(^matches_a_noun)
    |> select([user], {user.username, user.display_name})
    |> Repo.all()
    |> MapSet.new(fn {username, display_name} -> User.name_key(display_name || username) end)
  end
end
