# Accounting audit: September 2026

The *Accounting Web App Audit Checklist* (23 Sep 2026), worked against the code and the database rather than the screens.

| Review record | |
|---|---|
| Build | `main` @ `41e2ec9` plus migrations 0076–0079 (uncommitted at the time of writing) |
| Tenant / test period | Fresh tenant `ACPT`, provisioned by `app.provision_dealer`, zero opening balances; the current month. Also the demo dealer `SBM`. |
| How it was tested | `npm run db:verify`: every migration on a throwaway PostgreSQL 16, then the SQL suite. Test A runs as the dealer owner under `authenticated`, so RLS applies just as it does in the app. |
| Upgrade rehearsal | A 0075 database carrying the demo dealer's 63 journals, then `INCREMENTAL-0076-to-0079.sql`, then the trial balance and control tie-out |

**Marks.** P = pass, Pa = partial, F = fail, NA = out of scope. A P means a posted entry and its downstream effect were checked by an automated assertion. The test that proves each mark is named.

---

## Release decision

| Measure | Before this work | After |
|---|---|---|
| P0 failures | 3 (group/inactive postings, cash/bank sub-ledger divergence, no closed-period control) | 0 |
| P1 failures fixed | Stock adjustments unjournalled; stock adjustments and transfers impossible under RLS; BRS without reconciling items; no expense or fixed-asset document; no chart maintenance | 0 open from this list |
| P1/P2 still open | | None from the checklist after round 2 (0081–0086). What remains is listed under *Round 2* below. |
| Unresolved differences on upgraded demo data | Customer/control 0 · Supplier/control 0 · Stock/GL −₹900 / +₹480 · Bank 0 | All 0 after the one-off correcting journal described below |

**Decision:** fix and retest → ready for the P0 gate. Apply migrations 0076–0079 before deploying the app code that calls them (see *Deploying* at the end).

---

## Findings log (defects found and fixed)

| ID / pri | Feature + steps | Expected vs actual (before) | Fix / evidence |
|---|---|---|---|
| F1 / P0 | Manual journal of ₹999: Dr 1000 *Assets* (a group heading), Cr 2700 | Rejected. **Actual:** posted; trial balance out by exactly ₹999, because `account_balances()` hides group and inactive accounts. The only protection was the UI picker, so cash and bank entries could post to a heading too, and the seed test `9L` did. | `post_journal` now validates every line (leaf, active, own-dealer, one-sided, non-negative, numeric) before writing. Accounts cannot be deactivated with a balance, retyped, made a heading or deleted once used. `account_balances()` no longer drops posted money. *0076; test 9X* |
| F2 / P0 | Manual journal "Bank charges Dr / Bank Cr"; bank entry with Cash 1100 as the counter account | The bank book and cash book move with the ledger. **Actual:** the GL moved, `bank_transactions`/`cash_transactions` did not, so the BRS and cash book disagreed with the trial balance for good. The existing manual-journal test did exactly this. | Manual lines on cash or bank ledgers are refused. A cash or bank entry cannot name the other money ledger. New **Contra** voucher (`/bank/contra`) posts one journal and writes both books, and is idempotent. *0076, 0077; tests 9R, 9X* |
| F3 / P0 | Post or reverse into a filed month | Rejected, or reopened with a log. **Actual:** nothing could close anything; periods are whole financial years with no close function. | Lock date, "books locked through" (Journals page). Posting and reversal into it are refused. Moving it needs `accounting.periods.manage` and a reason, and the history is append-only and audited. Manual journals cannot be future-dated. *0076; test 9X* |
| F4 / P1 | Physical count adjustment ±1 | Stock value and GL move together. **Actual:** the stock moved with no journal (the demo dealer shows accessories ₹900 over account 1600 and spares ₹480 under 1700). | Adjustments post Inventory ⇄ **5970 Stock Adjustments**, accounts resolved from rules. *0079; test 9Y "count adjustment"* |
| F5 / P1 | Stock adjustment or branch transfer **as the app runs it** (RLS on) | Works. **Actual:** always refused with "Only 0 in stock", because `SELECT … FOR UPDATE` on `inventory_stock` returns nothing without an UPDATE policy. The seed runs as superuser, which hid it. Reproduced on the 0078 rehearsal database. | `app.lock_stock_lot()`, a definer lock scoped to the caller's dealer. *0079; test 9X "succeeds under RLS"* |
| F6 / P1 | Test B: book ₹2,40,000; direct deposit, charge, unpresented cheque, deposit in transit | Adjusted book ₹2,88,500; expected statement ₹2,98,500; items visible. **Actual:** one statement − book figure. | `bank_reconciliation_statement()` / `_items()` with an as-on date, shown on the Reconciliation page. Completed reconciliations store the items and report the *unexplained* difference. *0077; test 9Y Test B* |
| F7 / P1 | Computer or rent with input GST (Test A events 2 and 5) | A supplier document; ITC in the GST summary. **Actual:** purchase bills carried stock only, so overheads were hand journals and their ITC never reached `gst_input_summary`. No account existed for fixed assets or depreciation, and none could be added. | EXPENSE lines on purchase bills (account, HSN/SAC, "input tax claimable" switch for s.17(5) blocked credit). Chart of accounts gets **Add account** / deactivate. Standard accounts seeded: 1950/1951/1959 fixed assets and accumulated depreciation, 2800 Loans, 3400 Drawings, 5950 Depreciation, 5960 Interest, 5970 Stock Adjustments. *0076, 0078; test 9Y* |
| F8 / P2 | Test A gross profit | Read off the P&L. **Actual:** no cost-of-sales section. | COGS accounts marked COST_OF_SALES; the P&L page and export show Cost of sales → Gross profit → Expenses → Net. *0076* |
| F9 / P1 | Sub-ledger tie-out | A report compares control accounts with their detail. **Actual:** none. | **Accounting → Control Tie-out** (`control_account_tieout()`): party controls, cash, bank and stock at cost. *0077; test 9Y* |
| F11 / P1 | Post-deploy tie-out on production (DHARANI) | Every receivable belongs to a customer. **Actual:** ₹1,115.10 on 1300 with no customer: walk-in counter sale CSI-2026-000001, posted 16 Sep, never paid. Posting and collecting were separate steps, so a walk-in could be left owing with nobody to chase. | `settle_counter_invoice()` posts and collects in one step ("Post & take payment"). A deferred trigger refuses, at commit, any posted walk-in with a balance. The existing invoice is left alone, and collecting it in full clears it. *0080; test 9Y* |
| F10 / tooling | Generated TS types | `chart_of_accounts.account_type` typed `'ASSET' \| 'EXPENSE'` and attendance status missing four values, because the generator read unions from compound CHECKs. | `scripts/generate-types.mjs` skips compound checks. |

