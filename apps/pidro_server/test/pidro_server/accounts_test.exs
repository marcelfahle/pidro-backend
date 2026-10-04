defmodule PidroServer.AccountsTest do
  use ExUnit.Case, async: true

  alias PidroServer.Accounts

  test "rejects blocked names across case, spacing, punctuation and compatibility forms" do
    refute Accounts.public_name_allowed?("Fuckface")
    refute Accounts.public_name_allowed?("  FUCK FACE  ")
    refute Accounts.public_name_allowed?("fuck-face")
    refute Accounts.public_name_allowed?("f.u.c.k")
    refute Accounts.public_name_allowed?("ＦＵＣＫ")
    refute Accounts.public_name_allowed?("kyr.pä")
  end

  test "allows legitimate names that merely contain a blocked substring" do
    assert Accounts.public_name_allowed?("Scunthorpe")
    assert Accounts.public_name_allowed?("Classical Hero")
  end

  test "uses display-name formatting rules after collapsing separator whitespace" do
    assert Accounts.public_name_allowed?("  Nordic   Moose  ")
    refute Accounts.public_name_allowed?(nil)
    refute Accounts.public_name_allowed?("A")
    refute Accounts.public_name_allowed?(String.duplicate("a", 21))
    refute Accounts.public_name_allowed?("Nordic\tMoose")
  end
end
