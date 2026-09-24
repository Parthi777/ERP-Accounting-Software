# Design system

Light claymorphism, restrained. Spec §7 asks for a modern premium SaaS ERP that stays
professional and accounting-friendly; it rules out a dark-heavy admin dashboard. The chrome is soft
clay; the data is flat.

Tokens live in `src/app/globals.css`. The approved mockup is the Claude Design canvas
*ERP Claymorphism Redesign* (dashboard, journal entries, component sheet).

## Palette

| Role | Token | Value |
|---|---|---|
| Primary | `--color-brand-600` | `#2f5bd8` |
| Positive | `--color-positive-700` | `#1e7a55` on `#e4f6ee` |
| Warning | `--color-warning-700` | `#8a5200` on `#fdf1dc` |
| Danger | `--color-danger-700` | `#a11d26` on `#fce4e5` |
| Accent | `--color-accent-600` | `#4a36a8` on `#eeeafc` |
| Text | `--color-ink-800` | `#1b2638` |
| Muted text | `--color-ink-500` | `#5b6b82` |
| Page ground | `--page-ground` | `#e9eff8` |
| Clay surface | `--clay-bg` | `#f3f6fc` |

Typeface: Plus Jakarta Sans, self-hosted by `next/font` (`--font-jakarta`), tabular figures for money.

Light-only. There is no dark palette because §7 rules one out.

## Where clay applies

This is the rule that keeps §7 from eroding as the app grows.

**Raised clay** — `.glass` (the name is kept so no screen had to change), via `<Panel>`:

- Dashboard KPI cards, filter panels, summary panels
- `.glass-strong` (higher): the header bar, menus, modal dialogs, the command palette
- `.clay-raised`: secondary buttons, the active sidebar item, avatars
- `.clay-pebble`: the small pastel tile an icon sits on

**Pressed in** — `.field` for every input and select, `.clay-pit` for wells (search, filter chips,
the "needs attention" rows, inline figures).

**Solid white** — `.surface-solid`, via `<SolidPanel>`:

- Every operational table
- Anything holding dense rows of numbers

An accountant reading four hundred rows needs contrast, not depth. No clay inside a grid of figures.

`Panel` and `SolidPanel` sit in the same file (`src/components/ui/panel.tsx`) so the choice is
explicit at every call site rather than a default someone drifts away from.

## Numbers

Financial columns are right-aligned with tabular figures — the `numeric` utility. Digits then line up
vertically, which is the entire reason financial statements are set that way.

Indian grouping throughout: `₹1,25,000.00`. `formatINRShort()` gives `₹1.69 Cr` / `₹14.85 L` for KPI
tiles where the full figure will not fit.

## Density and motion

Desktop-first, dense but readable (§8). Sticky table headers via `.table-sticky`. Compact rows.

Animation is minimal by intent — §8 rules out excessive animation, and charts have
`isAnimationActive={false}` so a figure never appears to change while someone is reading it.
`prefers-reduced-motion` is honoured outright.

## Accessibility

- `:focus-visible` gets a 2px brand-blue ring at 2px offset
- Icons are `aria-hidden`; interactive controls carry labels
- Status is never conveyed by colour alone — badges carry text
- Errors use `role="alert"`
- Tables carry captions; headers use `scope="col"`

## Components

| Component | Purpose |
|---|---|
| `ui/panel.tsx` | `Panel` (raised clay) and `SolidPanel` (flat, opaque) |
| `ui/button.tsx` | primary, secondary, ghost, subtle, danger, link |
| `ui/badge.tsx` | Status badges mapped to the §7 palette |
| `ui/input.tsx` | Input, Label, FieldError for inline validation |
| `data-table/data-table.tsx` | Sticky-header table with right-aligned numeric columns |
| `dashboard/kpi-card.tsx` | KPI tile, including the "awaiting module" state |
| `layout/*` | Sidebar, header, branch switcher, command palette |

## The "awaiting module" state

A KPI whose source module is not built renders a dash, a phase badge and a one-line explanation —
never a number.

Spec §61 forbids building fake accounting behaviour to make the UI look complete. A card reading
"Phase 4 — unit counts arrive with the vehicle sales module" tells the truth and tells you when it
changes. A plausible figure that means nothing does neither, and is worse than blank because someone
will eventually act on it.
