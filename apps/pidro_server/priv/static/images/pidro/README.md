# Mobile card artwork

The 52 PNG faces and cardback are byte-for-byte copies from
`pidrogame/pidro-frontend` commit `df95bb8b6845f738cc669d840f17f51b86b4eb08`:

- `packages/mobile/assets/images/cards/*.png`
- `packages/mobile/assets/images/cardback.png`

This follows the copy-only export in `packages/mobile/scripts/sync-card-assets.mjs`.
Names are `{suit}_{rank}.png`, ranks 2–14. HTML uses the mobile 78:110 aspect ratio.
No old web-client art, game logic, persona definitions or new drawings are included.
Bot portraits come from the separate catalogue's optional `bot_profile.avatar_url`.
