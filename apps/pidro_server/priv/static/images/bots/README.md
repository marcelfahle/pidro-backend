# Bot portrait provenance

These are static exports of the actual frontend artwork, not replacements or
redrawings. Exported on 2026-10-22 from an authenticated `gh repo clone` into
`/tmp` (no frontend checkout or dependencies were added to this repository).

- Repository: `pidrogame/pidro-frontend`
- Exact source commit: `df95bb8b6845f738cc669d840f17f51b86b4eb08`
- Artwork: `packages/mobile/src/components/ui/BotPersonaFace.tsx`
- Palette: `packages/mobile/src/design/tokens.ts`, at the same commit
- Source link: https://github.com/pidrogame/pidro-frontend/blob/df95bb8b6845f738cc669d840f17f51b86b4eb08/packages/mobile/src/components/ui/BotPersonaFace.tsx

## Export method

The unchanged `BotPersonaFace.tsx` was bundled in a temporary directory with
esbuild 0.25.12 (`platform: node`, `format: cjs`, `jsx: automatic`). Its
`@/design/tokens` import was aliased to the original `tokens.ts`. The type-only
shared import was erased by the TSX compiler. React and react-dom were 19.2.3.

The `react-native-svg` import was aliased to this minimal DOM adapter:

```js
const React = require('react');
exports.__esModule = true;
exports.default = ({ children, ...props }) =>
  React.createElement('svg', {
    xmlns: 'http://www.w3.org/2000/svg', ...props
  }, children);
for (const name of ['Circle', 'Ellipse', 'G', 'Path', 'Rect']) {
  exports[name] = ({ children, ...props }) =>
    React.createElement(name.toLowerCase(), props, children);
}
```

For each of `marcel`, `antti`, and `jocke`, the corresponding file is exactly
`renderToStaticMarkup(React.createElement(BotPersonaFace, { persona }))` plus a
trailing newline. React serializes SVG properties such as `strokeWidth` to
`stroke-width`. No path editing, simplification, recoloring, rasterization,
extra clipping, or invented geometry was applied.

The source's `viewBox="0 0 100 100"`, percentage dimensions, blue background,
layer order, alpha colors, and `translate(50 58) scale(1.12) translate(-50 -58)`
are preserved. The component itself is square; its enclosing frontend avatar
provides the circular crop. Apply that crop in the consuming UI if needed,
rather than changing the artwork.

## Validation

All three files parsed successfully as XML with only SVG vector elements and
no external resources or scripts. Chromium opened each standalone SVG at
400 × 400 CSS pixels / 2× DPR without parser errors. Screenshots were inspected:
Marcel has the trucker cap, coffee and six-card fan; Antti has the black beanie,
ginger beard and red/white scarf; Jocke has long hair, round glasses, moustache,
waistcoat and a heart card. No application code was changed by this export.

SHA-256:

```text
07647b203329ed94b3fc165bcc3e1d4a7e0e891aa51fb7a072718705082389e0  marcel.svg
73df0d10068d2797a964f8df78eca9bf76a13d3f418f38e86bb85371ffc6f789  antti.svg
171581d23b36a837df72454f1fd90e6555c790989f962e99c8e9a4def6149cb8  jocke.svg
```
