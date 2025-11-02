defmodule PidroServerWeb.Schemas.RoomSchemas do
  @moduledoc """
  OpenAPI schema definitions for Room-related API objects.

  This module defines the OpenAPI 3.0 schemas used in room-related endpoints,
  including game state, player information, cards, bids, tricks, and plays.
  """

  require OpenApiSpex
  alias OpenApiSpex.Schema

  # ==================== Room Schemas ====================

  @doc """
  Schema for a Room object representing a game room.
  """
  defmodule Room do
    OpenApiSpex.schema(%{
      title: "Room",
      description: "A game room for playing Pidro with up to 4 players",
      type: :object,
      properties: %{
        code: %Schema{
          type: :string,
          description: "Unique 4-character room code",
          example: "A1B2",
          minLength: 4,
          maxLength: 4
        },
        host_id: %Schema{
          type: :string,
          description: "User ID of the room host/creator",
          example: "user123"
        },
        player_ids: %Schema{
          type: :array,
          items: %Schema{type: :string},
          description: "List of user IDs currently in the room",
          example: ["user123", "user456", "user789"]
        },
        status: %Schema{
          type: :string,
          enum: [:waiting, :ready, :in_progress, :finished],
          description: "Current status of the room",
          example: "waiting"
        },
        max_players: %Schema{
          type: :integer,
          description: "Maximum number of players allowed",
          example: 4
        },
        created_at: %Schema{
          type: :string,
          format: :"date-time",
          description: "ISO8601 timestamp when the room was created",
          example: "2024-11-02T10:30:00Z"
        }
      },
      required: [:code, :host_id, :player_ids, :status, :max_players, :created_at],
      example: %{
        "code" => "A1B2",
        "host_id" => "user123",
        "player_ids" => ["user123", "user456"],
        "status" => "waiting",
        "max_players" => 4,
        "created_at" => "2024-11-02T10:30:00Z"
      }
    })
  end

  @doc """
  Schema for a single room response.
  """
  defmodule RoomResponse do
    OpenApiSpex.schema(%{
      title: "RoomResponse",
      description: "Response containing a single room object",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            room: Room
          },
          required: [:room]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "room" => %{
            "code" => "A1B2",
            "host_id" => "user123",
            "player_ids" => ["user123", "user456"],
            "status" => "waiting",
            "max_players" => 4,
            "created_at" => "2024-11-02T10:30:00Z"
          }
        }
      }
    })
  end

  @doc """
  Schema for a list of rooms response.
  """
  defmodule RoomsResponse do
    OpenApiSpex.schema(%{
      title: "RoomsResponse",
      description: "Response containing a list of room objects",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            rooms: %Schema{
              type: :array,
              items: Room,
              description: "List of room objects"
            }
          },
          required: [:rooms]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "rooms" => [
            %{
              "code" => "A1B2",
              "host_id" => "user123",
              "player_ids" => ["user123", "user456"],
              "status" => "waiting",
              "max_players" => 4,
              "created_at" => "2024-11-02T10:30:00Z"
            },
            %{
              "code" => "X9Z8",
              "host_id" => "user789",
              "player_ids" => ["user789"],
              "status" => "waiting",
              "max_players" => 4,
              "created_at" => "2024-11-02T10:35:00Z"
            }
          ]
        }
      }
    })
  end

  @doc """
  Schema for room creation response including the room code.
  """
  defmodule RoomCreatedResponse do
    OpenApiSpex.schema(%{
      title: "RoomCreatedResponse",
      description:
        "Response when a room is created, including the room and a convenience code field",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            room: Room,
            code: %Schema{
              type: :string,
              description: "Convenience copy of the room code",
              example: "A1B2"
            }
          },
          required: [:room, :code]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "room" => %{
            "code" => "A1B2",
            "host_id" => "user123",
            "player_ids" => ["user123"],
            "status" => "waiting",
            "max_players" => 4,
            "created_at" => "2024-11-02T10:30:00Z"
          },
          "code" => "A1B2"
        }
      }
    })
  end

  # ==================== Game State Schemas ====================

  @doc """
  Schema for a Card object representing a playing card.
  """
  defmodule Card do
    OpenApiSpex.schema(%{
      title: "Card",
      description:
        "A playing card with rank and suit. Rank values: 2-10 (numeric), 11 (Jack), 12 (Queen), 13 (King), 14 (Ace). Suit values: hearts, diamonds, clubs, spades",
      type: :object,
      properties: %{
        rank: %Schema{
          oneOf: [
            %Schema{type: :integer, description: "Numeric rank 2-10"},
            %Schema{type: :integer, enum: [11, 12, 13, 14], description: "Face cards and Ace"}
          ],
          description: "Card rank (2-14, where 11=Jack, 12=Queen, 13=King, 14=Ace)",
          example: 14
        },
        suit: %Schema{
          type: :string,
          enum: [:hearts, :diamonds, :clubs, :spades],
          description: "Card suit",
          example: :hearts
        }
      },
      required: [:rank, :suit],
      example: %{
        "rank" => 14,
        "suit" => "hearts"
      }
    })
  end

  @doc """
  Schema for a Bid object representing a player's bid.
  """
  defmodule Bid do
    OpenApiSpex.schema(%{
      title: "Bid",
      description: "A bid made by a player during the bidding phase",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Player position",
          example: :north
        },
        amount: %Schema{
          oneOf: [
            %Schema{type: :integer, minimum: 8, maximum: 13, description: "Numeric bid"},
            %Schema{type: :string, enum: ["pass"], description: "Pass indicator"}
          ],
          description: "Bid amount (8-13) or 'pass' to pass",
          example: 8
        }
      },
      required: [:position, :amount],
      example: %{
        "position" => "north",
        "amount" => 8
      }
    })
  end

  @doc """
  Schema for a Play object representing a card played in a trick.
  """
  defmodule Play do
    OpenApiSpex.schema(%{
      title: "Play",
      description: "A card played by a player in a trick",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who played the card",
          example: :north
        },
        card: Card
      },
      required: [:position, :card],
      example: %{
        "position" => "north",
        "card" => %{
          "rank" => 14,
          "suit" => "hearts"
        }
      }
    })
  end

  @doc """
  Schema for a Trick object representing a completed trick.
  """
  defmodule Trick do
    OpenApiSpex.schema(%{
      title: "Trick",
      description: "A completed trick including all plays and winner information",
      type: :object,
      properties: %{
        number: %Schema{
          type: :integer,
          description: "Sequential trick number (1-13)",
          minimum: 1,
          maximum: 13,
          example: 1
        },
        leader: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who led the trick",
          example: :north
        },
        plays: %Schema{
          type: :array,
          items: Play,
          description: "List of cards played in order",
          example: [
            %{
              "position" => "north",
              "card" => %{"rank" => 14, "suit" => "hearts"}
            },
            %{
              "position" => "east",
              "card" => %{"rank" => 13, "suit" => "hearts"}
            }
          ]
        },
        winner: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Position of the player who won the trick",
          example: :north,
          nullable: true
        },
        points: %Schema{
          type: :integer,
          description: "Points earned in this trick",
          minimum: 0,
          example: 15
        }
      },
      required: [:number, :leader, :plays, :points],
      example: %{
        "number" => 1,
        "leader" => "north",
        "plays" => [
          %{
            "position" => "north",
            "card" => %{"rank" => 14, "suit" => "hearts"}
          },
          %{
            "position" => "east",
            "card" => %{"rank" => 13, "suit" => "hearts"}
          }
        ],
        "winner" => "north",
        "points" => 15
      }
    })
  end

  @doc """
  Schema for a Player object representing a player's state in the game.
  """
  defmodule Player do
    OpenApiSpex.schema(%{
      title: "Player",
      description: "A player's current state in the game including hand and stats",
      type: :object,
      properties: %{
        position: %Schema{
          type: :string,
          enum: [:north, :south, :east, :west],
          description: "Player position at the table",
          example: :north
        },
        team: %Schema{
          type: :string,
          enum: [:north_south, :east_west],
          description: "Team assignment (north and south vs east and west)",
          example: :north_south
        },
        hand: %Schema{
          type: :array,
          items: Card,
          description: "Cards currently held by the player",
          example: [
            %{"rank" => 14, "suit" => "hearts"},
            %{"rank" => 13, "suit" => "hearts"}
          ]
        },
        tricks_won: %Schema{
          type: :integer,
          description: "Number of tricks won by this player",
          minimum: 0,
          maximum: 13,
          example: 3
        },
        eliminated: %Schema{
          type: :boolean,
          description: "Whether the player is eliminated from the round",
          example: false
        }
      },
      required: [:position, :team, :hand, :tricks_won, :eliminated],
      example: %{
        "position" => "north",
        "team" => "north_south",
        "hand" => [
          %{"rank" => 14, "suit" => "hearts"},
          %{"rank" => 13, "suit" => "hearts"}
        ],
        "tricks_won" => 3,
        "eliminated" => false
      }
    })
  end

  @doc """
  Schema for the complex game state response.
  """
  defmodule GameStateResponse do
    OpenApiSpex.schema(%{
      title: "GameStateResponse",
      description: "Complete game state for a room including all game information",
      type: :object,
      properties: %{
        data: %Schema{
          type: :object,
          properties: %{
            state: %Schema{
              type: :object,
              title: "GameState",
              description: "The current game state from Pidro.Server",
              properties: %{
                phase: %Schema{
                  type: :string,
                  enum: [
                    :not_started,
                    :setup,
                    :dealing,
                    :bidding,
                    :trump_selection,
                    :playing,
                    :completed
                  ],
                  description: "Current phase of the game",
                  example: :bidding
                },
                hand_number: %Schema{
                  type: :integer,
                  description: "Current hand/round number",
                  minimum: 1,
                  example: 1
                },
                variant: %Schema{
                  type: :string,
                  description: "Game variant being played",
                  example: "standard",
                  nullable: true
                },
                current_turn: %Schema{
                  type: :string,
                  enum: [:north, :south, :east, :west],
                  description: "Position of the player whose turn it is",
                  example: :north,
                  nullable: true
                },
                current_dealer: %Schema{
                  type: :string,
                  enum: [:north, :south, :east, :west],
                  description: "Position of the current dealer",
                  example: :west,
                  nullable: true
                },
                players: %Schema{
                  type: :object,
                  additionalProperties: Player,
                  description: "Map of player positions to player states",
                  example: %{
                    "north" => %{
                      "position" => "north",
                      "team" => "north_south",
                      "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                      "tricks_won" => 0,
                      "eliminated" => false
                    }
                  }
                },
                bids: %Schema{
                  type: :array,
                  items: Bid,
                  description: "List of bids made so far in this hand",
                  example: [
                    %{"position" => "west", "amount" => "pass"},
                    %{"position" => "north", "amount" => 8}
                  ]
                },
                highest_bid: %Schema{
                  type: :object,
                  properties: %{
                    position: %Schema{
                      type: :string,
                      enum: [:north, :south, :east, :west],
                      description: "Position of player with highest bid",
                      example: :north
                    },
                    amount: %Schema{
                      type: :integer,
                      minimum: 8,
                      maximum: 13,
                      description: "Highest bid amount",
                      example: 10
                    }
                  },
                  required: [:position, :amount],
                  description: "The highest bid so far in this hand",
                  nullable: true,
                  example: %{"position" => "north", "amount" => 10}
                },
                bidding_team: %Schema{
                  type: :string,
                  enum: [:north_south, :east_west],
                  description: "Team that made the highest bid",
                  example: :north_south,
                  nullable: true
                },
                trump_suit: %Schema{
                  type: :string,
                  enum: [:hearts, :diamonds, :clubs, :spades],
                  description: "Trump suit for this hand",
                  example: :hearts,
                  nullable: true
                },
                tricks: %Schema{
                  type: :array,
                  items: Trick,
                  description: "List of completed tricks",
                  example: []
                },
                current_trick: Trick,
                trick_number: %Schema{
                  type: :integer,
                  description: "Current trick number being played",
                  minimum: 1,
                  maximum: 13,
                  example: 1,
                  nullable: true
                },
                hand_points: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :integer},
                  description: "Points earned by each team in this hand",
                  example: %{"north_south" => 0, "east_west" => 0}
                },
                cumulative_scores: %Schema{
                  type: :object,
                  additionalProperties: %Schema{type: :integer},
                  description: "Total points for each team across all hands",
                  example: %{"north_south" => 0, "east_west" => 0}
                },
                winner: %Schema{
                  type: :string,
                  description: "Winner of the game (team name)",
                  example: "north_south",
                  nullable: true
                }
              },
              required: [
                :phase,
                :hand_number,
                :players,
                :bids,
                :tricks,
                :hand_points,
                :cumulative_scores
              ],
              example: %{
                "phase" => "bidding",
                "hand_number" => 1,
                "variant" => "standard",
                "current_turn" => "north",
                "current_dealer" => "west",
                "players" => %{
                  "north" => %{
                    "position" => "north",
                    "team" => "north_south",
                    "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                    "tricks_won" => 0,
                    "eliminated" => false
                  },
                  "south" => %{
                    "position" => "south",
                    "team" => "north_south",
                    "hand" => [%{"rank" => 13, "suit" => "hearts"}],
                    "tricks_won" => 0,
                    "eliminated" => false
                  }
                },
                "bids" => [
                  %{"position" => "west", "amount" => "pass"},
                  %{"position" => "north", "amount" => 8}
                ],
                "highest_bid" => %{"position" => "north", "amount" => 8},
                "bidding_team" => "north_south",
                "trump_suit" => nil,
                "tricks" => [],
                "current_trick" => nil,
                "trick_number" => nil,
                "hand_points" => %{"north_south" => 0, "east_west" => 0},
                "cumulative_scores" => %{"north_south" => 0, "east_west" => 0},
                "winner" => nil
              }
            }
          },
          required: [:state]
        }
      },
      required: [:data],
      example: %{
        "data" => %{
          "state" => %{
            "phase" => "bidding",
            "hand_number" => 1,
            "variant" => "standard",
            "current_turn" => "north",
            "current_dealer" => "west",
            "players" => %{
              "north" => %{
                "position" => "north",
                "team" => "north_south",
                "hand" => [%{"rank" => 14, "suit" => "hearts"}],
                "tricks_won" => 0,
                "eliminated" => false
              }
            },
            "bids" => [
              %{"position" => "west", "amount" => "pass"},
              %{"position" => "north", "amount" => 8}
            ],
            "highest_bid" => %{"position" => "north", "amount" => 8},
            "bidding_team" => "north_south",
            "trump_suit" => nil,
            "tricks" => [],
            "current_trick" => nil,
            "trick_number" => nil,
            "hand_points" => %{"north_south" => 0, "east_west" => 0},
            "cumulative_scores" => %{"north_south" => 0, "east_west" => 0},
            "winner" => nil
          }
        }
      }
    })
  end
end
