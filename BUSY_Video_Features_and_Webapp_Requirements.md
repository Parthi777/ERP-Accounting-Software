# BUSY course: feature extraction and web-app requirements

Prepared for Parthi • 25 September 2026

## Scope and evidence

Source: [Busy Accounting Software Complete Course 2026 | Accounting, Inventory, GST & TDS | Full Course | Busy](https://www.youtube.com/watch?v=1sDu7IoRUgQ), by Excel & ERP with Ata. The player shows 3:01:37; the last caption starts at 3:01:33. The page records a premiere on 22 July 2026.

This analysis reviews the complete available Hindi auto-generated transcript, from the first to the last caption, and the expanded video description. It is a full-transcript analysis, not a frame-by-frame visual or audio audit. The captions contain incorrect amounts, missing digits and inconsistent terms. Timecodes identify relevant narrated sections; they are approximate navigation points, not independently verified screen events.

The feature catalog below separates demonstrated workflows described in the transcript, brief mentions, description-only claims and proposed implementation requirements. A workflow narrated in a tutorial is not proof that all edge cases work, or that every BUSY edition includes it. No source code, live database or current feature inventory of your web app was inspected.

**Working assumption:** you want to implement comparable capabilities inside your existing accounting/dealership web app. Connecting the app directly to BUSY is a separate integration decision. This video does not establish a supported API, authentication method or real-time synchronization contract.

**Recommendation:** build a dependable accounting engine and connected document workflows first. Reproducing menus alone will not produce a reliable accounting system.

## 1. Course coverage map

| Time | Coverage established by the transcript |
|---|---|
| 00:00–02:47 | Introduction, download and installation discussion; BUSY 21 is named |
| 02:49–07:02 | Create, open, edit, close and delete a company; financial-year setup |
| 07:06–20:57 | Account masters, account groups, opening balances, narration templates |
| 21:03–26:44 | Customer/vendor opening balances allocated to individual bills |
| 26:47–29:35 | Trial balance, balance sheet and P&L report views |
| 29:38–33:30 | Company backup, deletion and restoration |
| 33:36–46:05 | Item groups, units, items, opening stock and unit conversion |
| 46:08–47:35 | Keyboard shortcuts and inline master creation |
| 47:39–1:05:03 | Payment, receipt, contra and journal entries; day book |
| 1:05:08–1:32:59 | Purchase order, receipt/challan, invoice, return and payment with GST |
| 1:33:05–1:53:58 | Sales order, delivery/challan, invoice, return and customer receipt |
| 1:54:01–1:59:23 | Service purchase using an amount-based service item and GST |
| 1:59:24–2:08:47 | GST summary, ITC adjustment and recording tax payment |
| 2:08:50–2:33:46 | TDS setup, categories, deductions, lower-rate certificate fields and reports |
| 2:33:52–2:51:27 | Warehouses, bill of materials and production costing |
| 2:51:29–2:54:46 | Warehouse stock transfer and freight charge |
| 2:54:50–3:01:33 | Master-data export and import into another company |

## 2. Feature catalog translated into implementation requirements

**Evidence codes:** D = a worked workflow is described in the transcript; M = mentioned or an option is described without a complete worked example. The requirement and priority columns are my recommendations, not claims about BUSY internals.

**Priority:** P0 = foundation / required before live posting; P1 = first operational release; P2 = after core operation is reliable; P3 = optional for a dealership. These are dependency priorities, not estimates of development time. An applicable statutory obligation cannot be postponed merely because it appears in a later phase.

### Company and account masters

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F01 | Multiple company records | D 02:49; 2:57:32 | Separate legal entities; create and switch company context; prevent cross-company posting | P0 |
| F02 | Company details and financial year | D 03:11–04:24 | Legal/display name, address, country, state, PIN, FY dates and books start date | P0 |
| F03 | Location suggestions from PIN | D 03:46–03:58 | Suggest location from a maintained postal dataset; require confirmation and permit correction | P2 |
| F04 | Edit and delete company | D 04:29–06:46 | Editable setup with history; archive used companies; tightly control destructive removal | P0 |
| F05 | Feature configuration | D 52:16; 1:10:07; 2:11:01 | Company settings for GST, TDS, orders, challans and warehouses; enforce dependencies | P0 |
| F06 | Default chart of accounts | D 08:44–09:44 | Versioned starter accounts for cash, banks, income, expenses, assets, liabilities and taxes; avoid duplicate seeding | P0 |
| F07 | Account master maintenance | D 10:13–16:15 | Create/edit/list accounts with name, alias, print name, group and active status | P0 |
| F08 | Account group hierarchy | D 16:19–18:47 | Parent/subgroup structure; inherit accounting classification; block cycles | P0 |
| F09 | Debit/credit opening balances | D 12:10–14:43 | Controlled opening journal with migration date, source and reconciliation; distinguish year opening from midyear migration | P0 |
| F10 | Asset depreciation rate fields | M 13:40–14:02 | Asset register may hold book/tax policies separately; rate fields alone do not constitute a depreciation engine | P2 |
| F11 | Customer/vendor masters | D 21:59–26:44 | Party identity, customer/vendor role, linked control account, address, GST status, GSTIN and PAN as applicable | P0 |
| F12 | Bill-wise opening allocation | D 21:03–26:44 | Opening invoices with reference, invoice date, due date and residual amount; allocations must match party opening balance | P0 |
| F13 | Reusable narration templates | D 18:49–20:57; 1:01:06–1:03:24 | Templates per voucher type, editable before posting | P1 |

### Inventory masters and data-entry usability

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F14 | Item groups | D 35:36–37:52 | Searchable product categories and optional hierarchy | P1 |
| F15 | Standard and custom units | D 37:57–38:48 | Base units, precision and tax-unit mapping where required | P1 |
| F16 | Item master | D 38:53–42:27 | SKU, description, alias/print name, group, goods/service type and base unit | P1 |
| F17 | Opening stock quantity and value | D 39:52–42:27 | Store both quantity and total cost; derive unit cost; reconcile opening inventory to accounts | P0 |
| F18 | Unit conversion | D 43:25–46:05 | Conversion factor, base unit and pack unit; item-specific factors where pack sizes differ | P1 |
| F19 | Closing stock report | D 42:30–43:22 | Quantity, cost per unit and stock value with as-of-date filter | P1 |
| F20 | Inline master creation | D 44:53–45:27; 50:51–51:30 | Create a missing party/item/account in a modal, then return to the unsaved document | P1 |
| F21 | Keyboard-driven entry | D 46:08–47:35 | Fast row entry, save, search and navigation; use browser-safe shortcuts, not literal desktop-key copying | P2 |
| F22 | Embedded calculator | D 40:24–40:42 | Optional calculator; more importantly calculate quantity × rate automatically | P2 |

### Accounting transactions

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F23 | Payment vouchers | D 48:32–53:59 | Payment date, bank/cash account, counterparties/expenses, amount, reference and narration | P0 |
| F24 | Multiple expense lines in one payment | D 50:21–52:01 | Split one payment across multiple accounts; validate the full journal balance | P1 |
| F25 | Simple and debit/credit entry screens | D 49:23–53:59 | Simple business form plus advanced journal form, both feeding the same balanced ledger engine | P0 |
| F26 | Receipt vouchers | D 54:24–56:20 | Receive against invoices or appropriate non-invoice accounts; explicit unapplied balance/advance support | P0 |
| F27 | Contra entries | D 56:27–58:03 | Cash deposit, cash withdrawal and same-entity bank transfer, without treating transfers as income/expense | P0 |
| F28 | General journal | D 58:06–1:00:56 | Balanced multi-line adjustments, accruals and reclassifications with approval and supporting evidence | P0 |
| F29 | Short and long narration | D 49:35–50:08 | Line notes and document notes; dedicated cheque/UTR/reference fields instead of hiding references in narration | P1 |
| F30 | Voucher list and modification | D 54:03–54:20; 1:03:33 | Filter drafts and posted entries; edit drafts; correct posted entries through an auditable process | P0 |
| F31 | Voucher series | D 1:08:49–1:09:26 | Unique sequence by company/FY/document type/series; allocate numbers safely under concurrent use | P0 |
| F32 | Day book and drill-down | D 1:03:33–1:05:00 | Date-filtered journal list, narration, optional cash balances and drill-through to source documents | P0 |

### Purchase-to-payment workflow

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F33 | Purchase order | D 1:11:26–1:18:36 | Supplier, order date, expected delivery, lines, quantities, prices and estimated tax; no AP posting from order alone | P1 |
| F34 | Goods receipt / purchase challan | D 1:18:45–1:21:25 | Receive quantities into a location; reference order lines; retain supplier challan number | P1 |
| F35 | Select an order to populate receipt | D 1:19:50–1:20:24 | Copy linked remaining quantities; support partial receipt without retyping every item | P1 |
| F36 | Transport details | D 1:20:30–1:21:23 | Transporter, goods/consignment reference, vehicle, origin and PIN; separate logistics vehicle from vehicle stock identity | P1 |
| F37 | Supplier invoice against receipt/challan | D 1:23:06–1:25:35 | Link invoice lines to accepted receipt quantities; book liability/tax without receiving the same stock twice | P0 |
| F38 | Purchase return | D 1:25:40–1:28:23 | Original receipt/invoice line, returned quantity, reason, supplier credit-note reference and stock/tax effects | P1 |
| F39 | Supplier invoice settlement | D 1:30:31–1:32:54 | Allocate payments and adjustments to bills; prevent over-allocation; retain unallocated amounts separately | P0 |
| F40 | Pending purchase orders | D 1:21:34–1:22:54 | Remaining order quantities by supplier/item, with due/overdue filters | P1 |
| F41 | Accounts payable report | D 1:29:16–1:30:25; 1:32:15 | Open and cleared supplier bills, adjustment history and remaining payable | P0 |

### Order-to-cash workflow

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F42 | Sales order | D 1:35:22–1:40:07 | Customer, order date, lines, prices, tax treatment and fulfilment status | P1 |
| F43 | Delivery challan / material issue | D 1:40:10–1:42:10 | Dispatch linked order quantities from a location; capture transporter details | P1 |
| F44 | Sales invoice, direct or against challan | D 1:43:22–1:45:22 | Customer receivable and revenue/tax posting with stock-link logic that prevents a second issue | P0 |
| F45 | Line discount | M 1:44:08–1:44:32 | Amount/percentage discount with permission limits, clear tax base and explicit rounding policy | P1 |
| F46 | Invoice preview and printing | D 1:45:26–1:46:38 | PDF/print from posted data; party details, lines, HSN/SAC, units, discounts and tax breakup | P1 |
| F47 | Sales return | D 1:47:05–1:49:59 | Link returned quantities to original invoice; credit adjustment and stock disposition; validate referenced documents | P1 |
| F48 | Customer receipt allocation | D 1:51:04–1:53:40 | Apply receipt against selected invoices after credits; reconcile receipt amount and residual balances | P0 |
| F49 | Accounts receivable report | D 1:50:08–1:50:59; 1:53:21 | Open/cleared customer invoices, returns, receipts and pending amount with drill-down | P0 |
| F50 | Pending sales orders | D 1:42:32–1:43:19 | Unfulfilled quantities by customer/item; split partial and complete dispatch | P1 |

### GST and service accounting

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F51 | GST settings | D 1:06:43–1:09:37 | Record registration details and return frequency; enabling a setting does not register a business with government | P0 |
| F52 | GST masters and tax categories | D 1:08:02–1:08:46 | Effective-dated tax categories and input/output ledger mappings; freeze calculation snapshots on posting | P0 |
| F53 | Local/interstate tax treatment | D 1:11:53–1:14:05 | Determine tax heads from validated supply facts and applicable place-of-supply rules, with documented exceptions | P0 |
| F54 | Multiple GST rates on one document | D 1:35:50–1:40:04 | Line-level tax categories; aggregate by rate and tax head | P0 |
| F55 | HSN/SAC fields | D 1:16:00–1:17:26; 1:58:14–1:58:27 | Configurable validated codes, goods/services distinction and applicable reporting rules | P0 |
| F56 | ITC eligibility classification | D 1:23:52–1:24:03; 1:57:09–1:57:19 | Separate tax charged from credit eligible/blocked/pending/reversed; classification must have reasons | P0 |
| F57 | Service item and service purchase | D 1:54:01–1:59:23 | Non-stock service lines supporting fixed amounts and optional hours/jobs/units; no physical stock change | P1 |
| F58 | GST summary and tax balances | D 1:59:46–2:02:17 | Period/GSTIN-wise input, output, adjustments and payment reconciliation | P1 |
| F59 | ITC adjustment journal | D 2:02:20–2:05:18 | Rule-checked proposal and approval; separate book adjustment from government-portal utilization | P1 |
| F60 | Recording GST payment | D 2:06:34–2:08:37 | Payment reference, period and tax heads; record actual payment evidence; no automatic claim of filing or settlement | P1 |

### TDS

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F61 | TDS activation and TAN | D 2:10:23–2:12:28 | Deductor details, applicable regime and configuration history | P1 |
| F62 | TDS category master | D 2:12:39–2:14:47 | Versioned category, legal section/table mapping, rate, threshold, period, payee type and effective dates | P1 |
| F63 | Expense and payee TDS settings | D 2:15:32–2:18:36 | Expense mapping, payee category, PAN status and applicability; do not infer legal status from a name | P1 |
| F64 | Threshold alert and deduction posting | D 2:18:40–2:22:26 | Track applicable aggregate thresholds; create expense, net payable and TDS payable consistently | P1 |
| F65 | Lower-rate deduction fields | D 2:25:44–2:30:01 | Certificate identifier, permitted category/rate, validity and limits; reconcile changed tax to the main journal | P1 |
| F66 | TDS deduction report | D 2:30:03–2:31:22 | Payee/category/reference/rate/base/deduction with reconciliation to TDS control accounts | P1 |
| F67 | Recording TDS remittance | D 2:31:24–2:33:42 | Link government payment to deductions, category and period; keep remittance and filing statuses separate | P1 |

### Warehouses, production and data management

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F68 | Multiple warehouses/material centres | D 2:36:24–2:38:01 | Warehouse master linked to company/branch; default warehouse is explicit | P1 |
| F69 | Location-wise opening stock | D 2:38:30–2:42:09 | Allocate item opening quantity/cost across locations without duplicating company totals | P0 |
| F70 | Bill of materials | D 2:42:27–2:47:51 | Output item/base quantity plus component quantities, units and version | P3 |
| F71 | Extra production cost | D 2:44:47–2:45:37 | Explicit overhead/labour allocation policy and cost basis | P3 |
| F72 | By-products/scrap | M 2:46:58–2:47:37 | Optional output lines and valuation policy; no worked by-product transaction in this course | P3 |
| F73 | Production voucher | D 2:48:16–2:51:27 | Scale component needs, consume stock and create output in one atomic operation; retain actual cost | P3 |
| F74 | Warehouse transfer | D 2:51:29–2:54:46 | Source/destination, quantities and costs; add dispatch/in-transit/received states for real branch movements | P1 |
| F75 | Transfer freight/bill sundry | D 2:53:07–2:54:08 | Distinguish fixed charge from percentage; apply an approved cost capitalization/expense policy | P2 |
| F76 | Location drill-down | D 2:54:13–2:54:46 | Show company total and location split, with movement history | P1 |
| F77 | Backup and restore | D 29:38–33:30 | Scheduled recovery backups, access controls, restore testing and company-level recovery plan | P0 |
| F78 | Master-data export | D 2:54:50–2:57:23 | Export selected master types with schema version, company identity and counts | P2 |
| F79 | Master-data import | D 2:57:26–3:01:33 | Preview record counts and configuration compatibility; validate references and duplicates before commit | P2 |
| F80 | Transaction export option | M 2:56:10–2:57:16 | Separate transaction migration project; define document dependencies and accounting reconciliation | P2 |

### Financial report views

| ID | Feature | Evidence / time | Requirement for your app | Priority |
|---|---|---|---|---|
| F81 | Trial balance | D 26:47–27:56 | Opening/movement/closing balances; account/group views and debit-credit control totals | P0 |
| F82 | Balance sheet | D 28:03–28:58 | Classified accounts, report date, company context and drill-down; optional horizontal/vertical presentation | P0 |
| F83 | Profit and loss | D 29:01–29:35 | Period revenue/expense report from posted ledger and selected inventory costing policy | P0 |
| F84 | Receipts/payments and income/expenditure views | M 28:08–28:14 | Optional report layouts for relevant entity types; menu mention is not a complete demonstrated workflow | P3 |

The financial statements are initially opened with incomplete sample data. This establishes report access and layout options, not proof that the example company is correctly finalized.

## 3. What should not be described as fully demonstrated

| Capability | What the evidence actually establishes |
|---|---|
| Bank reconciliation | Listed in the video description, but no worked reconciliation appears in the full transcript |
| General MIS dashboards | Description mentions MIS; specific inventory and accounting reports are discussed, but a full configurable MIS/dashboard workflow is not shown |
| Payroll | Brief introductory mention; no salary processing, attendance or payroll compliance demonstration |
| Cash-flow statement | Introductory mention; no worked cash-flow report review |
| Service sales | Announced at 1:54:01; the worked example that follows is a service purchase |
| Independent debit/credit notes | Description mentions them; returns and supplier credit-note references are covered, but a complete independent non-stock adjustment-note workflow is not established |
| By-product production | Explained as an option; no worked by-product output is entered |
| Transaction migration | Export option described; the completed import example is for masters |
| Automated depreciation | Rate fields discussed; depreciation calculation/posting not demonstrated |
| Direct GST/TDS payment or filing | Accounting entries are demonstrated, not an authenticated government payment or return-submission transaction |
| E-invoice / e-way bill / GSTR reconciliation | Not demonstrated in this transcript; BUSY's official feature page separately advertises these capabilities [S2] |
| Serial-number/chassis inventory | Not demonstrated here; BUSY separately advertises serial tracking [S2] |
| API/webhook/real-time sync | No usable integration specification established |
| Roles, audit trail, tenant isolation | Not established by this course; must be designed for your web app |

These are limits of this video's evidence, not statements that BUSY lacks these features.

## 4. Tutorial shortcuts that must not become application rules

1. **Opening balances (12:10–13:17).** The instructor describes carrying earlier salary-expense and commission-income amounts into opening balances. Your app needs a proper financial-year close. Ordinary prior-year income/expense balances should not simply be carried forward as next-year income/expense opening balances. Midyear migration is a different case and must retain current-year movements and a documented cut-off.
2. **Company GST setting (1:06:43–1:09:37).** Saving a GSTIN in software does not perform government registration. Label it “GST configuration,” with verified registration details supplied separately.
3. **Invalid GSTIN and missing references (1:26:48; 1:49:14; 1:56:16).** The tutorial continues past warnings and changes a return from “against challan” to “direct” after allocation fails. Your app should preserve the intended workflow, identify the missing link and block inconsistent posting. Permit an opening/migrated reference only through a distinct controlled path.
4. **Tax rates and thresholds (especially 2:13–2:14).** Do not ship the tutorial's default rates as current law. Store effective dates, source and reviewer. The Income Tax Department explicitly says ERP systems need the updated section numbering and reporting framework for the 2026 transition; the earlier credit/payment event governs which Act applies [S3].
5. **GST utilization (2:00:32–2:01:05).** The narration contains inconsistent explanations. CGST credit cannot directly settle SGST, and SGST credit cannot directly settle CGST; IGST utilization has ordering rules [S4]. Build a validated rule engine, not a generic subtraction of total input from total output tax.
6. **TDS lower-rate example (2:28–2:30).** The transcript describes a warning that tax details and the ledger amount differ. A deduction report showing the intended rate is insufficient. Validate the expense, vendor payable, TDS ledger and deduction subledger together before posting.
7. **TDS payee type (2:17:48–2:18:07).** A name ending in “& Company” is not evidence of incorporation. Obtain the actual legal/payee category.
8. **Services (1:57:36–1:58:39).** This demo uses amount-only service entry. Your workshop needs hours, jobs or quantities where useful; a service still must not move physical stock.
9. **Stock transfers (2:52–2:54).** Model the legal entity, GST registration and location separately. Movement between locations and a transaction between separate entities cannot be treated as the same event. Determine applicable tax/document requirements before enabling each route.
10. **Payments (2:06–2:08; 2:32–2:33).** A posted payment voucher records a financial event; it does not prove money moved or a return was filed. Require bank/portal evidence and reconciliation.
11. **Single-entry screen (49:23–53:59).** The simplified input screen must still generate balanced double-entry accounting underneath. Do not create a separate incomplete ledger system for simple users.
12. **Deletion.** Replace routine deletion of posted financial records with a controlled correction/reversal process. Keep the historical link and reason.

## 5. Recommended architecture for the existing web app

### One accounting engine, several business screens

Sales, purchases, service billing, receipts, payments, imports and approved automation should all use the same posting service. Do not let each screen calculate its own ledger balance independently.

| Layer | Responsibility |
|---|---|
| Business documents | Orders, receipts, dispatches, invoices, returns, payments and approvals |
| Posting service | Validate document, company, period, tax snapshot, allocations and permissions; produce balanced journals |
| General ledger | Immutable posted journal lines, linked to source documents and reversals |
| Party subledger | Individual open bills, due dates, credits and settlement allocations |
| Inventory subledger | Every quantity/cost movement by item and warehouse; serial identity for vehicles |
| Tax subledgers | GST components, eligibility/utilization and TDS deduction/remittance detail |
| Reporting | Compute reports from these records; drill down to supporting documents |
| Integration jobs | Idempotent imports, notifications and external sync with retries and exception handling |

A modular backend is a sensible starting point. Splitting this into many microservices before reliable posting exists would add failure points without solving the accounting problem.

### Minimum data model

These are proposed entities; adapt them to the existing schema instead of creating duplicate customer, vehicle or branch tables.

| Entity family | Important records / fields |
|---|---|
| Organization | tenants, companies, branches, GST registrations, financial periods; company and tenant ownership |
| Access | users, memberships, roles, permissions, branch scope, approval rules |
| Accounts | account groups, accounts, normal classification, control-account type, active status |
| Parties | party identity, customer/vendor roles, tax identities, addresses, credit terms, ledger mappings |
| Items | item/SKU, goods/service flag, group, base unit, tax category, inventory tracking mode |
| Units | units and item-unit conversions with decimal precision |
| Locations | warehouse/material centre, branch, owning company and registration context |
| Documents | document type, series, number, dates, party, status, totals, version and source |
| Document lines | item/account, quantity, unit, rate, discount, tax snapshot, warehouse and source-line reference |
| Fulfilment links | ordered, received/dispatched, returned and billed quantities across document lines |
| Journals | source document, posting date, status, immutable line debits/credits, reversal relationship |
| Settlements | source payment/credit, target invoice, allocated amount, dates and reversal status |
| Stock movements | item, serial/chassis if applicable, quantity, unit cost, source document, location and movement type |
| Cost records | inventory costing layers or moving-average state, linked cost adjustments and COGS |
| GST | registrations, effective-dated rules, tax transaction lines, eligibility, adjustment and payment references |
| TDS | effective-dated categories, payee profile, deductions, certificates, remittances and legal-reference mapping |
| BOM / production | optional recipes, recipe versions, component lines, output lines and production batches |
| Control / evidence | approvals, audit events, attachments, import batches, integration outbox, idempotency keys |

Use decimal arithmetic for money and quantities. Store accounting dates as dates, separately from event timestamps. Keep business display times in IST where required. Rounding rules must be explicit and consistent between the document, journal, printed invoice and tax output.

### Posting rules that prevent expensive errors

| Event | Required effect |
|---|---|
| Order approved | Commercial commitment/reservation as configured; no invoice receivable/payable solely because an order exists |
| Goods received before supplier invoice | Receive inventory once; if using perpetual accounting, apply an approved goods-received-not-invoiced/accrual policy |
| Supplier invoice against receipt | Recognize/clear the appropriate accrual, liability and eligible tax; do not add receipt stock again |
| Direct supplier invoice with receipt | Receive stock and post accounting together according to the chosen policy |
| Delivery before invoice | Record dispatch once; explicitly define ownership, revenue and COGS recognition policy for this timing |
| Sales invoice against delivery | Recognize receivable/revenue/tax as appropriate; reference earlier movement so stock and COGS are not duplicated |
| Service invoice | Revenue/expense and tax effects without physical stock movements |
| Customer receipt | Debit bank/cash and credit the appropriate receivable/advance account; allocate separately to bills |
| Supplier payment | Debit payable/advance as applicable and credit bank/cash; allocate separately to bills |
| Return | Link original quantities and values; apply inverse financial effects and correct inventory disposition; distinguish tax note from commercial adjustment |
| Warehouse transfer | Reduce source, increase destination/in-transit; preserve entity-wide quantity; record approved transfer costs explicitly |
| Production | Consume components and add output/by-products atomically using an approved cost allocation |
| Reversal | Create traceable reversing effects and reopen related balances where appropriate; never leave financial and stock reversals out of sync |

The exact GRNI, dispatch, COGS, return and tax postings require an agreed accounting policy. The course does not resolve these design choices.

### Core invariants

- Every posted journal balances within the approved rounding policy.
- Every record and API operation enforces tenant/company access on the server; a frontend company dropdown is not isolation.
- Posting a document, its journal, stock effects, settlement links and audit event succeeds together or rolls back together.
- Posting the same document twice, or retrying the same webhook/import, cannot create duplicate effects.
- Invoice and voucher numbers remain unique under concurrent submissions.
- A payment cannot be allocated beyond its available amount; an invoice cannot be settled beyond its residual without an explicit credit/advance treatment.
- Quantities already returned, invoiced or delivered remain linked and cannot be consumed twice.
- Posted document tax rates and descriptive snapshots do not change when a master is edited later.
- Locked accounting periods reject ordinary backdated posting; reopening is approved and audited.
- Vehicle chassis/serial identity cannot simultaneously occupy two locations or be delivered twice.
- General-ledger control balances reconcile to party, inventory and tax subledgers.
- Backup recovery is verified by a restore exercise, not by a “backup succeeded” notification alone.

## 6. How this maps to your dealership app

The following are recommendations based on your dealership/automation use case; they are additions to the video extraction, not demonstrated BUSY features from this lesson.

| Your business requirement | Build on | Specific adaptation |
|---|---|---|
| Customer booking and delivery | Sales order, receipt, invoice, dispatch | Booking advance, vehicle allocation, cancellation/refund and final settlement; booking receipt is not automatically vehicle sales revenue |
| Vehicle inventory | Item and warehouse subledgers | Model, variant, colour, chassis, engine number, purchase document, status and exact location |
| HP-financed sale | Invoice and bill allocations | Distinguish customer downpayment, financier remittance, customer balance, charges, deductions and short receipt; prevent double-counting invoice collections |
| Branch stock transfer | Warehouse transfer | Dispatch and receiving acknowledgement, in-transit vehicles and mismatch queue; separate same-entity movement from intercompany sale/purchase |
| Accessories and spares | Item/unit/order workflows | SKU stock, bin, stock alerts, purchase receipts and returns; use BOM only for actual assembled kits |
| Workshop service | Service plus goods lines | Job card, labour charges, issued spares, outsourced work, technician and payment; labour does not reduce stock |
| Exchange vehicles | Linked purchase and sale documents | Separate used-vehicle valuation, ownership, inventory and disposal from the new-vehicle sales discount |
| Cashier collection | Receipt/payment vouchers | Cash, UPI, card, bank transfer and cheque with dedicated references, branch/day closing and deposit reconciliation |
| Insurance / registration collections | Party/control-account mappings | Identify own revenue versus amounts collected for another party; reconcile each settlement under an approved policy |
| Discount approval | Sales discounts and approvals | Role limits, reason, manager approval and record of who changed the price |
| Management view | Ledger and operational reports | Branch/model/executive performance with reconciled underlying numbers; cash collection and sales revenue remain separate metrics |
| AI document upload | Import pipeline | Extract to draft, show confidence and source page, identify duplicates, require review before financial posting |
| WhatsApp/Telegram reminders | Integration outbox | Schedule authorized reminders from validated balances; retain consent/contact controls and delivery logs |

**Suggested roles:** Executive creates operational drafts; Cashier records collections/disbursements within limits; Accountant reviews/posts/reconciles; Manager approves exceptions; Admin configures access and company settings; Auditor has read-only access. Apply server-side permissions and company/branch scopes to every role.

## 7. Practical build sequence

| Phase | Deliverables | Exit condition |
|---|---|---|
| 0 — Inventory of your current app | Map existing routes, tables, journal logic, authentication, tax logic and integrations against F01–F84 | Each requirement marked Existing / Partial / Missing / Deferred with evidence; no duplicate master model |
| 1 — Accounting foundation | Company/FY, chart of accounts, parties, journal engine, opening import, vouchers, allocations, day book, TB, P&L, balance sheet, audit and recovery | Opening balances reconcile; end-to-end posting/reversal tests pass; tenant and period controls work |
| 2 — Inventory and billing | Stock ledger/cost policy, invoices/returns, units, warehouses, printing, GST snapshots, vehicle identity | A purchase-sale-return-payment cycle reconciles across ledger, stock and party balances |
| 3 — Connected operations | Purchase/sales orders, receipt/delivery challans, partial fulfilment, transfers, service job cards, HP collection mapping and bank reconciliation | No duplicate stock effects; pending orders, in-transit stock and settlement exceptions are explainable |
| 4 — Compliance and integration depth | Applicable TDS, GST reconciliation, approved return exports/API adapters, source-document imports and notifications | Accountant signs off effective-dated rules and representative cases; external statuses distinguish submitted/accepted/rejected |
| 5 — Optional extensions | BOM/production, advanced MIS, additional automations | Real business demand justifies each extension |

Implement any applicable GST/TDS capability before the affected transactions go live, even if the rest of phase 4 is deferred. Manufacturing can remain disabled for a dealership that does not manufacture or assemble stock.

Do not assign a credible timeline until the current app and data model are inspected. “Add all BUSY features” is not a single implementation task.

## 8. Acceptance scenarios for a developer and accountant

These are proposed tests to implement during development; they have not been run against your app. Tax percentages below are deliberately illustrative, not product-rate guidance.

| Test | Expected result |
|---|---|
| Opening payable ₹1,00,000 split across three bills | Bill residuals total ₹1,00,000 and agree with the supplier control balance |
| Illustrative purchase ₹1,00,000 + ₹18,000 tax; eligible credit assumed | Journal balances; supplier payable ₹1,18,000; stock/tax follow selected policy |
| Return ₹10,000 + ₹1,800 of that purchase | Payable falls to ₹1,06,200; correct quantities leave stock; credit/return links retained |
| Pay ₹60,000 against that bill | ₹46,200 remains payable; bank reduces ₹60,000; no second expense booking |
| Illustrative sale ₹1,00,000 + ₹18,000 tax, followed by ₹10,000 + ₹1,800 return | Customer residual before receipts is ₹1,06,200; original-rate snapshot used |
| Receive ₹80,000 against that sale | ₹26,200 remains receivable; revenue is not posted a second time |
| Receive ₹1,20,000 against a bill with ₹1,18,000 remaining | Allocate ₹1,18,000; retain ₹2,000 as explicit unapplied/advance balance under policy |
| Order 10, receive 6, invoice those 6 | Pending receipt 4; inventory increases only 6; invoice does not add another 6 |
| Deliver 2 vehicles then invoice against delivery | Chassis count reduces only once; financial posting follows agreed recognition policy |
| Transfer 5 units out of a warehouse holding 20 | Source 15; in-transit/destination 5; company-wide physical quantity remains 20 |
| Return more units than the remaining eligible original quantity | Posting is blocked with a precise reason |
| Change a master tax rate after posting | Old invoice and old report totals remain unchanged |
| Lower-rate TDS certificate changes a draft deduction | Payee net, TDS subledger and TDS control ledger all recalculate and agree |
| Try unauthorized cross-company document access | Server denies access, including exports, attachments and reports |
| Two cashiers submit concurrently | Unique document numbers; both valid transactions recorded exactly once |
| Retry an already accepted import/webhook | Existing result returned; no extra journal or stock movement |
| Failure occurs between journal and stock write | Entire posting rolls back; no orphan effect |
| Post into a locked period | Rejected unless approved reopening process is completed |
| Reverse an invoice that has a payment allocation | Controlled deallocation/reversal policy applies; party and bank histories stay traceable |
| Restore a backup to an isolated test environment | Journal totals, stock, party balances and attachments reconcile to the backup checkpoint |

## 9. If you meant “connect my app directly to BUSY”

The video demonstrates a file-based master export/import between two BUSY companies. It does not establish that the exported format is open, supported for third-party apps, or suitable for unattended two-way sync.

Before writing a connector, establish the BUSY version/edition, officially supported integration route, available sample export, import semantics and licensing. Then choose the system of record for each entity.

| Decision | Recommended starting position |
|---|---|
| Direction | Begin with one-way, controlled transfer; introduce bidirectional writes only with explicit conflict rules |
| Identity | Persist external company, party, item and voucher IDs; never match solely on name |
| Posting owner | Exactly one system owns final accounting posting for each transaction |
| Corrections | Synchronize reversal/cancellation references; do not overwrite historical entries silently |
| Reliability | Idempotency, retry queue, row-level failures and replayable audit record |
| Reconciliation | Compare document count, taxable/tax totals, party balances and ledger control totals after each batch |
| Security | Use supported authenticated interfaces; do not write directly to undocumented BUSY database structures |

For reproducing capabilities inside your app, use this document as a requirements backlog. For direct BUSY synchronization, obtain the supported interface first; the course alone is insufficient.

## 10. Implementation brief for your coding agent

> Inspect the existing application before changing its schema. Map requirements F01–F84 to existing, partial, missing or deferred functionality. Identify the current source of truth for customers, suppliers, vehicles, branches, inventory and journals. Preserve existing IDs and avoid creating parallel masters. Propose the smallest phased changes needed for a shared double-entry posting service, bill allocations and inventory movements. Enforce company isolation, balanced journals, atomic posting, immutable posted records with reversals, unique numbering, idempotent retries, period locks and source-document links. Treat GST/TDS rules as effective-dated reviewed configuration. Do not copy rates, fake tax identities or warning bypasses from the tutorial. Separate database changes, migration reconciliation, API behavior, screens, permissions and acceptance scenarios. Implement and verify one vertical workflow at a time, starting with opening balances and purchase/sale/payment settlement. Keep manufacturing optional. Do not claim filing, bank settlement or BUSY sync unless the relevant external interface and success response are verified.

## Sources and boundaries

- **[S1] Video and its full auto-generated Hindi transcript:** [YouTube](https://www.youtube.com/watch?v=1sDu7IoRUgQ). Feature timecodes above refer to this source. Accessed 25 September 2026. The title's year is not proof that every tax default in the lesson is current.
- **[S2] BUSY official feature catalog:** [Features and FAQs](https://busy.in/busy-features-and-faqs/). Used only to separate additional advertised product capabilities from what this lesson establishes. Accessed 25 September 2026.
- **[S3] Income Tax Department:** [TDS Compliance](https://www.incometax.gov.in/iec/foportal/help/all-topics/e-filing-services/tds-compliance). Used for the date-sensitive transition and ERP section-mapping warning. Accessed 25 September 2026; this report is not a complete TDS rate/threshold specification.
- **[S4] CBIC:** [Circular 98/17/2019-GST](https://cbic-gst.gov.in/pdf/Circular-98-17-2019-GST.pdf), including the utilization table on page 2. Used to correct the narrated cross-utilization explanation, not as a complete GST compliance specification.

All architecture, priorities, controls, dealership adaptations and acceptance scenarios are recommendations. They are not extracted claims about BUSY's internal implementation and are not a code audit of your web app.
