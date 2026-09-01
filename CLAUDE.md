# CLAUDE.md — Two-Wheeler Dealer ERP

## 1. Project Mission

Build a production-ready, multi-tenant ERP web application for two-wheeler dealers.

The product combines:

- Vehicle sales
- Vehicle bookings
- Vehicle inventory
- Accessories inventory
- Spare-parts inventory
- Service billing
- Customer management
- Finance / HP sales
- Finance-company trade advances
- Double-entry accounting
- Daily cash book
- Bank book
- Bank reconciliation
- GST
- E-Invoice / E-Way Bill integration layer
- Price history
- Margin and profitability
- Dealer/branch consolidated MIS
- Role-based access
- Audit trail

This is an accounting-first ERP. Do not build it as a simple POS/billing application.

---

# 2. Technology Stack

## Frontend

Preferred:

- Next.js
- TypeScript
- React
- Tailwind CSS
- shadcn/ui or equivalent accessible component system
- TanStack Query for server state where useful
- React Hook Form + Zod for forms and validation

## Backend

Use a clean API/service architecture inside the application.

- TypeScript
- Server-side validation
- Service layer for business rules
- Repository/data-access layer where appropriate

Do NOT put critical accounting logic directly inside React components.

## Database

### Supabase PostgreSQL

Supabase is the primary database.

Use:

- PostgreSQL
- Supabase Auth
- Supabase Storage where required
- Row Level Security (RLS)
- PostgreSQL transactions
- Foreign keys
- Unique constraints
- Check constraints
- Indexes
- Database functions/triggers only where they improve integrity and are well controlled

All tenant-sensitive data must be protected at database level.

Never depend only on frontend filtering for tenant isolation.

---

# 3. Deployment

## Railway

The application will be deployed on Railway.

Production architecture:

User
→ Railway-hosted Web App
→ Supabase PostgreSQL/Auth/Storage
→ External GST / E-Invoice services where configured

Keep the application stateless wherever possible.

Do not store business-critical persistent data on the Railway filesystem.

Use environment variables for:

- Supabase URL
- Supabase anon key
- Supabase service role key
- Database connection where required
- GST/e-invoice credentials
- Storage credentials
- Encryption secrets
- Application secrets

Never commit secrets to Git.

Provide:

- `.env.example`
- Railway deployment documentation
- Supabase migration scripts
- production build configuration

---

# 4. Multi-Tenant Architecture

The system must support multiple dealers.

Example:

Platform
├── Dealer A
│   ├── Branch 1
│   ├── Branch 2
│   └── Branch 3
├── Dealer B
│   ├── Branch 1
│   ├── Branch 2
│   └── Branch 3
└── Dealer C
    └── ...

Every dealer must be isolated.

Core tables should use:

- dealer_id
- branch_id where the record is branch-specific

Never allow a user from Dealer A to read or modify Dealer B data.

Use Supabase RLS as a mandatory second line of defense.

---

# 5. Organization Model

Recommended hierarchy:

- Platform
- Dealer
- Branch
- Department
- Employee
- User
- Role

Dealer-level masters:

- Customer
- Vehicle Model
- Variant
- Tax
- HSN/SAC
- Accessories
- Spares
- Finance Companies
- Chart of Accounts
- Pricing Templates

Branch-level operational data:

- Vehicle stock
- Accessory stock
- Spare stock
- Sales
- Bookings
- Service
- Cash book
- Bank book
- Payments
- Receipts

---

# 6. Roles & Access Control

Minimum roles:

## Platform Admin

Can:

- Create/manage dealers
- Manage tenant configuration
- Manage platform settings

## Dealer Owner/Admin

Can:

- View all branches
- View consolidated reports
- Approve transactions
- View profitability
- Manage users
- Manage masters

## Accounts

Can:

- Upload vehicle stock
- Upload accessory/spare stock
- Configure pricing
- Configure GST
- Verify sales
- View purchase cost
- View margin
- View profit
- Manage ledgers
- Manage journals
- Manage cash book
- Manage bank reconciliation
- Manage finance-company ledgers
- Run reports
- Approve accounting transactions

## Cashier

Can:

