defmodule Pidro.Bot.Thresholds do
  @moduledoc """
  Every constant the rulebook bot bids by, in one place.

  A suit's bid estimate sums sure points, the held Fives weighted by how
  protected they are, half-credit for the Jack and Ten, a bonus for holding
  the top trumps, and a bonus for the dealer. The bot bids the estimate
  rounded down.

  No quantified Pidro bidding thresholds exist in writing. The starting values
  were adapted from Cinch and Setback conventions, then calibrated in
  self-play (`mix pidro.selfplay`) with four rulebook seats. Two changed: a
  protected Five counts 3, not 5, and one top trump earns the control bonus
  from three trumps, not four. With the starting values, rulebook teams made
  67% of their bids against each other; with these they make 77%, and the
  calibrated bidder beats the starting one in 54% of games. No other single
  change improved on that. Community answers are expected to tune them
  further.
  """

  @values %{
    ace: 1,
    two: 1,
    jack_or_ten: 0.5,
    five_protected: 3,
    five_unprotected: 2,
    five_protection_trumps: 4,
    five_protection_trumps_with_honour: 3,
    control_ace_king: 3,
    control_one_honour: 2,
    control_one_honour_min_trumps: 3,
    dealer_bonus: 1,
    overbid_partner_margin: 2
  }

  @typedoc "The name of a bidding constant."
  @type name ::
          :ace
          | :two
          | :jack_or_ten
          | :five_protected
          | :five_unprotected
          | :five_protection_trumps
          | :five_protection_trumps_with_honour
          | :control_ace_king
          | :control_one_honour
          | :control_one_honour_min_trumps
          | :dealer_bonus
          | :overbid_partner_margin

  @doc """
  Returns the value of one bidding constant.

  - `:ace`, `:two` - sure points for holding the Ace or the 2 of the suit
  - `:jack_or_ten` - half-credit for each of the Jack and the Ten
  - `:five_protected` / `:five_unprotected` - value of each held Five
  - `:five_protection_trumps` - trumps held, the Five included, that protect it
  - `:five_protection_trumps_with_honour` - the same with the Ace or King held
  - `:control_ace_king` - bonus for the Ace and King together
  - `:control_one_honour` - bonus for one of them with enough length
  - `:control_one_honour_min_trumps` - the length that bonus needs
  - `:dealer_bonus` - added when the bidder is the dealer, who robs the pack
  - `:overbid_partner_margin` - how far above partner's bid the estimate must
    reach before the bot overbids partner

  ## Examples

      iex> Pidro.Bot.Thresholds.get(:overbid_partner_margin)
      2
  """
  @spec get(name()) :: number()
  def get(name), do: Map.fetch!(@values, name)

  @doc """
  Returns all bidding constants.
  """
  @spec all() :: %{name() => number()}
  def all, do: @values
end
