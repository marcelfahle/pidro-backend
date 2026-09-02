defmodule PidroServerWeb.Schemas.InviteSchemas do
  @moduledoc """
  OpenAPI schema definitions for invite links (R1, R4, R5, R27).

  Request bodies for minting and redeeming, and the three response shapes
  rendered by `PidroServerWeb.API.InviteJSON`: the host's invite, the public
  preview and the redeem result.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema
  alias PidroServerWeb.Schemas.RoomSchemas

  defmodule State do
    @moduledoc "The derived invite state (R3), in priority order."

    OpenApiSpex.schema(%{
      title: "InviteState",
      description:
        "Derived at read time (R3): revoked, moved, expired, closed, started, locked, full, open",
      type: :string,
      enum: [:open, :full, :locked, :started, :closed, :expired, :revoked, :moved],
      example: "open"
    })
  end

  defmodule Invite do
    @moduledoc "Schema for the host's view of an invite."

    OpenApiSpex.schema(%{
      title: "Invite",
      description: "An invite link as the host sees it after minting or regenerating",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          description:
            "8-character Crockford Base32 secret; lookups accept dashes and lower case",
          example: "7KQ4M2XB",
          minLength: 8,
          maxLength: 8
        },
        url: %Schema{
          type: :string,
          description: "Shareable link, `<link_base_url>/<code>`",
          example: "https://pidro.online/j/7KQ4M2XB"
        },
        share_text: %Schema{
          type: :string,
          description: "Ready-to-paste share message with the link and the dashed code",
          example: "Come play Pidro with me 🃏 https://pidro.online/j/7KQ4M2XB — code 7KQ4-M2XB"
        },
        seat_hint: %Schema{
          type: :string,
          nullable: true,
          enum: [:north, :east, :south, :west, :north_south, :east_west, :partner],
          description:
            "Seat preference for whoever redeems; `partner` is the seat opposite the host"
        },
        label: %Schema{
          type: :string,
          nullable: true,
          maxLength: 40,
          description: "Host's private note on who the link is for",
          example: "Anna"
        },
        expires_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "24 hours after minting",
          example: "2026-09-03T15:30:00Z"
        },
        state: PidroServerWeb.Schemas.InviteSchemas.State
      },
      required: [:code, :url, :share_text, :seat_hint, :label, :expires_at, :state],
      example: %{
        "code" => "7KQ4M2XB",
        "url" => "https://pidro.online/j/7KQ4M2XB",
        "share_text" =>
          "Come play Pidro with me 🃏 https://pidro.online/j/7KQ4M2XB — code 7KQ4-M2XB",
        "seat_hint" => "partner",
        "label" => "Anna",
        "expires_at" => "2026-09-03T15:30:00Z",
        "state" => "open"
      }
    })
  end

  defmodule InviteResponse do
    @moduledoc "Schema for the host's invite response."

    OpenApiSpex.schema(%{
      title: "InviteResponse",
      description: "Response containing the host's invite",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{invite: Invite},
          required: [:invite]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "invite" => %{
            "code" => "7KQ4M2XB",
            "url" => "https://pidro.online/j/7KQ4M2XB",
            "share_text" =>
              "Come play Pidro with me 🃏 https://pidro.online/j/7KQ4M2XB — code 7KQ4-M2XB",
            "seat_hint" => "partner",
            "label" => "Anna",
            "expires_at" => "2026-09-03T15:30:00Z",
            "state" => "open"
          }
        }
      }
    })
  end

  defmodule InvitePreview do
    @moduledoc "Schema for the public invite preview."

    OpenApiSpex.schema(%{
      title: "InvitePreview",
      description:
        "What a landing page may show before anyone signs in; never carries the room code",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          description: "The normalized invite code",
          example: "7KQ4M2XB"
        },
        state: PidroServerWeb.Schemas.InviteSchemas.State,
        host: %Schema{
          type: :string,
          nullable: true,
          description: "Host's display name or username; null once the account is deleted",
          example: "Marcel"
        },
        seats_taken: %Schema{
          type: :integer,
          minimum: 0,
          maximum: 4,
          description: "Occupied positions; 0 when the table is closed",
          example: 1
        },
        seats_total: %Schema{type: :integer, description: "Always 4", example: 4},
        seat_hint: %Schema{
          type: :string,
          nullable: true,
          enum: [:north, :east, :south, :west, :north_south, :east_west, :partner]
        },
        label: %Schema{type: :string, nullable: true, maxLength: 40, example: "Anna"},
        expires_at: %Schema{type: :string, format: :"date-time", example: "2026-09-03T15:30:00Z"},
        next_code: %Schema{
          type: :string,
          description: "Present only when state is `moved`: the invite of the host's new table",
          example: "N4RT8VW2"
        }
      },
      required: [
        :code,
        :state,
        :host,
        :seats_taken,
        :seats_total,
        :seat_hint,
        :label,
        :expires_at
      ],
      example: %{
        "code" => "7KQ4M2XB",
        "state" => "open",
        "host" => "Marcel",
        "seats_taken" => 1,
        "seats_total" => 4,
        "seat_hint" => "partner",
        "label" => "Anna",
        "expires_at" => "2026-09-03T15:30:00Z"
      }
    })
  end

  defmodule InvitePreviewResponse do
    @moduledoc "Schema for the preview response."

    OpenApiSpex.schema(%{
      title: "InvitePreviewResponse",
      description: "Response containing the public invite preview",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{invite: InvitePreview},
          required: [:invite]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "invite" => %{
            "code" => "7KQ4M2XB",
            "state" => "open",
            "host" => "Marcel",
            "seats_taken" => 1,
            "seats_total" => 4,
            "seat_hint" => "partner",
            "label" => "Anna",
            "expires_at" => "2026-09-03T15:30:00Z"
          }
        }
      }
    })
  end

  defmodule MintRequest do
    @moduledoc "Schema for the mint request body."

    OpenApiSpex.schema(%{
      title: "MintInviteRequest",
      description:
        "Optional seat hint, label and the code of an earlier invite this one supersedes (play again)",
      type: :object,
      properties: %{
        seat_hint: %Schema{
          type: :string,
          nullable: true,
          enum: [:north, :east, :south, :west, :north_south, :east_west, :partner],
          description: "Seat preference for whoever redeems"
        },
        label: %Schema{
          type: :string,
          nullable: true,
          maxLength: 40,
          description: "Host's private note on who the link is for"
        },
        supersedes: %Schema{
          type: :string,
          description:
            "Code of an invite the caller hosted; it forwards here with state `moved` while this table waits"
        },
        platform: %Schema{
          type: :string,
          enum: [:ios, :android, :web],
          description: "Client platform, recorded on the funnel event"
        }
      },
      example: %{"seat_hint" => "partner", "label" => "Anna"}
    })
  end

  defmodule RedeemRequest do
    @moduledoc "Schema for the redeem request body."

    OpenApiSpex.schema(%{
      title: "RedeemInviteRequest",
      description: "Optional explicit seat and analytics fields",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :east, :south, :west],
          description:
            "Explicit seat; overrides the invite's hint and answers SEAT_TAKEN when occupied"
        },
        platform: %Schema{type: :string, enum: [:ios, :android, :web]},
        source: %Schema{
          type: :string,
          enum: [:wa, :im, :sms, :qr, :copy],
          description: "How the link travelled"
        }
      },
      example: %{"platform" => "ios", "source" => "wa"}
    })
  end

  defmodule RedeemResponse do
    @moduledoc "Schema for the redeem response."

    OpenApiSpex.schema(%{
      title: "RedeemResponse",
      description:
        "The room after the caller sat down, the seat taken and whether the hint was met",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            room: RoomSchemas.Room,
            position: %Schema{
              type: :string,
              enum: [:north, :east, :south, :west],
              example: "south"
            },
            hint_honored: %Schema{
              type: :boolean,
              description:
                "True when the hinted seat (or an explicit position) was taken, or there was no hint; false on fallback",
              example: true
            }
          },
          required: [:room, :position, :hint_honored]
        }
      },
      required: [:data]
    })
  end
end