- Create customer
- Create booking
- Create payment receipt
- Create sales draft
- View selling price
- View customer balance

Cannot see:

- Purchase cost
- COGS
- Gross margin
- Net profit
- Internal commission
- Confidential finance information

## Sales Executive

Can:

- Create customer
- Create booking
- Prepare sales
- View assigned customers
- View vehicle availability

## Service Advisor

Can:

- Search customer
- Search vehicle
- Create job card
- Create service bill
- Add spares/accessories
- Collect service payment

## Counter Sales

Can:

- Sell accessories
- Sell spares
- Check stock
- Generate invoice

Permissions must be enforced server-side and through RLS where applicable.

---

# 7. UI Design System

## Design Direction

Use a modern premium SaaS ERP interface.

Style:

### Light Glassmorphism

Primary visual direction:

- White
- Soft blue
- Very light blue
- Cool gray
- Subtle gradients
- Frosted glass surfaces
- Thin borders
- Soft shadows
- High readability

Do NOT create a dark-heavy admin dashboard.

Do NOT overuse glass effects.

The UI must remain professional and accounting-friendly.

### Suggested visual language

Background:

- Very light blue/white gradient

Panels:

- White with slight transparency
- `backdrop-blur`
- Thin white/blue border
- Soft shadow

Primary:

- Blue

Positive:

- Green

Warning:

- Amber

Danger:

- Red

Text:

- Dark navy / slate

Muted text:

- Slate gray

### Glass card rules

Use glassmorphism mainly for:

- Dashboard KPI cards
- Header
- Filter panels
- Summary panels
- Modal dialogs

Operational accounting tables should remain highly readable with mostly solid white surfaces.

Do not make tables excessively transparent.

---

# 8. UX Principles

The ERP must be:

- Fast
- Dense but readable
- Keyboard friendly
- Desktop-first
- Responsive
- Search-first
- Form-efficient
- Accounting-safe

Avoid:

- Excessive animations
- Huge cards
- Excessive rounded corners
- Decorative charts
- Hidden accounting information
- Long multi-step forms where unnecessary

Use:

- Sticky table headers
- Global search
- Command/search palette
- Keyboard shortcuts
- Breadcrumbs
- Clear status badges
- Inline validation
- Confirmation dialogs for financial actions
- Drill-down reports

---

# 9. Main Navigation

Dashboard

Sales
- Vehicle Sales
- Deliveries
- Sales Returns

Bookings
- Booking List
- New Booking
- Booking Advances

Customers
- Customer Master
- Customer Ledger
- Vehicle History
- Service History

Vehicles
- Vehicle Stock
- Vehicle Models
- Variants
- Price History
- Vehicle Transfers

Inventory
- Accessories
- Spares
- Stock Upload
- Stock Transfer
- Stock Adjustment
- Stock Ledger

Service
- Job Cards
- Service Billing
- Service History

Finance
- Finance Companies
- HP Sales
- Trade Advances
- Finance Settlement

Accounting
- Chart of Accounts
- Journal Entries
- Customer Ledger
- Supplier Ledger
- Trial Balance
- P&L
- Balance Sheet

Cash Book
- Daily Cash Book
- Cash Receipts
- Cash Payments
- Day Close

Bank
- Bank Accounts
- Bank Book
- Statement Import
- Reconciliation

GST
- GST Summary
- E-Invoice
- E-Way Bill
- GST Reports

Reports
- Sales
- Inventory
- Finance
- Margin
- Branch Performance
- Consolidated MIS

Masters
- Tax
- HSN/SAC
- Customers
- Employees
- Finance Companies
- Accessories
- Spares
- Pricing
- Accounting

Administration
- Dealers
- Branches
- Users
- Roles
- Permissions
- Audit Logs
- Settings

---

# 10. Dashboard

Dashboard must support:

- Dealer filter
- Branch filter
- Date/month filter

For dealer users, default to consolidated view.

## Mandatory KPI cards

- Vehicle Sales
- Vehicle Sales Value
- Bookings
- Booking Advance
- Finance Units
- Finance Amount
- Deliveries
- Vehicle Stock
- Vehicle Stock Value
- Accessories Stock
- Accessories Stock Value
- Spare Stock
- Spare Stock Value
- Service Revenue
- Cash Balance
- Bank Balance
- Receivables
- Payables

