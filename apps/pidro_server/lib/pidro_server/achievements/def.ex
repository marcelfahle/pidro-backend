defmodule PidroServer.Achievements.Def do
  @moduledoc """
  A single achievement definition — pure data, declared in
  `PidroServer.Achievements.Catalog`.

  `key`/`name`/`description`/`tier`/`evaluator`/`threshold`/`status` are
  required; `reason`/`followup` are dormant-only bookkeeping (why a def is
  deferred and which ticket unlocks it).
  """

  @type status :: :active | :dormant
  @type t :: %__MODULE__{
          key: atom(),
          name: String.t(),
          description: String.t(),
          tier: pos_integer(),
          evaluator: term(),
          threshold: integer(),
          status: status(),
          reason: String.t() | nil,
          followup: String.t() | nil
        }

  @enforce_keys [:key, :name, :description, :tier, :evaluator, :threshold, :status]
  defstruct key: nil,
            name: nil,
            description: nil,
            tier: 1,
            evaluator: nil,
            threshold: nil,
            status: :active,
            reason: nil,
            followup: nil
end
