-- =============================================================================
-- TEST — approvals, attachments, place of supply (0081)
-- =============================================================================
-- Checklist §02 general journal (approvals), §06 counts and exceptions
-- (approved), §03 source and attachments, §07 GSTIN and place of supply,
-- §11 test E (invalid B2B invoice).
-- =============================================================================

\echo '--- approvals, attachments, place of supply ---'

-- Approval switched on for the demo dealer (owner-level configuration).
update public.system_settings set value = 'true'::jsonb
 where dealer_id = (select id from public.dealers where code = 'SBM')
   and key in ('approvals.manual_journal', 'approvals.stock_adjustment');
insert into public.system_settings (dealer_id, key, value, value_type, description, is_public)
select d.id, k, 'true'::jsonb, 'boolean', 'test', true
  from public.dealers d cross join (values ('approvals.manual_journal'), ('approvals.stock_adjustment')) v(k)
 where d.code = 'SBM'
on conflict on constraint system_settings_scope_key do update set value = 'true'::jsonb;

select app_test.login('11111111-1111-4111-8111-111111111111');   -- owner: the maker
set role authenticated;

do $$
declare
  v_dealer  uuid := app.current_dealer_id();
  v_exp     uuid;
  v_pay     uuid;
  v_journals bigint;
  v_req     uuid;
  v_req2    uuid;
  v_item    uuid;
  v_branch  uuid;
begin
  select id into v_exp from public.chart_of_accounts where dealer_id = v_dealer and code = '5800';
  select id into v_pay from public.chart_of_accounts where dealer_id = v_dealer and code = '2700';
  select count(*) into v_journals from public.journal_entries;

  perform app_test.assert_raises(
    format($q$select public.post_manual_journal(current_date, 'Direct',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_exp, v_pay),
    'with approval switched on, a manual journal cannot be posted directly');

  v_req := public.request_manual_journal(current_date, 'Audit fee accrual for review',
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit', 4000, 'credit', 0),
      jsonb_build_object('account_id', v_pay, 'debit', 0, 'credit', 4000)),
    null, 'approval-test-1');

  perform app_test.assert_equals(
    (select status from public.approval_requests where id = v_req), 'PENDING',
    'it is submitted for approval instead');
  perform app_test.assert_equals((select count(*) from public.journal_entries), v_journals,
    'and nothing is posted, numbered or burned while it waits');
  perform app_test.assert_equals(
    public.request_manual_journal(current_date, 'Audit fee accrual for review',
      jsonb_build_array(
        jsonb_build_object('account_id', v_exp, 'debit', 4000, 'credit', 0),
        jsonb_build_object('account_id', v_pay, 'debit', 0, 'credit', 4000)),
      null, 'approval-test-1'),
    v_req, 'a resubmitted request is the same request');

  perform app_test.assert_raises(
    format($q$select public.request_manual_journal(current_date, 'Unbalanced',
      jsonb_build_array(
        jsonb_build_object('account_id', %L, 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 9)))$q$, v_exp, v_pay),
    'a request that could never post is refused at submission, not in the approver''s queue');
  perform app_test.assert_raises(
    format($q$select public.request_manual_journal(current_date, 'To a heading',
      jsonb_build_array(
        jsonb_build_object('account_id', (select id from public.chart_of_accounts where dealer_id = %L and code = '5000'), 'debit', 10, 'credit', 0),
        jsonb_build_object('account_id', %L, 'debit', 0, 'credit', 10)))$q$, v_dealer, v_pay),
    'including one naming a heading account');

  perform app_test.assert_raises(
    format('select public.decide_approval(%L, true)', v_req),
    'the person who submitted it cannot approve it');

  v_req2 := public.request_manual_journal(current_date, 'Second accrual',
    jsonb_build_array(
      jsonb_build_object('account_id', v_exp, 'debit', 100, 'credit', 0),
      jsonb_build_object('account_id', v_pay, 'debit', 0, 'credit', 100)));
  perform public.withdraw_approval(v_req2);
  perform app_test.assert_equals((select status from public.approval_requests where id = v_req2),
    'WITHDRAWN', 'the maker can withdraw a pending request');

  -- Stock adjustment by request.
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';
  select id into v_item from public.inventory_items where item_code = 'AC-HELM-01';
  perform app_test.assert_raises(
    format($q$select public.adjust_inventory_stock(%L, %L, 'COMPANY', -1, 'direct')$q$, v_item, v_branch),
    'with approval on, a stock adjustment cannot be posted directly');
  perform public.request_stock_adjustment(v_item, v_branch, 'COMPANY', -1, 'Cracked visor at count', 'approval-stock-1');
  perform app_test.assert_raises(
    format($q$select public.request_stock_adjustment(%L, %L, 'COMPANY', -999, 'too many')$q$, v_item, v_branch),
    'a stock request that would drive stock negative is refused at submission');

  perform app_test.assert_raises(
    format($q$update public.approval_requests set summary = 'changed' where id = %L$q$, v_req),
    'a request cannot be edited after submission');
