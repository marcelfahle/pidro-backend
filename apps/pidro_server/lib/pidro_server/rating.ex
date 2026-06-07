defmodule PidroServer.Rating do
  @moduledoc """
  Pure OpenSkill (Weng-Lin Bayesian) team rating: two partnerships + outcome →
  updated `{mu, sigma}` per player. Library-agnostic facade — the estimator behind
  it is swappable without touching callers (PID-46 rerating, PID-47 completion).

  A rating is a `{mu, sigma}` tuple of floats. New players init to `default/0`
  (mu = 25.0, sigma = 25/3 ≈ 8.333). The model is *order-only*: it consumes who
  won, NOT by how much, so a blowout and a nail-biter produce identical updates.

  This implementation wraps the `:openskill` hex package (Weng-Lin model, MIT,
  pure Elixir). It is hidden entirely behind `default/0`, `rate/2`, and `ordinal/1`
  so swapping the estimator is a local change.
  """

  @typedoc "A player rating: mean skill `mu` and uncertainty `sigma`, both floats."
  @type rating :: {mu :: float(), sigma :: float()}

  @doc """
  New-player initial rating: `{25.0, 8.333333333333334}` (μ=25, σ=25/3).

  ## Examples

      iex> {mu, sigma} = PidroServer.Rating.default()
      iex> mu
      25.0
      iex> Float.round(sigma, 4)
      8.3333

  """
  @spec default() :: rating()
  def default do
    {mu, sigma} = Openskill.rating()
    {mu / 1, sigma / 1}
  end

  @doc """
  Updates ratings given a result.

  `winning_team` and `losing_team` are each a non-empty list of `{mu, sigma}`.
  Returns `%{winners: [...], losers: [...]}` with updated tuples in the SAME
  order as the inputs. Pure and deterministic: winners' μ rises, losers' μ falls,
  every σ shrinks.

  The model is order-only — there is no score-margin input, so a blowout and a
  close win between the same ratings yield identical results.

  ## Examples

      iex> r = PidroServer.Rating.default()
      iex> %{winners: [{wmu, _wsig}], losers: [{lmu, _lsig}]} =
      ...>   PidroServer.Rating.rate([r], [r])
      iex> wmu > 25.0 and lmu < 25.0
      true

  """
  @spec rate([rating(), ...], [rating(), ...]) :: %{
          winners: [rating(), ...],
          losers: [rating(), ...]
        }
  def rate(winning_team, losing_team)
      when is_list(winning_team) and winning_team != [] and
             is_list(losing_team) and losing_team != [] do
    [winners, losers] = Openskill.rate([winning_team, losing_team])
    %{winners: winners, losers: losers}
  end

  @doc """
  Conservative scalar for display/sorting: `mu - 3 * sigma`.

  ## Examples

      iex> PidroServer.Rating.ordinal({25.0, 8.0})
      1.0

  """
  @spec ordinal(rating()) :: float()
  def ordinal({mu, sigma}), do: mu - 3 * sigma
end
