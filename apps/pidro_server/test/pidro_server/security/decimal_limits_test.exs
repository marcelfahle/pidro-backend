defmodule PidroServer.Security.DecimalLimitsTest do
  use ExUnit.Case, async: true

  # These bounds protect against CVE-2026-32686; retain them while the
  # version-scoped advisory exception in the umbrella mix.exs is needed.
  test "rejects an attacker-controlled oversized exponent" do
    assert Decimal.parse("1e1000000000") == :error
    assert Decimal.parse("1e6145") == :error
    assert Decimal.parse("1e-6145") == :error
  end

  test "rejects oversized coefficients while accepting normal decimals" do
    assert Decimal.parse(String.duplicate("9", 35)) == :error
    assert {value, ""} = Decimal.parse("123.45")
    assert Decimal.equal?(value, Decimal.new("123.45"))
  end
end
