defmodule PidroServerWeb.API.AvatarControllerTest do
  use PidroServerWeb.ConnCase, async: false

  alias PidroServer.Accounts.{Avatars, Token, UserAvatar}
  alias PidroServer.AccountsFixtures
  alias PidroServer.Repo

  setup do
    dir = Path.join(System.tmp_dir!(), "avatar-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    %{dir: dir}
  end

  test "upload requires authentication and only changes the authenticated user's avatar", %{
    conn: conn,
    dir: dir
  } do
    owner = AccountsFixtures.user_fixture()
    other = AccountsFixtures.user_fixture()
    image = png!(dir, "owner.png")

    assert conn
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(image)})
           |> json_response(401)

    conn = conn |> auth(owner) |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(image)})
    assert %{"data" => %{"avatar_url" => url}} = json_response(conn, 200)
    assert String.starts_with?(url, PidroServerWeb.Endpoint.url())
    assert Avatars.metadata_for(owner.id)
    refute Avatars.metadata_for(other.id)
  end

  test "invalid and oversized replacement preserve the old row", %{conn: conn, dir: dir} do
    user = AccountsFixtures.user_fixture()
    valid = png!(dir, "valid.png")

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(valid)})
           |> response(200)

    old = Repo.get!(UserAvatar, user.id)

    invalid = Path.join(dir, "invalid.png")
    File.write!(invalid, "not an image")

    assert build_conn()
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(invalid)})
           |> response(422)

    assert Repo.get!(UserAvatar, user.id).version == old.version

    oversized = Path.join(dir, "oversized.png")
    File.write!(oversized, <<0x89, "PNG\r\n", 0x1A, 0x0A, 0::size(5_242_881 * 8)>>)

    assert build_conn()
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(oversized)})
           |> response(422)

    assert Repo.get!(UserAvatar, user.id).version == old.version
  end

  test "remove deletes the row", %{conn: conn, dir: dir} do
    user = AccountsFixtures.user_fixture()

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(png!(dir, "remove.png"))})
           |> response(200)

    assert build_conn() |> auth(user) |> delete(~p"/api/v1/profile/avatar") |> json_response(200) ==
             %{"data" => %{"avatar_url" => nil}}

    refute Repo.get(UserAvatar, user.id)
  end

  test "public immutable URL serves exact version without JSON Accept and malformed UUID is 404",
       %{
         conn: conn,
         dir: dir
       } do
    user = AccountsFixtures.user_fixture()

    assert conn
           |> auth(user)
           |> post(~p"/api/v1/profile/avatar", %{"avatar" => upload(png!(dir, "public.png"))})
           |> response(200)

    avatar = Repo.get!(UserAvatar, user.id)

    served =
      build_conn()
      |> put_req_header("accept", "image/*")
      |> get("/api/v1/users/#{user.id}/avatar/#{avatar.version}")

    assert response(served, 200) == avatar.image
    assert get(build_conn(), "/api/v1/users/#{user.id}/avatar/wrong").status == 404
    assert get(build_conn(), "/api/v1/users/not-a-uuid/avatar/#{avatar.version}").status == 404
  end

  test "normalizes orientation and metadata and flattens PNG transparency", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    source = Path.join(dir, "oriented.jpg")

    {_, 0} =
      System.cmd("convert", [
        "-size",
        "80x40",
        "xc:red",
        "-fill",
        "blue",
        "-draw",
        "rectangle 40,0 79,39",
        "-set",
        "comment",
        "secret",
        "JPEG:#{source}"
      ])

    # Real EXIF APP1 orientation=6, not ImageMagick's transient orientation setting.
    exif =
      <<"Exif", 0, 0, "II", 42::little-16, 8::little-32, 1::little-16, 0x0112::little-16,
        3::little-16, 1::little-32, 6::little-16, 0::16, 0::32>>

    <<0xFF, 0xD8, rest::binary>> = File.read!(source)

    File.write!(
      source,
      <<0xFF, 0xD8, 0xFF, 0xE1, byte_size(exif) + 2::16, exif::binary, rest::binary>>
    )

    assert {"RightTop", 0} = System.cmd("identify", ["-format", "%[orientation]", source])

    assert {:ok, _url} = Avatars.put(user.id, upload(source))
    output = Repo.get!(UserAvatar, user.id).image
    normalized = Path.join(dir, "normalized.jpg")
    File.write!(normalized, output)
    assert {"256 256", 0} = System.cmd("identify", ["-format", "%w %h", "JPEG:#{normalized}"])
    assert {"", 0} = System.cmd("identify", ["-format", "%c", "JPEG:#{normalized}"])
    refute output =~ "Exif"

    assert {"1 1", 0} =
             System.cmd("convert", [
               normalized,
               "-format",
               "%[fx:p{128,32}.r>0.9] %[fx:p{128,224}.b>0.9]",
               "info:"
             ])

    transparent = png!(dir, "transparent.png", "none")
    assert {:ok, _url} = Avatars.put(user.id, upload(transparent))
    File.write!(normalized, Repo.get!(UserAvatar, user.id).image)

    assert {"1 1 1", 0} =
             System.cmd("convert", [
               "JPEG:#{normalized}",
               "-format",
               "%[fx:p{0,0}.r>0.99] %[fx:p{0,0}.g>0.99] %[fx:p{0,0}.b>0.99]",
               "info:"
             ])
  end

  test "deleting a user cascades its avatar", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    assert {:ok, _url} = Avatars.put(user.id, upload(png!(dir, "cascade.png")))
    Repo.delete!(user)
    refute Repo.get(UserAvatar, user.id)
  end

  test "busy processing preserves the previous image and gives a retryable result", %{dir: dir} do
    user = AccountsFixtures.user_fixture()
    image = png!(dir, "busy.png")
    assert {:ok, _} = Avatars.put(user.id, upload(image))
    previous = Repo.get!(UserAvatar, user.id)
    # Hold the resource as a different requester to simulate another active conversion.
    lock = {Avatars, make_ref()}
    assert :global.set_lock(lock, [node()], 0)

    try do
      assert {:error, :busy} = Avatars.put(user.id, upload(image))
      assert Repo.get!(UserAvatar, user.id).image == previous.image
    after
      :global.del_lock(lock, [node()])
    end
  end

  defp auth(conn, user),
    do: put_req_header(conn, "authorization", "Bearer #{Token.generate(user)}")

  defp upload(path),
    do: %Plug.Upload{path: path, filename: Path.basename(path), content_type: "image/png"}

  defp png!(dir, name, color \\ "red") do
    path = Path.join(dir, name)
    {_, 0} = System.cmd("convert", ["-size", "320x200", "xc:#{color}", "PNG:#{path}"])
    path
  end
end
