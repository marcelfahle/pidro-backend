defmodule PidroServer.Invites.CodesTest do
  use ExUnit.Case, async: true

  alias PidroServer.Invites.Codes

  doctest Codes

  @code_format ~r/\A[0-9A-HJKMNP-TV-Z]{8}\z/
  @draws 10_000

  describe "generate/0" do
    test "returns 8 symbols from the Crockford alphabet and never I, L, O or U" do
      codes = Enum.map(1..@draws, fn _ -> Codes.generate() end)

      assert Enum.all?(codes, &Regex.match?(@code_format, &1))

      seen = codes |> Enum.join() |> String.graphemes() |> MapSet.new()
      expected = Codes.alphabet() |> String.graphemes() |> MapSet.new()

      assert seen == expected
      refute Enum.any?(~w(I L O U), &MapSet.member?(seen, &1))
    end

    test "10,000 draws produce no duplicate" do
      codes = Enum.map(1..@draws, fn _ -> Codes.generate() end)

      assert codes |> Enum.uniq() |> length() == @draws
    end
  end

  describe "normalize/1" do
    test "strips dashes and upcases" do
      assert Codes.normalize("7kq4-m2xb") == {:ok, "7KQ4M2XB"}
    end

    test "maps I to 1" do
      assert Codes.normalize("7KQ4-M2XI") == {:ok, "7KQ4M2X1"}
    end

    test "maps o to 0 and l to 1 after upcasing" do
      assert Codes.normalize("oLQ4M2XB") == {:ok, "01Q4M2XB"}
    end

    test "returns a canonical code unchanged" do
      assert Codes.normalize("7KQ4M2XB") == {:ok, "7KQ4M2XB"}
    end

    test "rejects 7 symbols" do
      assert Codes.normalize("7KQ4M2X") == :error
    end

    test "rejects 9 symbols" do
      assert Codes.normalize("7KQ4-M2XB1") == :error
    end

    test "rejects U, which is outside the alphabet" do
      assert Codes.normalize("7KQ4M2XU") == :error
    end

    test "rejects symbols outside the alphabet and non-strings" do
      assert Codes.normalize("7KQ4M2X!") == :error
      assert Codes.normalize("") == :error
      assert Codes.normalize(nil) == :error
      assert Codes.normalize(12_345_678) == :error
    end
  end

  describe "valid?/1" do
    test "accepts exactly 8 upper-case alphabet symbols" do
      assert Codes.valid?("7KQ4M2XB")
      assert Codes.valid?("00000000")
    end

    test "rejects lower case, dashes, wrong length and excluded letters" do
      refute Codes.valid?("7kq4m2xb")
      refute Codes.valid?("7KQ4-M2XB")
      refute Codes.valid?("7KQ4M2X")
      refute Codes.valid?("7KQ4M2XI")
      refute Codes.valid?("7KQ4M2XL")
      refute Codes.valid?("7KQ4M2XO")
      refute Codes.valid?("7KQ4M2XU")
      refute Codes.valid?(nil)
    end
  end

  describe "dashed/1" do
    test "splits a code into two groups of four" do
      assert Codes.dashed("7KQ4M2XB") == "7KQ4-M2XB"
    end
  end
end
