# Accounting feature gap analysis — BUSY course requirements F01–F84

Assessed 26 September 2026 against the repository at schema 0090, and updated
after batches 1–4 (0091–0094). Production is at 0089 until
`supabase/INCREMENTAL-0090-to-0094.sql` is applied.
Requirements source: `BUSY_Video_Features_and_Webapp_Requirements.md`.

## How to read this

**Status**

- **Complete** — the connected behaviour exists and is exercised by an SQL
  integrity test under `supabase/test/` (run by `npm run db:verify` against a
  fresh PostgreSQL 16), or traced UI → server action → RPC → tables.
- **Partial** — part of the requirement exists; the gap column says what is not.
- **Missing** — nothing implements it.
- **N/A** — deliberately out of scope for a two-wheeler dealership, with the reason.
- **Blocked** — needs something outside the codebase (data, credentials, a decision).

**Verification limits.** SQL behaviour is verified by the integrity tests. Screens
are verified by `next build` (type-checked, compiled) but **not** by a signed-in
browser run: the Playwright suite needs `E2E_EMAIL` / `E2E_PASSWORD` in
`.env.local`, which are not saved. Wherever a row says "UI", read "compiled and
wired to the RPC named, not clicked through".

**Scope decisions** (dealer, 26 Sep 2026): TDS is built with rates entered by the
accountant, none seeded; purchase order → goods receipt → bill is built; sales
orders and delivery challans are not applicable; one dealer tenant is one company.

**Priority** follows the source document: P0 before live posting, P1 first
operational release, P2 later, P3 optional.

---

## 1. Company and account masters

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F01 | Multiple company records | Complete (by decision) | Every table is `dealer_id`-scoped with RLS (0002, 0004, 0009); `provision_dealer()` 0056; `/admin/dealers`; test `10_rls_isolation`, `9G_dealer_provisioning` | One login belongs to one dealer; there is no in-app company switch. A second legal entity is a second dealer tenant (decision 26 Sep) | P0 | None |
| F02 | Company details and financial year | Complete | `dealers` (legal name, GSTIN, state, `fy_start_month`) 0002; `accounting_periods`; `create_financial_year()` 0090; `/accounting/financial-years`; test `9ZH` | — | P0 | Done in 0090 |
| F03 | Location from PIN | Blocked | — | Needs a maintained postal dataset (India Post PIN directory) with a licence and refresh process | P2 | Deferred; state code is already derived from GSTIN |
| F04 | Edit / delete company | Complete | Dealer edit and status switch (`dealer_status_gate` 0055); `purge_dealer()` guarded; `/admin/dealers`; test `9G` (suspend/reactivate) | Destructive purge is platform-admin only, as it should be | P0 | — |
| F05 | Feature configuration | Complete | `system_settings` 0008; admin settings page (GST, HSN, quick bill, e-invoice, narrations); TDS on/off and TAN in `tds_deductor` (0093) | — | P0 | — |
| F06 | Default chart of accounts | Complete | `app.seed_chart_of_accounts` chain, 85 accounts incl. 17 groups, 2760 GRNI and 2745 TDS Payable — Suppliers; idempotent (`on conflict do nothing`); test `9G` asserts 85; `check:lists` compares migration vs seed | — | P0 | — |
| F07 | Account master maintenance | Complete | `create_account` / `set_account_status` 0076; `update_account` + `alias` 0090; `/accounting/ledgers`, `/accounting/ledgers/[kind]/[id]`; test `9ZH` | Print name separate from alias not modelled (alias serves both) | P0 | — |
| F08 | Account group hierarchy | Complete | 17 BUSY groups, `update_account` refuses cycles, 0076 guard enforces same-type parent; `/accounting/ledger-groups`; test `9ZH` | — | P0 | — |
| F09 | Dr/Cr opening balances | Complete | `post_opening_balances` 0066/0067 (bulk), `set_ledger_opening_balance` 0090 (per ledger, difference-only, against 3300); tests `9O`, `9ZH` | Mid-year migration vs year opening is distinguished only by the date chosen | P0 | — |
| F10 | Depreciation | Complete | `fixed_assets`, `fixed_asset_depreciation`, `run_depreciation()` 0082; `/accounting/fixed-assets` | Book policy only; no separate tax-depreciation block | P2 | — |
| F11 | Customer / vendor masters | Complete | `customers` 0013, `suppliers` 0040, `finance_companies` 0016; control accounts via `accounting_rules`; GSTIN/PAN checks; tests `30`, `92` | — | P0 | — |
| F12 | Bill-wise opening allocation | Complete | `opening_bills`, `post_opening_bills()` 0091; `party_open_items` / `party_ageing` read each bill's number and date; bill-wise CSV mode on `/accounting/opening-balances`; opening bills listed on the party's ledger page; test `9ZI` | — | P0 | Done (0091). UI build-verified |
| F13 | Narration templates | Complete | `narration_templates` 0091; managed on `/admin/settings`; suggested in cash receipts/payments and journal narration; test `9ZI` (RLS) | — | P1 | Done (0091). UI build-verified |