## Owner/Accounts-only KPIs

- Gross Margin
- Vehicle Margin
- Accessories Margin
- Spare Margin
- Service Margin
- Net Profit
- Finance Commission
- Insurance Income
- Forwarding Income

Cashier must not receive these fields from the API.

---

# 11. Customer Master

Every customer gets an auto-generated Customer ID.

Fields:

- customer_id
- dealer_id
- name
- mobile
- alternate_mobile
- address
- city
- state
- pincode
- GSTIN
- PAN
- created_by
- created_at

Customer search:

- Customer ID
- Mobile
- Name
- Vehicle registration
- Chassis number

Customer 360 page:

Customer
→ Bookings
→ Vehicle Sales
→ Payments
→ Outstanding
→ Finance
→ Service
→ Accessories
→ Spares
→ Ledger

---

# 12. Employee Master

Employee ID is mandatory.

Fields:

- employee_id
- dealer_id
- branch_id
- name
- department
- designation
- mobile
- joining_date
- status

Transactions retain employee attribution.

---

# 13. Vehicle Inventory

Vehicle stock is chassis-level.

Fields:

- vehicle_id
- dealer_id
- branch_id
- brand
- model
- variant
- colour
- model_code
- chassis_no
- engine_no
- key_no
- purchase_invoice
- purchase_date
- purchase_cost
- stock_date
- status

Vehicle statuses:

- IN_STOCK
- BOOKED
- SOLD_PENDING_DELIVERY
- DELIVERED
- TRANSFERRED
- CANCELLED

Never represent vehicle inventory only as quantity.

Every physical vehicle must be individually traceable.

---

# 14. Vehicle Stock Upload

Accounts team uploads vehicle stock.

Support:

- CSV
- Excel

Validate before import:

- duplicate chassis
- duplicate engine
- invalid model
- invalid variant
- invalid branch
- missing purchase cost
- missing purchase invoice

Import process:

Upload
→ Preview
→ Validation
→ Error report
→ Confirm Import
→ Stock Transaction
→ Audit Log

Do not partially import silently.

---

# 15. Pricing Architecture

Vehicle prices change regularly.

Do NOT update one price field and destroy history.

Use effective-dated price versions.

Example:

Model X

01-Aug:
Ex-showroom = X

08-Aug:
Ex-showroom = Y

15-Aug:
Ex-showroom = Z

Historical transactions must retain the exact price used at the time.

Pricing components:

- Ex-showroom
- Insurance
- LTRT/registration
- Mandatory accessories
- Forwarding charge
- Other charge
- Discount policy
- Tax code

Accounts can configure pricing.

Price changes require audit trail.

Optional approval:

DRAFT
→ SUBMITTED
→ APPROVED
→ ACTIVE

---

# 16. GST Architecture

Never hard-code GST rates in UI logic.

Tax master:

- tax_code
- HSN/SAC
- GST rate
- CGST rate
- SGST rate
- IGST rate
- effective_from
- effective_to
- active

Support examples:

- 5%
- 9% CGST + 9% SGST
- 18%
- Other configured rates

Tax is calculated from transaction values using the applicable tax configuration.

Historical invoices retain their original tax values.

---

# 17. Vehicle Pricing Template

Accounts configures model-level defaults.

Example:

Jupiter 110

- Ex-showroom
- Insurance
- LTRT
- Mandatory accessories
- Forwarding
- Other charges
- GST

Cashier sees selling values only.

Accounts sees:

- Purchase cost
- Cost allocation
- Tax allocation
- Margin
- Profitability

This avoids re-entering accounting splits during every sale.

---

# 18. Booking Workflow

Cashier:

Customer
→ Select model/vehicle
→ Booking amount
→ Payment mode
→ Receipt
→ Save

Accounting:

Cash/Bank Dr
    Customer Advance Cr

Booking should not immediately recognize vehicle revenue unless configured by the accounting policy.

Booking can later be converted into a vehicle sale.

---

