/**
 * Database types — GENERATED FILE. Do not edit.
 *
 * Regenerate with:  node scripts/generate-types.mjs
 * (or, once Supabase is current: supabase gen types typescript --project-id <ref>)
 *
 * `numeric` columns are typed as `string`. That is deliberate and matches what
 * PostgREST sends: a JS number cannot represent them exactly, and money must be
 * exact. Parse them with `fromDb()` in src/lib/money.ts.
 */

export type Json = string | number | boolean | null | { [key: string]: Json } | Json[];

type Insertable<T, R extends keyof T> = Partial<Omit<T, R>> & Pick<T, R>;

type AccessoryVehicleMappingsRow = {
  id: string;
  dealer_id: string;
  model_id: string;
  variant_id: string | null;
  item_id: string;
  quantity: string;
  is_default: boolean;
  priority: number;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
};

type AccessoryVehicleMappingsRowInsert = Insertable<AccessoryVehicleMappingsRow, 'dealer_id' | 'model_id' | 'item_id'>;

type AccountingPeriodsRow = {
  id: string;
  dealer_id: string;
  name: string;
  start_date: string;
  end_date: string;
  status: 'OPEN' | 'CLOSED' | 'LOCKED';
  closed_at: string | null;
  closed_by: string | null;
  created_at: string;
  updated_at: string;
};

type AccountingPeriodsRowInsert = Insertable<AccountingPeriodsRow, 'dealer_id' | 'name' | 'start_date' | 'end_date'>;

type AccountingRulesRow = {
  id: string;
  dealer_id: string;
  module: 'SALES' | 'BOOKING' | 'SERVICE' | 'ACCESSORY' | 'SPARE' | 'FINANCE' | 'TRADE_ADVANCE' | 'CASH' | 'BANK' | 'EXPENSE' | 'INVENTORY' | 'MANUAL' | 'OPENING';
  event: string;
  component: string;
  side: 'DEBIT' | 'CREDIT';
  account_id: string;
  branch_id: string | null;
  priority: number;
  description: string | null;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type AccountingRulesRowInsert = Insertable<AccountingRulesRow, 'dealer_id' | 'module' | 'event' | 'component' | 'side' | 'account_id'>;

type AttendanceDaysRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  employee_id: string;
  attendance_date: string;
  status: 'PRESENT' | 'HALF_DAY';
  first_in: string | null;
  last_out: string | null;
  worked_minutes: number;
  late_minutes: number;
  early_exit_minutes: number;
  overtime_minutes: number;
  leave_type_id: string | null;
  source: 'SYNC' | 'MANUAL';
  external_ref: string | null;
  sync_run_id: string | null;
  remarks: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type AttendanceDaysRowInsert = Insertable<AttendanceDaysRow, 'dealer_id' | 'branch_id' | 'employee_id' | 'attendance_date' | 'status'>;

type AttendanceSyncRunsRow = {
  id: string;
  dealer_id: string;
  from_date: string;
  to_date: string;
  status: 'RUNNING' | 'SUCCESS' | 'PARTIAL' | 'FAILED';
  fetched_count: number;
  matched_count: number;
  unmatched_count: number;
  written_count: number;
  skipped_manual_count: number;
  last_error: string | null;
  error_detail: Json | null;
  started_at: string;
  finished_at: string | null;
  triggered_by: string | null;
};

type AttendanceSyncRunsRowInsert = Insertable<AttendanceSyncRunsRow, 'dealer_id' | 'from_date' | 'to_date'>;

type AuditLogsRow = {
  id: number;
  dealer_id: string | null;
  branch_id: string | null;
  user_id: string | null;
  user_email: string | null;
  action: 'CREATE' | 'UPDATE' | 'DELETE' | 'APPROVE' | 'REJECT' | 'POST' | 'CANCEL' | 'REVERSE' | 'LOGIN' | 'LOGIN_FAILED' | 'LOGOUT' | 'BRANCH_SWITCH' | 'PERMISSION_CHANGE' | 'ROLE_CHANGE' | 'STOCK_ADJUST' | 'PRICE_CHANGE' | 'GST_CHANGE' | 'DAY_CLOSE' | 'RECONCILE' | 'IMPORT' | 'EXPORT';
  entity_type: string;
  entity_id: string | null;
  old_data: Json | null;
  new_data: Json | null;
  changed_fields: string[] | null;
  reason: string | null;
  ip_address: string | null;
  user_agent: string | null;
  session_id: string | null;
  request_id: string | null;
  created_at: string;
};

type AuditLogsRowInsert = Insertable<AuditLogsRow, 'action' | 'entity_type'>;

type BankAccountsRow = {
  id: string;
  dealer_id: string;
  branch_id: string | null;
  name: string;
  bank_name: string;
  account_number: string;
  ifsc: string | null;
  account_type: 'CURRENT' | 'SAVINGS' | 'OD' | 'CC';
  ledger_account_id: string;
  opening_balance: string;
  current_balance: string;
  status: 'ACTIVE' | 'INACTIVE' | 'CLOSED';
  created_at: string;
  updated_at: string;
};

type BankAccountsRowInsert = Insertable<BankAccountsRow, 'dealer_id' | 'name' | 'bank_name' | 'account_number' | 'ledger_account_id'>;

type BankReconciliationsRow = {
  id: string;
  dealer_id: string;
  bank_account_id: string;
  reconciliation_number: string;
  from_date: string;
  to_date: string;
  statement_closing_balance: string;
  book_closing_balance: string;
  difference: string | null;
  matched_count: number;
  unmatched_count: number;
  status: 'DRAFT' | 'COMPLETED' | 'CANCELLED';
  completed_at: string | null;
  completed_by: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
};

type BankReconciliationsRowInsert = Insertable<BankReconciliationsRow, 'dealer_id' | 'bank_account_id' | 'reconciliation_number' | 'from_date' | 'to_date'>;

type BankStatementLinesRow = {
  id: number;
  dealer_id: string;
  bank_account_id: string;
  import_batch: string;
  statement_date: string;
  value_date: string | null;
  narration: string;
  reference: string | null;
  utr: string | null;
  upi_id: string | null;
  cheque_number: string | null;
  debit: string;
  credit: string;
  running_balance: string | null;
  match_status: 'UNMATCHED' | 'MATCHED' | 'PARTIAL' | 'IGNORED';
  matched_transaction_id: number | null;
  reconciliation_id: string | null;
  raw_row: Json | null;
  created_at: string;
  created_by: string | null;
};

type BankStatementLinesRowInsert = Insertable<BankStatementLinesRow, 'dealer_id' | 'bank_account_id' | 'import_batch' | 'statement_date' | 'narration'>;

type BankTransactionsRow = {
  id: number;
  dealer_id: string;
  bank_account_id: string;
  transaction_date: string;
  direction: 'RECEIPT' | 'PAYMENT';
  amount: string;
  balance_after: string;
  particular: string;
  reference_type: string | null;
  reference_id: string | null;
  reference_number: string | null;
  utr: string | null;
  instrument_number: string | null;
  journal_entry_id: string | null;
  reconciled: boolean;
  reconciliation_id: string | null;
  status: 'ACTIVE' | 'REVERSED';
  created_at: string;
  created_by: string | null;
  supplier_id: string | null;
  customer_id: string | null;
};

type BankTransactionsRowInsert = Insertable<BankTransactionsRow, 'dealer_id' | 'bank_account_id' | 'direction' | 'amount' | 'particular'>;

type BookingPaymentsRow = {
  id: string;
  dealer_id: string;
  booking_id: string;
  receipt_number: string;
  payment_date: string;
  amount: string;
  payment_mode: 'CASH' | 'CARD' | 'UPI' | 'NEFT' | 'RTGS' | 'IMPS' | 'CHEQUE' | 'DD' | 'FINANCE';
  reference: string | null;
  journal_entry_id: string | null;
  status: 'RECEIVED' | 'REVERSED';
  created_at: string;
  created_by: string | null;
};

type BookingPaymentsRowInsert = Insertable<BookingPaymentsRow, 'dealer_id' | 'booking_id' | 'receipt_number' | 'amount' | 'payment_mode'>;

type BookingsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  booking_number: string;
  booking_date: string;
  customer_id: string;
  model_id: string;
  variant_id: string | null;
  colour_id: string | null;
  vehicle_id: string | null;
  expected_delivery: string | null;
  booking_amount: string;
  received_amount: string;
  sales_executive_id: string | null;
  status: 'OPEN' | 'CONVERTED' | 'CANCELLED' | 'EXPIRED';
  converted_sale_id: string | null;
  cancelled_reason: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type BookingsRowInsert = Insertable<BookingsRow, 'dealer_id' | 'branch_id' | 'booking_number' | 'customer_id' | 'model_id'>;

type BranchesRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  gstin: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  pincode: string | null;
  phone: string | null;
  email: string | null;
  is_head_office: boolean;
  status: 'ACTIVE' | 'SUSPENDED' | 'CLOSED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type BranchesRowInsert = Insertable<BranchesRow, 'dealer_id' | 'code' | 'name'>;

type CashAccountsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  name: string;
  ledger_account_id: string;
  opening_balance: string;
  current_balance: string;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
};

type CashAccountsRowInsert = Insertable<CashAccountsRow, 'dealer_id' | 'branch_id' | 'name' | 'ledger_account_id'>;

type CashDayClosingsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  cash_account_id: string;
  business_date: string;
  status: 'OPEN' | 'IN_PROGRESS' | 'COUNTED' | 'CLOSED';
  opening_balance: string;
  total_receipts: string;
  total_payments: string;
  expected_closing: string | null;
  physical_cash: string | null;
  difference: string | null;
  denominations: Json | null;
  counted_at: string | null;
  counted_by: string | null;
  closed_at: string | null;
  closed_by: string | null;
  reopened_at: string | null;
  reopened_by: string | null;
  reopen_reason: string | null;
  remarks: string | null;
  created_at: string;
  updated_at: string;
};

type CashDayClosingsRowInsert = Insertable<CashDayClosingsRow, 'dealer_id' | 'branch_id' | 'cash_account_id' | 'business_date'>;

type CashTransactionsRow = {
  id: number;
  dealer_id: string;
  branch_id: string;
  cash_account_id: string;
  business_date: string;
  transaction_time: string;
  direction: 'RECEIPT' | 'PAYMENT';
  amount: string;
  balance_after: string;
  particular: string;
  reference_type: string | null;
  reference_id: string | null;
  reference_number: string | null;
  customer_id: string | null;
  journal_entry_id: string | null;
  status: 'ACTIVE' | 'REVERSED';
  created_at: string;
  created_by: string | null;
  supplier_id: string | null;
};

