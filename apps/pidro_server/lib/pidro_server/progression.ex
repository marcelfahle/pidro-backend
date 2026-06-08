defmodule PidroServer.Progression do
  @moduledoc """
  Pure veteran-progression math: XP per completed game, XP → level, level →
  milestone title, level-progress helpers, plus the uncapped Prestige tail.

  XP award is faithful to Pidro 1 (carried so PID-53 imports land on the same
  total): winner = team final score + 50; loser = team final score. (legacy:
  pidro_api/lib/pidro_api/game_results.ex:185-211; confirmed by
  pidro_api/test/features/game_results_test.exs:156-160 — winner 66+50=116,
  loser 54.)

  The level curve is a re-paced **power law**, data-calibrated against the real
  Pidro 1 distribution (~78 XP/player/game; top player ≈ 5.02M total XP over
  ~63k games). The old legacy-exponential curve put L100 in the tens of millions
  of XP — unreachable even for the top player — so it is replaced with:

      threshold(1) = 0
      threshold(level) = round(coefficient * level ** exponent)   (level 2..max)

  With the defaults (`coefficient` 80, `exponent` 2.0, `max_level` 100) the
  titled ladder is reachable: L5=2,000, L10=8,000, L20=32,000, L50=200,000,
  L75=450,000, **L100=800,000**. `level = count(thresholds <= xp) + 1`, capped
  at `max_level`.

  Past the L100 cap the ladder continues forever via **Prestige** — one extra
  star per `prestige_step` XP (default 500,000) earned beyond the L100 threshold.
  Calibrated so the real top player (5.02M XP) lands at Hall of Famer ★8
  (`floor((5_020_512 - 800_000) / 500_000) == 8`).

  XP is a per-game sum (order-agnostic), so totals are rebuildable by summation.
  Levels and prestige are PURE functions of total XP — recomputed on read, never
  authoritative on their own (no migration; XP stays canonical). Bonuses, curve
  params, `max_level`, `prestige_step`, and milestone titles are config-tunable
  (see `config :pidro_server, PidroServer.Progression`); titles are launch
  placeholders, not final copy.

  ## Examples

      iex> PidroServer.Progression.xp_for_game(54, false)
      54

      iex> PidroServer.Progression.xp_for_game(66, true)
      116

      iex> PidroServer.Progression.level_for_xp(0)
      1

      iex> PidroServer.Progression.level_for_xp(2000)
      5

  """

  @typedoc "A milestone title for a level band."
  @type title :: String.t()

  @defaults %{
    win_bonus: 50,
    extra_bonus: 0,
    max_level: 100,
    curve_coefficient: 80,
    curve_exponent: 2.0,
    prestige_step: 500_000,
    thresholds: nil,
    titles: %{
      1 => "Rookie",
      5 => "Apprentice",
      10 => "Journeyman",
      20 => "Veteran",
      35 => "Expert",
      50 => "Master",
      75 => "Grandmaster",
      100 => "Legend"
    }
  }

  @doc """
  Builds the ascending threshold list for the given power-law curve params.

  Conceptually `threshold(1) = 0` and
  `threshold(level) = round(coefficient * level ** exponent)` for `level` in
  `2..max_level` (using `:math.pow`). The returned list is the
  *level-entry boundaries for levels 2..max_level* — i.e. the leading `0` for
  level 1 is omitted, since `level_for_xp/1` counts boundaries crossed and adds
  1. With the defaults this is `[320, 720, 1280, 2000, ...]` (99 entries).
  For tests/tools and runtime regeneration when config params differ from the
  compile-time defaults.
  """
  @spec build_thresholds(pos_integer(), number(), number()) :: [non_neg_integer()]
  def build_thresholds(max_level, coefficient, exponent)
      when is_integer(max_level) and max_level >= 1 do
    case max_level do
      1 -> []
      _ -> Enum.map(2..max_level, fn level -> round(coefficient * :math.pow(level, exponent)) end)
    end
  end

  # Compile-time default threshold list (used when config :thresholds is nil and
  # the config curve params match the defaults). Computed once at compile time by
  # inlining the generator above.
  @default_thresholds (fn ->
                         Enum.map(2..@defaults.max_level, fn level ->
                           round(
                             @defaults.curve_coefficient *
                               :math.pow(level, @defaults.curve_exponent)
                           )
                         end)
                       end).()

  @doc """
  XP earned for one completed game by one participant.

  `team_score + (won? && win_bonus || 0) + extra_bonus`. Negative team scores
  (legacy `allow_negative_scores`) are clamped to a non-negative result. `opts`
  overrides config: `:win_bonus`, `:extra_bonus`.

  ## Examples

      iex> PidroServer.Progression.xp_for_game(10, true, win_bonus: 5)
      15

      iex> PidroServer.Progression.xp_for_game(-5, false)
      0

  """
  @spec xp_for_game(integer(), boolean(), keyword()) :: non_neg_integer()
  def xp_for_game(team_score, won?, opts \\ []) when is_integer(team_score) do
    win_bonus = Keyword.get(opts, :win_bonus, config(:win_bonus))
    extra_bonus = Keyword.get(opts, :extra_bonus, config(:extra_bonus))
    raw = team_score + if(won?, do: win_bonus, else: 0) + extra_bonus
    max(raw, 0)
  end

  @doc """
  Level (1..max_level) for a cumulative XP total.

  `level = count(thresholds <= xp) + 1`, capped at `max_level`.
  `level_for_xp(0) == 1`.

  ## Examples

      iex> PidroServer.Progression.level_for_xp(319)
      1

      iex> PidroServer.Progression.level_for_xp(320)
      2

      iex> PidroServer.Progression.level_for_xp(800_000)
      100

  """
  @spec level_for_xp(non_neg_integer()) :: pos_integer()
  def level_for_xp(xp) when is_integer(xp) and xp >= 0 do
    level = Enum.count(thresholds(), &(&1 <= xp)) + 1
    min(level, config(:max_level))
  end

  @doc """
  Milestone title for a level — the highest configured title whose level ≤ the
  given level. Returns the lowest (floor) title for levels below the lowest key.

  ## Examples

      iex> PidroServer.Progression.title_for_level(1)
      "Rookie"

      iex> PidroServer.Progression.title_for_level(4)
      "Rookie"

      iex> PidroServer.Progression.title_for_level(20)
      "Veteran"

  """
  @spec title_for_level(pos_integer()) :: title()
  def title_for_level(level) when is_integer(level) do
    titles = config(:titles)
    sorted = Enum.sort_by(Map.keys(titles), & &1)

    case Enum.filter(sorted, &(&1 <= level)) do
      [] -> Map.fetch!(titles, List.first(sorted))
      eligible -> Map.fetch!(titles, List.last(eligible))
    end
  end

  @doc """
  XP threshold at which the *next* level begins, or `:max` at the cap.

  ## Examples

      iex> PidroServer.Progression.next_level_at(0)
      320

      iex> PidroServer.Progression.next_level_at(320)
      720

  """
  @spec next_level_at(non_neg_integer()) :: non_neg_integer() | :max
  def next_level_at(xp) when is_integer(xp) and xp >= 0 do
    if level_for_xp(xp) >= config(:max_level) do
      :max
    else
      Enum.find(thresholds(), :max, &(&1 > xp))
    end
  end

  @doc """
  Progress within the current level as `{xp_into_level, xp_span_of_level}`, or
  `:max` at the cap. Cheap derived field for the profile screen (PID-49 scope:
  a static snapshot, not a PID-52 delta).

  ## Examples

      iex> PidroServer.Progression.level_progress(0)
      {0, 320}

      iex> PidroServer.Progression.level_progress(320)
      {0, 400}

  """
  @spec level_progress(non_neg_integer()) :: {non_neg_integer(), pos_integer()} | :max
  def level_progress(xp) when is_integer(xp) and xp >= 0 do
    case next_level_at(xp) do
      :max ->
        :max

      upper ->
        # Lower bound of the current level = the highest threshold <= xp, or 0
        # for level 1.
        lower =
          thresholds()
          |> Enum.filter(&(&1 <= xp))
          |> List.last()
          |> Kernel.||(0)

        {xp - lower, upper - lower}
    end
  end

  @doc """
  Prestige tier for a cumulative XP total — `0` below the L100 cap, then one
  extra star per `prestige_step` XP past the cap. Uncapped (the infinite tail).

  `prestige_for_xp(xp) = 0` when `xp < threshold(max_level)`; else
  `floor((xp - threshold(max_level)) / prestige_step)`.

  ## Examples

      iex> PidroServer.Progression.prestige_for_xp(799_999)
      0

      iex> PidroServer.Progression.prestige_for_xp(1_300_000)
      1

      iex> PidroServer.Progression.prestige_for_xp(5_020_512)
      8

  """
  @spec prestige_for_xp(non_neg_integer()) :: non_neg_integer()
  def prestige_for_xp(xp) when is_integer(xp) and xp >= 0 do
    cap = cap_threshold()

    if xp < cap do
      0
    else
      div(xp - cap, config(:prestige_step))
    end
  end

  @doc """
  Progress toward the next Prestige star as `{xp_into_step, prestige_step}` once
  at/over the L100 cap, or `nil` below the cap (no prestige ring to render yet).

  ## Examples

      iex> PidroServer.Progression.prestige_progress(799_999)
      nil

      iex> PidroServer.Progression.prestige_progress(800_000)
      {0, 500_000}

      iex> PidroServer.Progression.prestige_progress(1_300_000)
      {0, 500_000}

  """
  @spec prestige_progress(non_neg_integer()) :: {non_neg_integer(), pos_integer()} | nil
  def prestige_progress(xp) when is_integer(xp) and xp >= 0 do
    cap = cap_threshold()

    if xp < cap do
      nil
    else
      step = config(:prestige_step)
      {rem(xp - cap, step), step}
    end
  end

  @doc "The full threshold list (boundaries for levels 2..max_level). For tests/tools."
  @spec thresholds() :: [non_neg_integer()]
  def thresholds do
    case config(:thresholds) do
      list when is_list(list) ->
        list

      _ ->
        max_level = config(:max_level)
        coefficient = config(:curve_coefficient)
        exponent = config(:curve_exponent)

        if {max_level, coefficient, exponent} ==
             {@defaults.max_level, @defaults.curve_coefficient, @defaults.curve_exponent} do
          @default_thresholds
        else
          build_thresholds(max_level, coefficient, exponent)
        end
    end
  end

  @doc "Full map of default config (bonuses, curve params, max_level, prestige, titles)."
  @spec defaults() :: map()
  def defaults, do: @defaults

  # The XP at which the L100 cap (the top level) begins — the last threshold
  # boundary, i.e. threshold(max_level). 0 when max_level is 1 (no boundaries).
  defp cap_threshold do
    case List.last(thresholds()) do
      nil -> 0
      cap -> cap
    end
  end

  defp config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end
end