## 2. Inventory masters and data entry

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F14 | Item groups | Complete | `item_groups` (nested) 0094, backfilled from categories; `/masters/item-groups`; group on the item form; test `9ZL` | Group filter on stock reports not added | P1 | Done (0094) |
| F15 | Units | Complete | `units` master with decimals and GST UQC 0094; `inventory_items.uom` references it; item forms read it; test `9ZL` | — | P1 | Done (0094) |
| F16 | Item master | Complete | `inventory_items` (code, name, type, brand, HSN, tax code, cost, price, reorder, fitment) 0016; `/masters/accessories`, `/masters/spares` | — | P1 | — |
| F17 | Opening stock qty and value | Complete | Opening stock upload (0036, `/inventory/upload`); stock lots carry cost; `control_account_tieout()` reconciles 1500–1700 to stock; test `93_opening_stock` | — | P0 | — |
| F18 | Unit conversion | Complete | `item_unit_conversions`, `app.unit_factor()` 0094; pack sizes panel on item edit; purchase orders entered in packs stored in the base unit; test `9ZL` (2 BOX × 12 → 24 NOS at ₹100) | Conversion on counter/service bills not needed (value-only) | P1 | Done (0094) |
| F19 | Closing stock report | Complete | `inventory_stock_report()`, `vehicle_stock_report()`; `/reports/inventory` | — | P1 | — |
| F20 | Inline master creation | Complete (new tab) | `QuickAdd` beside supplier/item/customer pickers on purchase order, purchase bill and cash entry forms: opens the master's own form in a new tab, then refreshes the list without losing the voucher | Not a modal; journal-entry party picker not wired | P1 | Done. UI build-verified |
| F21 | Keyboard entry | Complete | `src/config/shortcuts.ts`: Alt+Shift+R/P/J/D/L open receipt, payment, journal, day book, ledgers (only if the role sees them); Alt+S saves the form in focus; listed in the command palette | — | P2 | Done. UI build-verified |
| F22 | Calculator | Complete | `src/lib/calc.ts` (parser, no eval) with vitest `calc.test.ts`; `AmountInput` in cash, split voucher, journal and opening-balance fields | — | P2 | Done |

## 3. Accounting transactions

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F23 | Payment vouchers | Complete | `record_cash_transaction` / `record_bank_transaction` (0030/0031/0041/0061, idempotent); `/cash-book/payments`, `/bank/book`; tests `60`, `9A`, `9L` | — | P0 | — |
| F24 | Multi-line payment | Complete | `record_money_voucher()` 0091: one cash/bank row, one balanced journal, idempotent; "Split over several accounts" mode in the cash entry form; test `9ZI` | Bank book form not yet given the split mode (function supports it) | P1 | Done (0091) |
| F25 | Simple and Dr/Cr screens | Complete | Cash/bank forms (simple) and `post_manual_journal` 0069 (Dr/Cr) both post through `app.post_journal`; test `9R` | — | P0 | — |
| F26 | Receipt vouchers | Complete | Receipts with party tag; unapplied amounts stay open items until `allocate_party_payment` 0050; test `9B` | — | P0 | — |
| F27 | Contra | Complete | `record_contra` 0077 writes both books; `post_journal` refuses two money ledgers on a single book entry; test `9X` | — | P0 | — |
| F28 | General journal | Complete | `post_manual_journal` with approval (0081) and attachments; test `9R`, `9Z` | — | P0 | — |
| F29 | Short and long narration | Complete | Line and header narration; `reference` columns on cash/bank rows | — | P1 | — |
| F30 | Voucher list and modification | Complete | `/accounting/journals` list; posted entries corrected by `reverse_journal` + Correct (0088); drafts via approvals; test `40`, `9ZG` | — | P0 | — |
| F31 | Voucher series | Complete | `document_sequences`, `next_document_number()` with row lock, per dealer/FY token (0006, 0039, 0072); test `91`, `9T` | — | P0 | — |
| F32 | Day book | Complete | `day_book()` 0091; `/accounting/day-book` with vouchers, lines, parties, day totals and each branch's cash position; test `9ZI` (day book = day's movement) | — | P0 | Done (0091). UI build-verified |

