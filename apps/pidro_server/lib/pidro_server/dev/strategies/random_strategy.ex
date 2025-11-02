if Mix.env() == :dev do
  defmodule PidroServer.Dev.Strategies.RandomStrategy do
    @moduledoc """
    Simple random decision-making strategy for bot players.

    This module implements a basic strategy that makes bot decisions by randomly
    selecting from the available legal actions. It is useful for testing and
    development purposes.

    ## Usage

        # Get a random action from legal actions during bidding
        action = RandomStrategy.pick_action([{:bid, 6}, {:bid, 7}, :pass], game_state)
        # => {:bid, 7}  (randomly selected)

        # Get a random action during card play
        action = RandomStrategy.pick_action([{:play_card, {14, :spades}}, {:play_card, {13, :hearts}}], game_state)
        # => {:play_card, {14, :spades}}  (randomly selected)

        # Get a random action for trump declaration
        action = RandomStrategy.pick_action([{:declare_trump, :spades}, {:declare_trump, :hearts}], game_state)
        # => {:declare_trump, :hearts}  (randomly selected)

    ## Behavior

    This strategy always selects uniformly at random from the legal actions,
    regardless of game state or position. It does not employ any strategic logic
    or learning.
    """

    @doc """
    Selects a random action from the list of legal actions.

    Given a list of legal actions available to a bot player and the current game state,
    this function returns a randomly selected action. The game_state parameter is
    provided for API consistency with other strategies that may require it, but is
    not used by this implementation.

    ## Parameters

      - `legal_actions` - A list of valid actions the bot can take. Examples:
        - `[{:bid, 6}, {:bid, 7}, :pass]` during bidding phase
        - `[{:play_card, {14, :spades}}, {:play_card, {13, :hearts}}]` during play phase
        - `[{:declare_trump, :spades}, {:declare_trump, :hearts}]` for trump declaration
      - `game_state` - The current game state (not used by random strategy)

    ## Returns

      An action randomly selected from `legal_actions`. The return type depends
      on the phase and available actions:
      - A tuple like `{:bid, 6}` during bidding
      - A tuple like `{:play_card, {14, :spades}}` during play
      - A tuple like `{:declare_trump, :spades}` for trump declaration
      - An atom like `:pass` when passing is an option

    ## Examples

        iex> legal_actions = [{:bid, 6}, {:bid, 7}, :pass]
        iex> action = PidroServer.Dev.Strategies.RandomStrategy.pick_action(legal_actions, %{})
        iex> action in legal_actions
        true

        iex> legal_actions = [{:play_card, {14, :spades}}]
        iex> PidroServer.Dev.Strategies.RandomStrategy.pick_action(legal_actions, %{})
        {:play_card, {14, :spades}}

    ## Raises

      - `Enum.EmptyError` if `legal_actions` is empty
    """
    @spec pick_action(list(), map()) :: term()
    def pick_action(legal_actions, _game_state) do
      Enum.random(legal_actions)
    end
  end
end