# 19. Vehicle Sales Workflow

Sales flow:

Customer
→ Vehicle/chassis
→ Price template
→ Extra fittings
→ Finance/payment
→ Submit

Status:

DRAFT
→ SUBMITTED
→ ACCOUNTS VERIFICATION
→ APPROVED
→ POSTED
→ DELIVERED

Accounts verifies:

- Customer
- Vehicle
- Chassis
- Purchase cost
- Selling price
- Tax
- Accessories
- Payment
- Finance
- Accounting entries

Only after approval should financial posting occur.

---

# 20. Vehicle Invoice Components

Possible components:

- Ex-showroom
- Insurance
- LTRT/registration
- Mandatory accessories
- Extra fittings
- Forwarding
- Other charges
- Discount
- GST

Every invoice line stores:

- item
- HSN/SAC
- quantity
- rate
- taxable value
- tax code
- CGST
- SGST
- IGST
- total

---

# 21. Accounting Engine

This is the most important backend component.

All modules post into one accounting engine.

Modules:

- Sales
- Bookings
- Service
- Accessories
- Spares
- Finance
- Trade Advance
- Cash
- Bank
- Expenses
- Inventory

Architecture:

Business Transaction
→ Accounting Event
→ Journal Entry
→ Journal Lines
→ Ledger
→ Reports

Do not create separate accounting engines for sales, service, finance, etc.

---

# 22. Double-Entry Rules

Every posted journal must satisfy:

Total Debit = Total Credit

Example vehicle sale conceptually:

Customer/Finance Receivable Dr
    Vehicle/Revenue/Tax/Other Credit accounts as configured

Inventory/COGS posting must reduce vehicle inventory and recognize COGS.

Exact account mapping must be configurable through accounting rules.

Do not hard-code account IDs in frontend code.

---

# 23. Accounting Immutability

Once a journal is POSTED:

- no direct edit
- no delete

Correction mechanism:

Original Entry
→ Reversal
→ Corrected Entry

Every reversal requires:

- reason
- user
- timestamp
- reference

---

# 24. Chart of Accounts

Suggested structure:

## Assets

- Cash
- Bank
- Customer Receivable
- Finance Receivable
- Vehicle Inventory
- Accessories Inventory
- Spare Inventory
- Other Receivables

## Liabilities

- Customer Advances
- Supplier Payables
- Output CGST
- Output SGST
- Output IGST
- Other Payables

## Income

- Vehicle Sales
- Accessories Sales
- Spare Sales
- Service Labour
- Finance Commission
- Insurance Commission
- Forwarding Income
- Other Income

## Costs / Expenses

- Vehicle COGS
- Accessories COGS
- Spare COGS
- Service Cost
- Salaries
- Rent
- Utilities
- Bank Charges
- Other Expenses

---

# 25. Finance Company Ledger

Every finance company gets a separate ledger.

Examples:

- TVS Credit
- HDFC
- Cholamandalam
- ICICI
- Bajaj

Track:

- Opening
- Debit
- Credit
- Trade Advance
- Vehicle Adjustment
- Settlement
- Commission
- Refund
- Closing

Never combine all finance companies into one generic balance.

---

# 26. Trade Advance

Finance companies may provide advance/trade advance.

Transaction types:

- Advance Received
- Vehicle Adjustment
- Settlement
- Refund
- Commission
- Manual Adjustment

Each transaction must post to the finance-company ledger and accounting engine.

Provide daily ledger view:

Opening
+ Credits
- Debits
= Closing

---

# 27. Finance / HP Sales

Track:

- Finance company
- Customer
- Vehicle
- Loan amount
- Down payment
- Approval status
- Disbursement status
- DD/reference
- Bank reference
- Pending amount

Dashboard:

- Finance units
- Finance amount
- Finance penetration %
- Pending finance
- Approved
- Disbursed

---

# 28. Accessories Inventory

Accessories can be:

- COMPANY
- LOCAL

Do not merge them in the database.

Maintain separate stock lots.

Display:

Local Qty
Company Qty
Total Qty
Local Value
Company Value
Total Value

Every movement creates a stock transaction.

---

# 29. Spare Inventory

