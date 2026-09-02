defmodule PidroServer.Games.RoomCodesTest do
  use ExUnit.Case, async: true

  alias PidroServer.Games.RoomCodes

  @code_format ~r/\A[A-Z0-9]{4}\z/

  describe "random/0" do
    test "5,000 codes are 4 uppercase alphanumerics and cover the whole alphabet" do
      codes = Enum.map(1..5_000, fn _ -> RoomCodes.random() end)

      assert Enum.all?(codes, &Regex.match?(@code_format, &1))

      seen = codes |> Enum.join() |> String.graphemes() |> MapSet.new()
      expected = RoomCodes.alphabet() |> String.graphemes() |> MapSet.new()

      assert seen == expected
    end
  end

  describe "generate_unique/3" do
    test "returns the first drawn code when nothing is taken" do
      assert {:ok, code} = RoomCodes.generate_unique(fn _code -> false end)
      assert Regex.match?(@code_format, code)
    end

    test "draws again when taken? rejects the first sampled code" do
      generator = sequence_generator(["AAAA", "BBBB"])
      taken? = fn code -> code == "AAAA" end

      assert {:ok, "BBBB"} = RoomCodes.generate_unique(taken?, 10, generator)
    end

    test "gives up after exactly the attempt bound when every code is taken" do
      calls = :counters.new(1, [])

      generator = fn ->
        :counters.add(calls, 1, 1)
        "ZZZZ"
      end

      assert {:error, :room_code_exhausted} =
               RoomCodes.generate_unique(fn _code -> true end, 10, generator)

      assert :counters.get(calls, 1) == 10
    end

    test "defaults the attempt bound to 10" do
      calls = :counters.new(1, [])

      generator = fn ->
        :counters.add(calls, 1, 1)
        "ZZZZ"
      end

      assert {:error, :room_code_exhausted} =
               RoomCodes.generate_unique(
                 fn _code -> true end,
                 RoomCodes.default_attempts(),
                 generator
               )

      assert :counters.get(calls, 1) == 10
    end
  end

  # Returns a zero-arity generator that yields `codes` in order and then
  # repeats the last one forever.
  defp sequence_generator(codes) do
    index = :counters.new(1, [])
    codes = List.to_tuple(codes)

    fn ->
      position = :counters.get(index, 1)
      :counters.add(index, 1, 1)
      elem(codes, min(position, tuple_size(codes) - 1))
    end
  end
end
