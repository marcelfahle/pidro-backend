defmodule PidroServer.Profiles.PostGameSummary do
  @moduledoc """
  Pure builder for the per-player post-game "what changed" summary (PID-52).

  Given a player's BEFORE snapshot and the game's computed deltas, returns one
  snake_case, Jason-safe summary map. No DB access — it composes the existing
  pure layers (`Progression`, `Rating.Tier`, `Rating`, `Achievements.Catalog`)
  so it is trivially unit-testable and ephemeral (built at completion, pushed,
  discarded).

  ## Shape

  Always present (the guaranteed fallback — every game, win or lose, rated or
  casual):

    * `rated` — boolean
    * `xp_earned` — non_neg_integer (this game's XP award)
    * `veteran_xp` — non_neg_integer (after value)
    * `veteran_level_before` / `veteran_level` — pos_integer
    * `leveled_up` — boolean
    * `veteran_title_before` / `veteran_title` — string
    * `title_changed` — boolean
    * `veteran_progress` — `%{into, span, max}` (normalized; never a raw tuple)
    * `achievements_unlocked` — `[%{key, name, tier}]` (empty when none)

  Rated only (`nil` when casual — casual leads with Veteran/Mastery, never a
  loud skill number):

    * `rating` — `%{tier_before, tier_after, provisional_before,
      provisional_after, direction}` or `nil`

  ## Examples

      iex> before = %{veteran_xp: 0, rating_mu: 25.0, rating_sigma: 8.333, rating_games_count: 0}
      iex> deltas = %{xp_earned: 0, veteran_xp_after: 0, rated?: false,
      ...>   rating_after: nil, rating_count_after: nil, newly_earned_keys: []}
      iex> summary = PidroServer.Profiles.PostGameSummary.build(before, deltas, [])
      iex> {summary.xp_earned, summary.veteran_level, summary.rating}
      {0, 1, nil}

  """

  alias PidroServer.Achievements.Catalog
  alias PidroServer.Progression
  alias PidroServer.Rating
  alias PidroServer.Rating.Tier

  @typedoc "The BEFORE snapshot of a participant's profile columns."
  @type before_snapshot :: %{
          veteran_xp: non_neg_integer(),
          rating_mu: float(),
          rating_sigma: float(),
          rating_games_count: non_neg_integer()
        }

  @typedoc "The per-game computed deltas for one participant."
  @type deltas :: %{
          xp_earned: non_neg_integer(),
          veteran_xp_after: non_neg_integer(),
          rated?: boolean(),
          rating_after: Rating.rating() | nil,
          rating_count_after: non_neg_integer() | nil,
          newly_earned_keys: [atom()]
        }

  @doc """
  Builds the per-player summary map from a BEFORE snapshot + per-game deltas.

  `opts` is a forward seam only (`[]` in v1).
  """
  @spec build(before_snapshot(), deltas(), keyword()) :: map()
  def build(before, deltas, _opts \\ []) do
    xp_before = before.veteran_xp
    xp_after = deltas.veteran_xp_after

    level_before = Progression.level_for_xp(xp_before)
    level_after = Progression.level_for_xp(xp_after)

    title_before = Progression.title_for_level(level_before)
    title_after = Progression.title_for_level(level_after)

    %{
      rated: deltas.rated?,
      xp_earned: deltas.xp_earned,
      veteran_xp: xp_after,
      veteran_level_before: level_before,
      veteran_level: level_after,
      leveled_up: level_after > level_before,
      veteran_title_before: title_before,
      veteran_title: title_after,
      title_changed: title_after != title_before,
      veteran_progress: normalize_progress(Progression.level_progress(xp_after)),
      achievements_unlocked: achievements(deltas.newly_earned_keys),
      rating: rating_block(before, deltas)
    }
  end

  # `level_progress/1` returns `{into, span}` or `:max`; emit a Jason-friendly
  # map (tuples are not JSON-encodable).
  defp normalize_progress(:max), do: %{into: 0, span: 0, max: true}
  defp normalize_progress({into, span}), do: %{into: into, span: span, max: false}

  # Map newly-earned keys to display entries via the Catalog. Unknown keys are
  # dropped (same defensive pattern as Profiles.screen_achievements/1).
  defp achievements(keys) when is_list(keys) do
    Enum.flat_map(keys, fn key ->
      case Enum.find(Catalog.all(), &(&1.key == key)) do
        nil -> []
        def -> [%{key: Atom.to_string(def.key), name: def.name, tier: def.tier}]
      end
    end)
  end

  defp achievements(_keys), do: []

  # Casual games never wrote rating columns and must omit the skill number.
  defp rating_block(_before, %{rated?: false}), do: nil

  defp rating_block(before, %{rated?: true} = deltas) do
    {mu_before, sigma_before} = {before.rating_mu, before.rating_sigma}
    count_before = before.rating_games_count

    {mu_after, sigma_after} = deltas.rating_after
    count_after = deltas.rating_count_after

    %{tier: tier_before, provisional: provisional_before} =
      Tier.classify(mu_before, sigma_before, count_before)

    %{tier: tier_after, provisional: provisional_after} =
      Tier.classify(mu_after, sigma_after, count_after)

    %{
      tier_before: tier_before,
      tier_after: tier_after,
      provisional_before: provisional_before,
      provisional_after: provisional_after,
      direction: direction(mu_before, sigma_before, mu_after, sigma_after)
    }
  end

  # Direction from the ordinal delta (mu - 3*sigma), so the band input and the
  # direction agree.
  defp direction(mu_before, sigma_before, mu_after, sigma_after) do
    delta = Rating.ordinal({mu_after, sigma_after}) - Rating.ordinal({mu_before, sigma_before})

    cond do
      delta > 0 -> "up"
      delta < 0 -> "down"
      true -> "none"
    end
  end
end
