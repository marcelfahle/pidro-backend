defmodule PidroServer.Profiles.LegacyProgression do
  @moduledoc """
  The input contract for the Pidro 1 → Pidro 2 progression carry-over (PID-53).

  A plain data struct (no Ecto, no DB) describing the pre-aggregated legacy
  progression the bridge/claim flow hands to `Profiles.import_legacy_progression/2`.
  Defining it here documents the shape in one place, gives the mapping a single
  typed input to pattern-match, and gives the future bridge a named build target.

  Every optional field defaults so "nil/missing tolerated" is structural rather
  than scattered `Map.get/2` calls. The only field the bridge must supply is
  `:xp`; the rest degrade gracefully when absent.

  ## Fields

    * `xp` — lifetime legacy XP (`users.xp`). The only field needed for the
      Veteran level/title; kept verbatim. Defaults to `0` (→ level 1).
    * `badges` — opaque legacy accolade names (`user_badges.AchievementData`),
      routed to the display-only `legacy_accolades` Heritage flag. Default `[]`.
    * `premium` — the bridge's active-premium decision (`now < users.premium_until`).
      Recorded as a display-only Heritage flag (Pidro 2 has no entitlement system).
      Default `false`.
    * `founding_member` — pre-launch cohort flag (display only). Default `false`.
    * `playstyle` — pre-aggregated bidding facts (`bidding_attempts`,
      `bidding_wins`, `won_bid_sum`) from `game_play_data.RoomData`, or `nil`
      when unavailable. `won_bid_count == bidding_wins` (a winning bid is a won
      round), so there is no separate count. Default `nil`.

  Both a `%LegacyProgression{}` and a plain map are accepted by
  `import_legacy_progression/2` (a map is normalized via `struct/2`).
  """

  @type playstyle :: %{
          bidding_attempts: non_neg_integer(),
          bidding_wins: non_neg_integer(),
          won_bid_sum: non_neg_integer()
        }

  @type t :: %__MODULE__{
          xp: non_neg_integer(),
          badges: [String.t()],
          premium: boolean(),
          founding_member: boolean(),
          playstyle: playstyle() | nil
        }

  defstruct xp: 0, badges: [], premium: false, founding_member: false, playstyle: nil
end
