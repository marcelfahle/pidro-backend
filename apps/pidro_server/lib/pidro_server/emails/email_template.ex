defmodule PidroServer.Emails.EmailTemplate do
  @moduledoc """
  Draftable email template managed from the admin email studio.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "email_templates" do
    field :kind, Ecto.Enum, values: [:transactional, :campaign]
    field :name, :string
    field :subject, :string
    field :preview_text, :string
    field :from_name, :string
    field :from_email, :string
    field :reply_to, :string
    field :html_body, :string
    field :variables, {:array, :string}, default: []
    field :variables_text, :string, virtual: true

    timestamps(type: :utc_datetime_usec)
  end

  def changeset(template, attrs) do
    template
    |> cast(attrs, [
      :kind,
      :name,
      :subject,
      :preview_text,
      :from_name,
      :from_email,
      :reply_to,
      :html_body,
      :variables_text
    ])
    |> validate_required([:kind, :name, :subject, :html_body])
    |> validate_length(:name, min: 2, max: 120)
    |> validate_length(:subject, max: 180)
    |> validate_length(:preview_text, max: 240)
    |> validate_email(:from_email)
    |> validate_email(:reply_to)
    |> put_variables_from_text()
  end

  defp validate_email(changeset, field) do
    validate_change(changeset, field, fn ^field, value ->
      value = value || ""

      if String.trim(value) == "" or String.match?(value, ~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/) do
        []
      else
        [{field, "must be a valid email address"}]
      end
    end)
  end

  defp put_variables_from_text(changeset) do
    case get_change(changeset, :variables_text) do
      nil ->
        changeset

      text ->
        variables =
          text
          |> String.split([",", "\n", "\r"], trim: true)
          |> Enum.map(&String.trim/1)
          |> Enum.reject(&(&1 == ""))
          |> Enum.uniq()

        put_change(changeset, :variables, variables)
    end
  end
end
