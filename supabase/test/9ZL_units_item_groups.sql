-- =============================================================================
-- TEST — units, pack conversion, item groups (0094)
-- =============================================================================

\echo '--- units, conversions, item groups ---'

create temporary table fixture_units as
with d as (select id from public.dealers where code = 'SBM'),
     s as (insert into public.suppliers (dealer_id, name, supplier_type, mobile, city, state)
           select id, 'Unit Test Lubricants', 'OEM', '9840077401', 'Chennai', 'Tamil Nadu' from d returning id),
     i as (insert into public.inventory_items (dealer_id, item_code, name, item_type, uom, category, standard_cost, selling_price)
           select id, 'UT-BULB-01', 'Unit Test Bulb', 'SPARE', 'NOS', 'Electricals', 90, 150 from d returning id)
select (select id from s) as supplier_id, (select id from i) as item_id,
       (select b.id from public.branches b join d on b.dealer_id = d.id where b.code = 'MAIN') as branch_id;
grant select on fixture_units to authenticated;

do $$
begin
  perform app_test.assert_raises(
    $q$insert into public.inventory_items (dealer_id, item_code, name, item_type, uom)
       select id, 'UT-BAD-01', 'Bad unit', 'SPARE', 'CRATE' from public.dealers where code = 'SBM'$q$,
    'an item cannot use a unit that is not in the units master', 'inventory_items_uom_fkey');
  perform app_test.assert_equals((select gst_uqc from public.units where code = 'PAIR'), 'PRS',
    'each unit carries its GST unit quantity code');
end $$;

select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;

do $$
declare
  f       record;
  v_po    uuid;
  v_line  record;
  v_stock numeric;
  v_grp   uuid;
begin
  select * into f from fixture_units;

  -- ── Pack conversion ────────────────────────────────────────────────────
  perform app_test.assert_raises(
    format($q$select public.create_purchase_order(%L, %L, %L::jsonb)$q$, f.branch_id, f.supplier_id,
      jsonb_build_array(jsonb_build_object('item_id', f.item_id, 'unit', 'BOX', 'quantity', 2, 'unit_rate', 1200))),
    'ordering in boxes before the conversion is set is refused', 'No conversion');
  insert into public.item_unit_conversions (dealer_id, item_id, unit_code, factor)
  values (app.current_dealer_id(), f.item_id, 'BOX', 12);
  perform app_test.assert_raises(
    format($q$insert into public.item_unit_conversions (dealer_id, item_id, unit_code, factor) values (%L, %L, 'NOS', 1)$q$,
      app.current_dealer_id(), f.item_id),
    'the base unit is not a conversion', 'own unit');

  v_po := public.create_purchase_order(f.branch_id, f.supplier_id,
    jsonb_build_array(jsonb_build_object('item_id', f.item_id, 'unit', 'BOX', 'quantity', 2, 'unit_rate', 1200)));
  select * into v_line from public.purchase_order_lines where purchase_order_id = v_po;
  perform app_test.assert_equals(v_line.quantity::text || '|' || v_line.unit_rate::text, '24.000|100.0000',
    '2 boxes of 12 at ₹1,200 a box is 24 bulbs at ₹100');
  perform app_test.assert_equals(v_line.entry_unit || '|' || v_line.entry_quantity::text, 'BOX|2.000',
    'with what was ordered kept beside it');

  perform public.approve_purchase_order(v_po);
  perform public.post_goods_receipt(v_po, jsonb_build_array(jsonb_build_object('po_line_id', v_line.id, 'quantity', 24)));
  select coalesce(sum(quantity), 0) into v_stock from public.inventory_stock where item_id = f.item_id;
  perform app_test.assert_equals(v_stock, 24::numeric, 'receiving them puts 24 bulbs in stock');
  perform app_test.assert_equals(
    (select round(stock_value / nullif(quantity, 0), 2) from public.inventory_stock where item_id = f.item_id), 100::numeric,
    'at ₹100 each');

  -- ── Item groups ────────────────────────────────────────────────────────
  insert into public.item_groups (dealer_id, name) values (app.current_dealer_id(), 'Lighting') returning id into v_grp;
  insert into public.item_groups (dealer_id, name, parent_id) values (app.current_dealer_id(), 'Bulbs', v_grp);
  update public.inventory_items set item_group_id = (select id from public.item_groups where name = 'Bulbs' and dealer_id = app.current_dealer_id())
   where id = f.item_id;
  perform app_test.assert_equals(
    (select p.name from public.inventory_items i join public.item_groups g on g.id = i.item_group_id
       join public.item_groups p on p.id = g.parent_id where i.id = f.item_id), 'Lighting',
    'an item sits in a group, which sits in its parent');
end $$;

reset role;
select app_test.logout();

do $$
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.inventory_items where category is not null and length(btrim(category)) >= 2
        and item_group_id is null and created_at < (select min(created_at) from public.item_groups)), 0,
    'every item that had a category when groups arrived was put in that group');
end $$;

select app_test.login('33333333-3333-4333-8333-333333333333');
set role authenticated;
do $$
begin
  perform app_test.assert_raises(
    $q$insert into public.item_groups (dealer_id, name) values (app.current_dealer_id(), 'Cashier group')$q$,
    'a cashier cannot add item groups');
end $$;
reset role;
select app_test.logout();
