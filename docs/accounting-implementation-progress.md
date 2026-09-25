# Accounting implementation progress — BUSY requirements

Companion to `docs/accounting-feature-gap-analysis.md`.

## Baseline (26 Sep 2026)

- Schema 0090 locally; production at 0089 (0090 not yet applied).
- `env -u NODE_ENV npm run verify` green at 0090. No pre-existing failures.

## Decisions

- One dealer tenant = one company (F01).
- Sales orders and delivery challans not applicable (F42, F43, F50): bookings are the vehicle order and delivery note; counter and service bills are direct and value-only.
- TDS is built with no seeded rates. A section deducts only after the accountant has entered its rate, threshold, Act, effective dates and source and marked it reviewed.
- Supplier TDS goes to its own ledger, 2745 TDS Payable — Suppliers, so the deduction register ties exactly to its control account. Salary TDS stays on 2740.
- Purchase order → goods receipt → bill for accessories and spares:
  - the receipt brings stock in and credits 2760 Goods Received Not Invoiced;
  - the bill clears GRNI and adds no stock;
  - a rate difference goes to 5970 Stock Adjustments;
  - permissions reuse `purchases.create` / `post` / `cancel`, so no new roles were needed.
- Bill of materials and production are not applicable, because there is no manufacturing.
- PIN-code location lookup is blocked on a licensed postal dataset.
- Quick-add (F20) opens the master in a new tab and refreshes the picker, rather than a modal. The master's own form and validation stay in one place.

## Batches

| Batch | Scope | Migration | Test | Status |
|---|---|---|---|---|
| 0 | Gap analysis, baseline | — | — | Done |
| 1 | Bill-wise opening (F12), split cash/bank voucher (F24), day book (F32), narration templates (F13) | 0091 | `9ZI` (24 assertions) | Done |
| 2 | Purchase order → goods receipt → bill (F33–F37, F40) | 0092 | `9ZJ` (30) | Done |
| 3 | TDS (F61–F67) | 0093 | `9ZK` (24) | Done |
| 4 | Item groups, units and pack conversion, quick-add, shortcuts, calculator (F14, F15, F18, F20–F22) | 0094 | `9ZL` (11), vitest `calc.test.ts` | Done |

## Verification record

- `env -u NODE_ENV npm run verify` green at 0094:
  - typecheck and lint;
  - 129 unit tests;
  - 138 permissions in sync; 85 accounts in all three copies; 181 RPCs; 19 document series; 101 nav entries;
  - db:verify: all 94 migrations plus every SQL test file;
  - production build.
- Restore drill: production dumped read-only, restored locally, `INCREMENTAL-0090-to-0094.sql` applied. Checked as DHARANI's owner:
  - 85 accounts; trial balance 0.00;
  - control tie-out unchanged, with only the known ₹1,115.10 unassigned walk-in bill (review item O7);
  - `tds_control_check` 0 = 0; GRNI empty;
  - ledger master and day book work.

  The copy and dump were deleted afterwards.
- **Not verified:** any screen in a signed-in browser. Every page compiles and calls the RPC named, but none has been clicked through, because `E2E_EMAIL` / `E2E_PASSWORD` are not saved in `.env.local`.

## Remaining gaps

- **F03 PIN lookup:** blocked on a dataset.
- **F75 freight on a stock transfer:** P2.
- **F78–F80 cross-dealer master/transaction bundles:** P2.
- **F14:** item-group filter on stock reports.
- **F24:** split mode on the bank book form. The function already supports it.
- **F64:** TDS on advances paid before a bill.
- **F66:** a TDS return file.
- **O2:** rate limiting on sensitive endpoints, carried from the 25 Sep review.

## Actions for the dealer

1. Apply `supabase/INCREMENTAL-0090-to-0094.sql` in the Supabase SQL editor. It contains 0090–0094; production is at 0089.
2. Say "deploy" to push.
3. Save `E2E_EMAIL` / `E2E_PASSWORD` in `.env.local` for a signed-in screen run.
4. TDS:
   - enter the TAN;
   - enter each section with the rate from the Act and its source, then review it;
   - set each supplier's section, payee type and PAN check;
   - switch TDS on.
