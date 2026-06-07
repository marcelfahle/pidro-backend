defmodule PidroServer.Rating.Tier do
  @moduledoc """
  Pure mapping from a rating to a skill tier + provisional flag.

  Bands (ascending): Bronze → Silver → Gold → Platinum → Master, gated by a
  Provisional state. Bands are read off `Rating.ordinal/1` (mu - 3*sigma), NOT
  raw mu, so uncertainty is already priced in.

  A player is PROVISIONAL while they have too few rated games OR their sigma is
  still too high; the band is suppressed and `tier: :provisional` is returned.
  Provisional clears only once BOTH conditions are satisfied
  (games_count >= min_games AND sigma < max_sigma).

  Thresholds are config-tunable (see `config :pidro_server, PidroServer.Rating.Tier`);
  launch defaults are placeholders, not finely calibrated.

  ## Examples

      iex> PidroServer.Rating.Tier.classify(25.0, 8.333, 0)
      %{tier: :provisional, provisional: true}

      iex> PidroServer.Rating.Tier.classify(40.0, 5.0, 50)
      %{tier: :gold, provisional: false}

  """

  alias PidroServer.Rating

  @typedoc "A skill tier (or the provisional gate)."
  @type tier ::
          :provisional | :bronze | :silver | :gold | :platinum | :master

  @typedoc "Result of classifying a rating."
  @type result :: %{tier: tier(), provisional: boolean()}

  @defaults %{
    provisional_min_games: 10,
    provisional_max_sigma: 6.0,
    bronze_min: 0.0,
    silver_min: 10.0,
    gold_min: 18.0,
    platinum_min: 26.0,
    master_min: 34.0
  }

  @doc """
  Classify from raw `mu`, `sigma`, and rated `games_count`.

  Returns `%{tier:, provisional:}`. The band is derived from
  `Rating.ordinal/1` (`mu - 3*sigma`); it is suppressed (`tier: :provisional`)
  while `games_count < provisional_min_games` OR `sigma >= provisional_max_sigma`.

  ## Examples

      iex> PidroServer.Rating.Tier.classify(40.0, 5.0, 50)
      %{tier: :gold, provisional: false}

      iex> PidroServer.Rating.Tier.classify(15.0, 5.0, 50)
      %{tier: :bronze, provisional: false}

      iex> PidroServer.Rating.Tier.classify(40.0, 3.0, 9)
      %{tier: :provisional, provisional: true}

  """
  @spec classify(float(), float(), non_neg_integer()) :: result()
  def classify(mu, sigma, games_count)
      when is_number(mu) and is_number(sigma) and is_integer(games_count) do
    if provisional?(sigma, games_count) do
      %{tier: :provisional, provisional: true}
    else
      %{tier: band_for(Rating.ordinal({mu, sigma})), provisional: false}
    end
  end

  @doc """
  Convenience overload reading a profile-shaped map with
  `:rating_mu`, `:rating_sigma`, `:rating_games_count` keys (PID-54 call site).

  ## Examples

      iex> PidroServer.Rating.Tier.classify(%{
      ...>   rating_mu: 40.0,
      ...>   rating_sigma: 5.0,
      ...>   rating_games_count: 50
      ...> })
      %{tier: :gold, provisional: false}

  """
  @spec classify(%{
          required(:rating_mu) => float(),
          required(:rating_sigma) => float(),
          required(:rating_games_count) => non_neg_integer()
        }) :: result()
  def classify(%{
        rating_mu: mu,
        rating_sigma: sigma,
        rating_games_count: games_count
      }) do
    classify(mu, sigma, games_count)
  end

  @doc """
  Full map of default thresholds (band cutoffs + provisional gate).
  """
  @spec defaults() :: map()
  def defaults, do: @defaults

  # Provisional while too few games OR sigma still too high; clears only when
  # both conditions are satisfied.
  defp provisional?(sigma, games_count) do
    games_count < config(:provisional_min_games) or
      sigma >= config(:provisional_max_sigma)
  end

  # Bronze is the catch-all floor for any non-provisional ordinal below silver_min.
  defp band_for(ord) do
    cond do
      ord >= config(:master_min) -> :master
      ord >= config(:platinum_min) -> :platinum
      ord >= config(:gold_min) -> :gold
      ord >= config(:silver_min) -> :silver
      true -> :bronze
    end
  end

  defp config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end
end
