# Design system

Light glassmorphism, deliberately restrained. Spec §7 asks for a modern premium SaaS ERP that stays
professional and accounting-friendly, and is explicit about two things it does not want: a dark-heavy
admin dashboard, and overused glass.

Tokens live in `src/app/globals.css`.

## Palette

| Role | Token | Value |
|---|---|---|
| Primary | `--color-brand-600` | `#2563eb` |
| Positive | `--color-positive-500` | `#10b981` |
| Warning | `--color-warning-500` | `#f59e0b` |
| Danger | `--color-danger-500` | `#ef4444` |
| Accent | `--color-accent-500` | `#8b5cf6` |
| Text | `--color-ink-800` | `#1e293b` |
| Muted text | `--color-ink-500` | `#64748b` |
| Page ground | `--page-gradient` | very light blue → white |

Light-only. There is no dark palette because §7 rules one out; a toggle would be a feature nobody
asked for and a second surface set to keep honest.

## Where glass applies

This is the rule that keeps §7 from eroding as the app grows.

**Glass** — `.glass`, via the `<Panel>` component:

- Dashboard KPI cards
- The header
- Filter panels and summary panels
- Modal dialogs and the command palette (`.glass-strong`)

**Solid white** — `.surface-solid`, via `<SolidPanel>`:

- Every operational table
- Anything holding dense rows of numbers

An accountant reading four hundred rows needs contrast, not translucency. §7 says it plainly: *"Do
not make tables excessively transparent."*

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
| `ui/panel.tsx` | `Panel` (glass) and `SolidPanel` (opaque) |
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