Same architecture as accessories.

Track:

- item_code
- name
- brand/source
- HSN
- purchase cost
- selling price
- GST
- local/company source
- branch
- quantity

---

# 30. Vehicle → Accessory Mapping

Create fitting templates.

Example:

Jupiter 110
→ Floor Mat
→ Seat Cover
→ Leg Guard

Mapping contains:

- model/variant
- accessory item
- quantity
- default YES/NO
- priority
- source allocation rule

At vehicle sale:

Extra Fittings?
YES / NO

If YES:

Load mapped fittings
→ Check stock
→ Auto allocate
→ Add invoice lines
→ Reduce inventory
→ Record COGS
→ Calculate margin

---

# 31. Accessory Allocation Rule

Default rule:

1. Consume LOCAL stock first.
2. If local stock is zero/insufficient, consume COMPANY stock.
3. If both are insufficient, block or route for approval according to configuration.

Example:

Required = 3

Local = 2
Company = 10

Consumption:

Local = 2
Company = 1

Never hide the source.

Invoice and stock ledger must show the allocation.

---

# 32. Service

Existing customer:

Search customer
→ Select vehicle
→ Create job card

New customer:

Create customer
→ Generate Customer ID
→ Create vehicle/service record as applicable

Service transaction includes:

- Labour
- Spares
- Accessories
- Other charges
- GST
- Payment

Service history must be attached to:

- Customer
- Vehicle
- Branch

---

# 33. Counter Sales

Counter sales support:

- Accessories
- Spares

Flow:

Customer optional/required according to configuration
→ Item
→ Quantity
→ Stock validation
→ Tax
→ Invoice
→ Payment
→ Accounting
→ Inventory deduction

Stock cannot become negative unless explicitly configured.

---

# 34. Inventory Ledger

Every inventory movement is immutable and traceable.

Transaction types:

- OPENING
- PURCHASE
- SALE
- CONSUMPTION
- RETURN
- TRANSFER_OUT
- TRANSFER_IN
- ADJUSTMENT
- REVERSAL

Never directly overwrite inventory quantity.

Current stock should be derived from valid stock movements or maintained through controlled transactional updates.

---

# 35. Branch Transfer

Support:

- Vehicle transfer
- Accessories transfer
- Spare transfer

Vehicle transfer:

Branch A
→ Transfer
→ In Transit
→ Branch B Receive

Both branches retain audit history.

---

# 36. Mandatory Daily Cash Book

Each branch has a cash account.

Daily:

Opening Balance
+ Cash Receipts
- Cash Payments
= Expected Closing

Then:

Physical Cash
vs
Expected Closing

Calculate:

Cash Difference

End-of-day workflow:

OPEN
→ DAY IN PROGRESS
→ COUNTED
→ CLOSED

After close:

No direct edits.

Only reversal/adjustment with permission.

---

# 37. Cash Book UI

Show:

- Opening balance
- Total receipts
- Total payments
- Expected closing
- Physical cash
- Difference

Transaction table:

- Time
- Reference
- Particular
- Receipt
- Payment
- Running Balance

---

# 38. Bank Book

Each bank account has:

- Opening
- Receipts
- Payments
- Transfers
- Closing

Bank accounts are branch/dealer scoped.

---

# 39. Bank Reconciliation

Import bank statements.

Support:

- CSV
- Excel
- supported bank statement formats

Match using:

- Amount
- Date
- Reference
- UTR
- UPI ID
- Narration
- Customer

Statuses:

- MATCHED
- UNMATCHED
- PARTIAL
- IGNORED

Never mark an entry reconciled without recording the reconciliation link.

---

# 40. GST / E-Invoice Integration

Build an integration layer rather than coupling invoice screens directly to an external portal.

Flow:

Invoice Posted
→ Validate GST data
→ Generate e-invoice payload
→ Send to configured provider/API
→ Receive IRN/acknowledgement
→ Store response
→ Update invoice

Store:

- IRN
- acknowledgement number
- acknowledgement date
- signed QR/data where applicable
- request/response audit reference
- error message

Never allow external API failure to corrupt the accounting transaction.

If external service fails:

