defmodule PidroServer.Accounts do
  @moduledoc "Public account-name policy shared by every account write path."

  alias Ecto.Changeset
  alias PidroServer.Accounts.User

  @blocked_names ~w(fuck fuckface shit cunt bitch fitta vittu kyrpä)
  @token_separator ~r/[^\p{L}\p{N}]+/u

  @doc "Returns whether a value satisfies the public-name format and content policy."
  @spec public_name_allowed?(term()) :: boolean()
  def public_name_allowed?(name) when is_binary(name) do
    changeset = User.public_name_changeset(name)
    normalized = Changeset.get_change(changeset, :display_name)

    changeset.valid? and is_binary(normalized) and not blocked?(normalized)
  end

  def public_name_allowed?(_name), do: false

  @doc false
  @spec validate_public_name_changes(Changeset.t(), [atom()]) :: Changeset.t()
  def validate_public_name_changes(%Changeset{} = changeset, fields) when is_list(fields) do
    Enum.reduce(fields, changeset, fn field, acc ->
      case Changeset.fetch_change(acc, field) do
        {:ok, name} when is_binary(name) -> validate_changed_name(acc, field, name)
        _missing_or_nil -> acc
      end
    end)
  end

  defp validate_changed_name(changeset, field, name) do
    if public_name_allowed?(name) or field_has_error?(changeset, field) do
      changeset
    else
      Changeset.add_error(changeset, field, "is not allowed as a public name")
    end
  end

  defp field_has_error?(%Changeset{errors: errors}, field) do
    Enum.any?(errors, fn {error_field, _error} -> error_field == field end)
  end

  defp blocked?(name) do
    tokens =
      name
      |> String.downcase()
      |> String.split(@token_separator, trim: true)

    Enum.any?(tokens, &(&1 in @blocked_names)) or Enum.join(tokens) in @blocked_names
  end
end
