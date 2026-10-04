defmodule PidroServer.Accounts.AgeTermsTest do
  use PidroServer.DataCase, async: true

  alias Ecto.Changeset
  alias PidroServer.Accounts.AgeTerms

  test "optional requests with neither field remain backward compatible" do
    assert {:ok, nil} = AgeTerms.parse(%{})
  end

  test "accepts the two eligible bands and a bounded terms version" do
    for band <- ["13_17", "18_plus"] do
      assert {:ok, %{age_band: ^band, terms_version: "1"}} =
               AgeTerms.parse(%{"age_band" => band, "terms_version" => "1"})
    end
  end

  test "always refuses the under-13 band" do
    assert {:error, :age_not_eligible} =
             AgeTerms.parse(%{"age_band" => "under_13", "terms_version" => ""})
  end

  test "returns changesets for invalid age and terms values" do
    for params <- [
          %{"age_band" => "unknown"},
          %{"age_band" => nil},
          %{"age_band" => 18},
          %{"terms_version" => ""},
          %{"terms_version" => 1},
          %{"terms_version" => String.duplicate("x", 33)}
        ] do
      assert {:error, %Changeset{valid?: false}} = AgeTerms.parse(params)
    end
  end

  test "the declaration endpoint requires age_band" do
    assert {:error, %Changeset{valid?: false}} = AgeTerms.parse(%{}, required: true)

    assert {:error, %Changeset{valid?: false}} =
             AgeTerms.parse(%{"terms_version" => "1"}, required: true)
  end
end