Invoice remains posted
E-Invoice status = FAILED/PENDING

Then allow retry.

---

# 41. Reports

Mandatory reports:

## Sales

- Daily sales
- Monthly sales
- Model-wise
- Variant-wise
- Branch-wise
- Employee-wise
- Finance-wise

## Booking

- Booking count
- Booking value
- Advance
- Pending conversion
- Cancelled booking

## Inventory

- Vehicle stock
- Stock value
- Stock ageing
- Accessories stock
- Spare stock
- Local/company split
- Stock movement

## Finance

- Finance units
- Finance amount
- Company-wise
- Pending disbursement
- Trade advance ledger

## Accounting

- Customer ledger
- Supplier ledger
- Finance ledger
- Cash book
- Bank book
- Trial balance
- P&L
- Balance sheet
- Outstanding

## Profitability

Accounts/Owner only:

- Vehicle margin
- Accessory margin
- Spare margin
- Service margin
- Forwarding margin
- Finance commission
- Insurance income
- Branch profitability
- Model profitability

---

# 42. Price History Reporting

For any customer sale:

Search invoice/date/chassis.

System must show:

- Sale date
- Exact price used
- Price version
- Ex-showroom
- Insurance
- LTRT
- Forwarding
- Accessories
- GST
- Discount

This allows the dealer to answer:

"What was the price on that date?"

Do not derive historical invoice prices from the current price master.

---

# 43. Consolidated Dashboard

Dealer owner can select:

All branches

Then view:

- Total vehicle sales
- Total bookings
- Total finance
- Total deliveries
- Vehicle stock
- Vehicle stock value
- Accessories stock
- Accessories value
- Spare stock
- Spare value
- Service sales
- Cash
- Bank
- Receivables
- Payables
- Margin
- Profit

Every number must be drillable down to branch and transaction.

---

# 44. Database Design Principles

Use normalized PostgreSQL tables.

Recommended core tables:

### Organization

- dealers
- branches
- users
- roles
- permissions
- user_roles
- employees

### Customer

- customers
- customer_vehicles

### Vehicle

- vehicle_models
- vehicle_variants
- vehicles
- vehicle_price_versions
- vehicle_stock_transactions
- vehicle_transfers

### Inventory

- inventory_items
- inventory_sources
- inventory_stock
- inventory_transactions
- accessory_vehicle_mappings

### Sales

- bookings
- booking_payments
- sales
- sale_lines
- sale_payments
- deliveries

### Service

- job_cards
- service_lines
- service_payments

### Finance

- finance_companies
- finance_transactions
- finance_applications
- finance_settlements

### Accounting

- chart_of_accounts
- journal_entries
- journal_entry_lines
- ledger_accounts
- accounting_periods

### Cash/Bank

- cash_accounts
- cash_transactions
- cash_day_closings
- bank_accounts
- bank_transactions
- bank_statement_lines
- bank_reconciliations

### Tax

- tax_codes
- hsn_codes
- gst_transactions
- einvoices
- eway_bills

### Administration

- audit_logs
- document_sequences
- system_settings

Exact schema can evolve, but relationships and accounting integrity must remain strong.

---

# 45. Document Numbering

Use controlled sequences per dealer/branch/document type.

Examples:

- INV-2026-000001
- BK-2026-000001
- REC-2026-000001
- PAY-2026-000001
- JC-2026-000001
- JE-2026-000001

Never generate financial document numbers purely in frontend JavaScript.

Use database-safe sequence generation.

---

# 46. Audit Trail

Audit all sensitive actions:

- Create
- Update
- Approve
- Post
- Cancel
- Reverse
- Stock adjustment
- Price change
- GST change
- Permission change
- Day close
- Reconciliation

Store:

- user_id
- dealer_id
- branch_id
- action
- entity
- entity_id
- old data where appropriate
- new data where appropriate
- timestamp
- IP/session metadata where permitted

---

# 47. Security

Mandatory:

- Supabase Auth
- RLS
- Server-side authorization
- Role permissions
- Dealer isolation
- Branch isolation
- Input validation
- SQL injection protection
- CSRF protection where applicable
- Secure cookies/session handling
- Rate limiting on sensitive endpoints
- No service-role key in browser
- No secrets in source code

