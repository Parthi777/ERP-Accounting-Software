-- =============================================================================
-- TEST — the service workshop, job card to collected payment
-- =============================================================================
-- Spec §32, §33, §31.
--
-- The guarantees asserted here:
--   * a bill cannot promise parts the branch does not hold;
--   * parts leave LOCAL stock before COMPANY stock, and the invoice records
--     which;
--   * revenue, GST, COGS and stock relief post together, and the journal
--     balances;
--   * a posted invoice is not editable, and posting twice does not post twice.
-- =============================================================================

\echo '--- service ---'

do $$
declare
  v_dealer   uuid;
  v_branch   uuid;
  v_customer uuid;
  v_item     uuid;
  v_hsn      uuid;
  v_job      uuid;
  v_job_no   text;
  v_invoice  uuid;
  v_inv_no   text;
  v_line     uuid;
  v_entry    uuid;
  v_entry2   uuid;
  v_debit    numeric;
  v_credit   numeric;
  v_local    numeric;
  v_company  numeric;
  v_total    numeric;
  v_cost     numeric;
  v_source   text;
  v_status   text;
  v_balance  numeric;
  v_count    int;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code)
  values (v_dealer, 'Service Test Customer', '9840099055', 'Chennai', 'Tamil Nadu', '33')
  returning id into v_customer;

  insert into public.hsn_codes (dealer_id, code, description)
  values (v_dealer, '87141090', 'Motorcycle parts')
  returning id into v_hsn;

  insert into public.tax_codes
    (dealer_id, code, name, hsn_code_id, cgst_rate, sgst_rate, igst_rate, effective_from)
  values
    (v_dealer, 'GST28_PARTS', 'GST 28% parts', v_hsn, 14, 14, 28, date '2020-01-01');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, hsn_code_id, standard_cost, selling_price, tax_code)
  values
    (v_dealer, 'SP-OIL-01', 'Engine oil 1L', 'SPARE', v_hsn, 300, 450, 'GST28_PARTS')
  returning id into v_item;

  -- ── Stock: 2 local, 5 company (spec §31, §60.16) ──────────────────────────
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost, reference_type, narration)
  values
    (v_dealer, v_branch, v_item, 'LOCAL',   'OPENING', 2, 280, 'OPENING', 'Local purchase'),
    (v_dealer, v_branch, v_item, 'COMPANY', 'OPENING', 5, 300, 'OPENING', 'Company supply');

  -- ── Job card ──────────────────────────────────────────────────────────────
  select job_card_id, job_card_number into v_job, v_job_no
    from public.create_job_card(v_branch, v_customer, 'PAID', 'TN01AB1234', 5120,
                                'Engine noise and oil change');

  perform app_test.assert_equals(v_job_no is not null, true, 'the job card is numbered');

  select status into v_status from public.job_cards where id = v_job;
  perform app_test.assert_equals(v_status, 'OPEN', 'a new job card is OPEN');

  -- ── Invoice ───────────────────────────────────────────────────────────────
  select invoice_id, invoice_number into v_invoice, v_inv_no
    from public.create_service_invoice(v_job);

  perform app_test.assert_equals(v_inv_no is not null, true, 'the invoice is numbered');

  perform app_test.assert_raises(
    format('select public.create_service_invoice(%L)', v_job),
    'a job card cannot be billed twice');

  -- ── Lines ─────────────────────────────────────────────────────────────────
  v_line := public.add_service_line(v_invoice, 'LABOUR', 'General service labour', 1, 800, null, 'GST28_PARTS');

  -- 3 units: 2 from LOCAL and 1 from COMPANY.
  v_line := public.add_service_line(v_invoice, 'SPARE', 'Engine oil 1L', 3, 450, v_item, 'GST28_PARTS');

  select stock_source, cost_amount into v_source, v_cost
    from public.service_lines where id = v_line;

  perform app_test.assert_equals(v_source, 'LOCAL',
    'a part drawn partly from local stock records LOCAL as its source (spec §31)');
  -- 2 × 280 + 1 × 300 = 860, not 3 × 300.
  perform app_test.assert_equals(v_cost, 860::numeric,
    'the cost is what those specific units cost, local first');

  -- Selling more than the branch holds must be refused while the bill is a draft.
  -- The message is checked, not just the failure: this assertion once passed
  -- because an unrelated error fired first, which proved nothing about stock.
  begin
    perform public.add_service_line(v_invoice, 'SPARE', 'Too many', 99, 450, v_item);
    raise exception 'ASSERTION FAILED: a line for 99 units was accepted with 4 in stock.';
  exception
    when check_violation then
      if sqlerrm not like '%Not enough stock%' then
        raise exception 'ASSERTION FAILED: refused, but for the wrong reason: %', sqlerrm;
      end if;
      raise notice '  ok  a line for more than the stock on hand is refused (%)', sqlerrm;
  end;

  -- An untaxed line must not fail: p_tax_code is optional, and a record variable
  -- that was never assigned raises on first access.
  v_line := public.add_service_line(v_invoice, 'OTHER_CHARGE', 'Consumables', 1, 50);
  perform app_test.assert_equals(v_line is not null, true, 'a line with no tax code is accepted');
  perform public.remove_service_line(v_line);

  select total_amount into v_total from public.service_invoices where id = v_invoice;
  -- (800 + 1350) taxable + 28% GST = 2150 + 602 = 2752.
  perform app_test.assert_equals(v_total, 2752::numeric, 'the invoice totals its lines with GST');

  -- ── Posting (spec §48) ────────────────────────────────────────────────────
  v_entry := public.post_service_invoice(v_invoice);
  perform app_test.assert_equals(v_entry is not null, true, 'the invoice posts');

  select sum(debit), sum(credit) into v_debit, v_credit
    from public.journal_entry_lines where journal_entry_id = v_entry;
  perform app_test.assert_equals(v_debit, v_credit, 'the service journal balances');

  select status, total_cost into v_status, v_cost from public.service_invoices where id = v_invoice;
  perform app_test.assert_equals(v_status, 'POSTED', 'the invoice is posted');
  perform app_test.assert_equals(v_cost, 860::numeric, 'COGS is recognised at what the parts cost');

  select status into v_status from public.job_cards where id = v_job;
  perform app_test.assert_equals(v_status, 'INVOICED', 'the job card is marked invoiced');

  -- ── Stock actually moved, in the right order ──────────────────────────────
  select quantity into v_local
    from public.inventory_stock where item_id = v_item and branch_id = v_branch and source = 'LOCAL';
  select quantity into v_company
    from public.inventory_stock where item_id = v_item and branch_id = v_branch and source = 'COMPANY';

  perform app_test.assert_equals(v_local,   0::numeric, 'local stock is consumed first');
  perform app_test.assert_equals(v_company, 4::numeric, 'company stock covers only the balance');

  select count(*) into v_count
    from public.inventory_transactions
   where reference_type = 'SERVICE_INVOICE' and reference_id = v_invoice and quantity < 0;
  perform app_test.assert_equals(v_count, 2,
    'the two sources are recorded as separate movements, never merged');

  -- ── Immutability and idempotency (spec §23, §48) ──────────────────────────
  perform app_test.assert_raises(
    format('select public.add_service_line(%L, %L, %L, 1, 100)', v_invoice, 'LABOUR', 'Late addition'),
    'a posted invoice cannot take new lines');

  v_entry2 := public.post_service_invoice(v_invoice);
  perform app_test.assert_equals(v_entry2, v_entry,
    'posting twice returns the first entry rather than posting again');

  select count(*) into v_count
    from public.inventory_transactions
   where reference_type = 'SERVICE_INVOICE' and reference_id = v_invoice and quantity < 0;
  perform app_test.assert_equals(v_count, 2, 'and does not relieve stock a second time');

  -- ── Payment ───────────────────────────────────────────────────────────────
  perform app_test.assert_raises(
    format('select public.record_service_payment(%L, 99999)', v_invoice),
    'a payment larger than the balance is refused');

  select balance_due into v_balance
    from public.record_service_payment(v_invoice, 1000, 'CASH', 'Counter cash');
  perform app_test.assert_equals(v_balance, 1752::numeric, 'a part payment leaves the balance open');

  select balance_due into v_balance
    from public.record_service_payment(v_invoice, 1752, 'UPI', 'UPI ref 998877');
  perform app_test.assert_equals(v_balance, 0::numeric, 'the final payment clears the invoice');

  -- ── History (spec §33) ────────────────────────────────────────────────────
  select count(*) into v_count from public.service_history(v_customer);
  perform app_test.assert_equals(v_count, 1, 'the job appears in the customer''s service history');

  select invoice_number, paid_amount into v_inv_no, v_balance
    from public.service_history(null, 'TN01AB1234');
  perform app_test.assert_equals(v_balance, 2752::numeric,
    'history shows what has been collected against the bill');

  -- ── And the books still balance ───────────────────────────────────────────
  select sum(l.debit), sum(l.credit) into v_debit, v_credit
    from public.journal_entry_lines l
    join public.journal_entries e on e.id = l.journal_entry_id
   where e.dealer_id = v_dealer and e.status = 'POSTED';

  perform app_test.assert_equals(v_debit, v_credit, 'the ledger balances after service activity');
end;
$$;
