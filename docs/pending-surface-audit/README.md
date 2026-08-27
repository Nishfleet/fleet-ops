# Pending: reusable surface-audit workflow (visual-quality matrix extension)

Owner: Nishfleet/fleet-ops#1198. Reference implementation: Nishfleet/0509#1302.

## Why

Wave-1's `visual-check.yml` (screenshot diff + CSS constraint lint + live
canary + AI design reviewer) targets public, logged-out, light-theme pages.
On 2026-08-27 four defects reached a live paying account on 0509 — all four
behind the login, in dark theme, at a wide viewport, on a paid tier. The
wave-1 design as written would have caught **none** of them.

This package adds two axes to the visual program, everywhere it appears:

- **theme** — `{light, dark}` wherever a product has a dark mode. 0509's is
  `data-f9-theme="dark"`, applied on `/app` and `/search`; the token flips
  there are exactly where hardcoded-literal / themed-token pairs break
  (the shipped defect at 2.14:1 lived there).
- **auth state** — `{logged-out} x {each plan tier} x {expired, dunning}`.
  The whole class of "the page says something false for THIS viewer" is
  unreachable without driving the cookie-based fixture sign-in.

## What is in this directory

| file | role |
|---|---|
| `reusable-surface-audit.yml` | The parked reusable workflow (`workflow_call`). Worker App cannot push `.github/workflows/**` directly; a token with Workflows scope should land it at `.github/workflows/reusable-surface-audit.yml` once this PR merges. |
| `surface-audit.json.example` | Sample `surface-audit.json` for product repos to copy and trim. Self-skip when absent. |
| `README.md` | This file. |

## Per-product configuration

Product repos declare their matrix via `surface-audit.json` at the repo
root. Schema (full example in `surface-audit.json.example`):

```json
{
  "matrix": {
    "themes": ["light", "dark"],
    "authStates": ["logged-out", "free", "scout", "starter", "agency", "expired"],
    "viewports": [
      { "name": "mobile", "width": 390, "height": 844 },
      { "name": "desktop", "width": 1440, "height": 900 },
      { "name": "wide", "width": 2000, "height": 900 }
    ],
    "routes": ["/", "/app", "/search"]
  },
  "auth": {
    "method": "cookie",
    "cookieName": "f9_e2e_fixture",
    "fixtureScript": "scripts/e2e-prepare-local.mjs"
  },
  "serve": {
    "command": "npm run preview -- --port 4180 --strictPort",
    "port": 4180
  }
}
```

Validation (in the reusable workflow's "Validate config" step) requires
`matrix.themes`, `matrix.authStates`, `matrix.viewports`, and
`matrix.routes` to each be a non-empty array, every viewport to have
`{name, width, height}`, every theme to be `light` or `dark`, and
`auth.method` to be `cookie`. Theme and auth-state axes are optional in
the sense that a repo with no dark mode sets `themes: ["light"]`; a repo
with no auth gating sets `authStates: ["logged-out"]`.

## Self-skip contract

Repos without `surface-audit.json` skip with a GitHub `::notice::` line, no
Node install wasted. This matches the wave-1 `visual-check.yml` pattern
and the reusable-PR-checks convention — a skipped required check must
never silently disappear.

## Per-product script contract

The consumer repo owns `scripts/surface-audit.mjs`. The reusable passes
the matrix to it via env vars; the per-product script is responsible for:

- serving the product locally (only the consumer knows the right command
  and readiness probe),
- hydrating the auth cookie for the current cell's auth state (via the
  consumer's own fixture script — `auth.fixtureScript` — or live in the
  script),
- setting the viewport (Playwright / Puppeteer / etc.),
- applying the theme (`data-f9-theme="dark"` on 0509; whatever the
  consumer uses),
- running the deterministic rules for that cell (contrast, control-row
  alignment, gutter alignment, horizontal overflow, tap targets, focus
  rings, …),
- writing per-cell artifacts into `OUT_DIR` (default `results/`),
- exiting non-zero when any cell fails.

Env vars the reusable sets:

- `SURFACE_AUDIT_MATRIX` — JSON array of cells, each
  `{theme, authState, viewport, width, height, route}`.
- `SURFACE_AUDIT_CONFIG` — absolute path to `surface-audit.json`.
- `OUT_DIR` — directory for per-cell artifacts (default `results`).

The reusable uploads `OUT_DIR/` as the `surface-audit-results` artifact
on every run (including failure), so a CI failure is inspectable.

## Layout rules

- The reusable never starts the product server itself. Only the consumer
  knows the right command and readiness probe, and a static `npm run
  preview` does not survive every product's stack.
- Theme and auth-state are inputs to the consumer's audit script, not
  branches inside the reusable. The reusable is the boilerplate; the
  rules live in the consumer.
- Live credentials must NOT cross CI. The cookie-based fixture sign-in
  pattern (proven on 0509's `e2e/local-authenticated.spec.ts`) is the
  supported shape.

## Acceptance bar

Per 0509#1302: the per-product script must catch the four shipped
defects against `cf0d3189~3` and pass clean against `main`. An audit
that passes on the commit that shipped them is not an audit.

## How to land this (Nish / Workflows scope required)

The nishfleet-worker App has no `workflows` permission, so these files
cannot land under `.github/workflows/` on this PR. A token with that
scope (Nish) should:

1. `git mv docs/pending-surface-audit/reusable-surface-audit.yml .github/workflows/reusable-surface-audit.yml`.
2. Update the thin caller at `template/.github/workflows/surface-audit.yml`
   to point at `Nishfleet/fleet-ops/.github/workflows/reusable-surface-audit.yml@v1`
   (it is already written that way).
3. Add `bash tests/reusable-surface-audit.test.sh` to the P14
   `verify-command` in `.github/workflows/ci.yml`.
4. Optionally: tag a `v1` ref. Until then, callers using `@v1` fail to
   resolve and the gate stays self-skipped everywhere — the safe default.
5. Delete `docs/pending-surface-audit/`.

Until then, the test `tests/reusable-surface-audit.test.sh` shape-locks
the parked source, the thin caller in `template/`, and the per-product
schema — all in fleet-ops itself, no Workflows permission needed.