type CashTransactionsRowInsert = Insertable<CashTransactionsRow, 'dealer_id' | 'branch_id' | 'cash_account_id' | 'direction' | 'amount' | 'particular'>;

type ChartOfAccountsRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  account_type: 'ASSET' | 'EXPENSE';
  account_subtype: string | null;
  parent_id: string | null;
  normal_balance: 'DEBIT' | 'CREDIT';
  is_group: boolean;
  is_system: boolean;
  is_branch_scoped: boolean;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type ChartOfAccountsRowInsert = Insertable<ChartOfAccountsRow, 'dealer_id' | 'code' | 'name' | 'account_type' | 'normal_balance'>;

type CustomerVehiclesRow = {
  id: string;
  dealer_id: string;
  customer_id: string;
  vehicle_id: string | null;
  model_id: string | null;
  variant_id: string | null;
  registration_no: string | null;
  chassis_no: string | null;
  engine_no: string | null;
  colour: string | null;
  purchase_date: string | null;
  status: 'ACTIVE' | 'SOLD' | 'SCRAPPED';
  created_at: string;
  updated_at: string;
};

type CustomerVehiclesRowInsert = Insertable<CustomerVehiclesRow, 'dealer_id' | 'customer_id'>;

type CustomersRow = {
  id: string;
  dealer_id: string;
  customer_code: string;
  name: string;
  customer_type: 'INDIVIDUAL' | 'BUSINESS';
  mobile: string;
  alternate_mobile: string | null;
  email: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  pincode: string | null;
  gstin: string | null;
  pan: string | null;
  origin_branch_id: string | null;
  notes: string | null;
  status: 'ACTIVE' | 'INACTIVE' | 'BLOCKED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type CustomersRowInsert = Insertable<CustomersRow, 'dealer_id' | 'name' | 'mobile'>;

type DealersRow = {
  id: string;
  code: string;
  legal_name: string;
  trade_name: string | null;
  gstin: string | null;
  pan: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  pincode: string | null;
  phone: string | null;
  email: string | null;
  fy_start_month: number;
  status: 'ACTIVE' | 'SUSPENDED' | 'CLOSED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type DealersRowInsert = Insertable<DealersRow, 'code' | 'legal_name'>;

type DeliveriesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  sale_id: string;
  vehicle_id: string;
  delivery_number: string;
  delivered_at: string;
  delivered_by: string | null;
  received_by_name: string | null;
  odometer: string | null;
  remarks: string | null;
  created_at: string;
};

type DeliveriesRowInsert = Insertable<DeliveriesRow, 'dealer_id' | 'branch_id' | 'sale_id' | 'vehicle_id' | 'delivery_number'>;

type DocumentSequencesRow = {
  id: string;
  dealer_id: string;
  branch_id: string | null;
  doc_type: string;
  financial_year: string;
  prefix: string;
  padding: number;
  last_number: number;
  created_at: string;
  updated_at: string;
};

type DocumentSequencesRowInsert = Insertable<DocumentSequencesRow, 'dealer_id' | 'doc_type' | 'financial_year' | 'prefix'>;

type EinvoicesRow = {
  id: string;
  dealer_id: string;
  document_type: 'SALE' | 'SERVICE_INVOICE';
  document_id: string;
  document_number: string;
  document_date: string;
  status: 'PENDING' | 'GENERATED' | 'FAILED' | 'CANCELLED';
  irn: string | null;
  ack_number: string | null;
  ack_date: string | null;
  signed_qr_code: string | null;
  signed_invoice: string | null;
  request_payload: Json | null;
  response_payload: Json | null;
  error_code: string | null;
  error_message: string | null;
  attempt_count: number;
  last_attempt_at: string | null;
  cancelled_at: string | null;
  cancel_reason: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
};

type EinvoicesRowInsert = Insertable<EinvoicesRow, 'dealer_id' | 'document_type' | 'document_id' | 'document_number' | 'document_date'>;

type EmployeeDocumentsRow = {
  id: string;
  dealer_id: string;
  employee_id: string;
  document_type: 'AADHAAR' | 'PAN' | 'PASSPORT' | 'DRIVING_LICENCE' | 'OFFER_LETTER' | 'CONTRACT' | 'EDUCATION' | 'EXPERIENCE' | 'BANK_PROOF' | 'ADDRESS_PROOF' | 'PHOTO' | 'OTHER';
  document_name: string;
  document_no: string | null;
  issued_on: string | null;
  expires_on: string | null;
  storage_path: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type EmployeeDocumentsRowInsert = Insertable<EmployeeDocumentsRow, 'dealer_id' | 'employee_id' | 'document_type' | 'document_name'>;

type EmployeeLeaveBalancesRow = {
  id: string;
  dealer_id: string;
  employee_id: string;
  leave_type_id: string;
  financial_year: string;
  opening: string;
  accrued: string;
  used: string;
  encashed: string;
  balance: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type EmployeeLeaveBalancesRowInsert = Insertable<EmployeeLeaveBalancesRow, 'dealer_id' | 'employee_id' | 'leave_type_id' | 'financial_year'>;

type EmployeeSalaryStructuresRow = {
  id: string;
  dealer_id: string;
  employee_id: string;
  effective_from: string;
  effective_to: string | null;
  basic: string;
  hra: string;
  conveyance: string;
  medical_allowance: string;
  special_allowance: string;
  other_allowance: string;
  pf_employee: string;
  esi_employee: string;
  professional_tax: string;
  other_deduction: string;
  pf_employer: string;
  esi_employer: string;
  gross_earnings: string | null;
  total_deductions: string | null;
  net_payable: string | null;
  cost_to_company: string | null;
  revision_note: string | null;
  created_at: string;
  created_by: string | null;
};

type EmployeeSalaryStructuresRowInsert = Insertable<EmployeeSalaryStructuresRow, 'dealer_id' | 'employee_id' | 'effective_from'>;

type EmployeesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  employee_code: string;
  name: string;
  department: string | null;
  designation: string | null;
  mobile: string | null;
  email: string | null;
  joining_date: string | null;
  leaving_date: string | null;
  user_id: string | null;
  status: 'ACTIVE' | 'ON_LEAVE' | 'RESIGNED' | 'TERMINATED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
  date_of_birth: string | null;
  gender: 'MALE' | 'FEMALE' | 'OTHER' | null;
  blood_group: string | null;
  personal_email: string | null;
  emergency_contact: string | null;
  emergency_mobile: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  pincode: string | null;
  pan: string | null;
  aadhaar_last4: string | null;
  uan: string | null;
  esi_number: string | null;
  bank_account_name: string | null;
  bank_account_no: string | null;
  bank_ifsc: string | null;
  employment_type: 'PERMANENT' | 'PROBATION' | 'CONTRACT' | 'INTERN' | 'CONSULTANT';
  probation_until: string | null;
  confirmed_on: string | null;
  exit_type: 'RESIGNATION' | 'TERMINATION' | 'RETIREMENT' | 'END_OF_CONTRACT' | 'ABSCONDED' | null;
  exit_reason: string | null;
  reports_to: string | null;
  shift_id: string | null;
  external_ref: string | null;
};

type EmployeesRowInsert = Insertable<EmployeesRow, 'dealer_id' | 'branch_id' | 'employee_code' | 'name'>;

type EwayBillsRow = {
  id: string;
  dealer_id: string;
  document_type: 'SALE' | 'SERVICE_INVOICE' | 'TRANSFER';
  document_id: string;
  document_number: string;
  status: 'PENDING' | 'GENERATED' | 'FAILED' | 'CANCELLED' | 'EXPIRED';
  eway_bill_number: string | null;
  generated_at: string | null;
  valid_until: string | null;
  transport_mode: 'ROAD' | 'RAIL' | 'AIR' | 'SHIP' | null;
  vehicle_number: string | null;
  transporter_id: string | null;
  transporter_name: string | null;
  distance_km: number | null;
  request_payload: Json | null;
  response_payload: Json | null;
  error_message: string | null;
  attempt_count: number;
  created_at: string;
  updated_at: string;
  created_by: string | null;
};

type EwayBillsRowInsert = Insertable<EwayBillsRow, 'dealer_id' | 'document_type' | 'document_id' | 'document_number'>;

type FinanceApplicationsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  application_number: string;
  application_date: string;
  customer_id: string;
  finance_company_id: string;
  vehicle_id: string | null;
  sale_id: string | null;
  loan_amount: string;
  down_payment: string;
  tenure_months: number | null;
  interest_rate: string | null;
  approval_status: 'PENDING' | 'APPROVED' | 'REJECTED' | 'CANCELLED';
  approved_amount: string | null;
  approved_at: string | null;
  disbursement_status: 'PENDING' | 'PARTIAL' | 'DISBURSED' | 'CANCELLED';
  disbursed_amount: string;
  disbursed_at: string | null;
  dd_number: string | null;
  bank_reference: string | null;
  commission_amount: string;
  pending_amount: string | null;
  rejection_reason: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type FinanceApplicationsRowInsert = Insertable<FinanceApplicationsRow, 'dealer_id' | 'branch_id' | 'application_number' | 'customer_id' | 'finance_company_id'>;

type FinanceCompaniesRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  contact_person: string | null;
  mobile: string | null;
  email: string | null;
  gstin: string | null;
  ledger_account_id: string | null;
  commission_percent: string;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type FinanceCompaniesRowInsert = Insertable<FinanceCompaniesRow, 'dealer_id' | 'code' | 'name'>;

type FinanceSettlementsRow = {
  id: string;
  dealer_id: string;
  finance_company_id: string;
  settlement_number: string;
  settlement_date: string;
  from_date: string | null;
  to_date: string | null;
  gross_amount: string;
  commission_amount: string;
  deductions: string;
  net_amount: string | null;
  status: 'DRAFT' | 'POSTED' | 'CANCELLED';
  journal_entry_id: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  branch_id: string;
};

type FinanceSettlementsRowInsert = Insertable<FinanceSettlementsRow, 'dealer_id' | 'finance_company_id' | 'settlement_number' | 'branch_id'>;

type FinanceTransactionsRow = {
  id: number;
  dealer_id: string;
  branch_id: string;
  finance_company_id: string;
  transaction_date: string;
  transaction_type: 'ADVANCE_RECEIVED' | 'VEHICLE_ADJUSTMENT' | 'SETTLEMENT' | 'REFUND' | 'COMMISSION' | 'MANUAL_ADJUSTMENT' | 'DISBURSEMENT';
  debit: string;
  credit: string;
  balance_after: string;
  reference_type: string | null;
  reference_id: string | null;
  reference_number: string | null;
  narration: string | null;
  application_id: string | null;
  sale_id: string | null;
  journal_entry_id: string | null;
  created_at: string;
  created_by: string | null;
};

type FinanceTransactionsRowInsert = Insertable<FinanceTransactionsRow, 'dealer_id' | 'branch_id' | 'finance_company_id' | 'transaction_type'>;

type HsnCodesRow = {
  id: string;
  dealer_id: string;
  code: string;
  code_type: 'HSN' | 'SAC';
  description: string;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type HsnCodesRowInsert = Insertable<HsnCodesRow, 'dealer_id' | 'code' | 'description'>;

type InventoryItemsRow = {
  id: string;
  dealer_id: string;
  item_code: string;
  name: string;
  item_type: 'ACCESSORY' | 'SPARE';
  brand: string | null;
  category: string | null;
  uom: 'NOS' | 'SET' | 'PAIR' | 'LTR' | 'KG' | 'MTR' | 'BOX';
  hsn_code_id: string | null;
  tax_code: string | null;
  standard_cost: string;
  selling_price: string;
  reorder_level: string;
  is_fitment: boolean;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type InventoryItemsRowInsert = Insertable<InventoryItemsRow, 'dealer_id' | 'item_code' | 'name' | 'item_type'>;

type InventoryStockRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  item_id: string;
  source: 'LOCAL' | 'COMPANY';
  quantity: string;
  average_cost: string;
  stock_value: string | null;
  updated_at: string;
};

type InventoryStockRowInsert = Insertable<InventoryStockRow, 'dealer_id' | 'branch_id' | 'item_id' | 'source'>;

type InventoryTransactionsRow = {
  id: number;
  dealer_id: string;
  branch_id: string;
  item_id: string;
  source: 'LOCAL' | 'COMPANY';
  transaction_type: 'OPENING' | 'PURCHASE' | 'SALE' | 'CONSUMPTION' | 'RETURN' | 'TRANSFER_OUT' | 'TRANSFER_IN' | 'ADJUSTMENT' | 'REVERSAL';
  quantity: string;
  unit_cost: string;
  value: string | null;
  balance_after: string;
  reference_type: string | null;
  reference_id: string | null;
  reference_number: string | null;
  narration: string | null;
  reason: string | null;
  created_at: string;
  created_by: string | null;
};

type InventoryTransactionsRowInsert = Insertable<InventoryTransactionsRow, 'dealer_id' | 'branch_id' | 'item_id' | 'source' | 'transaction_type' | 'quantity'>;

type JobCardsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  job_card_number: string;
  job_date: string;
  customer_id: string;
  customer_vehicle_id: string | null;
  registration_no: string | null;
  odometer: string | null;
  service_type: 'FREE' | 'PAID' | 'WARRANTY' | 'ACCIDENT' | 'RUNNING_REPAIR';
  complaint: string | null;
  diagnosis: string | null;
  service_advisor_id: string | null;
  technician_id: string | null;
  promised_at: string | null;
  status: 'OPEN' | 'IN_PROGRESS' | 'READY' | 'INVOICED' | 'CLOSED' | 'CANCELLED';
  closed_at: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type JobCardsRowInsert = Insertable<JobCardsRow, 'dealer_id' | 'branch_id' | 'job_card_number' | 'customer_id'>;

type JournalEntriesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  entry_number: string;
  entry_date: string;
  period_id: string | null;
  source_module: 'SALES' | 'BOOKING' | 'SERVICE' | 'ACCESSORY' | 'SPARE' | 'FINANCE' | 'TRADE_ADVANCE' | 'CASH' | 'BANK' | 'EXPENSE' | 'INVENTORY' | 'MANUAL' | 'OPENING';
  source_document_type: string | null;
  source_document_id: string | null;
  narration: string | null;
  status: 'DRAFT' | 'POSTED' | 'REVERSED';
  total_debit: string;
  total_credit: string;
  reversal_of_id: string | null;
  reversed_by_id: string | null;
  reversal_reason: string | null;
  idempotency_key: string | null;
  posted_at: string | null;
  posted_by: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type JournalEntriesRowInsert = Insertable<JournalEntriesRow, 'dealer_id' | 'branch_id' | 'entry_number' | 'entry_date' | 'source_module'>;

type JournalEntryLinesRow = {
  id: string;
  journal_entry_id: string;
  dealer_id: string;
  line_number: number;
  account_id: string;
  branch_id: string | null;
  debit: string;
  credit: string;
  narration: string | null;
  party_type: 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY' | 'EMPLOYEE' | null;
  party_id: string | null;
  created_at: string;
};

type JournalEntryLinesRowInsert = Insertable<JournalEntryLinesRow, 'journal_entry_id' | 'dealer_id' | 'line_number' | 'account_id'>;

type LeaveTypesRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  annual_quota: string;
  is_paid: boolean;
  carry_forward: boolean;
  max_carry_forward: string;
  counts_as_worked: boolean;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type LeaveTypesRowInsert = Insertable<LeaveTypesRow, 'dealer_id' | 'code' | 'name'>;

type PartyAllocationsRow = {
  id: string;
  dealer_id: string;
  party_type: 'CUSTOMER' | 'SUPPLIER' | 'FINANCE_COMPANY' | 'EMPLOYEE';
  party_id: string;
  debit_line_id: string;
  credit_line_id: string;
  amount: string;
  note: string | null;
  created_at: string;
  created_by: string | null;
};

type PartyAllocationsRowInsert = Insertable<PartyAllocationsRow, 'dealer_id' | 'party_type' | 'party_id' | 'debit_line_id' | 'credit_line_id' | 'amount'>;

type PermissionsRow = {
  code: string;
  module: string;
  description: string;
  is_sensitive: boolean;
  created_at: string;
};

type PermissionsRowInsert = Insertable<PermissionsRow, 'code' | 'module' | 'description'>;

type PurchaseBillLinesRow = {
  id: string;
  purchase_bill_id: string;
  dealer_id: string;
  line_number: number;
  line_type: 'VEHICLE' | 'ACCESSORY' | 'SPARE';
  vehicle_id: string | null;
  item_id: string | null;
  source: 'LOCAL' | 'COMPANY' | null;
  description: string;
  quantity: string;
  unit_rate: string;
  taxable_value: string;
  cgst_rate: string;
  sgst_rate: string;
  igst_rate: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  total_amount: string;
  created_at: string;
};

type PurchaseBillLinesRowInsert = Insertable<PurchaseBillLinesRow, 'purchase_bill_id' | 'dealer_id' | 'line_number' | 'line_type' | 'description' | 'quantity' | 'unit_rate' | 'taxable_value' | 'total_amount'>;

type PurchaseBillsRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  bill_number: string;
  supplier_bill_number: string;
  supplier_id: string;
  bill_date: string;
  due_date: string | null;
  status: 'DRAFT' | 'POSTED' | 'CANCELLED';
  taxable_value: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  total_amount: string;
  notes: string | null;
  journal_entry_id: string | null;
  posted_at: string | null;
  posted_by: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type PurchaseBillsRowInsert = Insertable<PurchaseBillsRow, 'dealer_id' | 'branch_id' | 'supplier_bill_number' | 'supplier_id'>;

type RolePermissionsRow = {
  role_id: string;
  permission_code: string;
  granted_at: string;
  granted_by: string | null;
};

type RolePermissionsRowInsert = Insertable<RolePermissionsRow, 'role_id' | 'permission_code'>;

type RolesRow = {
  id: string;
  dealer_id: string | null;
  code: string;
  name: string;
  description: string | null;
  is_system: boolean;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type RolesRowInsert = Insertable<RolesRow, 'code' | 'name'>;

type SaleLinesRow = {
  id: string;
  dealer_id: string;
  sale_id: string;
  line_number: number;
  line_type: 'VEHICLE' | 'INSURANCE' | 'REGISTRATION' | 'ACCESSORY' | 'FITTING' | 'FORWARDING' | 'OTHER_CHARGE' | 'DISCOUNT' | 'SPARE' | 'LABOUR';
  description: string;
  item_id: string | null;
  hsn_code: string | null;
  quantity: string;
  unit_rate: string;
  discount: string;
  taxable_value: string;
  tax_code: string | null;
  cgst_rate: string;
  sgst_rate: string;
  igst_rate: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  cess_amount: string;
  total_amount: string;
  unit_cost: string;
  cost_amount: string;
  stock_source: 'LOCAL' | 'COMPANY' | null;
  created_at: string;
};

type SaleLinesRowInsert = Insertable<SaleLinesRow, 'dealer_id' | 'sale_id' | 'line_number' | 'line_type' | 'description'>;

type SalePaymentsRow = {
  id: string;
  dealer_id: string;
  sale_id: string;
  receipt_number: string;
  payment_date: string;
  amount: string;
  payment_mode: 'CASH' | 'CARD' | 'UPI' | 'NEFT' | 'RTGS' | 'IMPS' | 'CHEQUE' | 'DD' | 'FINANCE' | 'BOOKING_ADVANCE';
  reference: string | null;
  finance_company_id: string | null;
  journal_entry_id: string | null;
  status: 'RECEIVED' | 'REVERSED';
  created_at: string;
  created_by: string | null;
};

type SalePaymentsRowInsert = Insertable<SalePaymentsRow, 'dealer_id' | 'sale_id' | 'receipt_number' | 'amount' | 'payment_mode'>;

type SalesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  invoice_number: string;
  invoice_date: string;
  customer_id: string;
  vehicle_id: string;
  booking_id: string | null;
  price_version_id: string | null;
  sales_executive_id: string | null;
  taxable_value: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  cess_amount: string;
  discount_amount: string;
  total_amount: string;
  total_cost: string;
  paid_amount: string;
  finance_amount: string;
  balance_amount: string | null;
  status: 'DRAFT' | 'SUBMITTED' | 'ACCOUNTS_VERIFICATION' | 'APPROVED' | 'POSTED' | 'DELIVERED' | 'CANCELLED' | 'RETURNED';
  submitted_at: string | null;
  submitted_by: string | null;
  verified_at: string | null;
  verified_by: string | null;
  approved_at: string | null;
  approved_by: string | null;
  posted_at: string | null;
  posted_by: string | null;
  delivered_at: string | null;
  delivered_by: string | null;
  cancelled_at: string | null;
  cancelled_by: string | null;
  cancelled_reason: string | null;
  rejection_reason: string | null;
  journal_entry_id: string | null;
  idempotency_key: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type SalesRowInsert = Insertable<SalesRow, 'dealer_id' | 'branch_id' | 'invoice_number' | 'customer_id' | 'vehicle_id'>;

type ServiceInvoicesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  invoice_number: string;
  invoice_date: string;
  invoice_type: 'SERVICE' | 'COUNTER';
  job_card_id: string | null;
  customer_id: string | null;
  taxable_value: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  discount_amount: string;
  total_amount: string;
  total_cost: string;
  paid_amount: string;
  status: 'DRAFT' | 'POSTED' | 'CANCELLED' | 'RETURNED';
  posted_at: string | null;
  journal_entry_id: string | null;
  idempotency_key: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type ServiceInvoicesRowInsert = Insertable<ServiceInvoicesRow, 'dealer_id' | 'branch_id' | 'invoice_number'>;

type ServiceLinesRow = {
  id: string;
  dealer_id: string;
  invoice_id: string;
  line_number: number;
  line_type: 'LABOUR' | 'SPARE' | 'ACCESSORY' | 'OTHER_CHARGE' | 'DISCOUNT';
  description: string;
  item_id: string | null;
  hsn_code: string | null;
  quantity: string;
  unit_rate: string;
  discount: string;
  taxable_value: string;
  tax_code: string | null;
  cgst_rate: string;
  sgst_rate: string;
  igst_rate: string;
  cgst_amount: string;
  sgst_amount: string;
  igst_amount: string;
  total_amount: string;
  unit_cost: string;
  cost_amount: string;
  stock_source: 'LOCAL' | 'COMPANY' | null;
  created_at: string;
};

type ServiceLinesRowInsert = Insertable<ServiceLinesRow, 'dealer_id' | 'invoice_id' | 'line_number' | 'line_type' | 'description'>;

type ServicePaymentsRow = {
  id: string;
  dealer_id: string;
  invoice_id: string;
  receipt_number: string;
  payment_date: string;
  amount: string;
  payment_mode: 'CASH' | 'CARD' | 'UPI' | 'NEFT' | 'RTGS' | 'IMPS' | 'CHEQUE';
  reference: string | null;
  journal_entry_id: string | null;
  status: 'RECEIVED' | 'REVERSED';
  created_at: string;
  created_by: string | null;
};

type ServicePaymentsRowInsert = Insertable<ServicePaymentsRow, 'dealer_id' | 'invoice_id' | 'receipt_number' | 'amount' | 'payment_mode'>;

type ShiftsRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  starts_at: string;
  ends_at: string;
  break_minutes: number;
  grace_minutes: number;
  week_off_days: unknown[];
  half_day_minutes: number;
  full_day_minutes: number;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type ShiftsRowInsert = Insertable<ShiftsRow, 'dealer_id' | 'code' | 'name' | 'starts_at' | 'ends_at'>;

type SuppliersRow = {
  id: string;
  dealer_id: string;
  supplier_code: string;
  name: string;
  supplier_type: 'GOODS' | 'SERVICE' | 'OEM';
  contact_person: string | null;
  mobile: string | null;
  alternate_mobile: string | null;
  email: string | null;
  address_line1: string | null;
  address_line2: string | null;
  city: string | null;
  state: string | null;
  state_code: string | null;
  pincode: string | null;
  gstin: string | null;
  pan: string | null;
  credit_days: number;
  notes: string | null;
  status: 'ACTIVE' | 'INACTIVE' | 'BLOCKED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type SuppliersRowInsert = Insertable<SuppliersRow, 'dealer_id' | 'supplier_code' | 'name'>;

type SystemSettingsRow = {
  id: string;
  dealer_id: string | null;
  key: string;
  value: Json;
  value_type: 'json' | 'string' | 'number' | 'boolean';
  description: string | null;
  is_public: boolean;
  created_at: string;
  updated_at: string;
  updated_by: string | null;
};

type SystemSettingsRowInsert = Insertable<SystemSettingsRow, 'key' | 'value'>;

type TaxCodesRow = {
  id: string;
  dealer_id: string;
  code: string;
  name: string;
  hsn_code_id: string | null;
  cgst_rate: string;
  sgst_rate: string;
  igst_rate: string;
  cess_rate: string;
  total_rate: string | null;
  effective_from: string;
  effective_to: string | null;
  status: 'ACTIVE' | 'INACTIVE';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type TaxCodesRowInsert = Insertable<TaxCodesRow, 'dealer_id' | 'code' | 'name' | 'effective_from'>;

type UserBranchesRow = {
  user_id: string;
  branch_id: string;
  dealer_id: string;
  granted_at: string;
  granted_by: string | null;
};

type UserBranchesRowInsert = Insertable<UserBranchesRow, 'user_id' | 'branch_id' | 'dealer_id'>;

type UserProfilesRow = {
  id: string;
  dealer_id: string | null;
  full_name: string;
  email: string;
  mobile: string | null;
  is_platform_admin: boolean;
  has_all_branch_access: boolean;
  default_branch_id: string | null;
  status: 'ACTIVE' | 'SUSPENDED' | 'DISABLED';
  last_login_at: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type UserProfilesRowInsert = Insertable<UserProfilesRow, 'id' | 'full_name' | 'email'>;

type UserRolesRow = {
  user_id: string;
  role_id: string;
  assigned_at: string;
  assigned_by: string | null;
};

type UserRolesRowInsert = Insertable<UserRolesRow, 'user_id' | 'role_id'>;

type VehicleColoursRow = {
  id: string;
  dealer_id: string;
  variant_id: string;
  name: string;
  colour_code: string | null;
  hex: string | null;
  status: 'ACTIVE' | 'DISCONTINUED';
  created_at: string;
  updated_at: string;
};

type VehicleColoursRowInsert = Insertable<VehicleColoursRow, 'dealer_id' | 'variant_id' | 'name'>;

type VehicleModelsRow = {
  id: string;
  dealer_id: string;
  brand: string;
  name: string;
  model_code: string;
  category: 'SCOOTER' | 'MOTORCYCLE' | 'MOPED' | 'ELECTRIC' | 'THREE_WHEELER';
  fuel_type: 'PETROL' | 'ELECTRIC' | 'CNG' | 'HYBRID';
  hsn_code_id: string | null;
  tax_code: string | null;
  status: 'ACTIVE' | 'DISCONTINUED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type VehicleModelsRowInsert = Insertable<VehicleModelsRow, 'dealer_id' | 'brand' | 'name' | 'model_code'>;

type VehiclePriceVersionsRow = {
  id: string;
  dealer_id: string;
  model_id: string;
  variant_id: string | null;
  branch_id: string | null;
  version_number: number;
  ex_showroom: string;
  insurance: string;
  registration: string;
  mandatory_accessories: string;
  forwarding_charge: string;
  other_charges: string;
  purchase_cost: string;
  max_discount: string;
  tax_code: string | null;
  total_on_road: string | null;
  effective_from: string;
  effective_to: string | null;
  status: 'DRAFT' | 'SUBMITTED' | 'APPROVED' | 'ACTIVE' | 'SUPERSEDED' | 'REJECTED';
  submitted_at: string | null;
  submitted_by: string | null;
  approved_at: string | null;
  approved_by: string | null;
  notes: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type VehiclePriceVersionsRowInsert = Insertable<VehiclePriceVersionsRow, 'dealer_id' | 'model_id' | 'version_number' | 'effective_from'>;

type VehicleStockTransactionsRow = {
  id: number;
  dealer_id: string;
  branch_id: string;
  vehicle_id: string;
  transaction_type: 'OPENING' | 'PURCHASE' | 'SALE' | 'RETURN' | 'TRANSFER_OUT' | 'TRANSFER_IN' | 'ADJUSTMENT' | 'REVERSAL' | 'STATUS_CHANGE';
  reference_type: string | null;
  reference_id: string | null;
  from_status: string | null;
  to_status: string | null;
  from_branch_id: string | null;
  to_branch_id: string | null;
  value: string;
  narration: string | null;
  created_at: string;
  created_by: string | null;
};

type VehicleStockTransactionsRowInsert = Insertable<VehicleStockTransactionsRow, 'dealer_id' | 'branch_id' | 'vehicle_id' | 'transaction_type'>;

type VehicleTransfersRow = {
  id: string;
  dealer_id: string;
  transfer_number: string;
  vehicle_id: string;
  from_branch_id: string;
  to_branch_id: string;
  status: 'IN_TRANSIT' | 'RECEIVED' | 'CANCELLED';
  dispatched_at: string;
  dispatched_by: string | null;
  received_at: string | null;
  received_by: string | null;
  remarks: string | null;
  created_at: string;
  updated_at: string;
};

type VehicleTransfersRowInsert = Insertable<VehicleTransfersRow, 'dealer_id' | 'transfer_number' | 'vehicle_id' | 'from_branch_id' | 'to_branch_id'>;

type VehicleVariantsRow = {
  id: string;
  dealer_id: string;
  model_id: string;
  name: string;
  variant_code: string;
  engine_cc: string | null;
  transmission: string | null;
  brake_type: string | null;
  start_type: string | null;
  status: 'ACTIVE' | 'DISCONTINUED';
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type VehicleVariantsRowInsert = Insertable<VehicleVariantsRow, 'dealer_id' | 'model_id' | 'name' | 'variant_code'>;

type VehiclesRow = {
  id: string;
  dealer_id: string;
  branch_id: string;
  model_id: string;
  variant_id: string | null;
  colour_id: string | null;
  chassis_no: string;
  engine_no: string;
  key_no: string | null;
  model_year: number | null;
  purchase_invoice: string | null;
  purchase_date: string | null;
  purchase_cost: string;
  stock_date: string;
  status: 'IN_STOCK' | 'BOOKED' | 'SOLD_PENDING_DELIVERY' | 'DELIVERED' | 'TRANSFERRED' | 'CANCELLED';
  sale_id: string | null;
  registration_no: string | null;
  created_at: string;
  updated_at: string;
  created_by: string | null;
  updated_by: string | null;
};

type VehiclesRowInsert = Insertable<VehiclesRow, 'dealer_id' | 'branch_id' | 'model_id' | 'chassis_no' | 'engine_no'>;

export interface Database {
  public: {
    Tables: {
      accessory_vehicle_mappings: {
        Row: AccessoryVehicleMappingsRow;
        Insert: AccessoryVehicleMappingsRowInsert;
        Update: Partial<AccessoryVehicleMappingsRow>;
        Relationships: [
          {
            foreignKeyName: 'accessory_vehicle_mappings_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'avm_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'avm_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'avm_variant_tenant_fkey';
            columns: ['variant_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_variants';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      accounting_periods: {
        Row: AccountingPeriodsRow;
        Insert: AccountingPeriodsRowInsert;
        Update: Partial<AccountingPeriodsRow>;
        Relationships: [
          {
            foreignKeyName: 'accounting_periods_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      accounting_rules: {
        Row: AccountingRulesRow;
        Insert: AccountingRulesRowInsert;
        Update: Partial<AccountingRulesRow>;
        Relationships: [
          {
            foreignKeyName: 'accounting_rules_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'ar_account_tenant_fkey';
            columns: ['account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ar_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      attendance_days: {
        Row: AttendanceDaysRow;
        Insert: AttendanceDaysRowInsert;
        Update: Partial<AttendanceDaysRow>;
        Relationships: [
          {
            foreignKeyName: 'ad_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ad_employee_tenant_fkey';
            columns: ['employee_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ad_leave_type_tenant_fkey';
            columns: ['leave_type_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'leave_types';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ad_sync_run_tenant_fkey';
            columns: ['sync_run_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'attendance_sync_runs';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'attendance_days_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      attendance_sync_runs: {
        Row: AttendanceSyncRunsRow;
        Insert: AttendanceSyncRunsRowInsert;
        Update: Partial<AttendanceSyncRunsRow>;
        Relationships: [
          {
            foreignKeyName: 'attendance_sync_runs_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      audit_logs: {
        Row: AuditLogsRow;
        Insert: AuditLogsRowInsert;
        Update: Partial<AuditLogsRow>;
        Relationships: [];
      };
      bank_accounts: {
        Row: BankAccountsRow;
        Insert: BankAccountsRowInsert;
        Update: Partial<BankAccountsRow>;
        Relationships: [
          {
            foreignKeyName: 'bank_accounts_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bank_accounts_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'bank_accounts_ledger_tenant_fkey';
            columns: ['ledger_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      bank_reconciliations: {
        Row: BankReconciliationsRow;
        Insert: BankReconciliationsRowInsert;
        Update: Partial<BankReconciliationsRow>;
        Relationships: [
          {
            foreignKeyName: 'br_account_tenant_fkey';
            columns: ['bank_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'bank_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      bank_statement_lines: {
        Row: BankStatementLinesRow;
        Insert: BankStatementLinesRowInsert;
        Update: Partial<BankStatementLinesRow>;
        Relationships: [
          {
            foreignKeyName: 'bsl_account_tenant_fkey';
            columns: ['bank_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'bank_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bsl_matched_transaction_fkey';
            columns: ['matched_transaction_id'];
            isOneToOne: false;
            referencedRelation: 'bank_transactions';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'bsl_reconciliation_fkey';
            columns: ['reconciliation_id'];
            isOneToOne: false;
            referencedRelation: 'bank_reconciliations';
            referencedColumns: ['id'];
          },
        ];
      };
      bank_transactions: {
        Row: BankTransactionsRow;
        Insert: BankTransactionsRowInsert;
        Update: Partial<BankTransactionsRow>;
        Relationships: [
          {
            foreignKeyName: 'bank_transactions_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bank_transactions_supplier_tenant_fkey';
            columns: ['supplier_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bt_account_tenant_fkey';
            columns: ['bank_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'bank_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bt_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bt_reconciliation_fkey';
            columns: ['reconciliation_id'];
            isOneToOne: false;
            referencedRelation: 'bank_reconciliations';
            referencedColumns: ['id'];
          },
        ];
      };
      booking_payments: {
        Row: BookingPaymentsRow;
        Insert: BookingPaymentsRowInsert;
        Update: Partial<BookingPaymentsRow>;
        Relationships: [
          {
            foreignKeyName: 'booking_payments_booking_tenant_fkey';
            columns: ['booking_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'bookings';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'booking_payments_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      bookings: {
        Row: BookingsRow;
        Insert: BookingsRowInsert;
        Update: Partial<BookingsRow>;
        Relationships: [
          {
            foreignKeyName: 'bookings_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bookings_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bookings_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'bookings_employee_tenant_fkey';
            columns: ['sales_executive_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bookings_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bookings_variant_tenant_fkey';
            columns: ['variant_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_variants';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'bookings_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      branches: {
        Row: BranchesRow;
        Insert: BranchesRowInsert;
        Update: Partial<BranchesRow>;
        Relationships: [
          {
            foreignKeyName: 'branches_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      cash_accounts: {
        Row: CashAccountsRow;
        Insert: CashAccountsRowInsert;
        Update: Partial<CashAccountsRow>;
        Relationships: [
          {
            foreignKeyName: 'cash_accounts_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'cash_accounts_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'cash_accounts_ledger_tenant_fkey';
            columns: ['ledger_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      cash_day_closings: {
        Row: CashDayClosingsRow;
        Insert: CashDayClosingsRowInsert;
        Update: Partial<CashDayClosingsRow>;
        Relationships: [
          {
            foreignKeyName: 'cdc_account_tenant_fkey';
            columns: ['cash_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'cdc_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      cash_transactions: {
        Row: CashTransactionsRow;
        Insert: CashTransactionsRowInsert;
        Update: Partial<CashTransactionsRow>;
        Relationships: [
          {
            foreignKeyName: 'cash_transactions_supplier_tenant_fkey';
            columns: ['supplier_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ct_account_tenant_fkey';
            columns: ['cash_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'cash_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ct_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ct_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ct_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      chart_of_accounts: {
        Row: ChartOfAccountsRow;
        Insert: ChartOfAccountsRowInsert;
        Update: Partial<ChartOfAccountsRow>;
        Relationships: [
          {
            foreignKeyName: 'chart_of_accounts_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'coa_parent_tenant_fkey';
            columns: ['parent_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      customer_vehicles: {
        Row: CustomerVehiclesRow;
        Insert: CustomerVehiclesRowInsert;
        Update: Partial<CustomerVehiclesRow>;
        Relationships: [
          {
            foreignKeyName: 'customer_vehicles_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'cv_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'cv_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'cv_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      customers: {
        Row: CustomersRow;
        Insert: CustomersRowInsert;
        Update: Partial<CustomersRow>;
        Relationships: [
          {
            foreignKeyName: 'customers_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'customers_origin_branch_tenant_fkey';
            columns: ['origin_branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      dealers: {
        Row: DealersRow;
        Insert: DealersRowInsert;
        Update: Partial<DealersRow>;
        Relationships: [];
      };
      deliveries: {
        Row: DeliveriesRow;
        Insert: DeliveriesRowInsert;
        Update: Partial<DeliveriesRow>;
        Relationships: [
          {
            foreignKeyName: 'deliveries_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'deliveries_sale_tenant_fkey';
            columns: ['sale_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'deliveries_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      document_sequences: {
        Row: DocumentSequencesRow;
        Insert: DocumentSequencesRowInsert;
        Update: Partial<DocumentSequencesRow>;
        Relationships: [
          {
            foreignKeyName: 'document_sequences_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'document_sequences_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      einvoices: {
        Row: EinvoicesRow;
        Insert: EinvoicesRowInsert;
        Update: Partial<EinvoicesRow>;
        Relationships: [
          {
            foreignKeyName: 'einvoices_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      employee_documents: {
        Row: EmployeeDocumentsRow;
        Insert: EmployeeDocumentsRowInsert;
        Update: Partial<EmployeeDocumentsRow>;
        Relationships: [
          {
            foreignKeyName: 'ed_employee_tenant_fkey';
            columns: ['employee_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'employee_documents_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      employee_leave_balances: {
        Row: EmployeeLeaveBalancesRow;
        Insert: EmployeeLeaveBalancesRowInsert;
        Update: Partial<EmployeeLeaveBalancesRow>;
        Relationships: [
          {
            foreignKeyName: 'elb_employee_tenant_fkey';
            columns: ['employee_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'elb_type_tenant_fkey';
            columns: ['leave_type_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'leave_types';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'employee_leave_balances_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      employee_salary_structures: {
        Row: EmployeeSalaryStructuresRow;
        Insert: EmployeeSalaryStructuresRowInsert;
        Update: Partial<EmployeeSalaryStructuresRow>;
        Relationships: [
          {
            foreignKeyName: 'employee_salary_structures_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'ess_employee_tenant_fkey';
            columns: ['employee_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      employees: {
        Row: EmployeesRow;
        Insert: EmployeesRowInsert;
        Update: Partial<EmployeesRow>;
        Relationships: [
          {
            foreignKeyName: 'employees_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'employees_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'employees_reports_to_tenant_fkey';
            columns: ['reports_to', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'employees_shift_tenant_fkey';
            columns: ['shift_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'shifts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'employees_user_id_fkey';
            columns: ['user_id'];
            isOneToOne: false;
            referencedRelation: 'user_profiles';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'employees_user_tenant_fkey';
            columns: ['user_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'user_profiles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      eway_bills: {
        Row: EwayBillsRow;
        Insert: EwayBillsRowInsert;
        Update: Partial<EwayBillsRow>;
        Relationships: [
          {
            foreignKeyName: 'eway_bills_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      finance_applications: {
        Row: FinanceApplicationsRow;
        Insert: FinanceApplicationsRowInsert;
        Update: Partial<FinanceApplicationsRow>;
        Relationships: [
          {
            foreignKeyName: 'fa_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fa_company_tenant_fkey';
            columns: ['finance_company_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'finance_companies';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fa_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fa_sale_tenant_fkey';
            columns: ['sale_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fa_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'finance_applications_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      finance_companies: {
        Row: FinanceCompaniesRow;
        Insert: FinanceCompaniesRowInsert;
        Update: Partial<FinanceCompaniesRow>;
        Relationships: [
          {
            foreignKeyName: 'finance_companies_account_tenant_fkey';
            columns: ['ledger_account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'finance_companies_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      finance_settlements: {
        Row: FinanceSettlementsRow;
        Insert: FinanceSettlementsRowInsert;
        Update: Partial<FinanceSettlementsRow>;
        Relationships: [
          {
            foreignKeyName: 'fs_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fs_company_tenant_fkey';
            columns: ['finance_company_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'finance_companies';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'fs_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      finance_transactions: {
        Row: FinanceTransactionsRow;
        Insert: FinanceTransactionsRowInsert;
        Update: Partial<FinanceTransactionsRow>;
        Relationships: [
          {
            foreignKeyName: 'ft_application_tenant_fkey';
            columns: ['application_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'finance_applications';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ft_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ft_company_tenant_fkey';
            columns: ['finance_company_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'finance_companies';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ft_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'ft_sale_tenant_fkey';
            columns: ['sale_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      hsn_codes: {
        Row: HsnCodesRow;
        Insert: HsnCodesRowInsert;
        Update: Partial<HsnCodesRow>;
        Relationships: [
          {
            foreignKeyName: 'hsn_codes_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      inventory_items: {
        Row: InventoryItemsRow;
        Insert: InventoryItemsRowInsert;
        Update: Partial<InventoryItemsRow>;
        Relationships: [
          {
            foreignKeyName: 'inventory_items_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'inventory_items_hsn_tenant_fkey';
            columns: ['hsn_code_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'hsn_codes';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      inventory_stock: {
        Row: InventoryStockRow;
        Insert: InventoryStockRowInsert;
        Update: Partial<InventoryStockRow>;
        Relationships: [
          {
            foreignKeyName: 'inventory_stock_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'inventory_stock_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'inventory_stock_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      inventory_transactions: {
        Row: InventoryTransactionsRow;
        Insert: InventoryTransactionsRowInsert;
        Update: Partial<InventoryTransactionsRow>;
        Relationships: [
          {
            foreignKeyName: 'inventory_transactions_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'inventory_transactions_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      job_cards: {
        Row: JobCardsRow;
        Insert: JobCardsRowInsert;
        Update: Partial<JobCardsRow>;
        Relationships: [
          {
            foreignKeyName: 'jc_advisor_tenant_fkey';
            columns: ['service_advisor_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jc_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jc_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jc_technician_tenant_fkey';
            columns: ['technician_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jc_vehicle_tenant_fkey';
            columns: ['customer_vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customer_vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'job_cards_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      journal_entries: {
        Row: JournalEntriesRow;
        Insert: JournalEntriesRowInsert;
        Update: Partial<JournalEntriesRow>;
        Relationships: [
          {
            foreignKeyName: 'journal_entries_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'journal_entries_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'journal_entries_period_tenant_fkey';
            columns: ['period_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'accounting_periods';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'journal_entries_reversal_of_fkey';
            columns: ['reversal_of_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'journal_entries_reversed_by_fkey';
            columns: ['reversed_by_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      journal_entry_lines: {
        Row: JournalEntryLinesRow;
        Insert: JournalEntryLinesRowInsert;
        Update: Partial<JournalEntryLinesRow>;
        Relationships: [
          {
            foreignKeyName: 'jel_account_tenant_fkey';
            columns: ['account_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'chart_of_accounts';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jel_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'jel_entry_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      leave_types: {
        Row: LeaveTypesRow;
        Insert: LeaveTypesRowInsert;
        Update: Partial<LeaveTypesRow>;
        Relationships: [
          {
            foreignKeyName: 'leave_types_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      party_allocations: {
        Row: PartyAllocationsRow;
        Insert: PartyAllocationsRowInsert;
        Update: Partial<PartyAllocationsRow>;
        Relationships: [
          {
            foreignKeyName: 'party_allocations_credit_tenant_fkey';
            columns: ['credit_line_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entry_lines';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'party_allocations_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'party_allocations_debit_tenant_fkey';
            columns: ['debit_line_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entry_lines';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      permissions: {
        Row: PermissionsRow;
        Insert: PermissionsRowInsert;
        Update: Partial<PermissionsRow>;
        Relationships: [];
      };
      purchase_bill_lines: {
        Row: PurchaseBillLinesRow;
        Insert: PurchaseBillLinesRowInsert;
        Update: Partial<PurchaseBillLinesRow>;
        Relationships: [
          {
            foreignKeyName: 'pbl_bill_tenant_fkey';
            columns: ['purchase_bill_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'purchase_bills';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'pbl_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'pbl_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      purchase_bills: {
        Row: PurchaseBillsRow;
        Insert: PurchaseBillsRowInsert;
        Update: Partial<PurchaseBillsRow>;
        Relationships: [
          {
            foreignKeyName: 'purchase_bills_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'purchase_bills_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'purchase_bills_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'purchase_bills_supplier_tenant_fkey';
            columns: ['supplier_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'suppliers';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      role_permissions: {
        Row: RolePermissionsRow;
        Insert: RolePermissionsRowInsert;
        Update: Partial<RolePermissionsRow>;
        Relationships: [
          {
            foreignKeyName: 'role_permissions_permission_code_fkey';
            columns: ['permission_code'];
            isOneToOne: false;
            referencedRelation: 'permissions';
            referencedColumns: ['code'];
          },
          {
            foreignKeyName: 'role_permissions_role_id_fkey';
            columns: ['role_id'];
            isOneToOne: false;
            referencedRelation: 'roles';
            referencedColumns: ['id'];
          },
        ];
      };
      roles: {
        Row: RolesRow;
        Insert: RolesRowInsert;
        Update: Partial<RolesRow>;
        Relationships: [
          {
            foreignKeyName: 'roles_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      sale_lines: {
        Row: SaleLinesRow;
        Insert: SaleLinesRowInsert;
        Update: Partial<SaleLinesRow>;
        Relationships: [
          {
            foreignKeyName: 'sale_lines_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sale_lines_sale_tenant_fkey';
            columns: ['sale_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      sale_payments: {
        Row: SalePaymentsRow;
        Insert: SalePaymentsRowInsert;
        Update: Partial<SalePaymentsRow>;
        Relationships: [
          {
            foreignKeyName: 'sale_payments_finance_tenant_fkey';
            columns: ['finance_company_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'finance_companies';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sale_payments_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sale_payments_sale_tenant_fkey';
            columns: ['sale_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'sales';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      sales: {
        Row: SalesRow;
        Insert: SalesRowInsert;
        Update: Partial<SalesRow>;
        Relationships: [
          {
            foreignKeyName: 'sales_booking_tenant_fkey';
            columns: ['booking_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'bookings';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'sales_employee_tenant_fkey';
            columns: ['sales_executive_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'employees';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_price_version_tenant_fkey';
            columns: ['price_version_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_price_versions';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sales_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      service_invoices: {
        Row: ServiceInvoicesRow;
        Insert: ServiceInvoicesRowInsert;
        Update: Partial<ServiceInvoicesRow>;
        Relationships: [
          {
            foreignKeyName: 'service_invoices_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'si_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'si_customer_tenant_fkey';
            columns: ['customer_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'customers';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'si_job_card_tenant_fkey';
            columns: ['job_card_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'job_cards';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'si_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      service_lines: {
        Row: ServiceLinesRow;
        Insert: ServiceLinesRowInsert;
        Update: Partial<ServiceLinesRow>;
        Relationships: [
          {
            foreignKeyName: 'sl_invoice_tenant_fkey';
            columns: ['invoice_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'service_invoices';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sl_item_tenant_fkey';
            columns: ['item_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'inventory_items';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      service_payments: {
        Row: ServicePaymentsRow;
        Insert: ServicePaymentsRowInsert;
        Update: Partial<ServicePaymentsRow>;
        Relationships: [
          {
            foreignKeyName: 'sp_invoice_tenant_fkey';
            columns: ['invoice_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'service_invoices';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'sp_journal_tenant_fkey';
            columns: ['journal_entry_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'journal_entries';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      shifts: {
        Row: ShiftsRow;
        Insert: ShiftsRowInsert;
        Update: Partial<ShiftsRow>;
        Relationships: [
          {
            foreignKeyName: 'shifts_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      suppliers: {
        Row: SuppliersRow;
        Insert: SuppliersRowInsert;
        Update: Partial<SuppliersRow>;
        Relationships: [
          {
            foreignKeyName: 'suppliers_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      system_settings: {
        Row: SystemSettingsRow;
        Insert: SystemSettingsRowInsert;
        Update: Partial<SystemSettingsRow>;
        Relationships: [
          {
            foreignKeyName: 'system_settings_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
        ];
      };
      tax_codes: {
        Row: TaxCodesRow;
        Insert: TaxCodesRowInsert;
        Update: Partial<TaxCodesRow>;
        Relationships: [
          {
            foreignKeyName: 'tax_codes_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'tax_codes_hsn_tenant_fkey';
            columns: ['hsn_code_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'hsn_codes';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      user_branches: {
        Row: UserBranchesRow;
        Insert: UserBranchesRowInsert;
        Update: Partial<UserBranchesRow>;
        Relationships: [
          {
            foreignKeyName: 'user_branches_branch_id_fkey';
            columns: ['branch_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'user_branches_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'user_branches_user_id_fkey';
            columns: ['user_id'];
            isOneToOne: false;
            referencedRelation: 'user_profiles';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'user_branches_user_tenant_fkey';
            columns: ['user_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'user_profiles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      user_profiles: {
        Row: UserProfilesRow;
        Insert: UserProfilesRowInsert;
        Update: Partial<UserProfilesRow>;
        Relationships: [
          {
            foreignKeyName: 'user_profiles_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'user_profiles_default_branch_id_fkey';
            columns: ['default_branch_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'user_profiles_default_branch_tenant_fkey';
            columns: ['default_branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'user_profiles_id_fkey';
            columns: ['id'];
            isOneToOne: false;
            referencedRelation: 'auth.users';
            referencedColumns: ['id'];
          },
        ];
      };
      user_roles: {
        Row: UserRolesRow;
        Insert: UserRolesRowInsert;
        Update: Partial<UserRolesRow>;
        Relationships: [
          {
            foreignKeyName: 'user_roles_role_id_fkey';
            columns: ['role_id'];
            isOneToOne: false;
            referencedRelation: 'roles';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'user_roles_user_id_fkey';
            columns: ['user_id'];
            isOneToOne: false;
            referencedRelation: 'user_profiles';
            referencedColumns: ['id'];
          },
        ];
      };
      vehicle_colours: {
        Row: VehicleColoursRow;
        Insert: VehicleColoursRowInsert;
        Update: Partial<VehicleColoursRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicle_colours_variant_tenant_fkey';
            columns: ['variant_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_variants';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicle_models: {
        Row: VehicleModelsRow;
        Insert: VehicleModelsRowInsert;
        Update: Partial<VehicleModelsRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicle_models_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'vehicle_models_hsn_tenant_fkey';
            columns: ['hsn_code_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'hsn_codes';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicle_price_versions: {
        Row: VehiclePriceVersionsRow;
        Insert: VehiclePriceVersionsRowInsert;
        Update: Partial<VehiclePriceVersionsRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicle_price_versions_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'vpv_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vpv_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vpv_variant_tenant_fkey';
            columns: ['variant_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_variants';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicle_stock_transactions: {
        Row: VehicleStockTransactionsRow;
        Insert: VehicleStockTransactionsRowInsert;
        Update: Partial<VehicleStockTransactionsRow>;
        Relationships: [
          {
            foreignKeyName: 'vst_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vst_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicle_transfers: {
        Row: VehicleTransfersRow;
        Insert: VehicleTransfersRowInsert;
        Update: Partial<VehicleTransfersRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicle_transfers_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'vehicle_transfers_from_tenant_fkey';
            columns: ['from_branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vehicle_transfers_to_tenant_fkey';
            columns: ['to_branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vehicle_transfers_vehicle_tenant_fkey';
            columns: ['vehicle_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicles';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicle_variants: {
        Row: VehicleVariantsRow;
        Insert: VehicleVariantsRowInsert;
        Update: Partial<VehicleVariantsRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicle_variants_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
      vehicles: {
        Row: VehiclesRow;
        Insert: VehiclesRowInsert;
        Update: Partial<VehiclesRow>;
        Relationships: [
          {
            foreignKeyName: 'vehicles_branch_tenant_fkey';
            columns: ['branch_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'branches';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vehicles_colour_tenant_fkey';
            columns: ['colour_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_colours';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vehicles_dealer_id_fkey';
            columns: ['dealer_id'];
            isOneToOne: false;
            referencedRelation: 'dealers';
            referencedColumns: ['id'];
          },
          {
            foreignKeyName: 'vehicles_model_tenant_fkey';
            columns: ['model_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_models';
            referencedColumns: ['id', 'dealer_id'];
          },
          {
            foreignKeyName: 'vehicles_variant_tenant_fkey';
            columns: ['variant_id', 'dealer_id'];
            isOneToOne: false;
            referencedRelation: 'vehicle_variants';
            referencedColumns: ['id', 'dealer_id'];
          },
        ];
      };
    };
    Views: Record<string, never>;
    Functions: {
      account_balances: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { account_id: string; account_code: string; account_name: string; account_type: string; normal_balance: string; period_debit: string; period_credit: string; closing_debit: string; closing_credit: string; period_movement: string; closing_balance: string }[];
      };
      add_service_line: {
        Args: { p_invoice_id: string; p_line_type: string; p_description: string; p_quantity: number; p_unit_rate: number; p_item_id?: string | null; p_tax_code?: string | null; p_discount?: number | null };
        Returns: string;
      };
      adjust_inventory_stock: {
        Args: { p_item_id: string; p_branch_id: string; p_source: string; p_quantity: number; p_reason: string };
        Returns: undefined;
      };
      allocate_party_payment: {
        Args: { p_credit_line_id: string; p_allocations?: Json | null; p_note?: string | null };
        Returns: { allocated: string; unapplied: string; bills: number }[];
      };
      allocate_stock: {
        Args: { p_item_id: string; p_branch_id: string; p_quantity: number };
        Returns: { source: string; quantity: string; unit_cost: string; available: string }[];
      };
      attendance_summary: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { employee_id: string; employee_code: string; employee_name: string; branch_name: string; present_days: string; leave_days: string; paid_leave_days: string; absent_days: number; week_off_days: number; holiday_days: number; payable_days: string; late_count: number; overtime_minutes: number; recorded_days: number }[];
      };
      balance_sheet: {
        Args: { p_as_on?: string | null; p_branch_id?: string | null };
        Returns: { section: string; account_code: string; account_name: string; amount: string }[];
      };
      bank_book: {
        Args: { p_bank_account_id: string; p_from_date?: string | null; p_to_date?: string | null };
        Returns: { id: number; transaction_date: string; particular: string; reference_number: string; utr: string; receipt: string; payment: string; running_balance: string; reconciled: boolean; journal_entry_id: string }[];
      };
      branch_performance: {
        Args: { p_from: string; p_to: string };
        Returns: { branch_id: string; branch_code: string; branch_name: string; vehicle_units: number; vehicle_revenue: string; vehicle_cost: string; vehicle_margin: string; service_jobs: number; service_revenue: string; service_cost: string; bookings_open: number; booking_advances: string; cash_in_hand: string; receivables: string }[];
      };
      cancel_purchase_bill: {
        Args: { p_bill_id: string; p_reason: string };
        Returns: string;
      };
      cash_book: {
        Args: { p_branch_id: string; p_date?: string | null };
        Returns: { transaction_time: string; reference_number: string; particular: string; receipt: string; payment: string; running_balance: string; journal_entry_id: string }[];
      };
      close_cash_day: {
        Args: { p_branch_id: string; p_date: string; p_physical_cash: number; p_denominations?: Json | null; p_remarks?: string | null };
        Returns: { expected: string; counted: string; difference: string }[];
      };
      complete_bank_reconciliation: {
        Args: { p_bank_account_id: string; p_from_date: string; p_to_date: string; p_statement_closing: number; p_notes?: string | null };
        Returns: { reconciliation_id: string; number: string; difference: string; matched: number; unmatched: number }[];
      };
      consolidated_mis: {
        Args: { p_from: string; p_to: string };
        Returns: { metric: string; category: string; value: string; count_value: number }[];
      };
      consume_fitting_stock: {
        Args: { p_sale_id: string; p_item_id: string; p_quantity: number; p_unit_rate: number };
        Returns: undefined;
      };
      create_booking_with_advance: {
        Args: { p_customer_id: string; p_model_id: string; p_branch_id: string; p_booking_amount: number; p_advance_amount: number; p_payment_mode: string; p_variant_id?: string | null; p_vehicle_id?: string | null; p_expected_delivery?: string | null; p_sales_executive_id?: string | null; p_reference?: string | null; p_notes?: string | null };
        Returns: { booking_id: string; booking_number: string; receipt_number: string; journal_entry_id: string }[];
      };
      create_counter_invoice: {
        Args: { p_branch_id: string; p_customer_id?: string | null; p_invoice_date?: string | null };
        Returns: { invoice_id: string; invoice_number: string }[];
      };
      create_finance_application: {
        Args: { p_branch_id: string; p_customer_id: string; p_finance_company_id: string; p_loan_amount: number; p_down_payment?: number | null; p_vehicle_id?: string | null; p_sale_id?: string | null; p_tenure_months?: number | null; p_interest_rate?: number | null; p_commission_amount?: number | null; p_application_date?: string | null; p_notes?: string | null };
        Returns: { application_id: string; application_number: string }[];
      };
      create_finance_settlement: {
        Args: { p_finance_company_id: string; p_branch_id: string; p_from: string; p_to: string; p_gross: number; p_commission?: number | null; p_deductions?: number | null; p_settlement_date?: string | null; p_notes?: string | null };
        Returns: { settlement_id: string; settlement_number: string }[];
      };
      create_job_card: {
        Args: { p_branch_id: string; p_customer_id: string; p_service_type?: string | null; p_registration_no?: string | null; p_odometer?: number | null; p_complaint?: string | null; p_customer_vehicle_id?: string | null; p_service_advisor_id?: string | null; p_technician_id?: string | null; p_promised_at?: string | null; p_job_date?: string | null };
        Returns: { job_card_id: string; job_card_number: string }[];
      };
      create_service_invoice: {
        Args: { p_job_card_id: string; p_invoice_date?: string | null };
        Returns: { invoice_id: string; invoice_number: string }[];
      };
      create_vehicle_sale_draft: {
        Args: { p_customer_id: string; p_vehicle_id: string; p_invoice_date?: string | null; p_booking_id?: string | null; p_sales_executive_id?: string | null; p_discount?: number | null; p_notes?: string | null };
        Returns: { sale_id: string; invoice_number: string; total_amount: string }[];
      };
      customer_ledger: {
        Args: { p_customer_id: string; p_from: string; p_to: string };
        Returns: { entry_date: string; entry_number: string; narration: string; debit: string; credit: string; running_balance: string }[];
      };
      customer_ledger_opening: {
        Args: { p_customer_id: string; p_as_on: string };
        Returns: unknown;
      };
      customer_service_summary: {
        Args: { p_customer_id?: string | null; p_branch_id?: string | null };
        Returns: { customer_id: string; customer_code: string; customer_name: string; mobile: string; vehicle_count: number; visit_count: number; first_visit: string; last_visit: string; days_since_last: number; lifetime_value: string; open_jobs: number }[];
      };
      decide_finance_application: {
        Args: { p_application_id: string; p_decision: string; p_approved_amount?: number | null; p_rejection_reason?: string | null };
        Returns: undefined;
      };
      decide_price_version: {
        Args: { p_version_id: string; p_action: string; p_reason?: string | null };
        Returns: string;
      };
      deliver_vehicle: {
        Args: { p_sale_id: string; p_received_by?: string | null; p_odometer?: number | null; p_remarks?: string | null };
        Returns: string;
      };
      disburse_finance_application: {
        Args: { p_application_id: string; p_amount: number; p_bank_account_id: string; p_dd_number?: string | null; p_bank_reference?: string | null; p_date?: string | null };
        Returns: { journal_entry_id: string; bank_transaction_id: number; finance_transaction_id: number }[];
      };
      dispatch_vehicle_transfer: {
        Args: { p_vehicle_id: string; p_to_branch_id: string; p_remarks?: string | null };
        Returns: { transfer_id: string; transfer_number: string }[];
      };
      einvoice_payload: {
        Args: { p_einvoice_id: string };
        Returns: unknown;
      };
      einvoice_queue: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { einvoice_id: string; document_type: string; document_id: string; document_number: string; document_date: string; customer_name: string; gstin: string; invoice_value: string; status: string; irn: string; ack_number: string; error_message: string; attempt_count: number }[];
      };
      employee_salary_on: {
        Args: { p_employee_id: string; p_as_on?: string | null };
        Returns: string;
      };
      ensure_cash_day: {
        Args: { p_branch_id: string; p_date?: string | null };
        Returns: string;
      };
      finance_company_ledger: {
        Args: { p_company_id: string; p_from: string; p_to: string };
        Returns: { transaction_date: string; transaction_type: string; reference_number: string; narration: string; debit: string; credit: string; balance_after: string }[];
      };
      finance_summary: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { finance_company_id: string; finance_company_name: string; application_count: number; approved_count: number; rejected_count: number; pending_count: number; loan_amount: string; disbursed_amount: string; pending_disbursement: string; commission_amount: string }[];
      };
      finish_attendance_sync: {
        Args: { p_run_id: string; p_status: string; p_error?: string | null; p_detail?: Json | null };
        Returns: undefined;
      };
      gst_document_register: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null; p_section?: string | null };
        Returns: { document_type: string; document_id: string; document_number: string; document_date: string; customer_name: string; gstin: string; place_of_supply: string; section: string; taxable_value: string; cgst_amount: string; sgst_amount: string; igst_amount: string; invoice_value: string; einvoice_status: string; irn: string }[];
      };
      gst_summary: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { hsn_code: string; description: string; taxable_value: string; cgst_amount: string; sgst_amount: string; igst_amount: string; total_tax: string; document_count: number }[];
      };
      gstr1_summary: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { section: string; document_count: number; taxable_value: string; cgst_amount: string; sgst_amount: string; igst_amount: string; total_tax: string; invoice_value: string }[];
      };
      ignore_bank_line: {
        Args: { p_statement_line_id: number };
        Returns: undefined;
      };
      import_attendance_days: {
        Args: { p_run_id: string; p_rows: Json };
        Returns: { matched: number; unmatched: number; written: number; skipped_manual: number }[];
      };
      import_bank_statement: {
        Args: { p_bank_account_id: string; p_rows: Json };
        Returns: { import_batch: string; imported: number; skipped: number }[];
      };
      inventory_movement_report: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { item_id: string; item_code: string; item_name: string; item_type: string; received_qty: string; issued_qty: string; received_value: string; issued_value: string; closing_qty: string; closing_value: string }[];
      };
      inventory_stock_report: {
        Args: { p_branch_id?: string | null; p_item_type?: string | null };
        Returns: { item_id: string; item_code: string; item_name: string; item_type: string; branch_name: string; local_qty: string; company_qty: string; total_qty: string; local_value: string; company_value: string; total_value: string }[];
      };
      margin_report: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { stream: string; document_count: number; revenue: string; cost: string; margin: string; margin_percent: string }[];
      };
      match_bank_line: {
        Args: { p_statement_line_id: number; p_transaction_id: number };
        Returns: undefined;
      };
      next_document_number: {
        Args: { p_dealer_id: string; p_branch_id: string; p_doc_type: string; p_financial_year: string };
        Returns: string;
      };
      party_ledger: {
        Args: { p_party_type: string; p_party_id: string; p_from: string; p_to: string };
        Returns: { entry_date: string; entry_number: string; narration: string; debit: string; credit: string; running_balance: string }[];
      };
      party_ledger_opening: {
        Args: { p_party_type: string; p_party_id: string; p_as_on: string };
        Returns: unknown;
      };
      party_open_items: {
        Args: { p_party_type: string; p_party_id: string; p_include_settled?: boolean | null };
        Returns: { line_id: string; entry_id: string; entry_date: string; entry_number: string; document_type: string; document_ref: string; account_code: string; account_name: string; particulars: string; side: string; amount: string; allocated: string; outstanding: string; age_days: number }[];
      };
      post_finance_settlement: {
        Args: { p_settlement_id: string; p_bank_account_id: string };
        Returns: string;
      };
      post_purchase_bill: {
        Args: { p_bill_id: string; p_idempotency_key?: string | null };
        Returns: string;
      };
      post_service_invoice: {
        Args: { p_invoice_id: string; p_idempotency_key?: string | null };
        Returns: string;
      };
      post_vehicle_sale: {
        Args: { p_sale_id: string; p_idempotency_key?: string | null };
        Returns: string;
      };
      profit_and_loss: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null };
        Returns: { section: string; account_code: string; account_name: string; amount: string }[];
      };
      queue_einvoice: {
        Args: { p_document_type: string; p_document_id: string };
        Returns: string;
      };
      queue_eway_bill: {
        Args: { p_document_type: string; p_document_id: string; p_transport_mode?: string | null; p_vehicle_number?: string | null; p_distance_km?: number | null; p_transporter_id?: string | null; p_transporter_name?: string | null };
        Returns: string;
      };
      receive_vehicle_transfer: {
        Args: { p_transfer_id: string; p_remarks?: string | null };
        Returns: undefined;
      };
      record_bank_transaction: {
        Args: { p_bank_account_id: string; p_direction: string; p_amount: number; p_particular: string; p_account_id: string; p_date?: string | null; p_reference?: string | null; p_utr?: string | null; p_instrument?: string | null; p_customer_id?: string | null; p_supplier_id?: string | null };
        Returns: { transaction_id: number; journal_entry_id: string; balance_after: string }[];
      };
      record_cash_transaction: {
        Args: { p_branch_id: string; p_direction: string; p_amount: number; p_particular: string; p_account_id: string; p_customer_id?: string | null; p_reference?: string | null; p_date?: string | null; p_supplier_id?: string | null };
        Returns: { transaction_id: number; journal_entry_id: string; balance_after: string }[];
      };
      record_einvoice_request: {
        Args: { p_einvoice_id: string; p_payload: Json };
        Returns: undefined;
      };
      record_einvoice_result: {
        Args: { p_einvoice_id: string; p_status: string; p_irn?: string | null; p_ack_number?: string | null; p_ack_date?: string | null; p_qr_code?: string | null; p_error_code?: string | null; p_error?: string | null; p_response?: Json | null };
        Returns: undefined;
      };
      record_sale_payment: {
        Args: { p_sale_id: string; p_amount: number; p_payment_mode: string; p_reference?: string | null; p_finance_company_id?: string | null };
        Returns: { receipt_number: string; journal_entry_id: string }[];
      };
      record_service_payment: {
        Args: { p_invoice_id: string; p_amount: number; p_payment_mode?: string | null; p_reference?: string | null; p_date?: string | null };
        Returns: { payment_id: string; receipt_number: string; balance_due: string }[];
      };
      record_trade_advance: {
        Args: { p_finance_company_id: string; p_branch_id: string; p_type: string; p_amount: number; p_bank_account_id?: string | null; p_date?: string | null; p_narration?: string | null; p_reference?: string | null };
        Returns: { transaction_id: number; journal_entry_id: string }[];
      };
      refund_booking_advance: {
        Args: { p_booking_id: string; p_amount: number; p_mode: string; p_reason: string; p_cash_branch_id?: string | null; p_bank_account_id?: string | null; p_date?: string | null };
        Returns: { journal_entry_id: string }[];
      };
      remove_service_line: {
        Args: { p_line_id: string };
        Returns: undefined;
      };
      reopen_cash_day: {
        Args: { p_branch_id: string; p_date: string; p_reason: string };
        Returns: undefined;
      };
      resolve_account: {
        Args: { p_dealer_id: string; p_module: string; p_event: string; p_component: string; p_branch_id?: string | null };
        Returns: string;
      };
      resolve_tax_code: {
        Args: { p_dealer_id: string; p_code: string; p_on_date?: string | null };
        Returns: { tax_code_id: string; code: string; cgst_rate: string; sgst_rate: string; igst_rate: string; cess_rate: string; total_rate: string }[];
      };
      resolve_vehicle_price: {
        Args: { p_dealer_id: string; p_model_id: string; p_variant_id?: string | null; p_branch_id?: string | null; p_on_date?: string | null };
        Returns: { price_version_id: string; version_number: number; ex_showroom: string; insurance: string; registration: string; mandatory_accessories: string; forwarding_charge: string; other_charges: string; total_on_road: string; max_discount: string; tax_code: string }[];
      };
      return_vehicle_sale: {
        Args: { p_sale_id: string; p_reason: string; p_refund_mode?: string | null; p_refund_amount?: number | null; p_bank_account_id?: string | null; p_reference?: string | null; p_date?: string | null };
        Returns: { reversal_entry_id: string; refund_entry_id: string; refunded: string; credit_left: string }[];
      };
      sales_summary: {
        Args: { p_from: string; p_to: string; p_branch_id?: string | null; p_group_by?: string | null };
        Returns: { group_key: string; group_label: string; unit_count: number; gross_amount: string; tax_amount: string; cost_amount: string; margin: string }[];
      };
      service_history: {
        Args: { p_customer_id?: string | null; p_registration_no?: string | null };
        Returns: { job_card_id: string; job_card_number: string; job_date: string; customer_name: string; registration_no: string; odometer: string; service_type: string; complaint: string; status: string; invoice_number: string; invoice_total: string; paid_amount: string }[];
      };
      start_attendance_sync: {
        Args: { p_from: string; p_to: string };
        Returns: string;
      };
      suggest_bank_matches: {
        Args: { p_bank_account_id: string; p_date_window?: number | null };
        Returns: { statement_line_id: number; statement_date: string; narration: string; debit: string; credit: string; transaction_id: number; transaction_date: string; particular: string; amount: string; confidence: string; reason: string }[];
      };
      transfer_inventory_stock: {
        Args: { p_item_id: string; p_from_branch_id: string; p_to_branch_id: string; p_quantity: number; p_source?: string | null; p_remarks?: string | null };
        Returns: undefined;
      };
      trial_balance: {
        Args: { p_as_on?: string | null; p_branch_id?: string | null };
        Returns: { account_id: string; account_code: string; account_name: string; account_type: string; debit_balance: string; credit_balance: string }[];
      };
      unbilled_vehicles: {
        Args: { p_branch_id?: string | null; p_search?: string | null };
        Returns: { vehicle_id: string; chassis_no: string; engine_no: string; model_label: string; branch_name: string; purchase_cost: string; stock_date: string }[];
      };
      unmatch_bank_line: {
        Args: { p_statement_line_id: number };
        Returns: undefined;
      };
      vehicle_stock_report: {
        Args: { p_branch_id?: string | null };
        Returns: { vehicle_id: string; chassis_no: string; engine_no: string; brand: string; model_name: string; variant_name: string; branch_name: string; status: string; stock_date: string; age_days: number; age_bucket: string; purchase_cost: string }[];
      };
    };
    Enums: Record<string, never>;
    CompositeTypes: Record<string, never>;
  };
}

export type Tables<T extends keyof Database['public']['Tables']> =
  Database['public']['Tables'][T]['Row'];

export type AccountType = ChartOfAccountsRow['account_type'];
export type JournalStatus = JournalEntriesRow['status'];
export type AccountBalance = Database['public']['Functions']['account_balances']['Returns'][number];
