-- =============================================================================
-- TEST — transfers that move value, damaged and consignment stock (0083)
-- =============================================================================
-- Checklist §06 transfers (quantity and GL / GST per GSTIN), damaged and
-- consignment; §07 document lifecycle (delivery challan).
-- =============================================================================

\echo '--- branch transfers, damaged and consignment stock ---'

-- Fixture (owner-level set-up): a Karnataka branch with its own GSTIN, and an
-- item with opening stock at MAIN.
do $$
declare
  v_dealer uuid := (select id from public.dealers where code = 'SBM');
  v_main   uuid;
  v_item   uuid;
begin
  select id into v_main from public.branches where dealer_id = v_dealer and code = 'MAIN';
  insert into public.branches (dealer_id, code, name, gstin, city, state, state_code, pincode)
  values (v_dealer, 'KAR', 'Bengaluru Branch', '29AABCS1429B1ZU', 'Bengaluru', 'Karnataka', '29', '560001');

  insert into public.inventory_items
    (dealer_id, item_code, name, item_type, standard_cost, selling_price, tax_code)
  values (v_dealer, 'TR-KIT-01', 'Transfer test kit', 'ACCESSORY', 1000, 1500, 'GST18_ACC')
  returning id into v_item;
  insert into public.inventory_transactions
    (dealer_id, branch_id, item_id, source, transaction_type, quantity, unit_cost, reference_type, narration)
  values (v_dealer, v_main, v_item, 'COMPANY', 'OPENING', 10, 1000, 'OPENING', 'Test opening');
end $$;

select app_test.login('11111111-1111-4111-8111-111111111111');
set role authenticated;

do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_main   uuid;
  v_north  uuid;
  v_kar    uuid;
  v_item   uuid;
  v_note   public.branch_transfer_notes;
  v_veh    record;
  v_xfer   record;
  r        record;
