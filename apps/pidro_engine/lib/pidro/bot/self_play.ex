defmodule Pidro.Bot.SelfPlay do
  @moduledoc """
  Plays whole games between two bot teams through the engine and reports
  how each team did.

  A policy is a function from a seat view and the legal actions to an
  action. The harness builds the view for the seat to move, so every policy
  it runs is held to the same fairness rule as a seated bot.

  Games are seeded and each runs in its own process, so a run with the same
  seed gives the same summary. Team A sits North/South in even-numbered
  games and East/West in odd ones. A game ends in one of:

  - `:complete` - a team reached the winning score
  - `{:illegal_action, position, action}` - a policy chose a move that was not legal
  - `{:crash, message}` - a policy raised or the engine rejected a legal move
  - `:stalled` - the seat to move had no legal action
  - `:capped` - the game passed the action cap

  Only complete games count towards win rates. Anything else is a failure the
  release gate refuses.
  """

  alias Pidro.Bot.{RandomPolicy, Rulebook}
  alias Pidro.Core.{GameState, SeatView, Types}
  alias Pidro.Game.{DealerRob, Dealing, Engine}

  @type policy :: (SeatView.t(), [Types.action(), ...] -> Types.action())
  @type team_spec :: {atom(), policy()}
  @type outcome ::
          :complete
          | :capped
          | :stalled
          | {:illegal_action, Types.position(), term()}
          | {:crash, String.t()}

  @type hand_record :: %{
          team: Types.team(),
          bid: Types.bid_amount(),
          forced?: boolean(),
          made?: boolean()
        }

  @type game_result :: %{
          outcome: outcome(),
          winner: Types.team() | nil,
          actions: non_neg_integer(),
          hands: [hand_record()],
          decision_us: %{Types.team() => [non_neg_integer()]}
        }

  @default_max_actions 5_000

  @doc """
  Returns the rulebook bot as a policy.
  """
  @spec rulebook_policy() :: policy()
  def rulebook_policy do
    fn view, legal ->
      {action, _reason} = Rulebook.decide(view, legal)
      action
    end
  end

  @doc """
  Returns the random baseline as a policy.
  """
  @spec random_policy() :: policy()
  def random_policy, do: &RandomPolicy.choose/2

  @doc """
  Plays one game.

  ## Parameters

  - `policies` - `%{north_south: policy, east_west: policy}`
  - `opts`
    - `:seed` - integer seed for the deal and any random policy (default 0)
    - `:max_actions` - action cap (default #{@default_max_actions})

  ## Returns

  A `game_result` map. `decision_us` holds, per team, the microseconds each
  decision took, including building the seat view.
  """
  @spec play_game(%{Types.team() => policy()}, keyword()) :: game_result()
  def play_game(policies, opts \\ []) do
    seed = Keyword.get(opts, :seed, 0)
    max_actions = Keyword.get(opts, :max_actions, @default_max_actions)
    :rand.seed(:exsss, {seed, 0x5EED, 0xB07})

    {:ok, cut} = Dealing.select_dealer(GameState.new())
    {:ok, state} = Engine.advance_from_dealer_selection(cut)

    acc = %{actions: 0, decision_us: %{north_south: [], east_west: []}}
    {outcome, final, acc} = loop(state, policies, max_actions, acc)

    %{
      outcome: outcome,
      winner: if(outcome == :complete, do: final.winner),
      actions: acc.actions,
      hands: hand_records(final.events),
      decision_us: acc.decision_us
    }
  end

  @doc """
  Plays a series of games between team A and team B and summarises them.

  ## Options

  - `:games` - number of games (default 100)
  - `:seed` - base seed (default 1); game `i` uses seed `seed * 100_000 + i`
  - `:a`, `:b` - `{label, policy}` for each team (default rulebook vs random)
  - `:max_actions` - per-game action cap
  - `:max_concurrency` - games played at once (default: online schedulers)

  ## Returns

  A summary map with, per label, games won, win rate, contracts won, bids
  made and set, made rate (also without forced dealer bids), and average
  bid; plus counts of illegal moves, crashes, stalls and capped games, and
  per-label decision times under `:timing`.
  """
  @spec run(keyword()) :: map()
  def run(opts \\ []) do
    games = Keyword.get(opts, :games, 100)
    seed = Keyword.get(opts, :seed, 1)
    {label_a, policy_a} = Keyword.get(opts, :a, {:rulebook, rulebook_policy()})
    {label_b, policy_b} = Keyword.get(opts, :b, {:random, random_policy()})
    game_opts = Keyword.take(opts, [:max_actions])

    results =
      1..games//1
      |> Task.async_stream(
        fn i ->
          a_team = if rem(i, 2) == 0, do: :north_south, else: :east_west
          b_team = Types.opposing_team(a_team)
          policies = %{a_team => policy_a, b_team => policy_b}
          result = play_game(policies, [seed: seed * 100_000 + i] ++ game_opts)
          {%{a_team => label_a, b_team => label_b}, result}
        end,
        ordered: true,
        timeout: :infinity,
        max_concurrency: Keyword.get(opts, :max_concurrency, System.schedulers_online())
      )
      |> Enum.map(fn {:ok, labelled} -> labelled end)

    summarise(results, [label_a, label_b], games, seed)
  end

  @doc """
  Formats a summary from `run/1` as text for the terminal.
  """
  @spec format(map()) :: String.t()
  def format(summary) do
    teams =
      for label <- summary.labels do
        t = summary.teams[label]
        time = summary.timing[label]

        """
        #{label}
          wins            #{t.wins}/#{summary.complete} (#{pct(t.win_rate)})
          contracts       #{t.contracts} (#{t.forced} forced), average bid #{Float.round(t.average_bid, 2)}
          made / set      #{t.made} / #{t.set} (#{pct(t.made_rate)}; #{pct(t.made_rate_unforced)} unforced)
          decision time   p50 #{time.p50} µs, p95 #{time.p95} µs, max #{time.max} µs
        """
      end

    """
    Self-play: #{summary.games} games, seed #{summary.seed}
    #{Enum.join(teams)}
    complete #{summary.complete}, illegal #{summary.illegal}, crashed #{summary.crashed}, stalled #{summary.stalled}, capped #{summary.capped}
    """
  end

  # --- Game loop --------------------------------------------------------------

  defp loop(%{phase: :complete} = state, _policies, _max, acc), do: {:complete, state, acc}
  defp loop(state, _policies, max, %{actions: n} = acc) when n >= max, do: {:capped, state, acc}

  defp loop(state, policies, max, acc) do
    position = state.current_turn

    case position && Engine.legal_actions(state, position) do
      [_ | _] = legal ->
        team = Types.position_to_team(position)

        case decide(policies[team], state, position, legal) do
          {:ok, action, micros} ->
            acc = %{acc | decision_us: Map.update!(acc.decision_us, team, &[micros | &1])}
            step(state, position, action, legal, policies, max, acc)

          {:error, message} ->
            {{:crash, message}, state, acc}
        end

      _none ->
        {:stalled, state, acc}
    end
  end

  defp decide(policy, state, position, legal) do
    {micros, action} = :timer.tc(fn -> policy.(SeatView.for_seat(state, position), legal) end)
    {:ok, action, micros}
  rescue
    error -> {:error, Exception.message(error)}
  end

  defp step(state, position, action, legal, policies, max, acc) do
    if action in legal do
      case Engine.apply_action(state, position, resolve(action, state, position)) do
        {:ok, next} ->
          loop(next, policies, max, %{acc | actions: acc.actions + 1})

        {:error, reason} ->
          {{:crash, "engine rejected #{inspect(action)}: #{inspect(reason)}"}, state, acc}
      end
    else
      {{:illegal_action, position, action}, state, acc}
    end
  end

  # The dealer's rob stays with the engine's own selection, as on the server.
  defp resolve({:select_hand, :choose_6_cards}, state, position) do
    pool = state.players[position].hand ++ state.deck
    {:select_hand, DealerRob.select_best_cards(pool, state.trump_suit)}
  end

  defp resolve(action, _state, _position), do: action

  # --- Results ----------------------------------------------------------------

  # One record per scored hand, read from the engine's events: the contract
  # from `:bidding_complete`, whether the dealer was forced from the bids
  # before it, and the outcome from the bidding team's `:hand_scored` delta.
  defp hand_records(events) do
    {records, _hand} =
      Enum.reduce(events, {[], %{bids: [], contract: nil}}, fn
        {:cards_dealt, _}, {records, _hand} ->
          {records, %{bids: [], contract: nil}}

        {:player_passed, _pos}, {records, hand} ->
          {records, %{hand | bids: [:pass | hand.bids]}}

        {:bid_made, _pos, amount}, {records, hand} ->
          {records, %{hand | bids: [amount | hand.bids]}}

        {:bidding_complete, pos, amount}, {records, hand} ->
          forced? = hand.bids == [amount, :pass, :pass, :pass]
          contract = %{team: Types.position_to_team(pos), bid: amount, forced?: forced?}
          {records, %{hand | contract: contract}}

        {:hand_scored, team, delta}, {records, %{contract: %{team: team} = contract} = hand} ->
          {[Map.put(contract, :made?, delta >= 0) | records], %{hand | contract: nil}}

        _event, acc ->
          acc
      end)

    Enum.reverse(records)
  end

  defp summarise(results, labels, games, seed) do
    complete = for {teams, %{outcome: :complete} = r} <- results, do: {teams, r}

    team_stats =
      Map.new(labels, fn label ->
        hands =
          for {teams, r} <- results, hand <- r.hands, teams[hand.team] == label, do: hand

        wins = Enum.count(complete, fn {teams, r} -> teams[r.winner] == label end)
        unforced = Enum.reject(hands, & &1.forced?)

        {label,
         %{
           wins: wins,
           win_rate: ratio(wins, length(complete)),
           contracts: length(hands),
           forced: length(hands) - length(unforced),
           made: Enum.count(hands, & &1.made?),
           set: Enum.count(hands, &(not &1.made?)),
           made_rate: ratio(Enum.count(hands, & &1.made?), length(hands)),
           made_rate_unforced: ratio(Enum.count(unforced, & &1.made?), length(unforced)),
           average_bid: ratio(Enum.sum(Enum.map(hands, & &1.bid)), length(hands))
         }}
      end)

    timing =
      Map.new(labels, fn label ->
        times =
          for({teams, r} <- results, {team, us} <- r.decision_us, teams[team] == label, do: us)
          |> List.flatten()
          |> Enum.sort()

        {label, percentiles(times)}
      end)

    %{
      games: games,
      seed: seed,
      labels: labels,
      complete: length(complete),
      teams: team_stats,
      illegal: Enum.count(results, &match?({_, %{outcome: {:illegal_action, _, _}}}, &1)),
      crashed: Enum.count(results, &match?({_, %{outcome: {:crash, _}}}, &1)),
      stalled: Enum.count(results, &match?({_, %{outcome: :stalled}}, &1)),
      capped: Enum.count(results, &match?({_, %{outcome: :capped}}, &1)),
      failures:
        for({_, %{outcome: outcome}} <- results, outcome != :complete, do: outcome)
        |> Enum.take(5),
      timing: timing
    }
  end

  defp percentiles([]), do: %{p50: 0, p95: 0, max: 0}

  defp percentiles(sorted) do
    at = fn q -> Enum.at(sorted, min(length(sorted) - 1, trunc(q * length(sorted)))) end
    %{p50: at.(0.5), p95: at.(0.95), max: List.last(sorted)}
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp pct(rate), do: "#{Float.round(rate * 100, 1)}%"
end
