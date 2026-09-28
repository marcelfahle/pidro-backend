defmodule PidroServerWeb.Schemas.ClassicClaimSchemas do
  @moduledoc false

  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule VerifyRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic ownership verification request",
      properties: %{
        method: %Schema{type: :string, enum: ["password", "apple", "facebook"]},
        login: %Schema{type: :string, description: "Classic username or email"},
        password: %Schema{type: :string},
        identity_token: %Schema{type: :string},
        access_token: %Schema{type: :string},
        install_id: %Schema{
          type: :string,
          maxLength: 64,
          description: "Required when the request has no Bearer token"
        }
      },
      required: [:method]
    })
  end

  defmodule VerifyResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic ownership verification response",
      properties: %{
        data: %Schema{
          type: :object,
          required: [:ticket, :expires_at, :classic],
          properties: %{
            ticket: %Schema{type: :string},
            expires_at: %Schema{type: :string, format: :"date-time"},
            classic: %Schema{
              type: :object,
              required: [:name, :games_played, :level, :member_since],
              properties: %{
                name: %Schema{type: :string},
                games_played: %Schema{type: :integer, minimum: 0},
                level: %Schema{type: :integer, minimum: 0},
                member_since: %Schema{type: :string},
                name_allowed: %Schema{
                  type: :boolean,
                  nullable: true,
                  description: "Populated by the public-name policy in PID-147"
                }
              }
            }
          }
        }
      },
      required: [:data]
    })
  end

  defmodule ClaimRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Classic claim request",
      properties: %{
        ticket: %Schema{
          type: :string,
          description: "Opaque ticket returned by Classic verification"
        },
        install_id: %Schema{type: :string, maxLength: 64},
        account: %Schema{
          type: :object,
          description:
            "Required on a fresh install. Password claims need username, email and password; social claims need username.",
          properties: %{
            username: %Schema{type: :string, minLength: 3},
            email: %Schema{type: :string, format: :email},
            password: %Schema{type: :string, minLength: 8},
            display_name: %Schema{type: :string, minLength: 2, maxLength: 20}
          }
        }
      },
      required: [:ticket]
    })
  end

  defmodule AppleRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Apple sign-in request",
      properties: %{identity_token: %Schema{type: :string}},
      required: [:identity_token]
    })
  end

  defmodule FacebookRequest do
    @moduledoc false
    OpenApiSpex.schema(%{
      type: :object,
      title: "Facebook sign-in request",
      properties: %{access_token: %Schema{type: :string}},
      required: [:access_token]
    })
  end
end
