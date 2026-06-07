defmodule PidroServer.Achievements.Catalog do
  @moduledoc """
  Achievements are **data, not branches.** This module is the single source of
  truth: a list of `%Def{}` structs declaring each achievement's `key`, `name`,
  `description`, `tier`, an `evaluator` spec (a tag routing to one generic
  evaluator), a `threshold`, and a `status` (`:active` | `:dormant`).

  Adding an achievement is a data edit — one `%Def{}` line reusing an existing
  evaluator tag — never a new code branch or schema change.

  ## The 6 active / 4 dormant scope cut (PID-50)

  The persisted `game_stats` row holds only end-of-game aggregates plus one
  last-hand bid number; there is no per-hand / per-player bid or points data
  persisted anywhere. So achievements split:

    * **6 ACTIVE** (A-class) — computable from columns that already exist
      (`player_results`, `winner`, `final_scores`, `completed_at`), so they
      evaluate live AND rebuild exactly: `player`, `winner`, `winstreak`,
      `ace`, `the_loser`, `partnership`.
    * **4 DORMANT** (B-class) — `homerun`, `forcer`, `full_house`,
      `unstoppable`. Defined here as data with `status: :dormant`, a `reason`,
      and a `followup`, but NOT evaluated (filtered out by `active/0`). They
      need per-hand facts derived from the engine `state.events` log, which is
      not persisted. Activating them later is a `status: :active` flip plus the
      separable per-hand capture ticket — zero catalog/schema churn here.

  ## Config-overridable thresholds

  Each def carries a canonical compile-time `threshold` visible in the list.
  `threshold/1` mirrors the `PidroServer.Progression` `config/1` idiom: it reads
  `Application.get_env(:pidro_server, __MODULE__, [])[:thresholds][key]` and
  falls back to the def default — so launch numbers are tunable without a code
  change while staying visible in the catalog.

  ## Examples

      iex> PidroServer.Achievements.Catalog.active() |> Enum.map(& &1.key) |> Enum.sort()
      [:ace, :partnership, :player, :the_loser, :winner, :winstreak]

      iex> PidroServer.Achievements.Catalog.threshold(:player)
      10

      iex> PidroServer.Achievements.Catalog.threshold(:winner)
      5

  """

  alias PidroServer.Achievements.Def

  @all [
    # --- ACTIVE (shipped, A-class, rebuildable from game_stats) ---------------
    %Def{
      key: :player,
      name: "Player",
      description: "Finish 10 games.",
      tier: 1,
      status: :active,
      evaluator: {:cumulative_count, :games_played},
      threshold: 10
    },
    %Def{
      key: :winner,
      name: "The Winner",
      description: "Win 5 games.",
      tier: 1,
      status: :active,
      evaluator: {:cumulative_count, :wins},
      threshold: 5
    },
    %Def{
      key: :winstreak,
      name: "Win Streak",
      description: "Win 3 games in a row.",
      tier: 1,
      status: :active,
      evaluator: :win_streak,
      threshold: 3
    },
    %Def{
      key: :ace,
      name: "Ace",
      description: "Win a game while the opposing team finishes at 0 or below.",
      tier: 1,
      status: :active,
      evaluator: {:single_game_predicate, :opponent_at_or_below},
      threshold: 0
    },
    %Def{
      key: :the_loser,
      name: "The Loser",
      description: "Finish a game with your team in negative points.",
      tier: 1,
      status: :active,
      evaluator: {:single_game_predicate, :final_score_negative},
      threshold: 0
    },
    %Def{
      key: :partnership,
      name: "Partnership",
      description: "Win a full 4-player game alongside your partner.",
      tier: 1,
      status: :active,
      evaluator: {:single_game_predicate, :partnered_win},
      threshold: 1
    },

    # --- DORMANT (defined as data, NOT evaluated — needs per-hand capture) ----
    %Def{
      key: :homerun,
      name: "Homerun",
      description: "Bid 14 and make it.",
      tier: 1,
      status: :dormant,
      evaluator: {:hand_event, :max_bid_made},
      threshold: 14,
      reason: "Needs per-hand bid+made facts from state.events; not persisted.",
      followup: "per-hand fact capture (separable ticket)"
    },
    %Def{
      key: :forcer,
      name: "Forcer",
      description: "As dealer, be forced to bid 6 and still make it.",
      tier: 1,
      status: :dormant,
      evaluator: {:hand_event, :forced_bid_made},
      threshold: 6,
      reason: "Needs forced-bid flag + hand outcome from state.events.",
      followup: "per-hand fact capture (separable ticket)"
    },
    %Def{
      key: :full_house,
      name: "Full House",
      description: "Take all 14 points in a single hand.",
      tier: 1,
      status: :dormant,
      evaluator: {:hand_event, :hand_points_at_least},
      threshold: 14,
      reason: "Needs per-hand per-team points deltas from state.events.",
      followup: "per-hand fact capture (separable ticket)"
    },
    %Def{
      key: :unstoppable,
      name: "Unstoppable",
      description: "Win a game in 5 hands or fewer.",
      tier: 1,
      status: :dormant,
      evaluator: {:game_meta, :hands_at_most},
      threshold: 5,
      reason: "Needs hand_number at completion; live-only, not persisted.",
      followup: "per-hand fact capture (separable ticket)"
    }
  ]

  @doc "The full def list (all 10 — active + dormant)."
  @spec all() :: [Def.t()]
  def all, do: @all

  @doc """
  The launch subset: defs with `status: :active`. Dormant defs are filtered out
  so the evaluation router never touches them in either path.
  """
  @spec active() :: [Def.t()]
  def active, do: Enum.filter(@all, &(&1.status == :active))

  @doc """
  The effective threshold for an achievement key — the config override if one is
  set, else the def's compile-time default. Mirrors `Progression.config/1`.

  ## Examples

      iex> PidroServer.Achievements.Catalog.threshold(:winstreak)
      3

  """
  @spec threshold(atom()) :: integer()
  def threshold(key) when is_atom(key) do
    overrides =
      :pidro_server
      |> Application.get_env(__MODULE__, [])
      |> Keyword.get(:thresholds, %{})

    case Map.fetch(overrides, key) do
      {:ok, value} -> value
      :error -> fetch!(key).threshold
    end
  end

  @doc "Fetches the def for a key, raising if unknown."
  @spec fetch!(atom()) :: Def.t()
  def fetch!(key) when is_atom(key) do
    case Enum.find(@all, &(&1.key == key)) do
      %Def{} = def -> def
      nil -> raise ArgumentError, "unknown achievement key #{inspect(key)}"
    end
  end
end
