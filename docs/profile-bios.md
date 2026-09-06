# Profile biographies

`bio` is public profile text. It is nullable and limited to 280 Unicode scalar values after CRLF/CR is normalized to LF and the documented ECMAScript whitespace set is trimmed from both ends. Interior newlines and Unicode normalization forms are preserved; invalid Unicode and U+0000 are rejected.

- `PATCH /api/v1/profile` accepts only `bio`; omitted `bio` is a no-op and `null` or normalized-empty text clears it.
- `GET /api/v1/profile` includes `username`, `display_name`, `avatar_url`, and `bio` alongside progression data.
- Authenticated `GET /api/v1/profiles/:id` (including guest authentication) exposes exactly `user_id`, `username`, `display_name`, `avatar_url`, and `bio`. A missing or malformed UUID returns 404.

The frozen trim set is U+0009–000D, U+0020, U+00A0, U+1680, U+2000–200A, U+2028–2029, U+202F, U+205F, U+3000, and U+FEFF. U+0085 and U+200B are not trimmed. No NFC/NFKC normalization is applied. Composite emoji and combining marks count separately; clients share fixtures for these rules and must not rely on UTF-16 `maxLength`.

Guest accounts are eligible and upgrades preserve the same user row. Bios are visible to authenticated profile viewers (including other guests), never rendered as markup, and refreshed when a profile is opened. Authentication is an access gate, not a confidentiality guarantee.
