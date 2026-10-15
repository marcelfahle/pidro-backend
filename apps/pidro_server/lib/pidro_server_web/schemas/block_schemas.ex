defmodule PidroServerWeb.Schemas.BlockSchemas do
  @moduledoc "Wire contract for blocking (PID-225)."
  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule ListResponse do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "BlocksResponse",
      type: :object,
      required: [:data],
      properties: %{
        data: %Schema{
          type: :object,
          required: [:blocked],
          properties: %{
            blocked: %Schema{
              type: :array,
              items: %Schema{
                type: :object,
                required: [:user_id, :display_name, :avatar_url],
                properties: %{
                  user_id: %Schema{type: :string, format: :uuid},
                  display_name: %Schema{type: :string, nullable: true},
                  avatar_url: %Schema{type: :string, nullable: true}
                }
              }
            }
          }
        }
      }
    })
  end

  defmodule Error do
    @moduledoc false
    OpenApiSpex.schema(%{
      title: "BlockError",
      type: :object,
      required: [:error],
      properties: %{
        error_code: %Schema{
          type: :string,
          description: "Stable localization key; the legacy error field is unchanged",
          enum: ["account_required", "cannot_block_self", "user_not_found"]
        },
        error_params: %Schema{type: :object, additionalProperties: false},
        error: %Schema{
          type: :string,
          enum: ["ACCOUNT_REQUIRED", "CANNOT_BLOCK_SELF", "USER_NOT_FOUND"]
        }
      }
    })
  end
end
