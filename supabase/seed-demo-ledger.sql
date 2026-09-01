-- =============================================================================
-- seed-demo-ledger.sql — DEMO ONLY
-- =============================================================================
-- Posts a month of balanced journal entries for the demo dealer so the dashboard
-- has real numbers behind it before the sales, inventory and service modules
-- exist.
--
-- These are not mock values painted onto the UI. Every figure the dashboard shows
-- is computed by public.account_balances() from double-entry journals that
-- satisfy the same constraints and immutability rules as production data — the
-- entries are simply seeded rather than raised by a business module.
--
-- Remove with:
--   delete from public.journal_entry_lines l using public.journal_entries je
--    where je.id = l.journal_entry_id and je.narration like '[DEMO]%';
--   -- posted journals cannot be deleted, so drop the dealer to fully reset:
--   -- see the teardown note in seed.sql
--
-- Skip this file entirely for a production deployment.
-- =============================================================================

do $$
declare
  v_dealer   uuid;
  v_main     uuid;
  v_north    uuid;
  v_south    uuid;
  v_period   uuid;
  v_branches uuid[];
  v_branch   uuid;
  v_day      date;
  v_je       uuid;
  v_number   text;
  v_scale    numeric;
  v_i        int;

  -- Account ids, resolved once.
  a_cash uuid; a_bank uuid; a_recv uuid; a_finrecv uuid;
  a_veh_stock uuid; a_acc_stock uuid; a_spr_stock uuid;
  a_advance uuid; a_payable uuid; a_cgst uuid; a_sgst uuid; a_capital uuid;
  a_veh_sales uuid; a_acc_sales uuid; a_spr_sales uuid; a_service uuid;
  a_fin_comm uuid; a_ins_comm uuid; a_fwd uuid;
  a_veh_cogs uuid; a_acc_cogs uuid; a_spr_cogs uuid; a_svc_cost uuid;
  a_salaries uuid; a_rent uuid;

  function_missing boolean;
