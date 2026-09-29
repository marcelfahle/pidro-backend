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
    Daring Dawn Dear Deep Dewy Eager Early Easy Fair Fancy Festive Fiery Fine
    Fleet Floral Fluffy Flying Fond
    Forest Fresh Friendly Frosty Funny Gentle Glad Gleaming Golden Good Grand
    Green Happy Hardy Hazel Hearty Helpful Heroic Honest Honey Hopeful
    Icy Jolly Joyful Keen Kind Lively Lucky Lunar Merry Mighty Misty Mellow Neat
    Nimble Noble Nordic Peachy Perky Pine Pink Plucky Polite Proud Quick Quiet
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
    live_name_keys = live_name_keys()
    generate_random(draw_pair, live_name_keys, @random_attempts, nil)
  end

  @doc false
  def word_lists, do: {@adjectives, @nouns}

  defp generate_random(draw_pair, live_name_keys, attempts_left, _last_name)
       when attempts_left > 0 do
    {adjective, noun} = draw_pair.()
    name = adjective <> " " <> noun

    if available?(name, live_name_keys) do
      {:ok, name}
    else
      generate_random(draw_pair, live_name_keys, attempts_left - 1, name)
    end
  end

  defp generate_random(draw_pair, live_name_keys, 0, last_name) do
    case Enum.find(2..9, &available?("#{last_name} #{&1}", live_name_keys)) do
      nil -> generate_random(draw_pair, live_name_keys, @random_attempts, nil)
      suffix -> {:ok, "#{last_name} #{suffix}"}
    end
  end

  defp available?(name, live_name_keys) do
    not MapSet.member?(live_name_keys, User.name_key(name)) and
      not ClassicNameReservations.reserved?(name)
  end

  defp live_name_keys do
    User
    |> select([user], {user.username, user.display_name})
    |> Repo.all()
    |> MapSet.new(fn {username, display_name} -> User.name_key(display_name || username) end)
  end
end
