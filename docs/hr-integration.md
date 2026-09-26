# HR Payroll app ↔ ERP connection

This covers claims, people, attendance and payroll. It was added in ERP migration 0095 and HR app migration `20260926090000_integration`.

## What flows where

| What | From → to | How |
|---|---|---|
| Approved claim | HR → ERP | A signed webhook (`claim.approved`), plus the ERP's pull every sync. The ERP books Dr *mapped expense ledger* / Cr **2770 Employee Claims Payable** for the employee. |
| Approval taken back | HR → ERP | Webhook `claim.changed`. If the claim is unpaid in the ERP, the booking is reversed. If it is paid, the claim is flagged **Needs review**. |
| Payment | ERP → HR | The cashier pays under **Cash Book → Claims to Pay**, as one cash or bank voucher with Dr 2770 / Cr Cash for the employee. The ERP then calls `POST /api/integration/v1/claims/:id/paid`, and the HR app shows the claim PAID (with a WhatsApp message to the employee). |
| People | HR → ERP | Pulled on each sync and matched on the HR id (`employees.external_ref`). |
| Attendance | HR → ERP | The existing attendance mirror, pointed at the HR app (see the env vars below). |
| Payroll | HR → ERP | **HR → HR App Link → Bring in payroll** for a finalised month creates draft payroll runs, one per branch, marked `source = HR`. These are posted and paid through the existing payroll screens. |

With the connection's "ERP pays approved claims" switch on (the default), the HR app refuses its own **Mark Paid**, so a claim is never paid twice. A claim already paid at the HR counter before connecting is not imported.

## Set it up

1. **HR app.** Deploy it, which applies its migration. In Master Control, open **Accounting ERP → Connect**:
   - Name: `Accounting ERP`.
   - Webhook address: `https://<erp domain>/api/integrations/hr/webhook`.
   - Copy the **Key** and the **Webhook secret**. They are shown once.
2. **ERP.**
   1. Apply the migration (`supabase/INCREMENTAL-…-0095.sql`).
   2. Set these Railway variables and redeploy:

      ```
      HR_API_BASE_URL=https://<hr backend domain>
      HR_API_KEY=<Key>
      HR_WEBHOOK_SECRET=<Webhook secret>
      HR_DEALER_CODE=<dealers.code, e.g. DHARANI>
      HR_SYNC_SECRET=<any 16+ character secret, optional>
      # attendance, from the same app:
      ATTENDANCE_API_BASE_URL=https://<hr backend domain>/api/integration/v1
      ATTENDANCE_API_KEY=<Key>
      ATTENDANCE_API_AUTH=bearer
      ATTENDANCE_API_PATH=/attendance
      ```
3. **HR app.** Press **Send a test**. The ERP answers `PONG`.
4. **ERP.** In **HR → HR App Link**, press **Sync now**, then:
   - map each HR branch to a branch here;
   - map each claim type to its ledger, e.g. Petrol Expenses → an expense ledger, Sales Incentives → a commission expense, Salary → 2710 Salaries Payable.

   Claims waiting for either mapping are booked the moment it is saved.
5. **Optional.** Add a Railway cron that calls `POST https://<erp domain>/api/integrations/hr/sync` with the header `x-sync-secret: <HR_SYNC_SECRET>` every 15 minutes. Without it, the ERP syncs whenever someone presses **Sync now**, and webhooks carry approvals as they happen.
6. **Test.** Put a ₹1 test claim through the whole flow: approve it in HR, see it under **Claims to Pay**, pay it, then check it shows PAID in HR.

## Security

- **The HR key.** It is a long-lived token scoped to one HR workspace. It opens only `/api/integration/v1` (the HR app's `requireIntegration`), and it is checked against its connection row on every call. **New key** or **Switch off** in the HR app stops it at once.
- **Webhooks.** They are HMAC-SHA256 signed over `timestamp.body` and accepted within 5 minutes. Each event is recorded once in `hr_inbound_events`, so replays are harmless.
- **Inbound SQL functions.** `hr_receive_event`, `hr_sync_batch` and the rest are executable by the service role only. The functions people call check `hr.claims.pay` / `hr.mapping.manage` / `hr.payroll.run`.
- **Receipts.** Photos and PDFs are streamed through the ERP server (`/api/integrations/hr/claims/:id/file`), so the key never reaches a browser.

## When something is off

| What you see | What it means |
|---|---|
| **HR App Link → Last problem** | The last error from a sync or a webhook. |
| **Claims to Pay → Paid → "not told yet"** | The HR app did not acknowledge the payment. Every later sync retries it, up to 20 times. |
| **HR app → Accounting ERP → Updates sent** | Events the ERP did not accept. These are retried for several hours; **Retry waiting** sends them now. |
