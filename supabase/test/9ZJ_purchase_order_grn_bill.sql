-- =============================================================================
-- TEST — purchase order → goods receipt → supplier bill (0092)
-- =============================================================================
-- Acceptance scenarios from the BUSY requirements review (§8): order 10,
-- receive 6, bill 6 — stock rises by 6 once, 4 stay pending, GRNI returns to
-- nil; over-receipt and over-billing refused; a rate difference goes to price
-- variance; a billed receipt cannot be cancelled; replays post nothing twice.
-- =============================================================================

\echo '--- purchase order, goods receipt, bill ---'

-- Fixtures written as the database owner, read by the accountant.
create temporary table fixture_po as
with d as (select id from public.dealers where code = 'SBM'),
     s as (insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
           select id, 'PO Test Motors', 'OEM', '9840077201', 'Chennai', 'Tamil Nadu' from d returning id),
     i as (insert into public.inventory_items (dealer_id, item_code, name, item_type, standard_cost, selling_price)
           select id, 'PO-GUARD-01', 'PO Test Leg Guard', 'ACCESSORY', 400, 650 from d returning id)
select (select id from s) as supplier_id, (select id from i) as item_id,
       (select b.id from public.branches b join d on b.dealer_id = d.id where b.code = 'MAIN') as branch_id;
grant select on fixture_po to authenticated;

create temporary table fixture_ids (k text primary key, id uuid);
grant select, insert, update on fixture_ids to authenticated;

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

do $$
declare
  f        record;
  v_po     uuid;
  v_again  uuid;
  v_line   uuid;
  v_grn    uuid;
  v_grn2   uuid;
  v_grl    uuid;
  v_bill   uuid;
  v_stock0 numeric;
  v_stock  numeric;
  v_grni   uuid := app.require_account(app.current_dealer_id(), 'INVENTORY', 'PURCHASE', 'GRNI', null);
  v_var    uuid := app.require_account(app.current_dealer_id(), 'INVENTORY', 'PURCHASE', 'PRICE_VARIANCE', null);
  v_entry  uuid;
