defmodule PidroServer.Progression do
  @moduledoc """
  Pure veteran-progression math: XP per completed game, XP → level, level →
  milestone title, plus level-progress helpers.

  Faithful to Pidro 1 (carried so PID-53 imports land on the same level):

    * XP award — winner = team final score + 50; loser = team final score.
      (legacy: pidro_api/lib/pidro_api/game_results.ex:185-211; confirmed by
      pidro_api/test/features/game_results_test.exs:156-160 — winner 66+50=116,
      loser 54)
    * Level curve — cumulative thresholds `floor(lvl + 300*2^(lvl/7))` then
      `÷4`; `level = count(thresholds <= xp) + 1`, capped at `max_level`.
      (legacy: pidro_api/lib/pidro_api_web/views/user_view.ex:378-405)

  XP is a per-game sum (order-agnostic), so totals are rebuildable by summation.
  Bonuses, curve params, max_level, and milestone titles are config-tunable
  (see `config :pidro_server, PidroServer.Progression`); titles are launch
  placeholders, not final copy.

  ## Examples

      iex> PidroServer.Progression.xp_for_game(54, false)
      54

      iex> PidroServer.Progression.xp_for_game(66, true)
      116

      iex> PidroServer.Progression.level_for_xp(0)
      1

      iex> PidroServer.Progression.level_for_xp(83)
      2

  """

  @typedoc "A milestone title for a level band."
  @type title :: String.t()

  @defaults %{
    win_bonus: 50,
    extra_bonus: 0,
    max_level: 100,
    curve_base_growth: 300,
    curve_growth_divisor: 7,
    curve_point_divisor: 4,
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
  Builds the ascending threshold list for the given curve params.

  Generator (legacy, source of truth): `lvl` runs `1..max_level`; each level's
  increment is `floor(lvl + base_growth * 2^(lvl/growth_divisor))` accumulated,
  and the stored threshold is `floor(points / point_divisor)`. Ascending list,
  e.g. `[83, 174, 276, 388, 512, ...]`. For tests/tools and runtime
  regeneration when config params differ from the compile-time defaults.
  """
  @spec build_thresholds(pos_integer(), number(), number(), number()) :: [non_neg_integer()]
  def build_thresholds(max_level, base_growth, growth_divisor, point_divisor)
      when is_integer(max_level) and max_level >= 1 do
    {thresholds, _points} =
      Enum.reduce(1..max_level, {[], 0}, fn lvl, {acc, points} ->
        increment = trunc(Float.floor(lvl + base_growth * :math.pow(2, lvl / growth_divisor)))
        points = points + increment
        {[trunc(Float.floor(points / point_divisor)) | acc], points}
      end)

    Enum.reverse(thresholds)
  end

  # Compile-time legacy default (used when config :thresholds is nil and the
  # config curve params match the defaults). This is the exact Pidro 1 array,
  # computed once at compile time by inlining the generator above.
  @legacy_thresholds (fn ->
                        {thresholds, _points} =
                          Enum.reduce(1..@defaults.max_level, {[], 0}, fn lvl, {acc, points} ->
                            increment =
                              trunc(
                                Float.floor(
                                  lvl +
                                    @defaults.curve_base_growth *
                                      :math.pow(2, lvl / @defaults.curve_growth_divisor)
                                )
                              )

                            points = points + increment

                            {[trunc(Float.floor(points / @defaults.curve_point_divisor)) | acc],
                             points}
                          end)

                        Enum.reverse(thresholds)
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

      iex> PidroServer.Progression.level_for_xp(82)
      1

      iex> PidroServer.Progression.level_for_xp(174)
      3

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
      83

      iex> PidroServer.Progression.next_level_at(83)
      174

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
      {0, 83}

      iex> PidroServer.Progression.level_progress(100)
      {17, 91}

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

  @doc "The full threshold list (config-overridable). For tests/tools."
  @spec thresholds() :: [non_neg_integer()]
  def thresholds do
    case config(:thresholds) do
      list when is_list(list) ->
        list

      _ ->
        max_level = config(:max_level)
        base_growth = config(:curve_base_growth)
        growth_divisor = config(:curve_growth_divisor)
        point_divisor = config(:curve_point_divisor)

        if {max_level, base_growth, growth_divisor, point_divisor} ==
             {@defaults.max_level, @defaults.curve_base_growth, @defaults.curve_growth_divisor,
              @defaults.curve_point_divisor} do
          @legacy_thresholds
        else
          build_thresholds(max_level, base_growth, growth_divisor, point_divisor)
        end
    end
  end

  @doc "Full map of default config (bonuses, curve params, max_level, titles)."
  @spec defaults() :: map()
  def defaults, do: @defaults

  defp config(key) when is_map_key(@defaults, key) do
    app_config = Application.get_env(:pidro_server, __MODULE__, [])
    Keyword.get(app_config, key, Map.fetch!(@defaults, key))
  end
end
