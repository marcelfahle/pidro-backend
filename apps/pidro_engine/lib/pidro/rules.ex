defmodule Pidro.Rules do
  @moduledoc "Rules that differ between Pidro variants; numeric settings remain plain config data."

  alias Pidro.Core.Types

  @callback legal_plays([Types.card()], Types.suit(), Types.suit() | nil) :: [Types.card()]
  @callback winner([{Types.position(), Types.card()}, ...], Types.suit()) :: Types.position()
  @callback eliminate?([Types.card()], Types.suit()) :: boolean()

  @doc "Resolves a game's variant to its rules module."
  @spec for_variant(atom()) :: module()
  def for_variant(:finnish), do: Pidro.Rules.Finnish

  @doc "Default config for a variant, before caller overrides."
  @spec defaults(atom()) :: map()
  def defaults(:finnish) do
    %{
      min_bid: 6,
      max_bid: 14,
      winning_score: 62,
      initial_deal_count: 9,
      final_hand_size: 6,
      allow_negative_scores: true
    }
  end
end
