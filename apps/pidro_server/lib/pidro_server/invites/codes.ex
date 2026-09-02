defmodule PidroServer.Invites.Codes do
  @moduledoc """
  Pure generation and normalization of invite codes (R2, KTD2).

  An invite code is an 8-symbol secret drawn from the Crockford Base32
  alphabet: the digits `0-9` and the letters `A-Z` without `I`, `L`, `O` and
  `U` (32 symbols, 32⁸ ≈ 1.1 × 10¹² codes). Unlike a 4-character room code it
  is not meant to be guessed, so it is long; unlike a token it is meant to be
  read aloud or typed from a screenshot, so the confusable letters are left out
  and mapped back on input: `I` and `L` read as `1`, `O` reads as `0`.

  Symbols come from `:crypto.strong_rand_bytes/1`, one symbol per byte via
  `rem(byte, 32)`. That is uniform without rejection sampling because 256 is an
  exact multiple of 32: every symbol is hit by exactly eight byte values.
  (`PidroServer.Games.RoomCodes` needs rejection for its 36-symbol alphabet;
  this alphabet does not.) Guest usernames reuse `generate/0` too.

  ## Examples

      iex> PidroServer.Invites.Codes.normalize("7kq4-m2xb")
      {:ok, "7KQ4M2XB"}

      iex> PidroServer.Invites.Codes.normalize("oLQ4M2XI")
      {:ok, "01Q4M2X1"}

      iex> PidroServer.Invites.Codes.normalize("7KQ4M2XU")
      :error

      iex> PidroServer.Invites.Codes.dashed("7KQ4M2XB")
      "7KQ4-M2XB"
  """

  @alphabet_string "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
  @alphabet @alphabet_string |> String.to_charlist() |> List.to_tuple()
  @alphabet_size tuple_size(@alphabet)
  @code_length 8
  @code_format ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/

  @doc "The 32-symbol alphabet codes are drawn from, as a string."
  @spec alphabet() :: String.t()
  def alphabet, do: @alphabet_string

  @doc "Number of symbols in an invite code."
  @spec code_length() :: pos_integer()
  def code_length, do: @code_length

  @doc """
  Draws one upper-case code of `code_length/0` symbols from the CSPRNG.
  """
  @spec generate() :: String.t()
  def generate do
    for <<byte <- :crypto.strong_rand_bytes(@code_length)>>, into: "" do
      <<elem(@alphabet, rem(byte, @alphabet_size))>>
    end
  end

  @doc """
  Normalizes user input into a canonical code for lookup.

  Strips `-`, upcases, maps `I` and `L` to `1` and `O` to `0`, then answers
  `{:ok, code}` for exactly `code_length/0` alphabet symbols and `:error` for
  anything else, including non-strings.
  """
  @spec normalize(term()) :: {:ok, String.t()} | :error
  def normalize(input) when is_binary(input) do
    code =
      input
      |> String.replace("-", "")
      |> String.upcase()
      |> String.replace(["I", "L"], "1")
      |> String.replace("O", "0")

    if valid?(code), do: {:ok, code}, else: :error
  end

  def normalize(_input), do: :error

  @doc "Whether `code` is exactly `code_length/0` upper-case alphabet symbols."
  @spec valid?(term()) :: boolean()
  def valid?(code) when is_binary(code), do: Regex.match?(@code_format, code)
  def valid?(_code), do: false

  @doc "Renders a canonical code as two groups of four for humans: `XXXX-XXXX`."
  @spec dashed(String.t()) :: String.t()
  def dashed(<<head::binary-size(4), tail::binary-size(4)>>), do: head <> "-" <> tail
end
