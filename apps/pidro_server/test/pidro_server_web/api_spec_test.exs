defmodule PidroServerWeb.ApiSpecTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias PidroServer.Games.Room.Config
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

  describe "the room config contract" do
    # Drift guard (KTD12): the OpenAPI create-request schema and the boundary
    # parser are two hand-written descriptions of one request. Adding a field to
    # either without the other fails here. Every expectation below is read from
    # `Room.Config`, never typed out, so a change to the parser's fields, enums
    # or name cap that the spec does not follow fails too.
    test "the create-room request accepts exactly the fields the parser accepts" do
      schema = create_room_request_schema(ApiSpec.spec())

      assert property_names(schema) == Enum.sort(Config.accepted_fields())
      assert schema.additionalProperties == false
    end

    test "the create-room seats schema names exactly the three non-host seats" do
      spec = ApiSpec.spec()

      seats =
        spec |> create_room_request_schema() |> Map.fetch!(:properties) |> Map.fetch!(:seats)

      seats = resolve(seats, spec)

      assert property_names(seats) == Enum.sort(Config.seat_keys())
      assert seats.additionalProperties == false
    end

    test "every create-room seat takes exactly the values the parser accepts" do
      spec = ApiSpec.spec()

      seats =
        spec |> create_room_request_schema() |> Map.fetch!(:properties) |> Map.fetch!(:seats)

      seats = resolve(seats, spec)

      for {seat, schema} <- seats.properties do
        assert resolve(schema, spec).enum == Config.seat_values(), "seat #{seat}"
      end
    end

    test "the request and the config list exactly the difficulties the parser accepts" do
      spec = ApiSpec.spec()

      for schema <- [create_room_request_schema(spec), room_config_schema(spec)] do
        difficulty = resolve(schema.properties.bot_difficulty, spec)

        assert difficulty.enum == Config.difficulties(), schema.title
      end
    end

    test "the request and the config cap the name where the parser does" do
      spec = ApiSpec.spec()

      for schema <- [create_room_request_schema(spec), room_config_schema(spec)] do
        name = resolve(schema.properties.name, spec)

        assert name.maxLength == Config.max_name_length(), schema.title
      end
    end

    test "the room schema carries the config and no metadata" do
      spec = ApiSpec.spec()
      room = Map.fetch!(spec.components.schemas, "Room")
      names = property_names(room)

      assert "config" in names
      refute "metadata" in names

      assert property_names(room_config_schema(spec)) == serialized_config_keys()
    end
  end

  defp room_config_schema(spec) do
    room = Map.fetch!(spec.components.schemas, "Room")
    resolve(room.properties.config, spec)
  end

  # The keys `Config.serialize/1` really emits, so a field added to the
  # serialized config without a schema property fails the guard.
  defp serialized_config_keys do
    %Config{} |> Config.serialize() |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
  end

  defp create_room_request_schema(spec) do
    %OpenApiSpex.PathItem{post: %OpenApiSpex.Operation{requestBody: body}} =
      Map.fetch!(spec.paths, "/api/v1/rooms")

    %OpenApiSpex.MediaType{schema: schema} = Map.fetch!(body.content, "application/json")
    resolve(schema, spec)
  end

  defp resolve(%OpenApiSpex.Reference{"$ref": "#/components/schemas/" <> name}, spec),
    do: Map.fetch!(spec.components.schemas, name)

  defp resolve(%OpenApiSpex.Schema{} = schema, _spec), do: schema

  defp property_names(%OpenApiSpex.Schema{properties: properties}),
    do: properties |> Map.keys() |> Enum.map(&to_string/1) |> Enum.sort()
end