## 4. Purchase to payment

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F33 | Purchase order | Complete | `purchase_orders` / lines, `create_purchase_order`, `approve_purchase_order`, `close_purchase_order` 0092; `/purchases/orders`; test `9ZJ` | — | P1 | Done (0092) |
| F34 | Goods receipt / challan | Complete | `goods_receipts`, `post_goods_receipt()` 0092 — stock in at the order rate, Cr 2760 GRNI; `cancel_goods_receipt()`; test `9ZJ` | — | P1 | Done (0092) |
| F35 | Receipt from order | Complete | Receipt form on the order fills what is still to come; over-receipt refused in SQL; test `9ZJ` | — | P1 | Done (0092) |
| F36 | Transport details | Complete | Challan no., transporter, LR, vehicle, origin, PIN on `goods_receipts` 0092; test `9ZJ` | — | P1 | Done (0092) |
| F37 | Bill against receipt | Complete | `purchase_bill_lines.grn_line_id`; `add_receipt_lines_to_bill`, `unbilled_receipt_lines` 0092; posting adds no stock, clears GRNI, rate difference to 5970; over-billing refused; test `9ZJ` | — | P0 | Done (0092) |
| F38 | Purchase return | Complete | `post_purchase_return`, `returnable_purchase_lines` 0057; test `9H` | — | P1 | — |
| F39 | Supplier settlement | Complete | `allocate_party_payment` refuses over-allocation 0050; test `9B` | — | P0 | — |
| F40 | Pending purchase orders | Complete | `pending_purchase_orders()` 0092 with overdue flag; "Pending items" and "Received, not billed" views; test `9ZJ` | — | P1 | Done (0092) |
| F41 | Accounts payable | Complete | `party_ageing` 0080; `/accounting/ageing`, `/accounting/supplier-ledger` | — | P0 | — |

## 5. Order to cash

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F42 | Sales order | N/A | Vehicle booking (0020, 0046) is the order: customer, model, advance, allocation | Counter and service bills are direct and value-only (dealer decision 25 Sep) | — | Recorded decision |
| F43 | Delivery challan | N/A | Vehicle delivery (0038 sequence, `/sales` deliveries) | As F42 | — | — |
| F44 | Sales invoice | Complete | `post_vehicle_sale` 0025/0049 (one issue of the chassis); counter/quick bills 0047/0088; tests `50`, `98`, `9ZF` | — | P0 | — |
| F45 | Line discount | Complete (vehicles) | `max_discount` per price version enforced 0018/0029 | Counter/service bills are value-only by decision | P1 | — |
| F46 | Invoice print | Complete | `/print/bill/[id]`, `/print/cash/[id]` from posted data | — | P1 | — |
| F47 | Sales return | Complete | `return_vehicle_sale` 0051, GST credit notes 0084; test `9C` | — | P1 | — |
| F48 | Customer receipt allocation | Complete | `allocate_party_payment`, `settle_counter_invoice` 0080; test `9B` | — | P0 | — |
| F49 | Accounts receivable | Complete | `party_ageing`, customer ledger, Customer 360 (0065); test `96`, `9M` | — | P0 | — |
| F50 | Pending sales orders | N/A | Pending bookings list stands in | As F42 | — | — |