begin
  select id into v_main  from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_north from public.branches where dealer_id = v_dealer and code = 'NORTH';
  select id into v_kar   from public.branches where dealer_id = v_dealer and code = 'KAR';
  select id into v_item  from public.inventory_items where item_code = 'TR-KIT-01';

  -- ── Same GSTIN: a delivery challan, value moved, no tax ──────────────────
  perform public.transfer_inventory_stock(v_item, v_main, v_north, 2, 'COMPANY', 'Stock for the weekend');
  select * into v_note from public.branch_transfer_notes
   where item_id = v_item and to_branch_id = v_north order by created_at desc limit 1;
  perform app_test.assert_equals(v_note.note_kind, 'DELIVERY_CHALLAN',
    'between branches of one GSTIN the transfer travels on a delivery challan');
  perform app_test.assert_equals(v_note.note_number ~ '^TN-[0-9]{4}-[0-9]{6}$', true, 'numbered TN-YYYY-NNNNNN');
  perform app_test.assert_equals(
    (select sum(l.debit) from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_note.receipt_journal_id and c.code = '1600' and l.branch_id = v_north),
    2000::numeric, 'the receiving branch''s stock account gains the 2,000 of stock it received');
  perform app_test.assert_equals(
    (select sum(l.credit) from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_note.receipt_journal_id and c.code = '1600' and l.branch_id = v_main),
    2000::numeric, 'and the sending branch''s loses it');

  -- ── Different GSTIN, different state: a tax invoice with IGST ────────────
  perform public.transfer_inventory_stock(v_item, v_main, v_kar, 1, 'COMPANY', 'For the Bengaluru counter');
  select * into v_note from public.branch_transfer_notes
   where item_id = v_item and to_branch_id = v_kar order by created_at desc limit 1;
  perform app_test.assert_equals(v_note.note_kind, 'TAX_INVOICE',
    'between two GSTINs the transfer is a supply, on a tax invoice');
  perform app_test.assert_equals(v_note.igst_amount, 180::numeric, 'inter-state: IGST 18% on the 1,000 at cost');
  perform app_test.assert_equals(
    (select string_agg(c.code || case when l.debit > 0 then ' Dr ' || l.debit::numeric(18, 0) else ' Cr ' || l.credit::numeric(18, 0) end
             || case when l.branch_id = v_main then ' (MAIN)' else ' (KAR)' end, ', ' order by l.line_number)
       from public.journal_entry_lines l join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = v_note.receipt_journal_id),
    '1850 Dr 1180 (MAIN), 1600 Cr 1000 (MAIN), 2500 Cr 180 (MAIN), 1600 Dr 1000 (KAR), 1920 Dr 180 (KAR), 1850 Cr 1180 (KAR)',
    'output IGST at the sender, input IGST at the receiver, through stock in transit');

  -- Every branch balances on its own, which is the point.
  for r in select b.code, (select sum(debit_balance) - sum(credit_balance)
                             from public.trial_balance(current_date, b.id)) as diff
             from public.branches b where b.dealer_id = v_dealer loop
    perform app_test.assert_equals(coalesce(r.diff, 0), 0::numeric,
      format('branch %s''s trial balance balances on its own', r.code));
  end loop;

  -- ── A vehicle on the road sits in stock in transit ────────────────────────
  select v.id, v.purchase_cost into v_veh from public.vehicles v
   where v.dealer_id = v_dealer and v.branch_id = v_main and v.status = 'IN_STOCK' and v.purchase_cost > 0
   limit 1;
  if v_veh.id is not null then
    -- Earlier tests make vehicles without purchase bills, so vehicle stock is
    -- already off in this database; what matters is that a dispatch leaves the
    -- difference exactly where it was.
    select difference into r from public.control_account_tieout(current_date) where control = 'VEHICLE_STOCK';
    select * into v_xfer from public.dispatch_vehicle_transfer(v_veh.id, v_north, 'Test transfer');
    perform app_test.assert_equals(
      (select subledger_balance from public.control_account_tieout(current_date) where control = 'STOCK_IN_TRANSIT'),
      v_veh.purchase_cost, 'a dispatched vehicle is stock in transit at its cost');
    perform app_test.assert_equals(
      (select difference from public.control_account_tieout(current_date) where control = 'STOCK_IN_TRANSIT'),
      0::numeric, 'stock in transit ties to the ledger while it is on the road');
    perform app_test.assert_equals(
      (select difference from public.control_account_tieout(current_date) where control = 'VEHICLE_STOCK'),
      r.difference, 'and vehicle stock moved out of 1500 exactly as the vehicle left it');
    perform public.receive_vehicle_transfer(v_xfer.transfer_id, 'Arrived');
    perform app_test.assert_equals(
      (select coalesce(sum(subledger_balance), 0) from public.control_account_tieout(current_date) where control = 'STOCK_IN_TRANSIT'),
      0::numeric, 'received, it leaves transit');
    perform app_test.assert_equals(
      (select receipt_journal_id is not null from public.vehicle_transfers where id = v_xfer.transfer_id), true,
      'the receipt posted its half');
  end if;

  -- ── Damaged stock: out of the saleable lot, written down ──────────────────
  perform public.mark_stock_damaged(v_item, v_main, 'COMPANY', 1, 400, 'Dropped in the store');
  perform app_test.assert_equals(
    (select quantity || '@' || stock_value from public.inventory_stock
      where item_id = v_item and branch_id = v_main and source = 'DAMAGED'),
    '1.000@400.0000', 'one kit sits in the DAMAGED lot at its realisable 400');
  perform app_test.assert_equals(
    (select count(*)::int from public.allocate_stock(v_item, v_main, 7) where source = 'DAMAGED'), 0,
    'the sale allocator never offers damaged stock');
  perform app_test.assert_equals(
    (select sum(l.debit) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
       join public.chart_of_accounts c on c.id = l.account_id
      where je.source_document_type = 'STOCK_DAMAGE' and je.source_document_id = v_item and c.code = '5970'),
    600::numeric, 'the 600 write-down to realisable value is charged to 5970');

  -- ── Consignment: held, not owned ──────────────────────────────────────────
  perform public.move_consignment_stock(v_item, v_main, 5, 'RECEIVE', 'CONSIGNOR-DN-17');
  perform public.move_consignment_stock(v_item, v_main, 2, 'RETURN', 'CONSIGNOR-RET-3');
  perform app_test.assert_equals(
    (select quantity || '@' || stock_value from public.inventory_stock
      where item_id = v_item and branch_id = v_main and source = 'CONSIGNMENT'),
    '3.000@0.0000', 'consignment stock is counted and carries no value');
  perform app_test.assert_equals(
    (select consignment_qty from public.inventory_condition_report(v_main) where item_id = v_item), 3::numeric,
    'and the condition report shows it apart from owned stock');
  perform app_test.assert_raises(
    format($q$select public.adjust_inventory_stock(%L, %L, 'CONSIGNMENT', -1, 'try')$q$, v_item, v_main),
    'consignment stock is not the dealer''s to adjust');
end $$;

reset role;
select app_test.logout();
