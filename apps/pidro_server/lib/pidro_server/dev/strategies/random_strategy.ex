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
    this function returns a tuple containing the randomly selected action and reasoning
    explaining the choice.

    ## Parameters

      - `legal_actions` - A list of valid actions the bot can take. Examples:
        - `[{:bid, 6}, {:bid, 7}, :pass]` during bidding phase
        - `[{:play_card, {14, :spades}}, {:play_card, {13, :hearts}}]` during play phase
        - `[{:declare_trump, :spades}, {:declare_trump, :hearts}]` for trump declaration
      - `game_state` - The current game state (not used by random strategy)

    ## Returns

      A tuple `{:ok, action, reasoning}` where:
      - `action` - The randomly selected action from `legal_actions`
      - `reasoning` - A string explaining why this action was chosen

    ## Examples

        iex> legal_actions = [{:bid, 6}, {:bid, 7}, :pass]
        iex> {:ok, action, reasoning} = PidroServer.Dev.Strategies.RandomStrategy.pick_action(legal_actions, %{})
        iex> action in legal_actions
        true
        iex> is_binary(reasoning)
        true

        iex> legal_actions = [{:play_card, {14, :spades}}]
        iex> {:ok, action, _reasoning} = PidroServer.Dev.Strategies.RandomStrategy.pick_action(legal_actions, %{})
        iex> action
        {:play_card, {14, :spades}}

    ## Raises

      - `Enum.EmptyError` if `legal_actions` is empty
    """
    @spec pick_action(list(), map()) :: {:ok, term(), String.t()}
    def pick_action(legal_actions, _game_state) do
      action = Enum.random(legal_actions)

      reasoning =
        "Randomly selected from #{length(legal_actions)} legal action#{if length(legal_actions) == 1, do: "", else: "s"}"

      {:ok, action, reasoning}
    end
  end
end
