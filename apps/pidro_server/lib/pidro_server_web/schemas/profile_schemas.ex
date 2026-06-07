defmodule PidroServerWeb.Schemas.ProfileSchemas do
  @moduledoc """
  OpenAPI schemas for the player profile API (PID-54).

  Documents the full profile screen returned by `GET /api/v1/profile`:
  headline lifetime stats, skill tier + provisional state, veteran
  progression, heritage badges, playstyle, and mastery achievements.

  The raw rating internals (`rating_mu`, `rating_sigma`, `rating_games_count`)
  are intentionally ABSENT from this schema — skill is exposed only as a derived
  `tier` + `provisional` state. The schema itself documents the exclusion.

  Uses OpenApiSpex.Schema for type safety and documentation.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  defmodule PlayerProfileResponse do
    @moduledoc """
    Response containing the authenticated user's full profile screen.

    Includes headline lifetime stats, skill (tier + provisional state only —
    NO raw μ/σ), veteran progression, heritage badges, playstyle, and mastery
    achievements. All keys are snake_case and wrapped in a `data` envelope.
    """

    OpenApiSpex.schema(%{
      type: :object,
      title: "Player Profile Response",
      description: "Response containing the authenticated user's full profile screen",
      properties: %{
        data: %Schema{
          type: :object,
          description: "Response data envelope containing the player profile",
          properties: %{
            user_id: %Schema{
              type: :string,
              format: :uuid,
              description: "The profile owner's user id",
              example: "b1f0c2e4-1111-2222-3333-444455556666"
            },
            games_played: %Schema{
              type: :integer,
              description: "Total number of games the user has participated in",
              minimum: 0,
              example: 42
            },
            wins: %Schema{
              type: :integer,
              description: "Total number of games won by the user",
              minimum: 0,
              example: 25
            },
            losses: %Schema{
              type: :integer,
              description: "Total number of games lost by the user",
              minimum: 0,
              example: 17
            },
            win_rate: %Schema{
              type: :number,
              format: :double,
              description: "Win rate as a decimal (0.0 to 1.0, or 0.0 if no games played)",
              minimum: 0.0,
              maximum: 1.0,
              example: 0.595
            },
            first_seen_at: %Schema{
              type: :string,
              format: "date-time",
              nullable: true,
              description: "When the account was first seen (account creation time)",
              example: "2025-11-02T08:14:00Z"
            },
            account_age_days: %Schema{
              type: :integer,
              nullable: true,
              description: "Age of the account in whole days",
              minimum: 0,
              example: 217
            },
            skill: %Schema{
              type: :object,
              description:
                "Derived skill tier + provisional state. The raw rating internals " <>
                  "(mu/sigma/rated-game count) are intentionally NOT exposed.",
              properties: %{
                tier: %Schema{
                  type: :string,
                  description: "The player's skill tier (or the provisional gate)",
                  enum: ["provisional", "bronze", "silver", "gold", "platinum", "master"],
                  example: "gold"
                },
                provisional: %Schema{
                  type: :boolean,
                  description:
                    "True while the player has too few rated games or too high uncertainty",
                  example: false
                }
              },
              required: [:tier, :provisional]
            },
            veteran: %Schema{
              type: :object,
              description: "Veteran progression: level, XP, title, and progress to next level",
              properties: %{
                level: %Schema{
                  type: :integer,
                  description: "Current veteran level",
                  minimum: 0,
                  example: 7
                },
                xp: %Schema{
                  type: :integer,
                  description: "Lifetime veteran XP",
                  minimum: 0,
                  example: 1480
                },
                title: %Schema{
                  type: :string,
                  description: "Title for the current level",
                  example: "Seasoned"
                },
                progress: %Schema{
                  description:
                    "Progress into the current level as a `[into, span]` integer pair, " <>
                      "or the string \"max\" once the level cap is reached",
                  oneOf: [
                    %Schema{
                      type: :array,
                      items: %Schema{type: :integer},
                      minItems: 2,
                      maxItems: 2,
                      example: [120, 210]
                    },
                    %Schema{type: :string, enum: ["max"]}
                  ],
                  example: [120, 210]
                }
              },
              required: [:level, :xp, :title, :progress]
            },
            heritage: %Schema{
              type: :array,
              description:
                "Display list of heritage badges (e.g. Pidro 1 veteran, founding member)",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "founding_member"},
                  label: %Schema{type: :string, example: "Founding Member"},
                  value: %Schema{description: "Badge value (typically boolean)", example: true}
                },
                required: [:key, :label, :value]
              },
              example: [
                %{"key" => "played_pidro_one", "label" => "Played Pidro 1", "value" => true},
                %{"key" => "founding_member", "label" => "Founding Member", "value" => true}
              ]
            },
            playstyle: %Schema{
              type: :object,
              description:
                "Bidding playstyle: win rate, aggression meter + label, avg winning bid",
              properties: %{
                bidding_win_rate: %Schema{
                  type: :number,
                  format: :double,
                  nullable: true,
                  description:
                    "Bidding win rate (0.0 to 1.0); null when there is insufficient data",
                  example: 0.61
                },
                aggression_needle: %Schema{
                  type: :number,
                  format: :double,
                  description:
                    "Aggression meter position (0.0 to 1.0; 0.5 when insufficient data)",
                  example: 0.72
                },
                aggression_label: %Schema{
                  type: :string,
                  description: "Human-readable aggression label",
                  example: "Aggressive"
                },
                aggression_insufficient: %Schema{
                  type: :boolean,
                  description:
                    "True when there is not enough bidding data to characterize playstyle",
                  example: false
                },
                avg_winning_bid: %Schema{
                  type: :number,
                  format: :double,
                  nullable: true,
                  description: "Average winning bid; null when the player has never won a bid",
                  example: 9.4
                }
              },
              required: [
                :bidding_win_rate,
                :aggression_needle,
                :aggression_label,
                :aggression_insufficient,
                :avg_winning_bid
              ]
            },
            achievements: %Schema{
              type: :array,
              description: "Earned achievements, joined to the catalog for display copy",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "first_win"},
                  name: %Schema{type: :string, example: "First Win"},
                  description: %Schema{type: :string, example: "Win your first game"},
                  tier: %Schema{type: :integer, example: 1},
                  awarded_at: %Schema{
                    type: :string,
                    format: "date-time",
                    example: "2025-11-05T19:30:00Z"
                  }
                },
                required: [:key, :name, :description, :tier, :awarded_at]
              }
            },
            achievements_catalog: %Schema{
              type: :array,
              description: "Active achievement catalog annotated with an `earned` flag",
              items: %Schema{
                type: :object,
                properties: %{
                  key: %Schema{type: :string, example: "ten_wins"},
                  name: %Schema{type: :string, example: "Ten Wins"},
                  description: %Schema{type: :string, example: "Win ten games"},
                  tier: %Schema{type: :integer, example: 2},
                  earned: %Schema{type: :boolean, example: false}
                },
                required: [:key, :name, :description, :tier, :earned]
              }
            }
          },
          required: [
            :user_id,
            :games_played,
            :wins,
            :losses,
            :win_rate,
            :first_seen_at,
            :account_age_days,
            :skill,
            :veteran,
            :heritage,
            :playstyle,
            :achievements,
            :achievements_catalog
          ]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "user_id" => "b1f0c2e4-1111-2222-3333-444455556666",
          "games_played" => 42,
          "wins" => 25,
          "losses" => 17,
          "win_rate" => 0.595,
          "first_seen_at" => "2025-11-02T08:14:00Z",
          "account_age_days" => 217,
          "skill" => %{"tier" => "gold", "provisional" => false},
          "veteran" => %{
            "level" => 7,
            "xp" => 1480,
            "title" => "Seasoned",
            "progress" => [120, 210]
          },
          "heritage" => [
            %{"key" => "played_pidro_one", "label" => "Played Pidro 1", "value" => true},
            %{"key" => "founding_member", "label" => "Founding Member", "value" => true}
          ],
          "playstyle" => %{
            "bidding_win_rate" => 0.61,
            "aggression_needle" => 0.72,
            "aggression_label" => "Aggressive",
            "aggression_insufficient" => false,
            "avg_winning_bid" => 9.4
          },
          "achievements" => [
            %{
              "key" => "first_win",
              "name" => "First Win",
              "description" => "Win your first game",
              "tier" => 1,
              "awarded_at" => "2025-11-05T19:30:00Z"
            }
          ],
          "achievements_catalog" => [
            %{
              "key" => "first_win",
              "name" => "First Win",
              "description" => "Win your first game",
              "tier" => 1,
              "earned" => true
            },
            %{
              "key" => "ten_wins",
              "name" => "Ten Wins",
              "description" => "Win ten games",
              "tier" => 2,
              "earned" => false
            }
          ]
        }
      }
    })
  end
end