begin
  select id into v_dealer from public.dealers where code = 'SBM';
  if v_dealer is null then
    raise notice 'Demo dealer SBM not found; skipping demo ledger.';
    return;
  end if;

  -- Already seeded? Leave it alone so re-running is harmless.
  select exists (
    select 1 from public.journal_entries
     where dealer_id = v_dealer and narration like '[DEMO]%'
  ) into function_missing;
  if function_missing then
    raise notice 'Demo ledger already present; skipping.';
    return;
  end if;

  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_south from public.branches where dealer_id = v_dealer and code = 'SOUTH';
  v_branches := array[v_main, v_north, v_south];

  select id into v_period from public.accounting_periods
   where dealer_id = v_dealer and start_date = date '2026-04-01';

  select id into a_cash      from public.chart_of_accounts where dealer_id = v_dealer and code = '1100';
  select id into a_bank      from public.chart_of_accounts where dealer_id = v_dealer and code = '1200';
  select id into a_recv      from public.chart_of_accounts where dealer_id = v_dealer and code = '1300';
  select id into a_finrecv   from public.chart_of_accounts where dealer_id = v_dealer and code = '1400';
  select id into a_veh_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1500';
  select id into a_acc_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1600';
  select id into a_spr_stock from public.chart_of_accounts where dealer_id = v_dealer and code = '1700';
  select id into a_advance   from public.chart_of_accounts where dealer_id = v_dealer and code = '2100';
  select id into a_payable   from public.chart_of_accounts where dealer_id = v_dealer and code = '2200';
  select id into a_cgst      from public.chart_of_accounts where dealer_id = v_dealer and code = '2300';
  select id into a_sgst      from public.chart_of_accounts where dealer_id = v_dealer and code = '2400';
  select id into a_capital   from public.chart_of_accounts where dealer_id = v_dealer and code = '3100';
  select id into a_veh_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4100';
  select id into a_acc_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4200';
  select id into a_spr_sales from public.chart_of_accounts where dealer_id = v_dealer and code = '4300';
  select id into a_service   from public.chart_of_accounts where dealer_id = v_dealer and code = '4400';
  select id into a_fin_comm  from public.chart_of_accounts where dealer_id = v_dealer and code = '4500';
  select id into a_ins_comm  from public.chart_of_accounts where dealer_id = v_dealer and code = '4600';
  select id into a_fwd       from public.chart_of_accounts where dealer_id = v_dealer and code = '4700';
  select id into a_veh_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5100';
  select id into a_acc_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5200';
  select id into a_spr_cogs  from public.chart_of_accounts where dealer_id = v_dealer and code = '5300';
  select id into a_svc_cost  from public.chart_of_accounts where dealer_id = v_dealer and code = '5400';
  select id into a_salaries  from public.chart_of_accounts where dealer_id = v_dealer and code = '5500';
  select id into a_rent      from public.chart_of_accounts where dealer_id = v_dealer and code = '5600';

  -- ── Opening balances: capital funds cash, bank and stock ──────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-04-01', v_period, 'OPENING',
          '[DEMO] Opening balances FY 2026-27')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_cash,      v_main,   650000.00,        0, 'Opening cash'),
    (v_je, v_dealer, 2, a_bank,      v_main, 11200000.00,        0, 'Opening bank'),
    (v_je, v_dealer, 3, a_veh_stock, v_main, 30500000.00,        0, 'Opening vehicle stock'),
    (v_je, v_dealer, 4, a_acc_stock, v_main,  2400000.00,        0, 'Opening accessories stock'),
    (v_je, v_dealer, 5, a_spr_stock, v_main,  1650000.00,        0, 'Opening spare stock'),
    (v_je, v_dealer, 6, a_payable,   v_main,          0, 2350000.00, 'Opening supplier payables'),
    (v_je, v_dealer, 7, a_capital,   v_main,          0, 44050000.00, 'Share capital');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── A month of trading, spread across the three branches ──────────────────
  -- Each day posts one composite sales entry and one service entry. Amounts vary
  -- deterministically so the sales-trend chart has a believable shape without
  -- being random from run to run.
  v_i := 0;
  for v_day in select generate_series(date '2026-08-01', date '2026-08-30', interval '1 day')::date loop
    v_i := v_i + 1;
    v_branch := v_branches[1 + (v_i % 3)];
    -- A repeating weekly rhythm plus a slow upward drift.
    v_scale := 0.72 + 0.34 * sin(v_i::numeric / 2.1) + 0.010 * v_i;

    -- Vehicle sale: part cash, part finance, with GST and COGS.
    v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
    insert into public.journal_entries
      (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
    values (v_dealer, v_branch, v_number, v_day, v_period, 'SALES',
            '[DEMO] Vehicle sales ' || to_char(v_day, 'DD Mon YYYY'))
    returning id into v_je;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
    values
      (v_je, v_dealer, 1, a_cash,      v_branch, round(240000 * v_scale, 2), 0, 'Cash collected'),
      (v_je, v_dealer, 2, a_finrecv,   v_branch, round(560000 * v_scale, 2), 0, 'Finance receivable'),
      (v_je, v_dealer, 3, a_veh_sales, v_branch, 0, round(620000 * v_scale, 2), 'Ex-showroom value'),
      (v_je, v_dealer, 4, a_acc_sales, v_branch, 0, round( 46000 * v_scale, 2), 'Fitted accessories'),
      (v_je, v_dealer, 5, a_fwd,       v_branch, 0, round(  8000 * v_scale, 2), 'Forwarding charges'),
      (v_je, v_dealer, 6, a_ins_comm,  v_branch, 0, round(  7400 * v_scale, 2), 'Insurance commission'),
      (v_je, v_dealer, 7, a_cgst,      v_branch, 0, round( 59300 * v_scale, 2), 'Output CGST'),
      (v_je, v_dealer, 8, a_sgst,      v_branch, 0, round( 59300 * v_scale, 2), 'Output SGST'),
      -- COGS and the matching stock relief.
      (v_je, v_dealer, 9, a_veh_cogs,  v_branch, round(521000 * v_scale, 2), 0, 'Vehicle COGS'),
      (v_je, v_dealer, 10, a_acc_cogs, v_branch, round( 31000 * v_scale, 2), 0, 'Accessories COGS'),
      (v_je, v_dealer, 11, a_veh_stock, v_branch, 0, round(521000 * v_scale, 2), 'Vehicle stock relief'),
      (v_je, v_dealer, 12, a_acc_stock, v_branch, 0, round( 31000 * v_scale, 2), 'Accessories stock relief');

    -- Balance the rounding: the debit and credit legs above are independently
    -- rounded, so square them off against cash before posting.
    declare
      v_debit  numeric(18, 4);
      v_credit numeric(18, 4);
      v_diff   numeric(18, 4);
    begin
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_debit, v_credit
        from public.journal_entry_lines where journal_entry_id = v_je;
      v_diff := v_debit - v_credit;

      if v_diff <> 0 then
        update public.journal_entry_lines
           set debit = debit - v_diff
         where journal_entry_id = v_je and line_number = 1;
      end if;
    end;

    update public.journal_entries set status = 'POSTED' where id = v_je;

    -- Service billing: labour and spares, collected in cash.
    v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
    insert into public.journal_entries
      (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
    values (v_dealer, v_branch, v_number, v_day, v_period, 'SERVICE',
            '[DEMO] Service billing ' || to_char(v_day, 'DD Mon YYYY'))
    returning id into v_je;

    insert into public.journal_entry_lines
      (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
    values
      (v_je, v_dealer, 1, a_cash,      v_branch, round(42000 * v_scale, 2), 0, 'Service collections'),
      (v_je, v_dealer, 2, a_service,   v_branch, 0, round(21000 * v_scale, 2), 'Labour'),
      (v_je, v_dealer, 3, a_spr_sales, v_branch, 0, round(14600 * v_scale, 2), 'Spares billed'),
      (v_je, v_dealer, 4, a_cgst,      v_branch, 0, round( 3200 * v_scale, 2), 'Output CGST'),
      (v_je, v_dealer, 5, a_sgst,      v_branch, 0, round( 3200 * v_scale, 2), 'Output SGST'),
      (v_je, v_dealer, 6, a_spr_cogs,  v_branch, round( 9800 * v_scale, 2), 0, 'Spare COGS'),
      (v_je, v_dealer, 7, a_svc_cost,  v_branch, round( 2600 * v_scale, 2), 0, 'Service consumables'),
      (v_je, v_dealer, 8, a_spr_stock, v_branch, 0, round( 9800 * v_scale, 2), 'Spare stock relief'),
      (v_je, v_dealer, 9, a_acc_stock, v_branch, 0, round( 2600 * v_scale, 2), 'Consumables relief');

    declare
      v_debit  numeric(18, 4);
      v_credit numeric(18, 4);
      v_diff   numeric(18, 4);
    begin
      select coalesce(sum(debit), 0), coalesce(sum(credit), 0)
        into v_debit, v_credit
        from public.journal_entry_lines where journal_entry_id = v_je;
      v_diff := v_debit - v_credit;

      if v_diff <> 0 then
        update public.journal_entry_lines
           set debit = debit - v_diff
         where journal_entry_id = v_je and line_number = 1;
      end if;
    end;

    update public.journal_entries set status = 'POSTED' where id = v_je;
  end loop;

  -- ── Booking advances outstanding ──────────────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-28', v_period, 'BOOKING',
          '[DEMO] Booking advances received')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_cash,    v_main, 1124500.00, 0, 'Advances collected'),
    (v_je, v_dealer, 2, a_advance, v_main, 0, 1124500.00, 'Customer advances (spec §18)');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Finance commission and a bank deposit ─────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-29', v_period, 'FINANCE',
          '[DEMO] Finance disbursement and commission')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_bank,     v_main, 9850000.00, 0, 'Finance disbursements received'),
    (v_je, v_dealer, 2, a_finrecv,  v_main, 0, 9850000.00, 'Finance receivable settled'),
    (v_je, v_dealer, 3, a_bank,     v_main,  384000.00, 0, 'Commission credited'),
    (v_je, v_dealer, 4, a_fin_comm, v_main, 0,  384000.00, 'Finance commission income');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Operating expenses ────────────────────────────────────────────────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-30', v_period, 'EXPENSE',
          '[DEMO] Monthly operating expenses')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_salaries, v_main, 1860000.00, 0, 'Salaries'),
    (v_je, v_dealer, 2, a_rent,     v_main,  420000.00, 0, 'Rent'),
    (v_je, v_dealer, 3, a_bank,     v_main, 0, 2280000.00, 'Paid by bank transfer');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  -- ── Trade payables partly settled, some receivables outstanding ───────────
  v_number := app.next_document_number(v_dealer, null, 'JOURNAL', '2026');
  insert into public.journal_entries
    (dealer_id, branch_id, entry_number, entry_date, period_id, source_module, narration)
  values (v_dealer, v_main, v_number, date '2026-08-30', v_period, 'CASH',
          '[DEMO] Customer dues outstanding')
  returning id into v_je;

  insert into public.journal_entry_lines
    (journal_entry_id, dealer_id, line_number, account_id, branch_id, debit, credit, narration)
  values
    (v_je, v_dealer, 1, a_recv,  v_main, 4875430.00, 0, 'Customer receivables'),
    (v_je, v_dealer, 2, a_cash,  v_main, 0, 4875430.00, 'Credit extended against cash sales');

  update public.journal_entries set status = 'POSTED' where id = v_je;

  raise notice '[DEMO] Ledger seeded: % posted journals.',
    (select count(*) from public.journal_entries where dealer_id = v_dealer and status = 'POSTED');
end;
$$;
