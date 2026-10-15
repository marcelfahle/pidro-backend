defmodule PidroServerWeb.ErrorContractTest do
  use ExUnit.Case, async: true

  alias PidroServerWeb.ErrorContract

  test "published codes and parameter schemas describe the emitted contract" do
    manifest =
      __DIR__
      |> Path.join("../../../../docs/contracts/localization-errors.json")
      |> File.read!()
      |> Jason.decode!()

    codes = Enum.map(manifest["errors"], & &1["code"])
    assert Enum.uniq(codes) == codes

    parameterized = %{
      "seat_requires_games" => {:seat_requires_games, 1000, 37},
      "rate_limited" => {:rate_limited, 42},
      "field_too_short" => {:field_too_short, 3},
      "field_too_long" => {:field_too_long, 20},
      "field_wrong_length" => {:field_wrong_length, 6}
    }

    for entry <- manifest["errors"] do
      assert entry["code"] =~ ~r/\A[a-z][a-z0-9_]*\z/
      assert is_binary(entry["meaning"]) and entry["meaning"] != ""
      assert entry["sources"] != []
      assert Enum.all?(entry["sources"], &Map.has_key?(manifest["sources"], &1))

      # This is trusted committed fixture data, never user input.
      reason = Map.get(parameterized, entry["code"], String.to_existing_atom(entry["code"]))
      result = ErrorContract.add(%{}, reason)
      assert result.error_code == entry["code"]
      params = Jason.decode!(Jason.encode!(result.error_params))
      assert Enum.sort(Map.keys(params)) == Enum.sort(Map.keys(entry["params"]))

      assert Enum.all?(entry["params"], fn {name, schema} ->
               schema == %{"type" => "integer"} and is_integer(params[name])
             end)
    end
  end

  test "unknown reasons never become codes or interpolation data" do
    for reason <- [
          :unexpected_failure,
          "not_your_turn",
          "database password=private",
          {:unexpected_failure, %{token: "private"}},
          %RuntimeError{message: "private"},
          {},
          {:seat_requires_games, "private", 12},
          {:rate_limited, "private"},
          {:field_too_long, "private"}
        ],
        fallback <- [:request_failed, :action_failed] do
      assert ErrorContract.add(%{reason: "legacy reason"}, reason, fallback) == %{
               reason: "legacy reason",
               error_code: Atom.to_string(fallback),
               error_params: %{}
             }
    end

    assert ErrorContract.add(%{}, {:invalid_action, %{token: "private"}, :playing}) == %{
             error_code: "invalid_action",
             error_params: %{}
           }

    assert ErrorContract.add(%{}, {:seat_requires_games, 1000, 37}).error_params == %{
             min_games: 1000,
             games_played: 37
           }
  end

  test "validation uses metadata, not English, and never copies arbitrary options" do
    changeset =
      Ecto.Changeset.change(%PidroServer.Accounts.User{})
      |> Ecto.Changeset.add_error(:username, "opaque", validation: :required)
      |> Ecto.Changeset.add_error(:email, "opaque", constraint: :unique, token: "private")
      |> Ecto.Changeset.add_error(:password, "opaque", validation: :length, kind: :min, count: 8)
      |> Ecto.Changeset.add_error(:display_name, "opaque", code: :classic_name_reserved)
      |> Ecto.Changeset.add_error(:bio, "can't be blank", validation: :unknown, value: "private")

    legacy = %{errors: [%{code: "unchanged", detail: "legacy"}]}
    response = ErrorContract.validation(legacy, changeset)
    assert Map.drop(response, [:error_code, :error_params, :field_errors]) == legacy
    assert response.error_code == "validation_failed"

    assert Enum.sort_by(response.field_errors, & &1.field) == [
             %{field: "bio", error_code: "field_invalid", error_params: %{}},
             %{field: "display_name", error_code: "classic_name_reserved", error_params: %{}},
             %{field: "email", error_code: "field_taken", error_params: %{}},
             %{field: "password", error_code: "field_too_short", error_params: %{count: 8}},
             %{field: "username", error_code: "field_required", error_params: %{}}
           ]
  end
end
