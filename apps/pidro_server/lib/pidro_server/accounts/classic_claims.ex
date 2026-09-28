defmodule PidroServer.Accounts.ClassicClaims do
  @moduledoc """
  Redeems verified Classic claims without merging or replacing accounts.

  PID-143 issues an opaque, short-lived ticket after verification. This module
  owns the durable one-to-one link, career import and repeat-sign-in identity.
  """

  import Ecto.Query

  alias PidroServer.Accounts.{ClassicClaimTicket, User}
  alias PidroServer.Profiles
  alias PidroServer.Profiles.{LegacyProgression, PlayerProfile}
  alias PidroServer.Repo

  @ticket_bytes 32
  @ticket_lifetime_seconds 10 * 60

  @doc """
  Stores a verified claim and returns its one-time opaque token.

  The caller is PID-143's verifier. `attrs` must contain trusted Classic data,
  a method, and exactly one binding: `user_id` or `install_id`.
  """
  def issue_ticket(attrs) when is_map(attrs) do
    token = @ticket_bytes |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)
    now = DateTime.utc_now()
    classic_user_id = fetch(attrs, :classic_user_id)

    legacy_data =
      attrs
      |> fetch(:legacy_data)
      |> LegacyProgression.new()
      |> Map.from_struct()
      |> Map.put(:classic_user_id, classic_user_id)

    ticket_attrs = %{
      token_hash: hash_token(token),
      classic_user_id: classic_user_id,
      method: fetch(attrs, :method),
      provider_id: fetch(attrs, :provider_id),
      legacy_data: legacy_data,
      bound_user_id: fetch(attrs, :user_id),
      install_id: fetch(attrs, :install_id),
      expires_at: DateTime.add(now, @ticket_lifetime_seconds, :second)
    }

    case %ClassicClaimTicket{}
         |> ClassicClaimTicket.issue_changeset(ticket_attrs)
         |> Repo.insert() do
      {:ok, ticket} -> {:ok, %{ticket: token, expires_at: ticket.expires_at}}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc "Redeems a ticket for the current user, or creates a user for an install-bound claim."
  def redeem(token, current_user, params)
      when is_binary(token) and (is_nil(current_user) or is_struct(current_user, User)) and
             is_map(params) do
    case redeem_once(token, current_user, params) do
      {:error, :claim_state_changed} -> redeem_once(token, current_user, params)
      result -> result
    end
  end

  def redeem(_token, _current_user, _params), do: {:error, :invalid_claim_ticket}

  defp redeem_once(token, current_user, params) do
    now = DateTime.utc_now()

    Repo.transaction(fn ->
      case find_ticket(token) do
        nil ->
          Repo.rollback(:invalid_claim_ticket)

        preview ->
          locked_user = lock_known_user(preview, current_user)

          with %ClassicClaimTicket{} = ticket <- lock_ticket(token),
               :ok <- validate_ticket_snapshot(preview, ticket, locked_user),
               :ok <- validate_binding(ticket, current_user, params),
               :ok <- validate_expiry(ticket, now),
               :ok <- lock_classic(ticket.classic_user_id),
               {:ok, user, mode} <- target_user(ticket, current_user, params, locked_user),
               {:ok, user} <- redeem_for_user(ticket, user, mode, now) do
            user
          else
            nil -> Repo.rollback(:invalid_claim_ticket)
            {:error, reason} -> Repo.rollback(reason)
          end
      end
    end)
  end

  defp find_ticket(token),
    do: Repo.get_by(ClassicClaimTicket, token_hash: hash_token(token))

  defp lock_ticket(token) do
    Repo.one(
      from t in ClassicClaimTicket,
        where: t.token_hash == ^hash_token(token),
        lock: "FOR UPDATE"
    )
  end

  defp lock_known_user(_ticket, %User{id: id}), do: lock_user(id)
  defp lock_known_user(%{redeemed_by_id: id}, nil) when is_binary(id), do: lock_user(id)
  defp lock_known_user(_ticket, nil), do: nil

  # A concurrent first redemption can commit while this transaction waits for
  # the ticket. Restart so the established user is locked before the ticket.
  defp validate_ticket_snapshot(
         %{redeemed_by_id: nil},
         %{redeemed_by_id: id},
         nil
       )
       when is_binary(id),
       do: {:error, :claim_state_changed}

  defp validate_ticket_snapshot(_preview, _ticket, _locked_user), do: :ok

  defp validate_binding(%{bound_user_id: id}, %User{id: id}, _params), do: :ok

  defp validate_binding(%{bound_user_id: nil, install_id: install_id}, nil, params) do
    if fetch(params, :install_id) == install_id,
      do: :ok,
      else: {:error, :claim_ticket_binding_mismatch}
  end

  defp validate_binding(_ticket, _user, _params),
    do: {:error, :claim_ticket_binding_mismatch}

  defp validate_expiry(%{expires_at: expires_at}, now) do
    if DateTime.compare(expires_at, now) == :gt,
      do: :ok,
      else: {:error, :claim_ticket_expired}
  end

  defp lock_classic(classic_user_id) do
    case Repo.query("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [
           "classic-claim:#{classic_user_id}"
         ]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp target_user(%{redeemed_by_id: id}, %User{id: id}, _params, %User{id: id} = user),
    do: {:ok, user, :retry}

  defp target_user(
         %{redeemed_by_id: id, install_id: install_id},
         nil,
         params,
         %User{id: id} = user
       )
       when is_binary(id) do
    if fetch(params, :install_id) == install_id,
      do: {:ok, user, :retry},
      else: {:error, :claim_ticket_binding_mismatch}
  end

  defp target_user(%{redeemed_by_id: id, method: method}, _current_user, _params, owner)
       when is_binary(id),
       do: {:error, {:already_claimed, sign_in_method(owner, method)}}

  defp target_user(_ticket, %User{id: id}, _params, %User{id: id} = user),
    do: {:ok, user, :first}

  defp target_user(ticket, nil, params, nil) do
    case Repo.get_by(User, classic_user_id: ticket.classic_user_id) do
      nil -> create_user(ticket, fetch(params, :account) || %{})
      owner -> {:error, {:already_claimed, sign_in_method(owner, ticket.method)}}
    end
  end

  defp create_user(%{method: :password}, attrs) do
    %User{}
    |> User.classic_password_registration_changeset(attrs)
    |> Repo.insert()
    |> with_mode()
  end

  defp create_user(%{method: method}, attrs) when method in [:apple, :facebook] do
    %User{}
    |> User.social_registration_changeset(attrs)
    |> Repo.insert()
    |> with_mode()
  end

  defp with_mode({:ok, user}), do: {:ok, user, :first}
  defp with_mode({:error, reason}), do: {:error, reason}

  defp redeem_for_user(ticket, user, :retry, _now) do
    if user.classic_user_id == ticket.classic_user_id,
      do: {:ok, user},
      else: {:error, :already_claimed}
  end

  defp redeem_for_user(ticket, user, :first, now) do
    already_linked? = user.classic_user_id == ticket.classic_user_id

    with :ok <- ensure_link_available(ticket, user),
         :ok <- ensure_provider_available(ticket, user),
         {:ok, linked} <- link_user(ticket, user, now),
         :ok <- maybe_import_progression(already_linked?, linked, ticket),
         {:ok, _ticket} <-
           ticket |> ClassicClaimTicket.redeem_changeset(linked.id, now) |> Repo.update() do
      {:ok, linked}
    end
  end

  defp ensure_provider_available(%{method: :password}, _user), do: :ok

  defp ensure_provider_available(%{method: :apple, provider_id: id}, %User{apple_sub: current}) do
    if current in [nil, id], do: :ok, else: {:error, :provider_already_linked}
  end

  defp ensure_provider_available(
         %{method: :facebook, provider_id: id},
         %User{facebook_id: current}
       ) do
    if current in [nil, id], do: :ok, else: {:error, :provider_already_linked}
  end

  defp ensure_link_available(ticket, user) do
    if user.classic_user_id in [nil, ticket.classic_user_id] do
      owner =
        Repo.one(
          from u in User,
            where: u.classic_user_id == ^ticket.classic_user_id,
            lock: "FOR UPDATE"
        )

      if is_nil(owner) or owner.id == user.id,
        do: :ok,
        else: {:error, {:already_claimed, sign_in_method(owner, ticket.method)}}
    else
      {:error, :user_already_claimed}
    end
  end

  defp sign_in_method(%User{} = user, attempted_method) do
    methods =
      [
        {:password, user.password_hash},
        {:apple, user.apple_sub},
        {:facebook, user.facebook_id}
      ]
      |> Enum.filter(fn {_method, identity} -> is_binary(identity) end)
      |> Enum.map(&elem(&1, 0))

    if attempted_method in methods, do: attempted_method, else: List.first(methods)
  end

  defp sign_in_method(_user, _attempted_method), do: nil

  defp link_user(ticket, user, now) do
    attrs =
      %{
        classic_user_id: ticket.classic_user_id,
        classic_claimed_at: user.classic_claimed_at || now
      }
      |> put_provider(ticket.method, ticket.provider_id)

    user
    |> User.classic_claim_changeset(attrs)
    |> Repo.update()
    |> map_link_error(ticket.method)
  end

  defp put_provider(attrs, :apple, provider_id), do: Map.put(attrs, :apple_sub, provider_id)
  defp put_provider(attrs, :facebook, provider_id), do: Map.put(attrs, :facebook_id, provider_id)
  defp put_provider(attrs, :password, _provider_id), do: attrs

  defp map_link_error({:ok, user}, _method), do: {:ok, user}

  defp map_link_error({:error, changeset}, method) do
    cond do
      unique_error?(changeset, :classic_user_id) -> {:error, {:already_claimed, method}}
      unique_error?(changeset, :apple_sub) -> {:error, :provider_already_linked}
      unique_error?(changeset, :facebook_id) -> {:error, :provider_already_linked}
      true -> {:error, changeset}
    end
  end

  defp maybe_import_progression(true, _user, _ticket), do: :ok
  defp maybe_import_progression(false, user, ticket), do: import_progression(user, ticket)

  defp import_progression(user, ticket) do
    case Profiles.import_legacy_progression(user, ticket.legacy_data) do
      {:ok, %PlayerProfile{}} -> :ok
      {:ok, :already_migrated} -> ensure_same_import(user.id, ticket.classic_user_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ensure_same_import(user_id, classic_user_id) do
    profile = Repo.get_by!(PlayerProfile, user_id: user_id)
    imported_id = Map.get(profile.heritage_flags || %{}, "classic_user_id")

    if imported_id == classic_user_id,
      do: :ok,
      else: {:error, :user_already_claimed}
  end

  defp lock_user(id),
    do: Repo.one!(from u in User, where: u.id == ^id, lock: "FOR UPDATE")

  defp unique_error?(changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_message, opts}} -> Keyword.get(opts, :constraint) == :unique
      _other -> false
    end)
  end

  defp hash_token(token), do: :crypto.hash(:sha256, token)

  defp fetch(map, key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key)))
  end
end
