defmodule PidroServer.Games.RoomCodes do
  @moduledoc """
  Pure generation of room codes.

  A room code is a 4-character display handle drawn from the uppercase alphabet
  `A-Z0-9` (36 symbols, 36⁴ ≈ 1.68 million codes). It is what players type or
  read aloud to find a table; it is not a secret, so it stays short and
  typeable. Uppercase is mandatory because every `RoomManager` lookup upcases
  its argument before matching.

  Codes are drawn from `:crypto.strong_rand_bytes/1` with rejection sampling:
  a byte at or above 252 (the largest multiple of 36 that fits in a byte) is
  discarded, so `rem(byte, 36)` is uniform over the alphabet and no symbol is
  favoured.

  `generate_unique/3` layers a bounded collision retry on top of `random/0`.
  It carries no process state: the caller supplies the `taken?` predicate
  (`RoomManager` checks its live room map from inside the `:create_room`
  callback, so the check and the insert are serialized) and may supply a
  generator, which is how tests force collisions. Uniqueness is only among
  live rooms; historical codes in `game_stats` may recur.

  ## Examples

      code = RoomCodes.random()
      #=> "K7Q2"

      RoomCodes.generate_unique(&Map.has_key?(rooms, &1))
      #=> {:ok, "K7Q2"} or {:error, :room_code_exhausted}
  """

  @alphabet_string "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
  @alphabet @alphabet_string |> String.to_charlist() |> List.to_tuple()
  @alphabet_size tuple_size(@alphabet)
  @code_length 4
  # Largest multiple of the alphabet size that fits in one byte. Bytes at or
  # above it are discarded so `rem(byte, @alphabet_size)` carries no bias.
  @rejection_threshold div(256, @alphabet_size) * @alphabet_size
  @default_attempts 10

  @typedoc "Predicate answering whether a candidate code is already in use."
  @type taken_fun :: (String.t() -> boolean())

  @typedoc "Zero-arity function producing one candidate code."
  @type generator :: (-> String.t())

  @doc "The 36-symbol alphabet codes are drawn from, as a string."
  @spec alphabet() :: String.t()
  def alphabet, do: @alphabet_string

  @doc "Number of characters in a room code."
  @spec code_length() :: pos_integer()
  def code_length, do: @code_length

  @doc "Default collision retry bound used by `generate_unique/3`."
  @spec default_attempts() :: pos_integer()
  def default_attempts, do: @default_attempts

  @doc """
  Draws one uppercase alphanumeric code from the CSPRNG without modulo bias.
  """
  @spec random() :: String.t()
  def random, do: random_chars(@code_length, [])

  @doc """
  Generates a code that `taken?` does not reject, retrying up to `attempts`
  times.

  Returns `{:ok, code}` on the first free draw, or `{:error, :room_code_exhausted}`
  once `attempts` draws have all been taken. `generator` defaults to `random/0`;
  tests pass a deterministic function to force collisions.
  """
  @spec generate_unique(taken_fun(), non_neg_integer(), generator()) ::
          {:ok, String.t()} | {:error, :room_code_exhausted}
  def generate_unique(taken?, attempts \\ @default_attempts, generator \\ &random/0)

  def generate_unique(_taken?, 0, _generator), do: {:error, :room_code_exhausted}

  def generate_unique(taken?, attempts, generator)
      when is_function(taken?, 1) and is_integer(attempts) and attempts > 0 and
             is_function(generator, 0) do
    code = generator.()

    if taken?.(code) do
      generate_unique(taken?, attempts - 1, generator)
    else
      {:ok, code}
    end
  end

  defp random_chars(0, acc), do: List.to_string(acc)

  defp random_chars(remaining, acc) do
    accepted =
      for <<byte <- :crypto.strong_rand_bytes(remaining)>>, byte < @rejection_threshold do
        elem(@alphabet, rem(byte, @alphabet_size))
      end

    random_chars(remaining - length(accepted), accepted ++ acc)
  end
end