begin
  select * into f from fixture_po;
  select coalesce(sum(quantity), 0) into v_stock0 from public.inventory_stock where item_id = f.item_id;

  -- ── The order ──────────────────────────────────────────────────────────
  v_po := public.create_purchase_order(f.branch_id, f.supplier_id,
    jsonb_build_array(jsonb_build_object('item_id', f.item_id, 'source', 'COMPANY', 'quantity', 10,
                                         'unit_rate', 400, 'cgst_rate', 14, 'sgst_rate', 14)),
    current_date, current_date + 7, 'For the festive stock', 'po-9zj');
  v_again := public.create_purchase_order(f.branch_id, f.supplier_id,
    jsonb_build_array(jsonb_build_object('item_id', f.item_id, 'quantity', 10, 'unit_rate', 400)),
    current_date, null, null, 'po-9zj');
  perform app_test.assert_equals(v_again, v_po, 'a replayed order is the same order');
  perform app_test.assert_equals((select po_number like 'PO-%' from public.purchase_orders where id = v_po), true,
    'the order is numbered from its own series');
  perform app_test.assert_equals(
    (select count(*)::int from public.journal_entries where source_document_id = v_po), 0,
    'an order posts nothing');

  select id into v_line from public.purchase_order_lines where purchase_order_id = v_po;
  perform app_test.assert_raises(
    format($q$select public.post_goods_receipt(%L, %L::jsonb)$q$, v_po,
      jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'quantity', 1))),
    'goods are not received against an unapproved order', 'approved order');
  perform public.approve_purchase_order(v_po);

  -- ── Receive 6 of 10 ────────────────────────────────────────────────────
  v_grn := public.post_goods_receipt(v_po, jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'quantity', 6)),
    current_date, jsonb_build_object('supplier_challan_number', 'DC-771', 'transporter', 'VRL Logistics',
                                     'lr_number', 'LR-55012', 'vehicle_number', 'tn09ab1234', 'origin', 'Hosur',
                                     'origin_pincode', '635109'), 'grn-9zj');
  perform app_test.assert_equals(
    public.post_goods_receipt(v_po, jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'quantity', 6)),
      current_date, '{}'::jsonb, 'grn-9zj'), v_grn, 'a replayed receipt is the same receipt');
  select coalesce(sum(quantity), 0) into v_stock from public.inventory_stock where item_id = f.item_id;
  perform app_test.assert_equals(v_stock - v_stock0, 6::numeric, 'receiving 6 puts 6 in stock');
  perform app_test.assert_equals(
    (select vehicle_number || '|' || lr_number || '|' || origin_pincode from public.goods_receipts where id = v_grn),
    'TN09AB1234|LR-55012|635109', 'with the transport details kept on the receipt');
  select journal_entry_id into v_entry from public.goods_receipts where id = v_grn;
  perform app_test.assert_equals(
    (select credit from public.journal_entry_lines where journal_entry_id = v_entry and account_id = v_grni),
    2400::numeric, 'and GRNI credited 6 × ₹400');
  perform app_test.assert_equals((select status from public.purchase_orders where id = v_po), 'PARTIAL',
    'the order is partly received');
  perform app_test.assert_equals(
    (select pending from public.pending_purchase_orders() where po_line_id = v_line), 4::numeric,
    'and 4 remain pending');
  perform app_test.assert_raises(
    format($q$select public.post_goods_receipt(%L, %L::jsonb)$q$, v_po,
      jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'quantity', 5))),
    'receiving 5 when 4 are outstanding is refused', 'still to come');

  -- ── Bill the 6 at ₹410: GRNI cleared, ₹60 to price variance, no new stock
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date, created_by)
  values (app.current_dealer_id(), f.branch_id, f.supplier_id, 'POT/2026/881', current_date, auth.uid())
  returning id into v_bill;
  select id into v_grl from public.goods_receipt_lines where goods_receipt_id = v_grn;
  perform app_test.assert_raises(
    format($q$select public.add_receipt_lines_to_bill(%L, %L::jsonb)$q$, v_bill,
      jsonb_build_array(jsonb_build_object('grn_line_id', v_grl, 'quantity', 7))),
    'billing 7 of 6 received is refused', 'cannot be billed');
  perform public.add_receipt_lines_to_bill(v_bill,
    jsonb_build_array(jsonb_build_object('grn_line_id', v_grl, 'quantity', 6, 'unit_rate', 410)));
  v_entry := public.post_purchase_bill(v_bill);

  select coalesce(sum(quantity), 0) into v_stock from public.inventory_stock where item_id = f.item_id;
  perform app_test.assert_equals(v_stock - v_stock0, 6::numeric, 'the bill adds no stock — still 6');
  perform app_test.assert_equals(
    (select debit from public.journal_entry_lines where journal_entry_id = v_entry and account_id = v_grni),
    2400::numeric, 'the bill debits GRNI at the received value');
  perform app_test.assert_equals(
    (select debit from public.journal_entry_lines where journal_entry_id = v_entry and account_id = v_var),
    60::numeric, 'and the ₹10 a unit difference to price variance');
  perform app_test.assert_equals(
    (select credit from public.journal_entry_lines where journal_entry_id = v_entry and party_type = 'SUPPLIER'),
    3148.80::numeric, 'the supplier is owed ₹2,460 plus 28% GST');
  perform app_test.assert_equals(
    coalesce((select sum(value) from public.grni_outstanding() where grn_number = (select grn_number from public.goods_receipts where id = v_grn)), 0),
    0::numeric, 'nothing on that receipt is left unbilled');
  perform app_test.assert_equals(
    (select coalesce(sum(l.credit - l.debit), 0) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where l.account_id = v_grni and je.status in ('POSTED', 'REVERSED')),
    (select coalesce(sum(value), 0) from public.grni_outstanding()),
    'GRNI equals the value received and not billed');
  perform app_test.assert_equals(
    (select billed from public.pending_purchase_orders() where po_line_id = v_line), 6::numeric,
    'the order line shows 6 billed');

  -- A second bill for the same receipt line is refused at posting.
  insert into public.purchase_bills (dealer_id, branch_id, supplier_id, supplier_bill_number, bill_date, created_by)
  values (app.current_dealer_id(), f.branch_id, f.supplier_id, 'POT/2026/882', current_date, auth.uid())
  returning id into v_bill;
  perform app_test.assert_raises(
    format($q$select public.add_receipt_lines_to_bill(%L, %L::jsonb)$q$, v_bill,
      jsonb_build_array(jsonb_build_object('grn_line_id', v_grl, 'quantity', 1))),
    'a billed receipt line cannot be billed again', 'cannot be billed');
  delete from public.purchase_bills where id = v_bill;

  perform app_test.assert_raises(
    format($q$select public.cancel_goods_receipt(%L, 'Wrong goods')$q$, v_grn),
    'a billed receipt cannot be cancelled', 'supplier bill');

  -- ── Receive the last 4, then cancel that receipt ──────────────────────
  v_grn2 := public.post_goods_receipt(v_po, jsonb_build_array(jsonb_build_object('po_line_id', v_line, 'quantity', 4)));
  perform app_test.assert_equals((select status from public.purchase_orders where id = v_po), 'RECEIVED',
    'all 10 received');
  perform public.cancel_goods_receipt(v_grn2, 'Damaged in transit, returned to the carrier');
  select coalesce(sum(quantity), 0) into v_stock from public.inventory_stock where item_id = f.item_id;
  perform app_test.assert_equals(v_stock - v_stock0, 6::numeric, 'cancelling a receipt takes its stock back out');
  perform app_test.assert_equals((select status from public.purchase_orders where id = v_po), 'PARTIAL',
    'and the order is partly received again');
  perform app_test.assert_equals(
    (select coalesce(sum(l.credit - l.debit), 0) from public.journal_entry_lines l
       join public.journal_entries je on je.id = l.journal_entry_id
      where l.account_id = v_grni and je.status in ('POSTED', 'REVERSED')),
    (select coalesce(sum(value), 0) from public.grni_outstanding()),
    'GRNI still equals what is received and unbilled');

  perform app_test.assert_equals(public.close_purchase_order(v_po, 'Supplier short-shipped'), 'CLOSED',
    'a partly received order is closed, not cancelled');
  perform app_test.assert_equals(
    (select count(*)::int from public.pending_purchase_orders() where po_line_id = v_line), 0,
    'and drops off the pending list');

  perform app_test.assert_equals(
    (select sum(debit_balance) - sum(credit_balance) from public.trial_balance(current_date)), 0::numeric,
    'the trial balance nets to nil');
  insert into fixture_ids values ('po', v_po);
end $$;

reset role;
select app_test.logout();

-- ── The cashier ───────────────────────────────────────────────────────────
select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
declare f record;
begin
  select * into f from fixture_po;
  perform app_test.assert_raises(
    format($q$select public.create_purchase_order(%L, %L, %L::jsonb)$q$, f.branch_id, f.supplier_id,
      jsonb_build_array(jsonb_build_object('item_id', f.item_id, 'quantity', 1, 'unit_rate', 1))),
    'a cashier cannot raise a purchase order', 'may not');
  perform app_test.assert_raises(
    format($q$select public.post_goods_receipt(%L, '[]'::jsonb)$q$, (select id from fixture_ids where k = 'po')),
    'nor receive goods', 'may not');
end $$;
reset role;
select app_test.logout();