**Legacy data the migrations deliberately don't fix silently.** Postings made before 0076 to group accounts, manual cash/bank lines, and stock adjustments made before 0079 are counted by `RAISE NOTICE` when the migration runs, and they show on the Tie-out page. On the demo data, one manual journal (1600 Dr 900 / 5970 Cr 900; 5970 Dr 480 / 1700 Cr 480) brought every control to zero. Do the same on production after reading the tie-out.

---

## 10 · Acceptance test A: the sample month

`supabase/test/9Y_acceptance_sample_month.sql`: all ten events go through the document functions the screens call, never through direct journal inserts. Each voucher's lines are asserted account by account.

| # | Entered through | Journal | Lines asserted |
|---|---|---|---|
| 1 | Bank entry, receipt to 3100 | JE-000001 | 1200 Dr 10,00,000 · 3100 Cr 10,00,000 |
| 2 | Purchase bill, EXPENSE line to 1951, 18% | JE-000002 | 1951 Dr 1,00,000 · 1900 Dr 9,000 · 1910 Dr 9,000 · 2200 Cr 1,18,000 |
| 3 | Purchase bill, 100 kits @ 5,000 | JE-000003 | 1600 Dr 5,00,000 · 1900/1910 Dr 45,000 each · 2200 Cr 5,90,000 |
| 4 | Counter invoice, 64 kits @ 7,031.25 | JE-000004 | 1300 Dr 5,31,000 · 4200 Cr 4,50,000 · 2300/2400 Cr 40,500 each · 5200 Dr / 1600 Cr 3,20,000 |
| 4 | Receipt against it by NEFT | JE-000005 | 1200 Dr / 1300 Cr 2,00,000 |
| 5 | Landlord's bill, EXPENSE line to 5600 | JE-000006 | 5600 Dr 50,000 · 1900/1910 Dr 4,500 each · 2200 Cr 59,000 |
| 5 | Bank payment to landlord | JE-000007 | 2200 Dr / 1200 Cr 59,000 |
| 6 | Bank payment to 5500 | JE-000008 | 5500 Dr / 1200 Cr 80,000 |
| 7 | Bank receipt tagged to customer | JE-000009 | 1200 Dr / 1300 Cr 2,50,000 |
| 8 | Bank payment tagged to supplier | JE-000010 | 2200 Dr / 1200 Cr 4,00,000 |
| 9 | Bank payment to 5800 | JE-000011 | 5800 Dr / 1200 Cr 1,000 |
| 10 | Manual journal | JE-000012 | 5950 Dr / 1959 Cr 2,000 |

