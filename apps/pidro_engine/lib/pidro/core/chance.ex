defmodule Pidro.Core.Chance do
  @moduledoc """
  The engine's explicit chance stream.

  Every random draw the game domain makes is derived from a value carried in
  `%GameState{}` — never from the calling process's `:rand` dictionary. This
  module is the only place in `lib/pidro/core/`, `lib/pidro/game/` and
  `lib/pidro/finnish/` that is allowed to mention `:rand`, it uses the
  explicit-state API exclusively, and **it is entirely pure**: it generates no
  entropy of its own. Entropy is generated at the runtime boundary, in
  `Pidro.Server`.

  ## The value

  A chance value is an exported `:rand` state — `{algorithm, algorithm_state}`.
  For the `:exsss` algorithm this is an atom and two integers:

      {:exsss, [117085240290607817 | 199386643319833935]}

  It contains no funs, no PIDs and no references, so it survives
  `:erlang.term_to_binary/1` and can be restored in another process, which is
  what makes a saved `%GameState{}` resumable.

  ## The contract

  Every function that draws returns the advanced chance state alongside the
  value, so a caller cannot obtain a random value without also receiving the
  stream it must store back:

      {cuts, chance} = Chance.cut_cards([:north, :east, :south, :west], state.chance)
      {deck, chance} = Chance.shuffle(Deck.ordered(), chance)

      state
      |> GameState.update(:deck, deck)
      |> GameState.update(:chance, chance)

  ## Reproducibility

  The sequence a seed produces is stable for a given engine version on the
  supported OTP version (see `.tool-versions`). It is not a cross-release or
  cross-implementation guarantee: the algorithm is pinned by name here, but a
  change to `:rand`, to `shuffle_s/2`'s internals, or to this module will
  legitimately change the cards a seed deals.

  Note also that `:exsss` is a simulation-quality generator, not a
  cryptographic one. Seeding it from `:crypto.strong_rand_bytes/1` — which
  `Pidro.Server` does for live games — makes the starting point unpredictable;
  it does not make the generator itself resistant to prediction.
  """

  alias Pidro.Core.Types

  @typedoc """
  An exported `:rand` state — the value carried in `GameState.chance`.
  """
  @type t :: Types.chance()

  @typedoc """
  Anything `:rand.seed_s/2` accepts as a seed for a named algorithm.
  """
  @type seed :: integer() | {integer(), integer(), integer()}

  # Pinned by name rather than taken from `:rand`'s default, which has changed
  # twice across OTP releases.
  @algorithm :exsss

  @doc """
  Builds a chance value from a seed.

  Pure: the same seed always produces the same chance value, and the calling
  process's `:rand` dictionary is neither read nor written.

  ## Examples

      iex> alias Pidro.Core.Chance
      iex> Chance.from_seed(7) == Chance.from_seed(7)
      true

      iex> alias Pidro.Core.Chance
      iex> {algorithm, _state} = Chance.from_seed({1, 2, 3})
      iex> algorithm
      :exsss
  """
  @spec from_seed(seed()) :: t()
  def from_seed(seed) when is_integer(seed) or is_tuple(seed) do
    @algorithm
    |> :rand.seed_s(seed)
    |> :rand.export_seed_s()
  end

  @doc """
  Shuffles `items`, returning the shuffled list and the advanced chance value.

  ## Examples

      iex> alias Pidro.Core.Chance
      iex> {shuffled, advanced} = Chance.shuffle([1, 2, 3, 4, 5], Chance.from_seed(7))
      iex> Enum.sort(shuffled)
      [1, 2, 3, 4, 5]
      iex> advanced == Chance.from_seed(7)
      false
  """
  @spec shuffle([term()], t()) :: {[term()], t()}
  def shuffle(items, chance) when is_list(items) do
    {shuffled, advanced} = :rand.shuffle_s(items, :rand.seed_s(chance))
    {shuffled, :rand.export_seed_s(advanced)}
  end

  @doc """
  Draws an integer in `1..n`, returning it with the advanced chance value.

  ## Examples

      iex> alias Pidro.Core.Chance
      iex> {value, _advanced} = Chance.uniform(6, Chance.from_seed(7))
      iex> value in 1..6
      true
  """
  @spec uniform(pos_integer(), t()) :: {pos_integer(), t()}
  def uniform(n, chance) when is_integer(n) and n > 0 do
    {value, advanced} = :rand.uniform_s(n, :rand.seed_s(chance))
    {value, :rand.export_seed_s(advanced)}
  end

  @doc """
  Draws one cut card per position for the dealer-selection ceremony.

  Each cut is an independently generated `{rank, suit}` pair rather than a draw
  from a deck, so two seats can cut the same rank or the identical card. That
  is the behaviour the ceremony has always had; this function only changes
  where the draws come from.

  Returns the cuts in the order the positions were given, paired with the
  advanced chance value.

  ## Examples

      iex> alias Pidro.Core.Chance
      iex> {cuts, _advanced} = Chance.cut_cards([:north, :south], Chance.from_seed(7))
      iex> Enum.map(cuts, fn {position, _card} -> position end)
      [:north, :south]
      iex> Enum.all?(cuts, fn {_position, {rank, suit}} ->
      ...>   rank in 2..14 and suit in [:hearts, :diamonds, :clubs, :spades]
      ...> end)
      true
  """
  @spec cut_cards([Types.position()], t()) :: {[{Types.position(), Types.card()}], t()}
  def cut_cards(positions, chance) when is_list(positions) do
    suits = Types.all_suits()

    Enum.map_reduce(positions, chance, fn position, acc ->
      {rank_offset, acc} = uniform(13, acc)
      {suit_index, acc} = uniform(length(suits), acc)

      {{position, {rank_offset + 1, Enum.at(suits, suit_index - 1)}}, acc}
    end)
  end
end
