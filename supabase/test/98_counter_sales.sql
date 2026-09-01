-- =============================================================================
-- TEST — counter sales
-- =============================================================================
-- Spec §33, §31, §60.18.
--
-- The guarantees asserted here:
--   * a counter sale is billed through the same engine as service, so revenue,
--     GST, COGS and stock relief post exactly once and from one code path;
--   * stock is allocated LOCAL before COMPANY and cannot go negative;
--   * the customer is optional or required by configuration, not by opinion;
--   * a counter invoice carries no job card, and the job-card machinery is
--     simply not exercised by it.
-- =============================================================================

\echo '--- counter sales ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_hsn      uuid;
  v_item     uuid;
  v_invoice  uuid;
  v_inv_no   text;
  v_entry    uuid;
  v_debit    numeric;
  v_credit   numeric;
  v_local    numeric;
  v_company  numeric;
  v_total    numeric;
  v_balance  numeric;
  v_count    int;
  v_status   text;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87141010', 'Helmets and accessories') returning id into v_hsn;

  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from)
  values (v_dealer, 'GST18_ACC', 'GST 18% accessories', v_hsn, 9, 9, 18, date '2020-01-01');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price, tax_code)
  values (v_dealer, 'AC-HELM-01', 'Full face helmet', 'ACCESSORY', v_hsn, 900, 1400, 'GST18_ACC')
  returning id into v_item;

  -- 2 local at 850, 5 company at 900 (spec §31).
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost,
     reference_type, narration)
  values
    (v_dealer, v_branch, v_item, 'LOCAL',   'OPENING', 2, 850, 'OPENING', 'Local purchase'),
    (v_dealer, v_branch, v_item, 'COMPANY', 'OPENING', 5, 900, 'OPENING', 'Company supply');

  -- ═══ A counter sale needs no customer by default ═════════════════════════
  select invoice_id, invoice_number into v_invoice, v_inv_no
    from public.create_counter_invoice(v_branch, null);

  perform app_test.assert_equals(v_inv_no ~ '^CSI-[0-9]{4}-[0-9]{6}$', true,
    'the counter invoice follows the CSI-YYYY-NNNNNN format');

  select invoice_type, job_card_id, customer_id into v_status, v_invoice, v_customer
    from public.service_invoices where invoice_number = v_inv_no;
  perform app_test.assert_equals(v_status, 'COUNTER', 'it is a counter invoice');
  perform app_test.assert_equals(v_invoice is null, true, 'with no job card behind it');
  perform app_test.assert_equals(v_customer is null, true, 'and no customer, which is allowed');

  select id into v_invoice from public.service_invoices where invoice_number = v_inv_no;

  -- ═══ Lines allocate local stock first (spec §31) ═════════════════════════
  perform public.add_service_line(v_invoice, 'ACCESSORY', 'Full face helmet', 3, 1400,
                                  v_item, 'GST18_ACC');

  -- Availability is checked as the line is added; the stock itself moves when
  -- the invoice posts, so a draft holds nothing.
  select quantity into v_local from public.inventory_stock
   where item_id = v_item and branch_id = v_branch and source = 'LOCAL';
  perform app_test.assert_equals(v_local, 2::numeric,
    'a draft line reserves nothing: stock moves when the invoice posts');

  -- 3 × 1400 = 4200 taxable, +18% = 4956.
  select total_amount into v_total from public.service_invoices where id = v_invoice;
  perform app_test.assert_equals(v_total, 4956::numeric, 'the invoice totals its lines with GST');

  perform app_test.assert_raises(
    format($f$select public.add_service_line(%L, 'ACCESSORY', 'Too many', 99, 1400, %L, 'GST18_ACC')$f$,
           v_invoice, v_item),
    'stock cannot go negative on a counter sale (spec §33)');

  -- ═══ Posting uses the one accounting engine (spec §60.18) ════════════════
  v_entry := public.post_service_invoice(v_invoice);

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the counter sale journal balances');

  select status into v_status from public.service_invoices where id = v_invoice;
  perform app_test.assert_equals(v_status, 'POSTED', 'the invoice is posted');

  -- COGS is what those specific units cost: 2 × 850 + 1 × 900 = 2600.
  select total_cost into v_total from public.service_invoices where id = v_invoice;
  perform app_test.assert_equals(v_total, 2600::numeric,
    'COGS is what the units actually cost, local first');

  select quantity into v_local from public.inventory_stock
   where item_id = v_item and branch_id = v_branch and source = 'LOCAL';
  select quantity into v_company from public.inventory_stock
   where item_id = v_item and branch_id = v_branch and source = 'COMPANY';

  perform app_test.assert_equals(v_local, 0::numeric, 'local stock is consumed first (spec §31)');
  perform app_test.assert_equals(v_company, 4::numeric, 'company stock covers only the balance');

  select count(*)::int into v_count
    from public.inventory_transactions
   where item_id = v_item and reference_id = v_invoice;
  perform app_test.assert_equals(v_count, 2,
    'the two sources move separately, so the allocation is never hidden (spec §31)');

  perform app_test.assert_equals(
    public.post_service_invoice(v_invoice), v_entry,
    'posting twice returns the first entry rather than posting again');

  select count(*)::int into v_count
    from public.inventory_transactions
   where item_id = v_item and reference_id = v_invoice;
  perform app_test.assert_equals(v_count, 2,
    'and does not relieve stock a second time');

  -- ═══ Payment ═════════════════════════════════════════════════════════════
  select balance_due into v_balance
    from public.record_service_payment(v_invoice, 4956, 'CASH', 'Counter cash');
  perform app_test.assert_equals(v_balance, 0::numeric, 'the payment clears the invoice');

  -- ═══ The customer can be made mandatory ══════════════════════════════════
  update public.system_settings
     set value = 'true'::jsonb
   where dealer_id = v_dealer and key = 'counter_sale.require_customer';

  perform app_test.assert_raises(
    format('select public.create_counter_invoice(%L, null)', v_branch),
    'a dealer can require a customer on every counter sale');

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Counter Customer', '9840093001', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  select invoice_id into v_invoice
    from public.create_counter_invoice(v_branch, v_customer);
  perform app_test.assert_equals(v_invoice is not null, true,
    'and naming one satisfies it');

  -- Put the setting back so later tests see the default.
  update public.system_settings
     set value = 'false'::jsonb
   where dealer_id = v_dealer and key = 'counter_sale.require_customer';

  -- ═══ And the books still balance ═════════════════════════════════════════
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status in ('POSTED', 'REVERSED');

  perform app_test.assert_equals(v_debit, v_credit,
    'the ledger balances after counter sales');
end;
$$;
