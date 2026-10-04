defmodule PidroServer.Accounts.AgeTerms do
  @moduledoc "Validates and records a user's age band and accepted terms version."

  import Ecto.Query

  alias Ecto.Changeset
  alias PidroServer.Accounts.User
  alias PidroServer.Repo

  @known_bands ["13_17", "18_plus"]
  @refused_band "under_13"
  @unknown_band "unknown"
  @terms_version_max_length 32

  @type declaration :: %{
          optional(:age_band) => String.t(),
          optional(:terms_version) => String.t()
        }

  @doc "Validates optional top-level age and terms fields from an authentication request."
  @spec parse(map(), keyword()) ::
          {:ok, declaration() | nil} | {:error, :age_not_eligible | Changeset.t()}
  def parse(params, opts \\ []) when is_map(params) do
    required? = Keyword.get(opts, :required, false)
    age_present? = has_key?(params, :age_band)
    terms_present? = has_key?(params, :terms_version)

    cond do
      fetch(params, :age_band) == @refused_band ->
        {:error, :age_not_eligible}

      not required? and not age_present? and not terms_present? ->
        {:ok, nil}

      true ->
        params = %{
          age_band: fetch(params, :age_band),
          terms_version: fetch(params, :terms_version)
        }

        changeset =
          {%{}, %{age_band: :string, terms_version: :string}}
          |> Changeset.cast(params, [:age_band, :terms_version])
          |> maybe_require(:age_band, required? or age_present?)
          |> maybe_require(:terms_version, terms_present?)
          |> Changeset.validate_inclusion(:age_band, @known_bands)
          |> Changeset.validate_length(:terms_version, max: @terms_version_max_length)

        if changeset.valid? do
          {:ok, Map.take(changeset.changes, [:age_band, :terms_version])}
        else
          {:error, changeset}
        end
    end
  end

  @doc "Stores a declaration only while the user's age band is still unknown."
  @spec store(User.t(), declaration() | nil) :: {:ok, User.t()}
  def store(%User{} = user, nil), do: {:ok, user}

  def store(%User{age_band: age_band} = user, _declaration) when age_band != @unknown_band,
    do: {:ok, user}

  def store(%User{id: id} = user, declaration) when is_map(declaration) do
    now = DateTime.utc_now()
    updates = declaration_updates(declaration, now)

    {updated, _} =
      from(u in User, where: u.id == ^id and u.age_band == @unknown_band)
      |> Repo.update_all(set: updates)

    if updated == 1, do: {:ok, Repo.get!(User, id)}, else: {:ok, Repo.get(User, id) || user}
  end

  @doc "Stores the required declaration for an authenticated user exactly once."
  @spec declare(User.t(), declaration()) :: {:ok, User.t()} | {:error, :age_already_set}
  def declare(%User{age_band: age_band}, _declaration) when age_band != @unknown_band,
    do: {:error, :age_already_set}

  def declare(%User{id: id}, declaration) when is_map(declaration) do
    now = DateTime.utc_now()

    {updated, _} =
      from(u in User, where: u.id == ^id and u.age_band == @unknown_band)
      |> Repo.update_all(set: declaration_updates(declaration, now))

    if updated == 1,
      do: {:ok, Repo.get!(User, id)},
      else: {:error, :age_already_set}
  end

  defp declaration_updates(declaration, now) do
    [updated_at: now]
    |> maybe_put_updates(:age_band, :age_declared_at, declaration[:age_band], now)
    |> maybe_put_updates(:terms_version, :terms_accepted_at, declaration[:terms_version], now)
  end

  defp maybe_put_updates(updates, _value_field, _time_field, nil, _now), do: updates

  defp maybe_put_updates(updates, value_field, time_field, value, now),
    do: [{time_field, now}, {value_field, value} | updates]

  defp maybe_require(changeset, _field, false), do: changeset
  defp maybe_require(changeset, field, true), do: Changeset.validate_required(changeset, field)

  defp has_key?(params, key),
    do: Map.has_key?(params, key) or Map.has_key?(params, Atom.to_string(key))

  defp fetch(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))
end