Events 4 and 5 are two documents each, as they would be in practice. The net effect is exactly the checklist's single journal: the landlord's account nets to nil.

| Checkpoint | Expected | Result |
|---|---|---|
| Customer receivable | ₹81,000 | **P** |
| Supplier payable | ₹3,08,000 | **P** |
| Inventory | ₹1,80,000 (36 kits) | **P** |
| Input / output GST | ₹1,17,000 Dr / ₹81,000 Cr | **P** |
| Excess ITC | ₹36,000 | **P** |
| Gross profit / net result | ₹1,30,000 / −₹3,000 | **P** (read from the P&L sections) |
| Bank | ₹9,10,000 Dr | **P**, and the bank book agrees |
| Trial balance | ₹18,41,000 each side | **P** |
| Balance sheet | Assets ₹13,86,000 = liabilities + equity + result | **P** |
| Tie-out | Every control = sub-ledger | **P** |
| Duplicate request | Resubmitted receipt | **P**: one voucher, one bank row |
| Tenant access | Other dealer's chart and journals invisible; guessed account id refused | **P** |

## 11 · Tests B–E

| Test | Result | Evidence |
|---|---|---|
| B: Bank | **P** | Book 2,40,000 → adjusted 2,88,500 → expected statement 2,98,500; unexplained 0; four items listed, and still listed after completion. *9Y* |
| C: GSTR-2B | **F** | No 2B import or matching exists. |
| D: Tax comparison (books vs 3B) | **F** | No 3B working exists to compare against. |
| E: Invalid invoice | **Pa** | Existing `9V`: missing HSN or pincode blocks the e-invoice; a sale without GSTIN is B2C, not an error. There is no place-of-supply check on non-e-invoice documents. |

## 12 · Stress and correction tests

| Test | Result | Evidence |
|---|---|---|
| Duplicate request | **P** | 9Y (receipt), 9X (contra), existing 9L |
| Mid-post failure | **P** | 9X: a bad third line leaves no header and no lines |
| Reversal | **P** | 9R, 9S, 9X; allocated-receipt reversal is covered by existing 9B |
| Closed period | **P** | 9X: post and reversal refused, reopen needs a reason, history kept and audited |
| Tenant access | **P** | 9Y, existing 10_rls_isolation, 9G |
| Sub-ledger tie-out | **P** | 9Y; upgrade rehearsal |

---

## Section results

### 01 Double-entry engine (P0)

| Row | Mark | Evidence |
|---|---|---|
| Balanced posting | P | 0007 trigger + 0025 pre-check; 9Y "every posted voucher balances" |
| Invalid voucher rejection | P | *Fixed (F1).* 9X |
| Account types | P | Type ↔ normal side is a CHECK; the chart guard stops retyping used accounts; 9X |
| Unique ID and idempotency | P | Unique entry numbers; idempotency keys; 9L, 9Y, 9X |
| Journal metadata | P | Date, created/posted time, source document, narration, branch, user, status on `journal_entries` |
| Unified posting path | P | Every module posts through `app.post_journal` |
| Ledger and trial balance | P | *Fixed (F1).* 9S, 9Y |
| Statements from GL | P | Trial balance, P&L and balance sheet all read `account_balances()` |
| Equation and retained result | P | 9Y: balance sheet balances with the current result |
| Edit and cancellation | P | Immutable, reversal-only; 9R |
| Closed period | P | *Fixed (F3).* 9X |
| Orphans and atomicity | P | FKs; single-transaction functions; 9X, 9Y |
| Tenant isolation | P | RLS + composite FKs; `post_journal` now checks line ownership for every caller |
| Audit log | P | Audit triggers on journals, chart and locks; `recordAudit` |

### 02 Transaction entry screens (P0/P1)

