# Recipes: fix a broken filter in 10 minutes

A recipe is one JSON file per platform in `Packages/BreakZeroKit/Sources/Core/Resources/Recipes/`.
It is **data**, interpreted by code bundled in the app (never downloaded code).

## Rules of the road
- **Subtractive only:** hide, redirect, block. Never rewrite DMs, the composer, uploads or login.
- **Language-independent:** match URLs, hrefs, attributes, tag names, ARIA roles, structure. Never
  visible text.
- **Fail safe:** if you can't hide something reliably, add a canary so it gets covered.

## Format

| Field | Meaning |
|---|---|
| `platform`, `version`, `minEngine` | Bump `version` on every change. `minEngine` = oldest app engine that understands it. |
| `hosts` | Where filters run (exact hosts; `*.example.com` for subdomains). |
| `authHosts` | Login/consent hosts: navigation allowed, no filters. |
| `landing` | `default` key + `options` map of key → path. |
| `toggles` | `{id, defaultOn}` — every rule names one; the user switches them in the Wall tab. |
| `scopes` | Named path regexes used by `allowOnce` ("where did we come from"). |
| `routes` | Ordered; first match wins. `action`: `allow`, `block` (→ landing), `redirect` (`to`, with `{name}` captures and `{landing}`), `allowOnce` (`scope`, `key`). |
| `hide` | CSS selectors hidden at document start; optional `routes`. |
| `heuristics` | `anchorHref` (regex on link paths) or `selector`; `hideAncestor` climbs up to N parents but never onto structural containers. |
| `behaviors` | `blockAutoAdvance` (refuse automatic next-video navigation). |
| `allowZones` | Paths where only route rules run (no CSS/heuristics/canaries). |
| `canaries` | `route` + `mustNotExist` (`anchorHref` or `selector`). If found and not hidden by us → blurred + "Filter needs an update". |
| `resourceBlocks` | WebKit content-blocker `urlFilter`s for subresources. |

Regexes must use the subset ICU and JavaScript agree on (no inline flags, lookbehind, possessive or
atomic groups, `\A`/`\z`). Route patterns are anchored with `^` and match the URL **path** only.

## Workflow
1. Reproduce: save the page HTML (scrub names/messages), add it to `jstests/fixtures/`.
2. Write a failing test in `jstests/dom.test.js` (or a route vector in
   `Packages/BreakZeroKit/Tests/CoreTests/Fixtures/route-vectors.json` — Swift and JS both run it).
3. Edit the recipe, bump `version`.
4. `cd jstests && npm test` and `cd Packages/BreakZeroKit && swift test` (validates every recipe).
5. Open a PR. Once signed updates ship (Phase 4), merged recipes reach users without an App Store release.
