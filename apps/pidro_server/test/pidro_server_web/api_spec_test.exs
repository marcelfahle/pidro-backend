defmodule PidroServerWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PidroServerWeb.ApiSpec
  alias PidroServerWeb.Schemas.{ErrorSchemas, UserSchemas}

  @new_paths [
    {"/api/v1/invites/deferred", ["post"]},
    {"/api/v1/invites/{code}", ["get", "delete"]},
    {"/api/v1/invites/{code}/redeem", ["post"]},
    {"/api/v1/invites/{code}/regenerate", ["post"]},
    {"/api/v1/rooms/{code}/invites", ["post"]},
    {"/api/v1/rooms/{code}/seat", ["post"]},
    {"/api/v1/rooms/{code}/lock", ["post"]},
    {"/api/v1/rooms/{code}/kick", ["post"]},
    {"/api/v1/auth/guest", ["post"]},
    {"/api/v1/auth/upgrade", ["post"]},
    {"/api/v1/auth/me", ["get", "delete"]}
  ]

  test "the spec builds without warnings and lists every phase-1 path with its operations" do
    {spec, warnings} = with_io(:stderr, fn -> ApiSpec.spec() end)

    assert warnings == ""
    assert %OpenApiSpex.OpenApi{paths: paths} = spec

    for {path, methods} <- @new_paths do
      assert %OpenApiSpex.PathItem{} = item = Map.get(paths, path), "missing path #{path}"

      for method <- methods do
        assert %OpenApiSpex.Operation{operationId: id} =
                 Map.get(item, String.to_existing_atom(method)),
               "missing #{method} on #{path}"

        assert is_binary(id)
      end
    end
  end

  test "the info text documents the new statuses and rate-limit policies" do
    description = ApiSpec.spec().info.description

    for status <- ["409 Conflict", "410 Gone", "423 Locked"] do
      assert description =~ status
    end

    for policy <-
          ~w(invite_mint invite_preview invite_capture invite_capture_code invite_deferred
             invite_deferred_install invite_redeem guest_create guest_create_daily
             guest_create_install room_join auth_upgrade) do
      assert description =~ "`#{policy}`"
    end
  end

  test "invite error schemas declare their conditional navigation fields" do
    assert %OpenApiSpex.Schema{properties: %{errors: conflict_errors}} =
             ErrorSchemas.conflict_error()

    assert %OpenApiSpex.Schema{items: %OpenApiSpex.Schema{properties: conflict_properties}} =
             conflict_errors

    assert %OpenApiSpex.Schema{type: :array} = conflict_properties.next_open

    assert %OpenApiSpex.Schema{properties: %{errors: gone_errors}} = ErrorSchemas.gone_error()

    assert %OpenApiSpex.Schema{items: %OpenApiSpex.Schema{properties: gone_properties}} =
             gone_errors

    assert %OpenApiSpex.Schema{type: :string} = gone_properties.next_code
  end

  test "guest responses use a nullable-email user schema" do
    assert %OpenApiSpex.Schema{properties: %{email: email}} = UserSchemas.GuestUser.schema()
    assert email.nullable == true

    assert %OpenApiSpex.Schema{properties: %{email: registered_email}} =
             UserSchemas.User.schema()

    refute registered_email.nullable
  end
end
