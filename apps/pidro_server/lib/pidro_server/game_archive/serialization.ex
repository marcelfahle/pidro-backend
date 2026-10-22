defmodule PidroServer.GameArchive.Serialization do
  @moduledoc "Version 1 data-only JSON. Never reconstructs executable Erlang terms."

  @doc "Encodes game facts, rejecting runtime resources rather than inspecting them."
  @spec encode(term()) :: term()
  def encode(nil), do: nil
  def encode(value) when is_boolean(value) or is_binary(value) or is_float(value), do: value
  def encode(value) when is_integer(value) and abs(value) <= 9_007_199_254_740_991, do: value
  def encode(value) when is_integer(value), do: %{"$integer" => Integer.to_string(value)}
  def encode(value) when is_atom(value), do: Atom.to_string(value)
  def encode(%DateTime{} = value), do: DateTime.to_iso8601(value)
  def encode(%MapSet{} = value), do: %{"$set" => encode(MapSet.to_list(value))}

  def encode(%module{} = value) do
    value |> Map.from_struct() |> encode() |> Map.put("$struct", Atom.to_string(module))
  end

  def encode(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key(key), encode(item)} end)
  end

  def encode(value) when is_tuple(value), do: %{"$tuple" => encode(Tuple.to_list(value))}
  def encode(value) when is_list(value), do: encode_list(value, [])
  def encode(_), do: raise(ArgumentError, "unsupported archive value")

  defp key(value) when is_atom(value), do: Atom.to_string(value)
  defp key(value) when is_binary(value), do: value
  defp key(value) when is_integer(value), do: Integer.to_string(value)
  defp key(_), do: raise(ArgumentError, "unsupported archive key")

  defp encode_list([], acc), do: Enum.reverse(acc)
  defp encode_list([head | tail], acc), do: encode_list(tail, [encode(head) | acc])

  defp encode_list(tail, acc),
    do: %{"$improper_list" => Enum.reverse(acc), "$tail" => encode(tail)}
end
