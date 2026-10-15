Implement additive translatable server error contracts in the attached contract.
Work in marcelfahle/pidro-backend, branch feat/localized-error-contract.
Read server/engine instructions and existing contracts/tests. Do the work and
open a draft PR, not merely an audit. Do not change game rules or success shapes.

First inventory current app-facing REST/channel error shapes. Publish the actual
code manifest early at docs/contracts/localization-errors.json and push it so the
frontend orb can integrate. This must be a machine-readable list with code,
parameter schema, source route/event and English meaning. Define a compact,
consistent vocabulary grounded in real domain failures; reuse existing stable
codes and retain old fields including English reason/message/detail and statuses.

Cover current game/lobby/auth/invite/friends/profile errors users encounter;
validation field errors need stable field identity and codes without changing
old field structures. Document any exact new shape. Do not expose sensitive
server exceptions or credentials in error_params. Keep generic fallbacks explicit.
No localization service, locale storage, game-engine strings or translated
broadcasts: two players in one room may each use different UI languages.

Test backward compatibility and errors for representative REST and channel
paths, including unknown/internal reasons and field validation. Run mix precommit
and Backend CI, fix actual regressions, review full diff and useful review comments.
Cross-link frontend branch feat/english-swedish-localization/PR in the description.
Write concise rollout notes with the manifest, covered paths, gaps and checks.
Keep rebased per contract. Leave the PR open for review; do not merge or deploy.