## 6. GST and service accounting

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F51 | GST settings | Complete | Dealer GSTIN/state; settings page; labelled configuration, not registration | — | P0 | — |
| F52 | Tax masters | Complete | `tax_codes` effective-dated 0014; categories 0084; invoice lines snapshot rates | — | P0 | — |
| F53 | Local / interstate | Complete | Place of supply 0081; CGST+SGST vs IGST per line | — | P0 | — |
| F54 | Several rates on one document | Complete | Line-level tax on sale, purchase and quick-bill lines | — | P0 | — |
| F55 | HSN/SAC | Complete | `hsn_codes` 0014; quick-bill HSN per head 0089 | — | P0 | — |
| F56 | ITC eligibility | Complete | ITC categories, blocked/reversed, `record_itc_adjustment` 0084; test `9ZC` | — | P0 | — |
| F57 | Service purchase | Complete | `EXPENSE` purchase lines, no stock 0078 | — | P1 | — |
| F58 | GST summary | Complete | `gstr3b_working`, `gst_cross_checks` 0085; `/gst/returns`, `/gst/reports` | — | P1 | — |
| F59 | ITC adjustment journal | Complete | `record_itc_adjustment` 0084; `gstr3b_setoff` follows the CBIC utilisation order 0085; test `9ZD` | — | P1 | — |
| F60 | Recording GST payment | Complete | `post_gst_setoff`, `record_gst_filing` (ARN recorded, not filed by the app) 0085 | — | P1 | — |

## 7. TDS

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F61 | TDS activation and TAN | Complete | `tds_deductor` 0093; `/accounting/tds` | — | P1 | Done (0093) |
| F62 | TDS categories | Complete | `tds_sections` 0093 — entered by the accountant (none shipped), Act 1961/2025, effective-dated, source recorded, never edited in place, must be reviewed; test `9ZK` | Rates themselves are the dealer's to enter and review | P1 | Done (0093) |
| F63 | Payee settings | Complete | Supplier TDS profile: section, payee type (documented, not inferred), PAN verified 0093; Payees tab | — | P1 | Done (0093) |
| F64 | Threshold and deduction posting | Complete | `app.tds_compute`; single and aggregate thresholds with THIS_BILL / WHOLE_AGGREGATE / EXCESS_ONLY; supplier paid net, Cr 2745 in the bill's journal; nil deductions recorded; preview on draft bills; test `9ZK` | TDS on advance payments (before a bill) not modelled | P1 | Done (0093) |
| F65 | Lower-rate certificate | Complete | Certificate no., rate, validity, limit on the supplier; applied within limit; test `9ZK` | — | P1 | Done (0093) |
| F66 | TDS report | Complete | `tds_register()`, `tds_control_check()` (2745 vs subledger) 0093; test `9ZK` | Return file (Form 26Q / its 2025-Act successor) not generated | P1 | Done (0093) |
| F67 | Recording TDS remittance | Complete | `record_tds_remittance()` 0093 — a deposit already made: challan, BSR, date; bank-book payment Dr 2745; no filing claimed; test `9ZK` | — | P1 | Done (0093) |

## 8. Warehouses, production, data management

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F68 | Warehouses | Complete (branches) | Each branch is the stock location; stock lots are per branch and LOCAL/COMPANY source (0019) | A second store inside one branch is not modelled | P1 | — |
| F69 | Location-wise opening stock | Complete | Opening stock upload per branch (0036); test `93` | — | P0 | — |
| F70 | Bill of materials | N/A | — | The dealer does not manufacture or assemble | P3 | — |
| F71 | Production cost | N/A | — | As F70 | P3 | — |
| F72 | By-products / scrap | N/A | Damaged stock handled 0083 | As F70 | P3 | — |
| F73 | Production voucher | N/A | — | As F70 | P3 | — |
| F74 | Transfer | Complete | Vehicle dispatch/receive, in transit (`dispatch_vehicle_transfer`, `receive_vehicle_transfer`), accessory/spare `transfer_inventory_stock`, 1850 in transit 0083; test `80`, `9ZB` | — | P1 | — |
| F75 | Transfer freight | Partial | Freight on finance DD (5930, 0087) | Not attachable to a stock transfer | P2 | Deferred |
| F76 | Location drill-down | Complete | Stock report by branch; stock ledger `/inventory/ledger` | — | P1 | — |
| F77 | Backup and restore | Complete | `scripts/restore-drill.sh` (read-only dump, restore, row-count / ledger / trial-balance checksums); `docs/backup-restore-runbook.md`; Supabase daily backups | — | P0 | — |
| F78 | Master export | Partial | CSV/XLSX exports of every list (`src/server/export`, `check:exports`) | No schema-versioned bundle for moving masters to another dealer | P2 | Deferred |
| F79 | Master import | Partial | Customer, supplier, vehicle stock, inventory stock, opening balance imports with preview and all-or-nothing | No cross-dealer bundle import | P2 | Deferred |
| F80 | Transaction export | Partial | Journal and report exports | No migration tool | P2 | Deferred |

