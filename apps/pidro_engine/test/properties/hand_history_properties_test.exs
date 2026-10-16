defmodule Pidro.Properties.HandHistoryPropertiesTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Pidro.Test.GameTrace

  property "hand history gains each scored hand, whose point cards add up to what each team captured" do
    check all(
            seed <- integer(1..1_000_000),
            variant <- member_of([:finnish, :louisiana]),
            max_runs: 50
          ) do
      trace = GameTrace.states(seed, variant: variant)

      for [before, next] <- Enum.chunk_every(trace, 2, 1, :discard) do
        if next.hand_history == before.hand_history do
          assert Enum.count(next.events, &match?({:hand_scored, _, _}, &1)) ==
                   Enum.count(before.events, &match?({:hand_scored, _, _}, &1))
        else
          assert next.hand_history ==
                   before.hand_history ++ [Map.drop(next.last_hand, [:bids, :tricks])]

          for team <- [:north_south, :east_west] do
            assert next.last_hand.point_cards
                   |> Enum.filter(&(&1.team == team))
                   |> Enum.map(& &1.points)
                   |> Enum.sum() == next.last_hand.captured[team]
          end
        end
      end

      final = List.last(trace)
      assert final.phase == :complete
      assert Enum.map(final.hand_history, & &1.hand_number) == Enum.to_list(1..final.hand_number)
      assert List.last(final.hand_history).scores == final.cumulative_scores
    end
  end
end