Never trust:

- frontend role
- hidden UI fields
- client-submitted dealer_id
- client-submitted branch_id
- client-submitted margin visibility

Resolve tenant and permissions from authenticated server context.

---

# 48. Transaction Integrity

Financial transaction should be atomic.

Example vehicle sale:

1. Validate user
2. Validate dealer/branch
3. Lock vehicle
4. Validate vehicle availability
5. Validate pricing
6. Validate accessory stock
7. Allocate accessory stock
8. Create invoice
9. Create payment/finance allocation
10. Create accounting journal
11. Create inventory movements
12. Update vehicle status
13. Commit transaction

If any critical step fails:

Rollback the transaction.

Never create an invoice without its accounting/inventory effects being consistent.

---

# 49. Concurrency

This is critical.

Two cashiers must not be able to sell the same chassis simultaneously.

Use:

- PostgreSQL transactions
- row locking / appropriate isolation
- unique constraints
- server-side stock validation

Same rule for accessory/spare stock where concurrent sales can cause overselling.

---

# 50. Idempotency

Financial endpoints must protect against duplicate submissions.

Prevent:

- duplicate invoice
- duplicate receipt
- duplicate payment
- duplicate journal
- duplicate stock deduction
- duplicate e-invoice request

Use idempotency keys or unique business references.

---

# 51. UI Screen Standards

Every operational screen should have:

### Header

- Page title
- Breadcrumb
- Search
- Branch context
- Date filter where relevant
- Primary action

### Table

- Search
- Filters
- Sort
- Pagination
- Export
- Column visibility where useful

### Detail Drawer/Page

Show:

- Transaction status
- Customer
- Branch
- Employee
- Financial summary
- Audit history
- Related documents

### Financial screens

Use right-aligned numeric columns.

Indian formatting:

₹1,25,000.00

---

# 52. Sales Screen Layout

Modern glass UI:

Left:
Customer + vehicle selection

Center:
Invoice/pricing breakdown

Right:
Payment summary

Show to cashier:

- Selling price
- Customer payment
- Finance
- Balance

Do not expose:

- Purchase cost
- COGS
- Margin
- Profit

Accounts view adds:

- Purchase cost
- COGS
- Margin
- GST allocation
- Journal preview

---

# 53. Accounts Verification Screen

Show:

Cashier Entry
vs
System Accounting Preview

Sections:

- Customer
- Vehicle
- Pricing
- Tax
- Accessories
- Payment
- Finance
- Journal
- Margin

Actions:

- Approve
- Reject
- Return for Correction

---

# 54. Dashboard Visual Requirements

Use:

- white background
- soft blue gradient
- glass KPI cards
- blue primary buttons
- subtle shadows
- thin borders
- clean charts
- compact tables

Recommended layout:

Top:
Dealer / Branch / Date filters

Row 1:
6 KPI cards

Row 2:
Sales trend + Financial snapshot

Row 3:
Branch performance + Finance companies + Attention required

Row 4:
Recent transactions + Cash/Bank status

---

# 55. Error Handling

Never silently fail.

Show:

- clear validation errors
- accounting errors
- inventory errors
- permission errors
- GST API errors
- reconciliation errors

For external API errors:

Store technical error internally.

Show user-friendly message.

---

# 56. Development Order

## Phase 1 — Foundation

- Next.js setup
- TypeScript
- Tailwind
- UI system
- Supabase
- Auth
- Multi-tenant model
- RLS
- Dealer/branch
- Roles/permissions
- Audit framework

## Phase 2 — Masters

- Customer
- Employee
- Vehicle model
- Variant
- Vehicle inventory
- Tax
- HSN
- Accessories
- Spares
- Finance companies
- Chart of accounts

## Phase 3 — Pricing & Inventory

- Vehicle stock upload
- Accessory/spare stock upload
- Price versions
- Price history
- Stock ledger
- Branch transfer
- Vehicle/accessory mapping

## Phase 4 — Sales & Booking

- Booking
- Booking advance
- Vehicle sales
- Payment
- Finance
- Delivery
- Accounting posting