## 9. Reports

| ID | Feature | Status | Evidence | Gap / defect | Pri | Plan & verification |
|---|---|---|---|---|---|---|
| F81 | Trial balance | Complete | `trial_balance()` 0026; group subtotals (0090 UI); tests `20`, `9X` | Movement columns (opening / period / closing) are not separate | P0 | — |
| F82 | Balance sheet | Complete | `balance_sheet()` incl. result to date 0026 | — | P0 | — |
| F83 | Profit and loss | Complete | `profit_and_loss()` 0026/0076 | — | P0 | — |
| F84 | Receipts & payments / I&E | N/A | — | For non-profit entities | P3 | — |

---

## 10. Cross-cutting accounting controls (§5 of the source)

| Control | Status | Mechanism |
|---|---|---|
| Every posted journal balances | Complete | Balance check in `app.post_journal` and deferred totals trigger (0007, 0025); test `20` |
| Tenant / branch isolation on the server | Complete | RLS on every table (0009, verified by db:verify "all tables protected"); definer functions resolve dealer from `auth.uid()`; test `10_rls_isolation`, `9ZF` |
| Atomic posting | Complete | Each business function posts document, journal, stock and allocation in one transaction |
| Idempotent retries | Complete | Idempotency keys on receipts, sale drafts, quick bills and imports (0061–0063); test `9L` |
| Unique numbering under concurrency | Complete | Row-locked `next_document_number` (0006/0072); test `91` |
| No over-allocation | Complete | `allocate_party_payment` (0050) |
| No double stock movement | Complete | Chassis status machine; bill lines linked to goods receipts add no stock (0092, test `9ZJ`) |
| Posted tax snapshots immutable | Complete | Line-level rate snapshots; posted journal guard |
| Period locks | Complete | `set_books_lock` (0076), closed financial years (0090) |
| Posting authority | Complete | `journal_entries_authority` trigger (0089); test `9ZG` |
| Audit history | Complete | `app.audit_trigger` on sensitive tables; `accounting_periods` added in 0090 |
| GL reconciles to subledgers | Complete | `control_account_tieout()` / `/accounting/tie-out`; `grni_outstanding()` = 2760 (0092); `tds_control_check()` = 2745 (0093) |
| Backup restore tested | Complete | Restore drill run before every migration |
| Rate limiting on sensitive endpoints | Missing (open item O2 from the 25 Sep review) | Outside this document's scope; recorded |

## 11. Dealership adaptations (§6 of the source)

| Requirement | Status | Where |
|---|---|---|
| Booking and delivery | Complete | Bookings, advances, sale → delivery (0020, 0046, 0038) |
| Vehicle inventory by chassis | Complete | `vehicles` with chassis/engine/status (0017) |
| HP-financed sale | Complete | Finance applications, DD with deductions, trade advances (0021, 0043, 0087) |
| Branch transfer | Complete | Dispatch / in transit / receive (0083) |
| Accessories and spares | Complete | Stock lots LOCAL/COMPANY, fitting allocation (0019, 0047) |
| Workshop service | Complete (value-only by decision) | Quick service bills (0088/0089) |
| Exchange vehicles | Missing | Not requested; deferred |
| Cashier collection and day close | Complete | Cash book, day close (0030, 0049) |
| Insurance / registration collections | Complete | Price components and income accounts (0018, 4600) |
| Discount approval | Complete for vehicles | `max_discount`; price approval workflow (0044) |
| Management view | Complete | Dashboard, MIS, branch performance (0035, 0064) |
| AI document upload | Missing | Not requested; deferred |
| WhatsApp / Telegram reminders | Missing | Not requested; deferred |
