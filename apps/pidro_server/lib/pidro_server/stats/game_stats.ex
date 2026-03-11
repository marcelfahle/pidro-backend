defmodule PidroServer.Stats.GameStats do
  @moduledoc """
  Schema for storing game statistics and history.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "game_stats" do
    field :room_code, :string
    field :winner, :string
    field :final_scores, :map
    field :bid_amount, :integer
    field :bid_team, :string
    field :duration_seconds, :integer
    field :completed_at, :utc_datetime
    field :player_ids, {:array, :binary_id}
    field :player_results, :map

    timestamps()
  end

  @doc false
  def changeset(game_stats, attrs) do
    attrs = normalize_enum_fields(attrs)

    game_stats
    |> cast(attrs, [
      :room_code,
      :winner,
      :final_scores,
      :bid_amount,
      :bid_team,
      :duration_seconds,
      :completed_at,
      :player_ids,
      :player_results
    ])
    |> validate_required([:room_code, :completed_at])
    |> validate_inclusion(:winner, ["north_south", "east_west"],
      message: "must be north_south or east_west"
    )
    |> validate_inclusion(:bid_team, ["north_south", "east_west"])
    |> validate_number(:bid_amount, greater_than_or_equal_to: 6, less_than_or_equal_to: 14)
    |> validate_number(:duration_seconds, greater_than: 0)
  end

  defp normalize_enum_fields(attrs) when is_map(attrs) do
    attrs
    |> normalize_enum_field(:winner)
    |> normalize_enum_field(:bid_team)
  end

  defp normalize_enum_fields(attrs), do: attrs

  defp normalize_enum_field(attrs, key) do
    case Map.get(attrs, key) do
      value when is_atom(value) and not is_nil(value) ->
        Map.put(attrs, key, Atom.to_string(value))

      _ ->
        attrs
    end
  end
end