end $$;

-- The checker.
select app_test.login('22222222-2222-4222-8222-222222222222');   -- accounts

do $$
declare
  v_req   uuid;
  v_entry uuid;
  v_stock uuid;
  v_qty   numeric;
begin
  select id into v_req from public.approval_requests where idempotency_key = 'approval-test-1';
  v_entry := public.decide_approval(v_req, true, 'Checked against the engagement letter');

  perform app_test.assert_equals(
    (select status from public.journal_entries where id = v_entry), 'POSTED',
    'a second person approves it, and the journal posts');
  perform app_test.assert_equals(
    (select result_id from public.approval_requests where id = v_req), v_entry,
    'the request records the journal it produced');
  perform app_test.assert_raises(
    format('select public.decide_approval(%L, true)', v_req),
    'a decided request cannot be decided again');

  select id into v_stock from public.approval_requests where idempotency_key = 'approval-stock-1';
  perform app_test.assert_raises(
    format('select public.decide_approval(%L, false, %L)', v_stock, ''),
    'a rejection needs a reason');

  select quantity into v_qty from public.inventory_stock s
    join public.inventory_items i on i.id = s.item_id
    join public.branches b on b.id = s.branch_id
   where i.item_code = 'AC-HELM-01' and b.code = 'MAIN' and s.source = 'COMPANY';
  perform public.decide_approval(v_stock, true, 'Seen the damaged unit');
  perform app_test.assert_equals(
    (select s.quantity from public.inventory_stock s
       join public.inventory_items i on i.id = s.item_id
       join public.branches b on b.id = s.branch_id
      where i.item_code = 'AC-HELM-01' and b.code = 'MAIN' and s.source = 'COMPANY'),
    v_qty - 1, 'an approved stock adjustment moves the stock');
  perform app_test.assert_equals(
    (select je.source_document_type from public.approval_requests r
       join public.journal_entries je on je.id = r.result_id where r.id = v_stock),
    'STOCK_ADJUSTMENT', 'and posts its journal');
end $$;

-- A cashier cannot approve at all.
select app_test.login('33333333-3333-4333-8333-333333333333');
do $$
begin
  perform app_test.assert_equals(
    (select count(*)::int from public.approval_requests where status = 'PENDING'
      and dealer_id = app.current_dealer_id() and kind = 'MANUAL_JOURNAL'), 0,
    'a cashier does not see the journal approval queue');
end $$;

reset role;

-- ═══ Attachments ═══════════════════════════════════════════════════════════════
select app_test.login('22222222-2222-4222-8222-222222222222');
set role authenticated;
do $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_entry  uuid;
  v_id     uuid;
begin
  select id into v_entry from public.journal_entries where dealer_id = v_dealer order by created_at desc limit 1;

  insert into public.document_attachments
    (dealer_id, entity_type, entity_id, storage_path, file_name, content_type, size_bytes, uploaded_by)
  values
    (v_dealer, 'JOURNAL_ENTRY', v_entry, v_dealer::text || '/JOURNAL_ENTRY/' || v_entry::text || '/letter.pdf',
     'letter.pdf', 'application/pdf', 20480, auth.uid())
  returning id into v_id;
  perform app_test.assert_equals(v_id is not null, true, 'a supporting file attaches to a journal');

  perform app_test.assert_raises(
    format($q$insert into public.document_attachments
      (dealer_id, entity_type, entity_id, storage_path, file_name, content_type, size_bytes, uploaded_by)
      values (%L, 'JOURNAL_ENTRY', %L, 'someone-else/x.pdf', 'x.pdf', 'application/pdf', 10, auth.uid())$q$,
      v_dealer, v_entry),
    'its storage path must sit in the dealer''s own folder');
  -- No delete policy: under RLS the delete simply finds nothing to remove.
  delete from public.document_attachments where id = v_id;
  perform app_test.assert_equals(
    (select count(*)::int from public.document_attachments where id = v_id), 1,
    'an attachment cannot be removed — it is evidence');
  reset role;
  perform app_test.assert_raises(
    format('delete from public.document_attachments where id = %L', v_id),
    'not even by the service role, which bypasses RLS: the trigger refuses');
  set role authenticated;
end $$;
reset role;

-- ═══ Place of supply ═══════════════════════════════════════════════════════════
select app_test.login('11111111-1111-4111-8111-111111111111');
set role authenticated;
do $$
declare
  v_dealer   uuid := app.current_dealer_id();
  v_branch   uuid;
  v_local    uuid;
  v_karnat   uuid;
  v_badgstin uuid;
  v_mismatch uuid;
  v_nostate  uuid;
  v_inv      uuid;
  r          record;