## Phase 5 — Accounting

- Journal engine
- Customer ledger
- Finance ledger
- Cash book
- Bank book
- Trial balance
- P&L
- Balance sheet

## Phase 6 — Service

- Job cards
- Service billing
- Service inventory consumption
- Service payments

## Phase 7 — Reconciliation & GST

- Bank statement import
- Reconciliation
- GST reports
- E-invoice integration
- E-way bill integration

## Phase 8 — MIS

- Consolidated dashboard
- Branch reports
- Margin reports
- Profitability
- Stock ageing
- Finance analytics

---

# 57. Claude Development Rules

When implementing any feature:

1. Inspect existing code before changing it.
2. Do not rewrite working modules unnecessarily.
3. Keep business logic in server/service layers.
4. Validate all input with schemas.
5. Use Supabase/PostgreSQL constraints for integrity.
6. Add RLS policies for every tenant-sensitive table.
7. Add indexes for frequent searches.
8. Never expose secrets to client code.
9. Never expose restricted financial fields to unauthorized roles.
10. Write migrations for schema changes.
11. Keep migrations reversible where practical.
12. Test accounting impact.
13. Test inventory impact.
14. Test permission impact.
15. Test dealer isolation.
16. Test branch isolation.
17. Test duplicate submission.
18. Test concurrent stock/sale behavior.
19. Test cancellation/reversal.
20. Update documentation when architecture changes.

---

# 58. Critical Business Rule

Do not implement the application as:

Form → Database Row

Implement it as:

User Action
→ Validation
→ Business Transaction
→ Accounting Event
→ Inventory Event
→ Ledger
→ Audit Trail
→ Reporting

Every important transaction must have a traceable chain.

---

# 59. Definition of Done

A feature is complete only when:

- UI works
- Mobile/responsive behavior is acceptable
- API/server validation works
- Supabase schema exists
- RLS exists
- Role permissions work
- Dealer isolation works
- Branch isolation works
- Audit trail works
- Accounting impact is defined
- Inventory impact is defined
- GST impact is defined where applicable
- Reversal/cancellation behavior is defined
- Duplicate protection works
- Error handling works
- Reports reconcile with transaction data
- Production environment variables are documented
- Railway deployment succeeds

---

# 60. Non-Negotiable Rules

1. Supabase PostgreSQL is the source of truth for business data.
2. Railway hosts the application; do not rely on Railway local filesystem for persistent business data.
3. Multi-tenant architecture must exist from day one.
4. Every tenant-sensitive record is dealer-scoped.
5. Branch-level transactions are branch-scoped.
6. Customer ID is mandatory.
7. Employee ID is mandatory for operational transactions.
8. Vehicle stock is chassis-level.
9. Vehicle price history is immutable.
10. Historical invoices never change because of new price configuration.
11. GST is configuration-driven.
12. Posted journals are immutable.
13. Corrections use reversal/adjustment.
14. Cash book is mandatory.
15. Daily cash closing is mandatory.
16. Local and Company accessory stock remains separately traceable.
17. Automatic fitting allocation must be auditable.
18. All modules use the same accounting engine.
19. Margin/profit visibility is role-controlled.
20. Backend and database enforce security; UI alone is never sufficient.
21. Consolidated reporting must respect tenant isolation.
22. No silent stock adjustments.
23. No silent accounting edits.
24. No duplicate financial posting.
25. Accounting correctness takes priority over UI convenience.

---

# 61. First Build Instruction

Start by creating the application foundation before building individual business modules.

First deliver:

1. Modern light glassmorphism UI shell
2. Sidebar navigation
3. Top header
4. Dealer/branch context selector
5. Role-aware navigation
6. Dashboard
7. Supabase connection
8. Authentication
9. Dealer/branch schema
10. User/role schema
11. RLS policies
12. Audit infrastructure
13. Base database migration structure

Then build modules incrementally according to the development phases above.

Do not build fake accounting behavior just to make the UI look complete.

When a module is not yet connected to the real database, clearly isolate mock/demo data and replace it before calling the feature production-ready.

<!-- BEGIN:nextjs-agent-rules -->

# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->
