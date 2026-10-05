defmodule PidroServer.Accounts.UserIdentities do
  @moduledoc "Stores and resolves the provider identities linked to users."

  import Ecto.Query
  require Logger

  alias Ecto.Changeset
  alias PidroServer.Accounts.{User, UserIdentity}
  alias PidroServer.Repo

  def sign_in(%{provider: provider, subject: subject} = attrs) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      identity =
        Repo.one(
          from i in UserIdentity,
            where: i.provider == ^provider and i.subject == ^subject,
            lock: "FOR UPDATE"
        )

      case identity do
        nil ->
          Repo.rollback(:not_found)

        %UserIdentity{} = identity ->
          maybe_log_changed_email(identity, attrs)
          identity |> UserIdentity.use_changeset(attrs, now) |> Repo.update!()
          user = Repo.get!(User, identity.user_id)
          promote_email(user, attrs.email)
      end
    end)
  end

  def link(%User{} = user, attrs, source, now \\ DateTime.utc_now()) do
    case Repo.get_by(UserIdentity, provider: attrs.provider, subject: attrs.subject) do
      %UserIdentity{user_id: user_id} = identity when user_id == user.id ->
        maybe_log_changed_email(identity, attrs)
        identity |> UserIdentity.use_changeset(attrs, now) |> Repo.update!()
        {:ok, promote_email(user, attrs.email)}

      %UserIdentity{} ->
        {:error, :provider_already_linked}

      nil ->
        changeset =
          %UserIdentity{user_id: user.id}
          |> UserIdentity.link_changeset(
            attrs
            |> Map.put(:link_source, source)
            |> Map.put(:linked_at, now)
            |> Map.put(:last_used_at, now)
          )

        case Repo.insert(changeset) do
          {:ok, _identity} -> {:ok, promote_email(user, attrs.email)}
          {:error, changeset} -> map_link_error(changeset)
        end
    end
  end

  defp promote_email(%User{email: nil} = user, email) when is_binary(email) do
    changeset =
      user
      |> Changeset.change(email: email)
      |> Changeset.unique_constraint(:email)
      |> Changeset.unique_constraint(:email, name: :users_lower_email_index)

    case Repo.update(changeset, mode: :savepoint) do
      {:ok, user} -> user
      {:error, _taken} -> user
    end
  end

  defp promote_email(user, _email), do: user

  defp maybe_log_changed_email(%{email: stored}, %{email: supplied})
       when is_binary(stored) and is_binary(supplied) and stored != supplied do
    Logger.warning("Provider supplied a different verified email for a stored identity")
  end

  defp maybe_log_changed_email(_identity, _attrs), do: :ok

  defp map_link_error(changeset) do
    if Enum.any?(changeset.errors, fn
         {_field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
         _other -> false
       end) do
      {:error, :provider_already_linked}
    else
      {:error, changeset}
    end
  end
end