begin
  select id into v_branch from public.branches where dealer_id = v_dealer and code = 'MAIN';

  insert into public.customers (dealer_id, name, mobile, city, state, state_code, gstin)
  values (v_dealer, 'POS Local Traders', '9840055501', 'Chennai', 'Tamil Nadu', '33', '33AABCL1234K1Z7')
  returning id into v_local;
  insert into public.customers (dealer_id, name, mobile, city, state, state_code, gstin)
  values (v_dealer, 'POS Bengaluru Traders', '9840055502', 'Bengaluru', 'Karnataka', '29', '29AABCU9603R1ZM')
  returning id into v_karnat;
  -- A malformed GSTIN never reaches an invoice: the customer master refuses it.
  perform app_test.assert_raises(
    format($q$insert into public.customers (dealer_id, name, mobile, city, state, state_code, gstin)
      values (%L, 'POS Bad GSTIN', '9840055503', 'Chennai', 'Tamil Nadu', '33', '33ABC')$q$, v_dealer),
    'test E: a malformed recipient GSTIN is refused on the customer master');
  insert into public.customers (dealer_id, name, mobile, city, state, state_code, gstin)
  values (v_dealer, 'POS Mismatch', '9840055504', 'Chennai', 'Tamil Nadu', '33', '29AABCM1234M1Z2')
  returning id into v_mismatch;
  insert into public.customers (dealer_id, name, mobile, city, gstin)
  values (v_dealer, 'POS No State', '9840055505', 'Chennai', '33AABCN1234N1Z1')
  returning id into v_nostate;

  -- Intra-state: CGST + SGST.
  select invoice_id into v_inv from public.create_counter_invoice(v_branch, v_local);
  perform public.add_service_line(v_inv, 'LABOUR', 'Fitting', 1, 1000, null, 'GST18_ACC');
  select place_of_supply, cgst_amount, sgst_amount, igst_amount into r from public.service_invoices where id = v_inv;
  perform app_test.assert_equals(r.place_of_supply, '33', 'a Tamil Nadu customer: place of supply 33');
  perform app_test.assert_equals((r.cgst_amount, r.sgst_amount, r.igst_amount)::text, '(90.0000,90.0000,0.0000)',
    'and intra-state tax: CGST + SGST');
  perform public.post_service_invoice(v_inv);

  -- Inter-state: the same line becomes IGST at the combined rate.
  select invoice_id into v_inv from public.create_counter_invoice(v_branch, v_karnat);
  perform public.add_service_line(v_inv, 'LABOUR', 'Fitting', 1, 1000, null, 'GST18_ACC');
  select place_of_supply, cgst_amount, sgst_amount, igst_amount, total_amount into r
    from public.service_invoices where id = v_inv;
  perform app_test.assert_equals(r.place_of_supply, '29', 'a Karnataka customer: place of supply 29');
  perform app_test.assert_equals((r.cgst_amount, r.sgst_amount, r.igst_amount)::text, '(0.0000,0.0000,180.0000)',
    'inter-state: IGST 18%, not CGST + SGST');
  perform app_test.assert_equals(r.total_amount, 1180::numeric, 'at the same total');
  perform public.post_service_invoice(v_inv);
  perform app_test.assert_equals(
    (select sum(l.credit) from public.journal_entry_lines l
       join public.chart_of_accounts c on c.id = l.account_id
      where l.journal_entry_id = (select journal_entry_id from public.service_invoices where id = v_inv)
        and c.code = '2500'),
    180::numeric, 'and it posts to Output IGST');

  -- Test E: a B2B invoice the portal would refuse does not post.
  select invoice_id into v_inv from public.create_counter_invoice(v_branch, v_mismatch);
  perform public.add_service_line(v_inv, 'LABOUR', 'Fitting', 1, 1000, null, 'GST18_ACC');
  perform app_test.assert_raises(format('select public.post_service_invoice(%L)', v_inv),
    'a GSTIN registered in another state than the customer''s blocks posting');

  select invoice_id into v_inv from public.create_counter_invoice(v_branch, v_nostate);
  perform public.add_service_line(v_inv, 'LABOUR', 'Fitting', 1, 1000, null, 'GST18_ACC');
  perform app_test.assert_raises(format('select public.post_service_invoice(%L)', v_inv),
    'test E: a registered customer with no state (no place of supply) blocks posting');
end $$;
reset role;

-- Put the demo dealer back as other tests expect it.
update public.system_settings set value = 'false'::jsonb
 where dealer_id = (select id from public.dealers where code = 'SBM')
   and key in ('approvals.manual_journal', 'approvals.stock_adjustment');

select app_test.logout();