| Row | Mark | Evidence |
|---|---|---|
| Opening balances | P | Existing 9O; bank opening balances since 0073 |
| Capital and drawings | P | Capital via bank or cash entry (9Y event 1); 3400 Drawings now exists |
| General journal | P | Multi-line, dated, narrated, reversible. *Round 2:* optional maker-checker approval (`approvals.manual_journal`, 0081). The approver can't be the maker, and a rejection needs a note. 9Z |
| Contra | P | *Fixed (F2).* 9X |
| Receipt and payment | P | Party-tagged; partial receipts (9Y event 4); allocation 9B |
| Cash and credit sales | P | 9Y event 4; existing 50, 98 |
| Cash and credit purchases | P | 9D, 9Y |
| Returns and notes | P | *Round 2:* standalone credit and debit notes against a sale, service invoice or purchase bill (`gst_notes`, 0084). They take the original's tax mode, can't exceed it, and are cancelled by reversal. 9ZC |
| Expenses and fixed assets | P | *Fixed (F7).* 9Y |
| Depreciation / accruals | P | *Round 2:* fixed-asset register, monthly SLM/WDV depreciation run (one journal per branch, once per asset per month) and disposal with gain/loss (0082). The register ties to 1951/1959. 9Y |
| Loans and interest | P | *Round 2:* loan master, disbursement and repayment split into principal and interest, reducing-balance EMI schedule, register tie-out (0082). 9Y |
| Payroll | P | *Round 2:* monthly run from salary structures → draft → post (gross, employer PF/ESI, net per employee, PF/ESI/TDS/PT payables) → pay by bank (0082). 9Y |
| Bank charges / income | P | Bank entry (9Y event 9). BRS lists unmatched statement charges. |
| GST / RCM adjustment | P | *Round 2:* reverse-charge purchase lines. The supplier is owed the value only; the tax is credited to 2590 GST Payable (RCM) and claimed as ITC when eligible (0084). 9ZC |

### 03 Masters and entry validation (P1)

| Row | Mark | Evidence |
|---|---|---|
| Chart of accounts | P | *Fixed (F7):* add, deactivate, guards |
| Customers and suppliers | P | Existing 30, 92, 9N |
| Items and tax | P | Effective-dated tax codes, HSN, cost |
| Vehicle identity | P | Unique chassis, movement log, transfers; existing 50, 80 |
| Mandatory fields | P | DB checks plus server validation |
| Date and period rules | P | *Fixed (F3):* lock date, no future-dated manual journals |
| Source and attachments | P | *Round 2:* append-only attachments on journals, bills, invoices, notes and GST filings. Stored in the private `attachments` bucket under the dealer's folder (0081). 9Z |
| Validation feedback | P | Line-numbered DB messages passed through; forms keep entered values |

### 04 Receivables and payables (P1)

| Row | Mark | Evidence |
|---|---|---|
| Invoice-level balance | P | `party_open_items` |
| Allocations | P | Existing 9B |
| Advance and credits | P | Booking advances (97) held apart from receivables; ageing shows advances and unallocated credit in their own columns (9Y) |
| Ageing | P | **Accounting → Ageing** (`party_ageing()`, 0080): customers, suppliers and finance companies in 0–30/31–60/61–90/90+ buckets; allocations first, then oldest-first; exportable. 9Y asserts the buckets, an as-on date in the past, and a total equal to the 2200 control. Aged from the document date, because sales invoices carry no due date. |
| Control account tie-out | P | *Fixed (F9)* |
| Statements and reversals | P | Party ledgers are built from GL lines, so reversals appear |

### 05 Banking and reconciliation (P1)

| Row | Mark | Evidence |
|---|---|---|
| Bank/cash ledgers | P | Multiple banks; branch cash; UPI and cards settle to bank |
| Statement import | P | Dedupe key; parser tests |
| Matching and exceptions | P | Suggestions, match, ignore, unmatch; 60 |
| Timing differences | P | *Fixed (F6)* |
| BRS control | P | *Fixed (F6)* |
| Reconciliation history | P | Numbered reconciliations, stamped lines, audit |

### 06 Inventory, COGS and branches (P1)

