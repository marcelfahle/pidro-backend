defmodule PidroServerWeb.Schemas.ClassicClaimSchemas do
  @moduledoc false

  require OpenApiSpex
  alias OpenApiSpex.Schema

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
