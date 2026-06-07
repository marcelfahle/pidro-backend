defmodule PidroServer.Progression.Heritage do
  @moduledoc """
  Pure modelling + display of origin-recognition flags stored in
  `player_profiles.heritage_flags` (free-form JSONB, default `%{}`).

  PID-49 defines the known key vocabulary and turns the flags map into a
  structured, displayable list. PID-49 NEVER writes these (defaults stay empty);
  PID-53 (account migration) populates them on import.

  ## Known keys

    * `played_pidro_one :: boolean`   — had a Pidro 1 account
    * `founding_member  :: boolean`   — pre-launch / founding cohort
    * `legacy_level     :: integer`   — the carried Pidro 1 level (display only)
    * `legacy_accolades :: [string]`  — named legacy awards/titles

  Tolerates atom- or string-keyed maps (JSONB round-trips to string keys).

  ## Examples

      iex> PidroServer.Progression.Heritage.display(%{})
      []

      iex> PidroServer.Progression.Heritage.display(%{"played_pidro_one" => true})
      [%{key: :played_pidro_one, label: "Played Pidro 1", value: true}]

  """

  @type flags :: map()
  @type badge :: %{key: atom(), label: String.t(), value: term()}

  # Vocabulary in display order. `:boolean` badges appear only when truthy;
  # `:value` badges appear whenever a non-nil value is present.
  @vocabulary [
    {:played_pidro_one, "Played Pidro 1", :boolean},
    {:founding_member, "Founding Member", :boolean},
    {:legacy_level, "Legacy Level", :value},
    {:legacy_accolades, "Legacy Accolades", :value}
  ]

  @doc """
  Turns a `heritage_flags` map into an ordered list of displayable badges,
  skipping falsy / absent flags. Returns `[]` for an empty/nil map.

  ## Examples

      iex> PidroServer.Progression.Heritage.display(nil)
      []

      iex> PidroServer.Progression.Heritage.display(%{played_pidro_one: false})
      []

  """
  @spec display(flags() | nil) :: [badge()]
  def display(nil), do: []

  def display(flags) when is_map(flags) do
    Enum.flat_map(@vocabulary, fn {key, label, kind} ->
      case fetch(flags, key) do
        {:ok, value} -> badge_for(kind, key, label, value)
        :error -> []
      end
    end)
  end

  def display(_flags), do: []

  # Boolean badges show only when truthy; their value is normalized to `true`.
  defp badge_for(:boolean, key, label, value) do
    if value do
      [%{key: key, label: label, value: true}]
    else
      []
    end
  end

  # Value badges show whenever a non-nil value is present.
  defp badge_for(:value, _key, _label, nil), do: []
  defp badge_for(:value, key, label, value), do: [%{key: key, label: label, value: value}]

  # Tolerate atom OR string keys (JSONB round-trips to string keys).
  defp fetch(flags, key) do
    case Map.fetch(flags, key) do
      {:ok, value} -> {:ok, value}
      :error -> Map.fetch(flags, Atom.to_string(key))
    end
  end
end