| Row | Mark | Evidence |
|---|---|---|
| Stock movement | P | Movement ledger for every type; *transfers fixed (F5)* |
| Cost valuation | P | Lot average cost; the tie-out compares stock value with the GL (9Y) |
| COGS on sale | P | 9Y event 4, local-first lots (98) |
| Chassis and locations | P | Existing 49/50 concurrency and unique chassis |
| Transfers | P | *Round 2:* every transfer issues a transfer note and posts through 1850 Inter-Branch Stock in Transit, so each branch's trial balance balances on its own. Between two GSTINs the note is a tax invoice with output tax at the sender and input tax at the receiver. A vehicle on the road sits in 1850 until it's received (0083). 9ZB |
| Counts and exceptions | P | *Fixed (F4)*; *round 2:* optional approval (`approvals.stock_adjustment`, 0081). 9Z |
| Damaged / consignment | P | *Round 2:* DAMAGED lot written down to realisable value (to 5970); CONSIGNMENT lot held at nil value and not adjustable. The sale allocator reads neither (0083). 9ZB |
| Negative stock | P | Blocked in sales, adjustments and transfers |

### 07 GST entry and documents (P1)

| Row | Mark | Evidence |
|---|---|---|
| GSTIN and place of supply | P | *Round 2:* place of supply is set on every sale and service invoice. Inter-state lines are converted to IGST. On posting, the GSTIN format, the GSTIN/state agreement and the tax mode against the place of supply are validated (0081). 9Z |
| Tax computation | P | Configured rates; CGST+SGST vs IGST split checks; cess column |
| Tax categories | P | *Round 2:* `tax_codes.tax_category` (taxable, zero-rated, nil, exempt, non-GST; the last three carry no rate), with a supply-category report (0084). 9ZC |
| Document lifecycle | P | *Round 2:* a delivery challan for every transfer within a GSTIN (0083). An invoice with no tax prints and shows as a **bill of supply** (0084). |
| Original link | P | Returns and every credit/debit note name the document they amend (0084). |
| Output/input ledger | P | Posted with the document; 9Y |
| ITC eligibility | P | *Round 2:* ITC categories eligible / capital goods / common / blocked / personal (personal purchases may be charged to Drawings). Reversals and re-claims under rules 37/42/43 and s.17(5) post ITC ⇄ 5990, and a re-claim can't exceed what was reversed. Rule 37 candidates are listed (0084). 9ZC |
| 2B matching | P | *Round 2:* GSTR-2B import (CSV; refused whole if any line is bad), matched on supplier GSTIN plus normalised document number: MATCHED, VALUE_MISMATCH, NOT_IN_BOOKS, NOT_CLAIMABLE, NOT_IN_2B (0085). 9ZD |
| ITC claim controls | P | *Round 2:* only credit in 2B is claimable, at the lower of 2B and the books head by head. RCM credit needs no 2B. Personal and blocked credit is never offered. A filed 3B records what it claimed, so nothing is claimed twice (0085). 9ZD |

### 08 GST return workpapers (P1/P2)

| Row | Mark |
|---|---|
| GSTR-1 working | P: sections, including CDNR/CDNUR notes and transfer tax invoices; the filed snapshot is frozen; `gstr1_amendments` lists changed, cancelled and missed documents (0085). 9ZD |
| Sales reconciliation | P: `gst_cross_checks` compares ledger output tax with GSTR-1 and GSTR-1 with 3B (Test C) (0085). 9ZD |
| GSTR-2B working | P: import, matching, reconciliation both ways (0085). 9ZD |
| GSTR-3B working | P: 3.1(a)–(e), 4(A)(3)/(5), 4(B)(1)/(2), 4(C), 4(D), 5, and set-off in the rule 88A order with RCM paid in cash. The set-off journal is posted after filing (0085). 9ZD |
| Cross-return checks | P: seven checks; Test D's ₹18,000 difference between filed GSTR-1 and GSTR-3B is flagged (0085). 9ZD |
| E-invoice controls | P: existing 99, 9V |
| E-way bill controls | P: existing 9Q |
| Filing evidence | P: prepared, then signed off by a second person, then filed with ARN, date, figures and challan; permanent once filed; acknowledgement attached as GST_FILING (0085). 9ZD |
| Configurable rules | P: effective-dated tax codes |

### 09 Reports and controls (P1/P2)

