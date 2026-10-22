# Watch table evidence

Implementation checkpoint; browser/integration verification is still in progress.
Branch: `admin-ops/watch-table`. Do not deploy this checkpoint independently.

- Observation is default. Table/Activity/Seats & bots/Inspect do not execute game
  actions; the server rejects intervention events outside Controls and in replay.
- Seats come from `RoomManager.get_seat_lifecycle/1`, which bulk-resolves accounts
  using `SeatLifecycle.with_names/1`, independent of the recent-user selector.
- `CardComponents.watch_table/1` is intrinsically read-only, accepts plain maps,
  and performs no process/DB calls. Archive UI may pass an allowlisted finite
  presentation conversion of JSON snapshots; no struct loading is necessary.
- Optional seat `bot_profile` uses the exact catalogue `name` and `avatar_url`;
  no persona enum or derived image path. Bot links go to `/admin/bots`.
- Mobile PNG cards are copied verbatim; provenance lives in
  `apps/pidro_server/priv/static/images/pidro/README.md`.
- Independent review found stale replay event bounds on return to live; fixed
  and covered by a regression. No rules, channel, router or catalogue changes.

## Checks on the origin/main-based checkpoint

`mise exec -- mix precommit`: exit 0; engine and server suites passed, including
server 1960 tests/doctests, 1 skipped; format, compilation, diff Credo and Dialyzer
passed. Latest small CSS sizing and bot-status refresh adjustments follow that
run and will be rechecked before final delivery.

`mise exec -- mix test apps/pidro_server/test/pidro_server_web/live/dev/game_detail_live_test.exs apps/pidro_server/test/pidro_server/games/game_topic_contract_test.exs`:
18 passed. Covers outside-recent-20 identity, blocked mutation, intentional undo,
fourth opaque bot metadata, private perspective and replay/live isolation.

## Integration seams

The coordinator supplies bot catalogue enrichment/portraits and the history
route. Watch links to `/admin/history?room_code=CODE`. The archive renderer
contract uses atom-key plain game maps: `players[position].hand` tuples,
`players[position].cold`, `phase`, `current_turn`, `current_dealer`, `trump_suit`,
`highest_bid` tuple, `current_trick.plays` position/card tuples and `number`,
`hand_number`, `cumulative_scores`, `winner`. `seats` are keyed by position and
contain lifecycle identity/status plus optional `bot_profile`. `perspective`
is `:all` or an allowlisted position. Missing state fields default safely.

Current live replay freezes game state, not roster identity; the UI says so.
Bot reasoning and connection transitions are bounded, session-local diagnostics,
not historical archives. The legacy interactive tools remain in Controls.
