defmodule PidroServer.Playstyle do
  @moduledoc """
  Pure playstyle math (PID-51): a player's **bidding-win rate** → a clamped
  Careful↔Aggressive needle (0.0..1.0) + a coarse label, plus an
  **average winning bid** helper.

  Reads off the `player_profile` accumulators PID-44 shipped
  (`playstyle_bidding_wins`, `playstyle_bidding_attempts`, `avg_winning_bid_sum`,
  `avg_winning_bid_count`); this module only interprets them. No DB, fully
  doctested, config-tunable via the `Progression` `@defaults` + `config/1` idiom
  (`config :pidro_server, PidroServer.Playstyle, ...`).

  ## Needle math

  The rate `wins / attempts` is mapped onto `0.0..1.0` by a **two-segment hinge**
  through three anchors — `low → 0.0`, `center → 0.5`, `high → 1.0`:

    * `rate <= low`              → 0.0 (full Careful)
    * `low < rate <= center`     → `0.5 * (rate - low) / (center - low)`
    * `center < rate < high`     → `0.5 + 0.5 * (rate - center) / (high - center)`
    * `rate >= high`             → 1.0 (full Aggressive)

  Two segments (rather than one straight `low→high`) honor all three anchors even
  when `center` is moved off the arithmetic midpoint of `[low, high]` by config. A
  degenerate config that collapses a segment (`center == low` or `center == high`)
  returns the boundary value rather than dividing by zero. The result is always
  clamped into `0.0..1.0`.

  `:insufficient` (no completed bidding rounds, `attempts == 0`) maps to the
  center `0.5` so the screen shows a neutral needle plus a "not enough data" flag.

  ## Examples

      iex> PidroServer.Playstyle.bidding_win_rate(0, 0)
      :insufficient

      iex> PidroServer.Playstyle.bidding_win_rate(1, 4)
      0.25

      iex> PidroServer.Playstyle.needle(0.10)
      0.0

      iex> PidroServer.Playstyle.needle(0.25)
      0.5

      iex> PidroServer.Playstyle.needle(0.40)
      1.0

      iex> PidroServer.Playstyle.needle(:insufficient)
      0.5

      iex> PidroServer.Playstyle.label(0.5)
      :balanced

      iex> PidroServer.Playstyle.avg_winning_bid(30, 4)
      7.5

      iex> PidroServer.Playstyle.avg_winning_bid(0, 0)
      nil

  """

  @defaults %{
    # 4-player baseline win rate → needle midpoint.
    center: 0.25,
    # <= this → full Careful (0.0).
    low: 0.10,
    # >= this → full Aggressive (1.0).
    high: 0.40,
    # needle < this → :careful.
    careful_max: 0.34,
    # needle >= this → :aggressive (between → :balanced).
    aggressive_min: 0.66
  }

  @typedoc "A bidding-win rate, or `:insufficient` when no rounds were played."
  @type rate :: float() | :insufficient

  @doc """
  The bidding-win rate `wins / attempts`, or `:insufficient` when `attempts == 0`
  (no completed bidding rounds — the screen shows a neutral needle + a flag).
  """
  @spec bidding_win_rate(non_neg_integer(), non_neg_integer()) :: rate()
  def bidding_win_rate(_wins, 0), do: :insufficient
  def bidding_win_rate(wins, attempts), do: wins / attempts

  @doc """
  Maps a `rate` (or `:insufficient`) onto the `0.0..1.0` Careful↔Aggressive needle
  via the two-segment hinge documented in the moduledoc. `:insufficient` → center.
  """
  @spec needle(rate()) :: float()
  def needle(:insufficient), do: 0.5

  def needle(rate) when is_number(rate) do
    low = config(:low)
    center = config(:center)
    high = config(:high)

    cond do
      rate <= low -> 0.0
      rate >= high -> 1.0
      rate <= center -> lower_segment(rate, low, center)
      true -> upper_segment(rate, center, high)
    end
    |> clamp01()
  end

  # Guard against a degenerate config collapsing the lower segment.
  defp lower_segment(_rate, low, center) when center <= low, do: 0.5
  defp lower_segment(rate, low, center), do: 0.5 * (rate - low) / (center - low)

  # Guard against a degenerate config collapsing the upper segment.
  defp upper_segment(_rate, center, high) when high <= center, do: 1.0
  defp upper_segment(rate, center, high), do: 0.5 + 0.5 * (rate - center) / (high - center)

  defp clamp01(value) when value < 0.0, do: 0.0
  defp clamp01(value) when value > 1.0, do: 1.0
  defp clamp01(value), do: value

  @doc """
  Labels a `needle` value: `:careful` below `careful_max`, `:aggressive` at/above
  `aggressive_min`, `:balanced` between.
  """
  @spec label(float()) :: :careful | :balanced | :aggressive
  def label(needle) when is_number(needle) do
    cond do
      needle < config(:careful_max) -> :careful
      needle >= config(:aggressive_min) -> :aggressive
      true -> :balanced
    end
  end

  @doc """
  Average winning bid `sum / count`, or `nil` when the player never won a bid
  (`count == 0`) — a genuine "never won a bid" reads as nil, not a misleading 0.0.
  """
  @spec avg_winning_bid(non_neg_integer(), non_neg_integer()) :: float() | nil
  def avg_winning_bid(_sum, 0), do: nil
  def avg_winning_bid(sum, count), do: sum / count

  @doc "Full map of default config (needle anchors + label cutoffs)."
  @spec defaults() :: map()
  def defaults, do: @defaults

  defp config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end
end