| Row | Mark | Evidence |
|---|---|---|
| Core reports | P | Journal register, account ledger, trial balance, P&L (now with gross profit), balance sheet. There's no day-book screen; the journal register serves. |
| Operational reports | P | Registers, cash and bank books, receivable and payable ageing (0080) |
| Asset and inventory | P | Stock ledger and valuation; fixed-asset register (0082); damaged/consignment condition report (0083) |
| Reconciliation reports | P | *New:* BRS, tie-out; GST summaries |
| Cutoff and filters | P | As-on and branch filters across statements and exports |
| Drill-down/export | P | Trial balance → ledger → journal → source; 31 export reports |
| Permissions and backup | P | Permissions enforced server-side and by RLS. *Round 2:* restore drill on 24 Sep 2026: production dumped read-only, restored locally, identical in every row count and in the ledger and trial-balance checksums (`scripts/restore-drill.sh`, `docs/backup-restore-runbook.md`). It found one orphan reference that a plain restore refused; repaired by 0086. |

---


## Round 2: the open items built (migrations 0081–0086)

| Group | Migration | Test | What it closes |
|---|---|---|---|
| Approvals, attachments, place of supply | 0081 | 9Z | Maker-checker for manual journals and stock adjustments (switches under **Administration → Settings**); append-only attachments; place of supply and GSTIN validation on every invoice |
| Fixed assets, payroll, loans | 0082 | 9Y | Asset register and depreciation; payroll with statutory payables; loans with principal and interest; register tie-outs |
| Transfers, damaged, consignment | 0083 | 9ZB | Branch transfers post through 1850, with a challan or tax invoice; damaged and consignment lots |
| Tax categories, notes, RCM, ITC | 0084 | 9ZC | Supply categories; credit and debit notes; bill of supply; reverse charge; ITC categories, reversals and re-claims |
| GST returns | 0085 | 9ZD | GSTR-2B import and matching; ITC claim controls; GSTR-3B working and set-off; cross-checks (Tests C and D); filing evidence and GSTR-1 amendments |
| Restore drill | 0086 | drill | `scripts/restore-drill.sh` and the runbook. It found and repaired an orphan left by `remove-demo-dealer.sql` |

Chart of accounts: new dealers now get 62 accounts (1850, 2590, 5990 are new). The three non-taxable tax codes are seeded with them.

**Known limits:**
- GSTR-2B is imported from CSV (the portal's Excel saved as CSV); there is no direct portal pull.
- 2B lines that don't match are listed but can't be linked to a bill by hand.
- The 3B opening credit is carried from the last *filed* 3B, so the first month starts from zero. Enter any earlier balance as a re-claim.
- Rule 42/43 apportionment is entered as a figure, with its working in the note, not computed.
- Consignment stock is counted but can't be sold until bought in on a purchase bill.
- The Storage bucket (attachment files) isn't in the logical backup. The runbook says how to keep it.

## What changed, file by file

- `supabase/migrations/0076`–`0079`, `supabase/INCREMENTAL-0076-to-0079.sql`, and the regenerated ALL-IN-ONE bundles.
- Tests: new `9X_ledger_integrity.sql` and `9Y_acceptance_sample_month.sql`. Corrected `9G` (account count), `9L` (it posted to a heading), and `9R` and `9S` (they hand-posted cash and bank).
- App: Contra page, Control Tie-out page, chart-of-accounts add/deactivate, books-lock panel on Journals, BRS panel on Reconciliation, gross profit on the P&L page and export, expense/asset lines in the purchase bill editor. The cash, bank and journal pickers no longer offer cash or bank ledgers.
- `scripts/generate-types.mjs`, `src/types/database.types.ts`, `src/config/schema.ts` (0079), `supabase/seed.sql`, `docs/database.md`.

## Deploying

Railway deploys on push and migrations are applied by hand, so the order matters.

**Round 1 (done):** 0076–0080 are in production.

**Round 2:**

1. Apply `supabase/INCREMENTAL-0081-to-0086.sql` to production in the SQL Editor. It is one transaction, so it applies whole or not at all.
2. Check that `select max(version) from public.schema_migrations` returns `0086`.
3. Push the app. The schema-version panel should show 0086.
4. Run `bash scripts/restore-drill.sh`. It should now pass with no orphans reported. Then remove the 0086 statement from `scripts/drill-repairs.sql`.
5. Optionally, turn on journal and stock-adjustment approval under **Administration → Settings → Controls**.

The round 2 screens were checked by typecheck, lint and build, not in a browser. Run the Playwright suite against staging once 0081–0086 are applied there (see `docs/testing-staging.md`).
