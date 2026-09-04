defmodule PidroServer.Admins do
  @moduledoc """
  Password authentication and lifecycle management for ops-panel admins.
  """

  import Ecto.Query

  require Logger

  alias PidroServer.Admins.{Admin, AdminToken}
  alias PidroServer.Repo

  def list_admins do
    Repo.all(from admin in Admin, order_by: [asc: admin.email])
  end

  def get_admin(id), do: Repo.get(Admin, id)

  def get_admin_by_email(email) when is_binary(email) do
    normalized_email = email |> String.trim() |> String.downcase()
    Repo.one(from admin in Admin, where: fragment("lower(?)", admin.email) == ^normalized_email)
  end

  def get_admin_by_email(_email), do: nil

  def get_admin_by_email_and_password(email, password) do
    admin = get_admin_by_email(email)
    if Admin.valid_password?(admin, password), do: admin
  end

  def change_admin_email(%Admin{} = admin, attrs \\ %{}) do
    Admin.email_changeset(admin, attrs)
  end

  def change_admin_password(%Admin{} = admin, attrs \\ %{}) do
    Admin.password_changeset(admin, attrs, hash_password: false)
  end

  def update_admin_password(%Admin{} = admin, attrs) do
    changeset = Admin.password_changeset(admin, attrs)

    if changeset.valid? do
      Repo.transaction(fn ->
        updated_admin = Repo.update!(changeset)
        Repo.delete_all(from token in AdminToken, where: token.admin_id == ^admin.id)

        Logger.info("admin_action admin=#{admin.email} action=change_password")
        updated_admin
      end)
    else
      {:error, changeset}
    end
  end

  def create_admin(%Admin{} = acting_admin, attrs) do
    temporary_password = generate_temporary_password()
    attrs = Map.put(attrs, "password", temporary_password)

    case %Admin{} |> Admin.registration_changeset(attrs) |> Repo.insert() do
      {:ok, admin} ->
        Logger.info(
          "admin_action admin=#{acting_admin.email} action=add_admin target=#{admin.email}"
        )

        {:ok, admin, temporary_password}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def delete_admin(%Admin{} = acting_admin, admin_id) do
    result =
      Repo.transaction(fn ->
        admins = Repo.all(from admin in Admin, lock: "FOR UPDATE")
        current_actor = Enum.find(admins, &(&1.id == acting_admin.id))
        admin = Enum.find(admins, &(&1.id == admin_id))

        cond do
          is_nil(current_actor) -> Repo.rollback(:unauthenticated)
          is_nil(admin) -> Repo.rollback(:not_found)
          admin.id == current_actor.id and length(admins) == 1 -> Repo.rollback(:last_admin)
          true -> Repo.delete!(admin)
        end
      end)

    case result do
      {:ok, deleted_admin} ->
        Logger.info(
          "admin_action admin=#{acting_admin.email} action=remove_admin target=#{deleted_admin.email}"
        )

        {:ok, deleted_admin}

      error ->
        error
    end
  end

  def generate_admin_session_token(%Admin{} = admin) do
    {token, admin_token} = AdminToken.build_session_token(admin)
    Repo.insert!(admin_token)
    token
  end

  def get_admin_by_session_token(token) when is_binary(token) do
    {:ok, query} = AdminToken.verify_session_token_query(token)

    case Repo.one(query) do
      nil ->
        nil

      admin ->
        Repo.update_all(AdminToken.by_token_and_context_query(token, "session"),
          set: [last_used_at: DateTime.utc_now()]
        )

        admin
    end
  end

  def get_admin_by_session_token(_token), do: nil

  def delete_admin_session_token(token) when is_binary(token) do
    Repo.delete_all(AdminToken.by_token_and_context_query(token, "session"))
    :ok
  end

  def delete_admin_session_token(_token), do: :ok

  def seed_first_admin do
    case Application.get_env(:pidro_server, :admin_seed_email) do
      email when is_binary(email) and byte_size(email) > 0 -> seed_first_admin(email)
      _other -> {:error, :admin_seed_email_missing}
    end
  end

  defp seed_first_admin(email) do
    result =
      Repo.transaction(fn ->
        {:ok, _result} =
          Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
            "pidro-admin-bootstrap"
          ])

        case Repo.all(Admin) do
          [] ->
            temporary_password = generate_temporary_password()

            admin =
              %Admin{}
              |> Admin.registration_changeset(%{
                "email" => email,
                "password" => temporary_password
              })
              |> Repo.insert!()

            {admin, temporary_password}

          _admins ->
            :already_seeded
        end
      end)

    case result do
      {:ok, {admin, temporary_password}} -> {:ok, admin, temporary_password}
      other -> other
    end
  rescue
    error in Ecto.InvalidChangesetError -> {:error, error.changeset}
  end

  defp generate_temporary_password do
    18
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
  end
end
