defmodule PidroServer.Achievements do
  @moduledoc """
  Pure achievement evaluation: the generic evaluators + the router that runs
  every active `Catalog` def against a context. No DB — the caller (`Profiles`)
  supplies the context and owns persistence.

  The SAME `evaluate_active/1` is called by both the live completion seam and
  the rebuild seam; only the `ctx` source differs and both contexts carry the
  identical shape, which is what guarantees live == rebuild award parity.

  ## Context shape

      %{
        user_id:    binary_id,
        aggregates: %{games_played: int, wins: int}, # post-update (live) / recomputed (rebuild)
        this_game:  game_view | nil,                 # live: this game; rebuild: nil
        history:    [game_view]                       # ordered total order; user's full history
      }

  A `game_view` is a normalized read of one completed game (built by `Profiles`
  from the in-scope live data or a `GameStats` row using the shared
  team/score/result helpers):

      %{
        won?:           boolean,
        team_score:     integer,
        opponent_score: integer,
        partnered_win?: boolean  # a 4-distinct-human 2v2 win for this user
      }

  ## Three generic evaluators

    * `{:cumulative_count, field}` — earns when `aggregates[field] >= threshold`.
      Order-agnostic; same counter live and rebuilt.
    * `:win_streak` — earns when the longest run of consecutive wins over the
      ordered `history` ≥ threshold. Both paths read history in the same total
      order, so they see the identical sequence.
    * `{:single_game_predicate, name}` — earns when ANY game satisfies a pure
      predicate. Live: evaluate `this_game`. Rebuild: `Enum.any?` over history.
      Because awards are permanent, "any historical game satisfied it" matches
      "the live game that first satisfied it" exactly.

  Dormant defs name evaluator tags (`:hand_event`, `:game_meta`) with NO
  evaluator wired — but `active/0` filters them out before the router runs, so
  they can never auto-award. Naming a not-yet-implemented tag is safe and
  self-documents the follow-up.
  """

  alias PidroServer.Achievements.Catalog
  alias PidroServer.Achievements.Def

  @typedoc "A normalized read of one completed game for one user."
  @type game_view :: %{
          won?: boolean(),
          team_score: integer(),
          opponent_score: integer(),
          partnered_win?: boolean()
        }

  @typedoc "An award the user qualifies for: `{key, tier, metadata}`."
  @type award :: {atom(), pos_integer(), map()}

  @doc """
  Runs every `Catalog.active/0` def against `ctx` and returns the awards the user
  qualifies for as `[{key, tier, metadata}]`. Pure, no DB.

  Identical function for the live and rebuild paths — parity by construction.
  """
  @spec evaluate_active(map()) :: [award()]
  def evaluate_active(ctx) when is_map(ctx) do
    Catalog.active()
    |> Enum.flat_map(fn def ->
      case earned?(def, ctx) do
        {:earned, metadata} -> [{def.key, def.tier, metadata}]
        :not_earned -> []
      end
    end)
  end

  # --- The router: dispatch a def to its evaluator by tag ---

  @spec earned?(Def.t(), map()) :: {:earned, map()} | :not_earned
  defp earned?(%Def{evaluator: {:cumulative_count, field}} = def, ctx) do
    threshold = Catalog.threshold(def.key)
    count = ctx |> Map.fetch!(:aggregates) |> Map.get(field, 0)

    if count >= threshold do
      {:earned, %{count: count}}
    else
      :not_earned
    end
  end

  defp earned?(%Def{evaluator: :win_streak} = def, ctx) do
    threshold = Catalog.threshold(def.key)
    longest = longest_win_streak(Map.get(ctx, :history, []))

    if longest >= threshold do
      {:earned, %{streak: longest}}
    else
      :not_earned
    end
  end

  defp earned?(%Def{evaluator: {:single_game_predicate, name}} = def, ctx) do
    threshold = Catalog.threshold(def.key)
    games = games_to_check(ctx)

    case Enum.find(games, fn game -> predicate(name, game, threshold) end) do
      nil -> :not_earned
      game -> {:earned, predicate_metadata(name, game)}
    end
  end

  # Dormant tags (`:hand_event`, `:game_meta`) reach here only if mistakenly made
  # active; they are not wired, so they never award.
  defp earned?(%Def{}, _ctx), do: :not_earned

  # Live evaluates THIS game; rebuild (this_game == nil) scans full history.
  defp games_to_check(%{this_game: %{} = game}), do: [game]
  defp games_to_check(ctx), do: Map.get(ctx, :history, [])

  # --- Single-game predicates (pure on a game_view) ---

  # Ace: win while the opponent finished at or below the threshold (0 = shutout).
  defp predicate(:opponent_at_or_below, %{won?: true} = game, threshold),
    do: game.opponent_score <= threshold

  defp predicate(:opponent_at_or_below, _game, _threshold), do: false

  # The Loser: finish with your own team's score strictly below the threshold (0).
  defp predicate(:final_score_negative, game, threshold), do: game.team_score < threshold

  # Partnership: a 4-distinct-human 2v2 win for this user (threshold unused — it
  # is a 1-shot predicate; threshold 1 documents "one such win earns it").
  defp predicate(:partnered_win, game, _threshold), do: game.partnered_win? == true

  defp predicate(_name, _game, _threshold), do: false

  defp predicate_metadata(:opponent_at_or_below, game),
    do: %{opponent_score: game.opponent_score, team_score: game.team_score}

  defp predicate_metadata(:final_score_negative, game), do: %{team_score: game.team_score}
  defp predicate_metadata(:partnered_win, _game), do: %{}
  defp predicate_metadata(_name, _game), do: %{}

  @doc """
  Longest run of consecutive wins over an ordered list of `game_view`s
  (`won?` true). The caller must pass history already in the canonical total
  order. Pure.

  ## Examples

      iex> wins = fn list -> Enum.map(list, &%{won?: &1}) end
      iex> PidroServer.Achievements.longest_win_streak(wins.([true, true, false, true, true]))
      2

      iex> wins = fn list -> Enum.map(list, &%{won?: &1}) end
      iex> PidroServer.Achievements.longest_win_streak(wins.([true, true, true]))
      3

  """
  @spec longest_win_streak([game_view()]) :: non_neg_integer()
  def longest_win_streak(history) when is_list(history) do
    {longest, _current} =
      Enum.reduce(history, {0, 0}, fn game, {longest, current} ->
        if game.won? do
          current = current + 1
          {max(longest, current), current}
        else
          {longest, 0}
        end
      end)

    longest
  end
end
