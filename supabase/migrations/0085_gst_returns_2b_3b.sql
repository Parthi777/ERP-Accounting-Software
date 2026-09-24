-- =============================================================================
-- 0085 — GST returns: GSTR-2B matching, ITC claims, GSTR-3B, cross-checks,
--        filing evidence
-- =============================================================================
-- Spec §40, §41, §46. Audit checklist §08 (input tax, 2B), §09 (returns:
-- GSTR-1, GSTR-3B, reconciliation, filing evidence; Tests C and D).
--
-- The product computed GSTR-1 style figures and stopped there. Nothing said
-- what had actually been filed, whether the ITC in the books had reached the
-- supplier-side statement (GSTR-2B), how much of it could be claimed, what the
-- 3B came to after set-off, or whether GSTR-1, GSTR-3B and the ledger agreed.
--
-- ── Outward documents ──────────────────────────────────────────────────────
--
-- app.gst_outward_documents() is the one list the returns read: sales,
-- service and counter invoices, credit/debit notes to customers (signed), and
-- branch-transfer tax invoices between two GSTINs (a supply from the sending
-- GSTIN). gstr1_summary() and gst_document_register() now read it too, so
-- transfer invoices reach GSTR-1. Every return is per GSTIN: a branch files
-- under its own GSTIN, or the dealer's when it has none.
--
-- ── GSTR-2B ────────────────────────────────────────────────────────────────
--
-- A month's 2B is imported as lines (supplier GSTIN, document number, date,
-- values) and matched to posted purchase bills and supplier notes by supplier
-- GSTIN and normalised document number. Each 2B line is MATCHED,
-- VALUE_MISMATCH, NOT_IN_BOOKS or NOT_CLAIMABLE (the books say the credit is
-- blocked or personal, so it is never claimed automatically, 2B or not); each
-- bill of the month the 2B does not carry is NOT_IN_2B. A re-import supersedes
-- the earlier one.
--
-- ── ITC claim controls (rule 36(4)) ────────────────────────────────────────
--
-- Credit on a bill is claimable in 3B only once the bill is in a 2B, and then
-- at the lower of the books and the 2B, head by head. Reverse-charge credit
-- needs no 2B (the dealer paid it). Supplier credit notes reduce the claim
-- whether or not they are in 2B. When a 3B is filed, what it claimed is written
-- to itc_claim_lines, so nothing is claimed twice.
--
-- ── GSTR-3B ────────────────────────────────────────────────────────────────
--
-- gstr3b_working() lays out 3.1, 4 and 5; gstr3b_setoff() applies the credit
-- in the order rule 88A requires (IGST first — against IGST, then CGST, then
-- SGST; then CGST against CGST then IGST; SGST against SGST then IGST; CGST and
-- SGST never cross) and gives the cash payable per head. Reverse-charge tax is
-- always paid in cash. post_gst_setoff() posts the result once filed.
--
-- ── Filing and evidence ────────────────────────────────────────────────────
--
-- gst_returns records each return: PREPARED (a snapshot of the system's
-- figures), SIGNED_OFF (by someone other than the preparer), FILED (ARN, date,
-- the figures actually filed, challan). A filed return is permanent; GSTR-1's
-- documents are frozen with it, and gstr1_amendments() later lists any that
-- changed, were cancelled or were missed — the next GSTR-1's amendments.
-- gst_cross_checks() compares GSTR-1, GSTR-3B, 2B and the ledger and flags any
-- difference; the filed return and its challan attach as 'GST_FILING'.
--
-- Rollback: drop the tables and functions created here; restore gstr1_summary
--           and gst_document_register from 0084.
-- =============================================================================

insert into public.permissions (code, module, description, is_sensitive) values
  ('gst.returns.prepare', 'gst', 'Import GSTR-2B and prepare GST returns', false),
  ('gst.returns.file',    'gst', 'Sign off and record the filing of GST returns', false)
on conflict (code) do update set module = excluded.module, description = excluded.description,
                                 is_sensitive = excluded.is_sensitive;

insert into public.role_permissions (role_id, permission_code)
select r.id, p.code
  from public.roles r
  cross join (values ('gst.returns.prepare'), ('gst.returns.file')) as p(code)
 where r.is_system and r.code in ('DEALER_OWNER', 'ACCOUNTS')
on conflict do nothing;

-- The GSTIN a branch files under.
create or replace function app.branch_gstin(p_branch_id uuid)
returns text
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select coalesce(nullif(btrim(b.gstin), ''), nullif(btrim(d.gstin), ''))
    from public.branches b join public.dealers d on d.id = b.dealer_id
   where b.id = p_branch_id;
$$;

create or replace function app.norm_doc_no(p text)
returns text
language sql
immutable
as $$
  select nullif(ltrim(upper(regexp_replace(coalesce(p, ''), '[^A-Za-z0-9]', '', 'g')), '0'), '');
$$;

create or replace function app.month_end(p_period date)
returns date
language sql
immutable
as $$
  select (date_trunc('month', p_period) + interval '1 month - 1 day')::date;
$$;

-- -----------------------------------------------------------------------------
-- app.gst_outward_documents()
-- -----------------------------------------------------------------------------
create or replace function app.gst_outward_documents(p_from date, p_to date, p_gstin text default null)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  branch_id       uuid,
  party_name      text,
  party_gstin     text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  total_amount    numeric(18, 4)
)
language sql
stable
as $$
  with docs as (
    select 'SALE'::text as dtype, s.id, s.invoice_number as num, s.invoice_date as ddate, s.branch_id as br,
           coalesce(c.name, 'Cash customer') as pname, nullif(btrim(coalesce(c.gstin, '')), '') as pgstin,
           coalesce(s.place_of_supply, c.state_code) as pos,
           s.taxable_value as tv, s.cgst_amount as cg, s.sgst_amount as sg, s.igst_amount as ig, s.total_amount as tot,
           false as is_note
      from public.sales s
      left join public.customers c on c.id = s.customer_id
     where s.dealer_id = app.current_dealer_id()
       and s.status in ('POSTED', 'DELIVERED') and s.invoice_date between p_from and p_to
    union all
    select 'SERVICE_INVOICE', si.id, si.invoice_number, si.invoice_date, si.branch_id,
           coalesce(c.name, 'Counter sale'), nullif(btrim(coalesce(c.gstin, '')), ''),
           coalesce(si.place_of_supply, c.state_code),
           si.taxable_value, si.cgst_amount, si.sgst_amount, si.igst_amount, si.total_amount, false
      from public.service_invoices si
      left join public.customers c on c.id = si.customer_id
     where si.dealer_id = app.current_dealer_id()
       and si.status = 'POSTED' and si.invoice_date between p_from and p_to
    union all
    select n.note_type || '_NOTE', n.id, n.note_number, n.note_date, n.branch_id,
           c.name, nullif(btrim(coalesce(c.gstin, '')), ''), c.state_code,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.taxable_value,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
           case when n.note_type = 'CREDIT' then -1 else 1 end * n.total_amount, true
      from public.gst_notes n
      join public.customers c on c.id = n.customer_id
     where n.dealer_id = app.current_dealer_id()
       and n.party_type = 'CUSTOMER' and n.status = 'POSTED' and n.note_date between p_from and p_to
    union all
    -- A transfer between two GSTINs is a supply by the sending one.
    select 'TRANSFER_INVOICE', t.id, t.note_number, t.note_date, t.from_branch_id,
           b.name, t.to_gstin, left(t.to_gstin, 2),
           t.taxable_value, t.cgst_amount, t.sgst_amount, t.igst_amount,
           t.taxable_value + t.cgst_amount + t.sgst_amount + t.igst_amount, false
      from public.branch_transfer_notes t
      join public.branches b on b.id = t.to_branch_id
     where t.dealer_id = app.current_dealer_id()
       and t.note_kind = 'TAX_INVOICE' and t.note_date between p_from and p_to
  )
  select d.dtype, d.id, d.num, d.ddate, d.br, d.pname, d.pgstin, d.pos,
         case when d.is_note then (case when d.pgstin is not null then 'CDNR' else 'CDNUR' end)
              when d.pgstin is not null then 'B2B' else 'B2C' end,
         d.tv, d.cg, d.sg, d.ig, d.tot
    from docs d
   where p_gstin is null or app.branch_gstin(d.br) = p_gstin;
$$;

create or replace function public.gstr1_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  section        text,
  document_count bigint,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  invoice_value  numeric(18, 4)
)
language sql
stable
as $$
  select d.section, count(*), sum(d.taxable_value), sum(d.cgst_amount), sum(d.sgst_amount),
         sum(d.igst_amount), sum(d.cgst_amount + d.sgst_amount + d.igst_amount), sum(d.total_amount)
    from app.gst_outward_documents(p_from, p_to) d
   where p_branch_id is null or d.branch_id = p_branch_id
   group by d.section
   order by d.section;
$$;

create or replace function public.gst_document_register(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null,
  p_section   text default null
)
returns table (
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  customer_name   text,
  gstin           text,
  place_of_supply text,
  section         text,
  taxable_value   numeric(18, 4),
  cgst_amount     numeric(18, 4),
  sgst_amount     numeric(18, 4),
  igst_amount     numeric(18, 4),
  invoice_value   numeric(18, 4),
  einvoice_status text,
  irn             text
)
language sql
stable
as $$
  select d.document_type, d.document_id, d.document_number, d.document_date, d.party_name,
         d.party_gstin, d.place_of_supply, d.section,
         d.taxable_value, d.cgst_amount, d.sgst_amount, d.igst_amount, d.total_amount,
         coalesce(e.status, 'NOT_REQUESTED'), e.irn
    from app.gst_outward_documents(p_from, p_to) d
    left join public.einvoices e on e.document_type = d.document_type and e.document_id = d.document_id
   where (p_branch_id is null or d.branch_id = p_branch_id)
     and (p_section is null or p_section = d.section)
   order by d.document_date, d.document_number;
$$;

-- -----------------------------------------------------------------------------
-- gst_returns — what was prepared, signed off and filed
-- -----------------------------------------------------------------------------
create table public.gst_returns (
  id               uuid primary key default gen_random_uuid(),
  dealer_id        uuid not null references public.dealers (id) on delete restrict,
  gstin            text not null,
  return_type      text not null,
  period           date not null,
  status           text not null default 'PREPARED',
  computed         jsonb not null,
  prepared_by      uuid,
  prepared_at      timestamptz not null default now(),
  signed_off_by    uuid,
  signed_off_at    timestamptz,
  -- As filed on the portal. For GSTR-1 the output figures; for GSTR-3B also
  -- the credit claimed.
  filed_taxable    numeric(18, 4),
  filed_igst       numeric(18, 4),
  filed_cgst       numeric(18, 4),
  filed_sgst       numeric(18, 4),
  filed_itc_igst   numeric(18, 4),
  filed_itc_cgst   numeric(18, 4),
  filed_itc_sgst   numeric(18, 4),
  arn              text,
  filed_on         date,
  filed_by         uuid,
  filed_at         timestamptz,
  challan_cpin     text,
  challan_cin      text,
  challan_amount   numeric(18, 4),
  setoff_journal_id uuid,
  notes            text,

  constraint gst_returns_scope_key unique (dealer_id, gstin, return_type, period),
  constraint gst_returns_journal_tenant_fkey
    foreign key (setoff_journal_id, dealer_id) references public.journal_entries (id, dealer_id),
  constraint gst_returns_type_check   check (return_type in ('GSTR1', 'GSTR3B')),
  constraint gst_returns_status_check check (status in ('PREPARED', 'SIGNED_OFF', 'FILED')),
  constraint gst_returns_period_check check (period = date_trunc('month', period)::date),
  constraint gst_returns_gstin_check  check (gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'),
  constraint gst_returns_filed_check  check (
    status <> 'FILED' or (arn is not null and filed_on is not null and signed_off_by is not null)),
  constraint gst_returns_arn_check    check (arn is null or length(btrim(arn)) between 5 and 30),
  -- Maker and checker are different people.
  constraint gst_returns_four_eyes_check check (signed_off_by is null or signed_off_by <> prepared_by)
);

comment on table public.gst_returns is
  'GST returns per GSTIN and month: the system''s figures when prepared, who '
  'signed off, and what was filed (ARN, figures, challan). A filed return is '
  'permanent; its evidence attaches as GST_FILING.';

create or replace function app.gst_returns_guard()
returns trigger
language plpgsql
as $$
begin
  if tg_op = 'DELETE' then
    if old.status = 'FILED' then
      raise exception 'A filed return cannot be deleted.' using errcode = 'insufficient_privilege';
    end if;
    return old;
  end if;
  if old.status = 'FILED'
     and (to_jsonb(new) - 'setoff_journal_id') is distinct from (to_jsonb(old) - 'setoff_journal_id') then
    raise exception 'The % for % is filed and cannot be changed.', old.return_type, to_char(old.period, 'Mon YYYY')
      using errcode = 'insufficient_privilege';
  end if;
  if old.setoff_journal_id is not null and new.setoff_journal_id is distinct from old.setoff_journal_id then
    raise exception 'The set-off of this return is already posted.' using errcode = 'insufficient_privilege';
  end if;
  return new;
end;
$$;

create trigger gst_returns_guard
  before update or delete on public.gst_returns
  for each row execute function app.gst_returns_guard();
create trigger gst_returns_audit after insert or update or delete on public.gst_returns
  for each row execute function app.audit_trigger();

-- The documents a filed GSTR-1 reported, as they stood.
create table public.gst_filed_documents (
  id              uuid primary key default gen_random_uuid(),
  return_id       uuid not null references public.gst_returns (id) on delete restrict,
  dealer_id       uuid not null,
  document_type   text not null,
  document_id     uuid not null,
  document_number text not null,
  document_date   date not null,
  party_gstin     text,
  place_of_supply text,
  section         text not null,
  taxable_value   numeric(18, 4) not null,
  cgst_amount     numeric(18, 4) not null,
  sgst_amount     numeric(18, 4) not null,
  igst_amount     numeric(18, 4) not null,
  total_amount    numeric(18, 4) not null,
  constraint gfd_return_document_key unique (return_id, document_type, document_id)
);
create index gfd_document_idx on public.gst_filed_documents (document_id);

-- -----------------------------------------------------------------------------
-- GSTR-2B
-- -----------------------------------------------------------------------------
create table public.gstr2b_imports (
  id          uuid primary key default gen_random_uuid(),
  dealer_id   uuid not null references public.dealers (id) on delete restrict,
  gstin       text not null,
  period      date not null,
  file_name   text,
  line_count  integer not null default 0,
  status      text not null default 'ACTIVE',
  imported_by uuid,
  imported_at timestamptz not null default now(),
  constraint gstr2b_imports_status_check check (status in ('ACTIVE', 'SUPERSEDED')),
  constraint gstr2b_imports_period_check check (period = date_trunc('month', period)::date),
  constraint gstr2b_imports_id_dealer_key unique (id, dealer_id)
);
create unique index gstr2b_imports_active_key
  on public.gstr2b_imports (dealer_id, gstin, period) where status = 'ACTIVE';

create table public.gstr2b_lines (
  id               uuid primary key default gen_random_uuid(),
  import_id        uuid not null,
  dealer_id        uuid not null,
  supplier_gstin   text not null,
  supplier_name    text,
  document_type    text not null default 'INVOICE',
  document_number  text not null,
  document_date    date,
  taxable_value    numeric(18, 4) not null default 0,
  igst_amount      numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  cess_amount      numeric(18, 4) not null default 0,
  itc_available    boolean not null default true,
  reverse_charge   boolean not null default false,
  match_status     text not null default 'NOT_IN_BOOKS',
  matched_bill_id  uuid,
  matched_note_id  uuid,
  books_taxable    numeric(18, 4),
  books_tax        numeric(18, 4),
  constraint gstr2b_lines_import_fkey
    foreign key (import_id, dealer_id) references public.gstr2b_imports (id, dealer_id) on delete restrict,
  constraint gstr2b_lines_type_check   check (document_type in ('INVOICE', 'CREDIT_NOTE', 'DEBIT_NOTE')),
  constraint gstr2b_lines_status_check check (match_status in ('MATCHED', 'VALUE_MISMATCH', 'NOT_IN_BOOKS', 'NOT_CLAIMABLE')),
  constraint gstr2b_lines_gstin_check  check (supplier_gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'),
  constraint gstr2b_lines_amounts_check check (
    taxable_value >= 0 and igst_amount >= 0 and cgst_amount >= 0 and sgst_amount >= 0 and cess_amount >= 0)
);
create index gstr2b_lines_import_idx on public.gstr2b_lines (import_id);
create index gstr2b_lines_bill_idx on public.gstr2b_lines (matched_bill_id) where matched_bill_id is not null;

-- What a filed 3B claimed, document by document, so no credit is taken twice.
create table public.itc_claim_lines (
  id               uuid primary key default gen_random_uuid(),
  return_id        uuid not null references public.gst_returns (id) on delete restrict,
  dealer_id        uuid not null,
  claim_kind       text not null,
  purchase_bill_id uuid,
  gst_note_id      uuid,
  igst_amount      numeric(18, 4) not null default 0,
  cgst_amount      numeric(18, 4) not null default 0,
  sgst_amount      numeric(18, 4) not null default 0,
  constraint itc_claim_kind_check check (claim_kind in ('INVOICE', 'RCM', 'CREDIT_NOTE', 'DEBIT_NOTE')),
  constraint itc_claim_doc_check check ((purchase_bill_id is null) <> (gst_note_id is null))
);
create unique index itc_claim_bill_key on public.itc_claim_lines (purchase_bill_id, claim_kind) where purchase_bill_id is not null;
create unique index itc_claim_note_key on public.itc_claim_lines (gst_note_id) where gst_note_id is not null;

-- Evidence tables are append-only.
create or replace function app.gst_evidence_append_only()
returns trigger
language plpgsql
as $$
begin
  raise exception 'Filed return evidence is permanent.' using errcode = 'insufficient_privilege';
end;
$$;
create trigger gst_filed_documents_append_only before update or delete on public.gst_filed_documents
  for each row execute function app.gst_evidence_append_only();
create trigger itc_claim_lines_append_only before update or delete on public.itc_claim_lines
  for each row execute function app.gst_evidence_append_only();

alter table public.gst_returns enable row level security;
alter table public.gst_filed_documents enable row level security;
alter table public.gstr2b_imports enable row level security;
alter table public.gstr2b_lines enable row level security;
alter table public.itc_claim_lines enable row level security;

create policy gst_returns_select on public.gst_returns for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gst_returns_write on public.gst_returns for all to authenticated
  using (dealer_id = app.current_dealer_id()
         and (app.has_permission('gst.returns.prepare') or app.has_permission('gst.returns.file')))
  with check (dealer_id = app.current_dealer_id()
              and (app.has_permission('gst.returns.prepare') or app.has_permission('gst.returns.file')));
create policy gfd_select on public.gst_filed_documents for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gfd_insert on public.gst_filed_documents for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.file'));
create policy gstr2b_imports_select on public.gstr2b_imports for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gstr2b_imports_write on public.gstr2b_imports for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'));
create policy gstr2b_lines_select on public.gstr2b_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy gstr2b_lines_write on public.gstr2b_lines for all to authenticated
  using (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'))
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.prepare'));
create policy itc_claim_select on public.itc_claim_lines for select to authenticated
  using (app.is_platform_admin() or (dealer_id = app.current_dealer_id() and app.has_permission('gst.reports.view')));
create policy itc_claim_insert on public.itc_claim_lines for insert to authenticated
  with check (dealer_id = app.current_dealer_id() and app.has_permission('gst.returns.file'));

-- -----------------------------------------------------------------------------
-- 2B import and matching
-- -----------------------------------------------------------------------------
create or replace function public.match_gstr2b(p_import_id uuid)
returns table (match_status text, line_count bigint)
language plpgsql
as $$
declare
  v_imp  public.gstr2b_imports;
  l      record;
  v_bill record;
  v_note record;
begin
  select * into v_imp from public.gstr2b_imports
   where id = p_import_id and dealer_id = app.current_dealer_id();
  if v_imp.id is null then
    raise exception 'GSTR-2B import not found.' using errcode = 'no_data_found';
  end if;

  update public.gstr2b_lines
     set match_status = 'NOT_IN_BOOKS', matched_bill_id = null, matched_note_id = null,
         books_taxable = null, books_tax = null
   where import_id = p_import_id;

  for l in select * from public.gstr2b_lines where import_id = p_import_id order by document_date, document_number loop
    if l.document_type in ('INVOICE') then
      select b.id, b.taxable_value, b.cgst_amount + b.sgst_amount + b.igst_amount as tax,
             exists (select 1 from public.purchase_bill_lines pl
                      where pl.purchase_bill_id = b.id and pl.itc_eligible
                        and pl.cgst_amount + pl.sgst_amount + pl.igst_amount > 0) as claimable
        into v_bill
        from public.purchase_bills b
        join public.suppliers s on s.id = b.supplier_id
       where b.dealer_id = v_imp.dealer_id and b.status = 'POSTED'
         and upper(btrim(s.gstin)) = l.supplier_gstin
         and app.norm_doc_no(b.supplier_bill_number) = app.norm_doc_no(l.document_number)
         -- One bill, one 2B line: a bill already matched in this or another live import is taken.
         and not exists (select 1 from public.gstr2b_lines x
                           join public.gstr2b_imports xi on xi.id = x.import_id and xi.status = 'ACTIVE'
                          where x.matched_bill_id = b.id and x.id <> l.id)
       order by b.bill_date desc
       limit 1;

      if v_bill.id is not null then
        update public.gstr2b_lines
           set matched_bill_id = v_bill.id, books_taxable = v_bill.taxable_value, books_tax = v_bill.tax,
               match_status = case
                 when not v_bill.claimable then 'NOT_CLAIMABLE'
                 when abs(v_bill.taxable_value - l.taxable_value) <= 1
                  and abs(v_bill.tax - (l.igst_amount + l.cgst_amount + l.sgst_amount)) <= 1 then 'MATCHED'
                 else 'VALUE_MISMATCH' end
         where id = l.id;
      end if;
    else
      select n.id, n.taxable_value, n.cgst_amount + n.sgst_amount + n.igst_amount as tax, n.itc_eligible
        into v_note
        from public.gst_notes n
        join public.suppliers s on s.id = n.supplier_id
       where n.dealer_id = v_imp.dealer_id and n.party_type = 'SUPPLIER' and n.status = 'POSTED'
         and n.note_type = case when l.document_type = 'CREDIT_NOTE' then 'CREDIT' else 'DEBIT' end
         and upper(btrim(s.gstin)) = l.supplier_gstin
         and app.norm_doc_no(n.party_note_number) = app.norm_doc_no(l.document_number)
       limit 1;
      if v_note.id is not null then
        update public.gstr2b_lines
           set matched_note_id = v_note.id, books_taxable = v_note.taxable_value, books_tax = v_note.tax,
               match_status = case
                 when not v_note.itc_eligible then 'NOT_CLAIMABLE'
                 when abs(v_note.taxable_value - l.taxable_value) <= 1
                  and abs(v_note.tax - (l.igst_amount + l.cgst_amount + l.sgst_amount)) <= 1 then 'MATCHED'
                 else 'VALUE_MISMATCH' end
         where id = l.id;
      end if;
    end if;
  end loop;

  return query
    select g.match_status, count(*) from public.gstr2b_lines g
     where g.import_id = p_import_id group by g.match_status order by 1;
end;
$$;

create or replace function public.import_gstr2b(
  p_gstin     text,
  p_period    date,
  p_lines     jsonb,
  p_file_name text default null
)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_id     uuid;
  v_count  integer;
  v_period date := date_trunc('month', p_period)::date;
  v_bad    record;
begin
  if v_dealer is null or not app.has_permission('gst.returns.prepare') then
    raise exception 'You do not have permission to import GSTR-2B.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches b where b.dealer_id = v_dealer and app.branch_gstin(b.id) = p_gstin) then
    raise exception 'GSTIN % is not one of yours.', p_gstin using errcode = 'check_violation';
  end if;
  if jsonb_typeof(p_lines) <> 'array' or jsonb_array_length(p_lines) = 0 then
    raise exception 'The GSTR-2B file has no lines.' using errcode = 'check_violation';
  end if;

  -- Validate before writing anything: no partial import (spec §14).
  select e.ordinality as n, e.value->>'supplier_gstin' as g, e.value->>'document_number' as d
    into v_bad
    from jsonb_array_elements(p_lines) with ordinality e
   where upper(btrim(coalesce(e.value->>'supplier_gstin', ''))) !~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][0-9A-Z]Z[0-9A-Z]$'
      or coalesce(btrim(e.value->>'document_number'), '') = ''
   limit 1;
  if v_bad.n is not null then
    raise exception 'Line % of the 2B file is not usable: supplier GSTIN "%" / document "%".', v_bad.n, v_bad.g, v_bad.d
      using errcode = 'check_violation';
  end if;

  update public.gstr2b_imports set status = 'SUPERSEDED'
   where dealer_id = v_dealer and gstin = p_gstin and period = v_period and status = 'ACTIVE';

  insert into public.gstr2b_imports (dealer_id, gstin, period, file_name, imported_by)
  values (v_dealer, p_gstin, v_period, p_file_name, auth.uid())
  returning id into v_id;

  insert into public.gstr2b_lines
    (import_id, dealer_id, supplier_gstin, supplier_name, document_type, document_number, document_date,
     taxable_value, igst_amount, cgst_amount, sgst_amount, cess_amount, itc_available, reverse_charge)
  select v_id, v_dealer, upper(btrim(e->>'supplier_gstin')), nullif(btrim(e->>'supplier_name'), ''),
         coalesce(nullif(upper(btrim(e->>'document_type')), ''), 'INVOICE'), btrim(e->>'document_number'),
         nullif(e->>'document_date', '')::date,
         coalesce(nullif(e->>'taxable_value', '')::numeric, 0), coalesce(nullif(e->>'igst', '')::numeric, 0),
         coalesce(nullif(e->>'cgst', '')::numeric, 0), coalesce(nullif(e->>'sgst', '')::numeric, 0),
         coalesce(nullif(e->>'cess', '')::numeric, 0),
         coalesce(nullif(e->>'itc_available', '')::boolean, true),
         coalesce(nullif(e->>'reverse_charge', '')::boolean, false)
    from jsonb_array_elements(p_lines) e;
  get diagnostics v_count = row_count;
  update public.gstr2b_imports set line_count = v_count where id = v_id;

  perform public.match_gstr2b(v_id);
  return v_id;
end;
$$;

-- Both sides of the 2B: every 2B line with its status, and every bill of the
-- month in the books that the 2B does not carry.
create or replace function public.gstr2b_reconciliation(p_import_id uuid)
returns table (
  side             text,
  match_status     text,
  supplier_gstin   text,
  supplier_name    text,
  document_number  text,
  document_date    date,
  taxable_2b       numeric(18, 4),
  tax_2b           numeric(18, 4),
  taxable_books    numeric(18, 4),
  tax_books        numeric(18, 4),
  difference       numeric(18, 4),
  purchase_bill_id uuid,
  line_id          uuid
)
language sql
stable
as $$
  with imp as (
    select * from public.gstr2b_imports where id = p_import_id and dealer_id = app.current_dealer_id()
  )
  select '2B', g.match_status, g.supplier_gstin, g.supplier_name, g.document_number, g.document_date,
         g.taxable_value, g.igst_amount + g.cgst_amount + g.sgst_amount, g.books_taxable, g.books_tax,
         coalesce(g.books_tax, 0) - (g.igst_amount + g.cgst_amount + g.sgst_amount),
         g.matched_bill_id, g.id
    from public.gstr2b_lines g join imp on imp.id = g.import_id
  union all
  select 'BOOKS', 'NOT_IN_2B', upper(btrim(s.gstin)), s.name, b.supplier_bill_number, b.bill_date,
         null, null, b.taxable_value, b.cgst_amount + b.sgst_amount + b.igst_amount,
         b.cgst_amount + b.sgst_amount + b.igst_amount, b.id, null
    from public.purchase_bills b
    join public.suppliers s on s.id = b.supplier_id
    join imp on true
   where b.dealer_id = imp.dealer_id and b.status = 'POSTED'
     and b.bill_date between imp.period and app.month_end(imp.period)
     and app.branch_gstin(b.branch_id) = imp.gstin
     and nullif(btrim(coalesce(s.gstin, '')), '') is not null
     and b.cgst_amount + b.sgst_amount + b.igst_amount > 0
     and not exists (select 1 from public.gstr2b_lines x
                       join public.gstr2b_imports xi on xi.id = x.import_id and xi.status = 'ACTIVE'
                      where x.matched_bill_id = b.id)
   order by 1, 6, 5;
$$;

-- -----------------------------------------------------------------------------
-- ITC claim controls
-- -----------------------------------------------------------------------------
-- Every document whose credit is open for this GSTIN up to a month's end:
-- claimable now, or held back and why.
create or replace function public.itc_claimable(p_gstin text, p_period date)
returns table (
  claim_kind       text,
  purchase_bill_id uuid,
  gst_note_id      uuid,
  document_number  text,
  document_date    date,
  supplier_name    text,
  igst_amount      numeric(18, 4),
  cgst_amount      numeric(18, 4),
  sgst_amount      numeric(18, 4),
  claimable        boolean,
  reason           text
)
language sql
stable
as $$
  with bills as (
    select b.id, b.bill_number, b.bill_date, s.name as supplier,
           sum(l.igst_amount) filter (where l.itc_eligible and not l.reverse_charge) as ig,
           sum(l.cgst_amount) filter (where l.itc_eligible and not l.reverse_charge) as cg,
           sum(l.sgst_amount) filter (where l.itc_eligible and not l.reverse_charge) as sg,
           sum(l.igst_amount) filter (where l.itc_eligible and l.reverse_charge) as rig,
           sum(l.cgst_amount) filter (where l.itc_eligible and l.reverse_charge) as rcg,
           sum(l.sgst_amount) filter (where l.itc_eligible and l.reverse_charge) as rsg
      from public.purchase_bills b
      join public.suppliers s on s.id = b.supplier_id
      join public.purchase_bill_lines l on l.purchase_bill_id = b.id
     where b.dealer_id = app.current_dealer_id() and b.status = 'POSTED'
       and b.bill_date <= app.month_end(p_period)
       and app.branch_gstin(b.branch_id) = p_gstin
     group by b.id, b.bill_number, b.bill_date, s.name
  ),
  in2b as (
    select distinct on (g.matched_bill_id) g.matched_bill_id, g.match_status,
           g.igst_amount, g.cgst_amount, g.sgst_amount
      from public.gstr2b_lines g
      join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
     where i.dealer_id = app.current_dealer_id() and i.gstin = p_gstin
       and i.period <= date_trunc('month', p_period)::date and g.matched_bill_id is not null
       and g.itc_available
     order by g.matched_bill_id, i.period desc
  )
  -- Invoices: in 2B, at the lower of books and 2B head by head.
  select 'INVOICE', b.id, null::uuid, b.bill_number, b.bill_date, b.supplier,
         case when m.matched_bill_id is null then coalesce(b.ig, 0) else least(coalesce(b.ig, 0), m.igst_amount) end,
         case when m.matched_bill_id is null then coalesce(b.cg, 0) else least(coalesce(b.cg, 0), m.cgst_amount) end,
         case when m.matched_bill_id is null then coalesce(b.sg, 0) else least(coalesce(b.sg, 0), m.sgst_amount) end,
         m.matched_bill_id is not null and m.match_status in ('MATCHED', 'VALUE_MISMATCH'),
         case when m.matched_bill_id is null then 'Not yet in GSTR-2B'
              when m.match_status = 'VALUE_MISMATCH' then 'In 2B with a different value: the lower is claimed'
              else 'In GSTR-2B' end
    from bills b
    left join in2b m on m.matched_bill_id = b.id
   where coalesce(b.ig, 0) + coalesce(b.cg, 0) + coalesce(b.sg, 0) > 0
     and not exists (select 1 from public.itc_claim_lines c where c.purchase_bill_id = b.id and c.claim_kind = 'INVOICE')
  union all
  -- Reverse charge: the dealer paid the tax; no 2B is needed.
  select 'RCM', b.id, null, b.bill_number, b.bill_date, b.supplier,
         coalesce(b.rig, 0), coalesce(b.rcg, 0), coalesce(b.rsg, 0), true, 'Reverse charge paid by you'
    from bills b
   where coalesce(b.rig, 0) + coalesce(b.rcg, 0) + coalesce(b.rsg, 0) > 0
     and b.bill_date >= date_trunc('month', p_period)::date
     and not exists (select 1 from public.itc_claim_lines c where c.purchase_bill_id = b.id and c.claim_kind = 'RCM')
  union all
  -- Supplier notes. A credit note reduces the claim regardless of 2B; a debit
  -- note, like an invoice, waits for it.
  select n.note_type || '_NOTE', null, n.id, coalesce(n.party_note_number, n.note_number), n.note_date, s.name,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.igst_amount,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.cgst_amount,
         case when n.note_type = 'CREDIT' then -1 else 1 end * n.sgst_amount,
         n.note_type = 'CREDIT' or exists (
           select 1 from public.gstr2b_lines g join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
            where g.matched_note_id = n.id and i.period <= date_trunc('month', p_period)::date),
         case when n.note_type = 'CREDIT' then 'Supplier credit note reduces credit'
              else 'Supplier debit note' end
    from public.gst_notes n
    join public.suppliers s on s.id = n.supplier_id
   where n.dealer_id = app.current_dealer_id() and n.party_type = 'SUPPLIER' and n.status = 'POSTED'
     and n.itc_eligible and n.note_date <= app.month_end(p_period)
     and app.branch_gstin(n.branch_id) = p_gstin
     and not exists (select 1 from public.itc_claim_lines c where c.gst_note_id = n.id)
   order by 1, 5;
$$;

-- -----------------------------------------------------------------------------
-- GSTR-3B working
-- -----------------------------------------------------------------------------
create or replace function public.gstr3b_working(p_gstin text, p_period date)
returns table (
  section       text,
  description   text,
  taxable_value numeric(18, 4),
  igst_amount   numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4)
)
language sql
stable
as $$
  with bounds as (
    select date_trunc('month', p_period)::date as f, app.month_end(p_period) as t
  ),
  outward_lines as (
    select app.supply_category(s.dealer_id, l.tax_code, s.invoice_date, l.cgst_amount + l.sgst_amount + l.igst_amount) as cat,
           l.taxable_value as tv, l.igst_amount as ig, l.cgst_amount as cg, l.sgst_amount as sg
      from public.sale_lines l join public.sales s on s.id = l.sale_id, bounds
     where s.dealer_id = app.current_dealer_id() and s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between bounds.f and bounds.t and app.branch_gstin(s.branch_id) = p_gstin
    union all
    select app.supply_category(si.dealer_id, l.tax_code, si.invoice_date, l.cgst_amount + l.sgst_amount + l.igst_amount),
           l.taxable_value, l.igst_amount, l.cgst_amount, l.sgst_amount
      from public.service_lines l join public.service_invoices si on si.id = l.invoice_id, bounds
     where si.dealer_id = app.current_dealer_id() and si.status = 'POSTED'
       and si.invoice_date between bounds.f and bounds.t and app.branch_gstin(si.branch_id) = p_gstin
    union all
    -- Notes and transfer invoices are taxable supplies (or their correction).
    select 'TAXABLE', d.taxable_value, d.igst_amount, d.cgst_amount, d.sgst_amount
      from bounds, app.gst_outward_documents(bounds.f, bounds.t, p_gstin) d
     where d.document_type in ('CREDIT_NOTE', 'DEBIT_NOTE', 'TRANSFER_INVOICE')
  ),
  inward_lines as (
    select l.tax_category as cat, l.reverse_charge as rcm, l.itc_eligible as elig,
           l.taxable_value as tv, l.igst_amount as ig, l.cgst_amount as cg, l.sgst_amount as sg
      from public.purchase_bill_lines l join public.purchase_bills b on b.id = l.purchase_bill_id, bounds
     where b.dealer_id = app.current_dealer_id() and b.status = 'POSTED'
       and b.bill_date between bounds.f and bounds.t and app.branch_gstin(b.branch_id) = p_gstin
  ),
  claims as (
    select * from public.itc_claimable(p_gstin, p_period) where claimable
  ),
  adj as (
    select a.direction, a.rule, a.igst_amount as ig, a.cgst_amount as cg, a.sgst_amount as sg
      from public.itc_adjustments a, bounds
     where a.dealer_id = app.current_dealer_id() and a.adjustment_date between bounds.f and bounds.t
       and app.branch_gstin(a.branch_id) = p_gstin
  ),
  rows as (
    select 1 as ord, '3.1(a)' as sec, 'Outward taxable supplies (other than zero, nil rated and exempted)' as descr,
           sum(tv) as tv, sum(ig) as ig, sum(cg) as cg, sum(sg) as sg
      from outward_lines where cat = 'TAXABLE'
    union all
    select 2, '3.1(b)', 'Outward taxable supplies (zero rated)', sum(tv), sum(ig), sum(cg), sum(sg)
      from outward_lines where cat = 'ZERO_RATED'
    union all
    select 3, '3.1(c)', 'Other outward supplies (nil rated, exempted)', sum(tv), 0, 0, 0
      from outward_lines where cat in ('NIL_RATED', 'EXEMPT')
    union all
    select 4, '3.1(d)', 'Inward supplies liable to reverse charge', sum(tv), sum(ig), sum(cg), sum(sg)
      from inward_lines where rcm
    union all
    select 5, '3.1(e)', 'Non-GST outward supplies', sum(tv), 0, 0, 0
      from outward_lines where cat = 'NON_GST'
    union all
    select 6, '3.1(!)', 'Unclassified zero-tax lines: give them a tax code before filing', sum(tv), 0, 0, 0
      from outward_lines where cat = 'UNCLASSIFIED' having count(*) > 0
    union all
    select 7, '4(A)(3)', 'ITC: inward supplies liable to reverse charge', null,
           sum(igst_amount), sum(cgst_amount), sum(sgst_amount)
      from claims where claim_kind = 'RCM'
    union all
    select 8, '4(A)(5)', 'ITC: all other (in GSTR-2B), net of supplier credit notes and re-claims', null,
           coalesce((select sum(igst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(ig) from adj where direction = 'RECLAIM'), 0),
           coalesce((select sum(cgst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(cg) from adj where direction = 'RECLAIM'), 0),
           coalesce((select sum(sgst_amount) from claims where claim_kind <> 'RCM'), 0)
             + coalesce((select sum(sg) from adj where direction = 'RECLAIM'), 0)
    union all
    select 9, '4(B)(1)', 'ITC reversed: rules 42, 43 and s.17(5)', null, sum(ig), sum(cg), sum(sg)
      from adj where direction = 'REVERSAL' and rule in ('RULE_42', 'RULE_43', 'SECTION_17_5')
    union all
    select 10, '4(B)(2)', 'ITC reversed: others (rule 37 etc.)', null, sum(ig), sum(cg), sum(sg)
      from adj where direction = 'REVERSAL' and rule not in ('RULE_42', 'RULE_43', 'SECTION_17_5')
    union all
    select 12, '4(D)', 'ITC in the books not yet claimable (not in GSTR-2B)', null,
           sum(igst_amount), sum(cgst_amount), sum(sgst_amount)
      from public.itc_claimable(p_gstin, p_period) where not claimable
    union all
    select 13, '5', 'Inward exempt, nil rated and non-GST supplies', sum(tv), 0, 0, 0
      from inward_lines where cat in ('NIL_RATED', 'EXEMPT', 'NON_GST')
  ),
  with_net as (
    select * from rows
    union all
    select 11, '4(C)', 'Net ITC available (A − B)', null,
           sum(case when sec like '4(A)%' then coalesce(ig, 0) when sec like '4(B)%' then -coalesce(ig, 0) else 0 end),
           sum(case when sec like '4(A)%' then coalesce(cg, 0) when sec like '4(B)%' then -coalesce(cg, 0) else 0 end),
           sum(case when sec like '4(A)%' then coalesce(sg, 0) when sec like '4(B)%' then -coalesce(sg, 0) else 0 end)
      from rows
  )
  select sec, descr, tv, coalesce(ig, 0), coalesce(cg, 0), coalesce(sg, 0)
    from with_net order by ord;
$$;

-- Credit left at the end of the last filed 3B for this GSTIN.
create or replace function app.gst_opening_credit(p_gstin text, p_period date)
returns table (igst numeric, cgst numeric, sgst numeric)
language sql
stable
as $$
  select coalesce((r.computed->'closing_credit'->>'igst')::numeric, 0),
         coalesce((r.computed->'closing_credit'->>'cgst')::numeric, 0),
         coalesce((r.computed->'closing_credit'->>'sgst')::numeric, 0)
    from (select 1) one
    left join lateral (
      select g.computed from public.gst_returns g
       where g.dealer_id = app.current_dealer_id() and g.gstin = p_gstin and g.return_type = 'GSTR3B'
         and g.status = 'FILED' and g.period < date_trunc('month', p_period)::date
       order by g.period desc limit 1) r on true;
$$;

-- Set-off in the order of rule 88A; reverse-charge tax is paid in cash.
create or replace function public.gstr3b_setoff(p_gstin text, p_period date)
returns table (
  tax_head         text,
  liability        numeric(18, 4),
  rcm_liability    numeric(18, 4),
  opening_credit   numeric(18, 4),
  period_credit    numeric(18, 4),
  paid_by_igst     numeric(18, 4),
  paid_by_cgst     numeric(18, 4),
  paid_by_sgst     numeric(18, 4),
  cash_payable     numeric(18, 4),
  closing_credit   numeric(18, 4)
)
language plpgsql
stable
as $$
declare
  li numeric; lc numeric; ls numeric;           -- liability left, per head
  ri numeric; rc numeric; rs numeric;           -- reverse charge
  oi numeric; oc numeric; os numeric;           -- opening credit
  ni numeric; nc numeric; ns numeric;           -- this period's net credit
  ci numeric; cc numeric; cs numeric;           -- credit left
  i_i numeric; i_c numeric; i_s numeric;        -- IGST credit used against IGST / CGST / SGST
  c_c numeric; c_i numeric;                     -- CGST credit used against CGST / IGST
  s_s numeric; s_i numeric;                     -- SGST credit used against SGST / IGST
  w record;
begin
  li := 0; lc := 0; ls := 0; ri := 0; rc := 0; rs := 0; ni := 0; nc := 0; ns := 0;
  for w in select * from public.gstr3b_working(p_gstin, p_period) loop
    if w.section in ('3.1(a)', '3.1(b)') then
      li := li + w.igst_amount; lc := lc + w.cgst_amount; ls := ls + w.sgst_amount;
    elsif w.section = '3.1(d)' then
      ri := ri + w.igst_amount; rc := rc + w.cgst_amount; rs := rs + w.sgst_amount;
    elsif w.section = '4(C)' then
      ni := w.igst_amount; nc := w.cgst_amount; ns := w.sgst_amount;
    end if;
  end loop;
  select o.igst, o.cgst, o.sgst into oi, oc, os from app.gst_opening_credit(p_gstin, p_period) o;

  -- Liability cannot be negative for set-off; a net credit note month simply
  -- has nothing to pay.
  li := greatest(li, 0); lc := greatest(lc, 0); ls := greatest(ls, 0);
  ci := greatest(oi + ni, 0); cc := greatest(oc + nc, 0); cs := greatest(os + ns, 0);

  tax_head := null;
  i_i := least(ci, li); li := li - i_i; ci := ci - i_i;
  i_c := least(ci, lc); lc := lc - i_c; ci := ci - i_c;
  i_s := least(ci, ls); ls := ls - i_s; ci := ci - i_s;
  c_c := least(cc, lc); lc := lc - c_c; cc := cc - c_c;
  c_i := least(cc, li); li := li - c_i; cc := cc - c_i;
  s_s := least(cs, ls); ls := ls - s_s; cs := cs - s_s;
  s_i := least(cs, li); li := li - s_i; cs := cs - s_i;

  return query values
    ('IGST', li + i_i + c_i + s_i, ri, oi, ni, i_i, c_i, s_i, li + ri, ci),
    ('CGST', lc + i_c + c_c, rc, oc, nc, i_c, c_c, 0::numeric, lc + rc, cc),
    ('SGST', ls + i_s + s_s, rs, os, ns, i_s, 0::numeric, s_s, ls + rs, cs);
end;
$$;

-- -----------------------------------------------------------------------------
-- Preparing, signing off and filing
-- -----------------------------------------------------------------------------
create or replace function app.gst_return_snapshot(p_type text, p_gstin text, p_period date)
returns jsonb
language plpgsql
stable
as $$
declare
  v_f date := date_trunc('month', p_period)::date;
  v_t date := app.month_end(p_period);
begin
  if p_type = 'GSTR1' then
    return jsonb_build_object(
      'sections', (select coalesce(jsonb_agg(to_jsonb(s) order by s.section), '[]'::jsonb) from (
         select d.section, count(*) as documents, sum(d.taxable_value) as taxable,
                sum(d.igst_amount) as igst, sum(d.cgst_amount) as cgst, sum(d.sgst_amount) as sgst
           from app.gst_outward_documents(v_f, v_t, p_gstin) d group by d.section) s),
      'totals', (select jsonb_build_object('taxable', coalesce(sum(taxable_value), 0),
                  'igst', coalesce(sum(igst_amount), 0), 'cgst', coalesce(sum(cgst_amount), 0),
                  'sgst', coalesce(sum(sgst_amount), 0))
                   from app.gst_outward_documents(v_f, v_t, p_gstin)));
  end if;
  return jsonb_build_object(
    'working', (select jsonb_agg(to_jsonb(w)) from public.gstr3b_working(p_gstin, p_period) w),
    'setoff',  (select jsonb_agg(to_jsonb(s)) from public.gstr3b_setoff(p_gstin, p_period) s),
    'closing_credit', (select jsonb_object_agg(lower(s.tax_head), s.closing_credit)
                         from public.gstr3b_setoff(p_gstin, p_period) s),
    'cash_payable', (select sum(s.cash_payable) from public.gstr3b_setoff(p_gstin, p_period) s));
end;
$$;

create or replace function public.prepare_gst_return(p_type text, p_gstin text, p_period date, p_notes text default null)
returns uuid
language plpgsql
as $$
declare
  v_dealer uuid := app.current_dealer_id();
  v_period date := date_trunc('month', p_period)::date;
  v_ret    public.gst_returns;
begin
  if v_dealer is null or not app.has_permission('gst.returns.prepare') then
    raise exception 'You do not have permission to prepare GST returns.' using errcode = 'insufficient_privilege';
  end if;
  if not exists (select 1 from public.branches b where b.dealer_id = v_dealer and app.branch_gstin(b.id) = p_gstin) then
    raise exception 'GSTIN % is not one of yours.', p_gstin using errcode = 'check_violation';
  end if;
  if v_period > date_trunc('month', current_date)::date then
    raise exception 'A return cannot be prepared for a month that has not begun.' using errcode = 'check_violation';
  end if;

  select * into v_ret from public.gst_returns
   where dealer_id = v_dealer and gstin = p_gstin and return_type = p_type and period = v_period for update;
  if v_ret.status = 'FILED' then
    raise exception 'The % for % is already filed. Corrections go in a later return as amendments.',
      p_type, to_char(v_period, 'Mon YYYY') using errcode = 'check_violation';
  end if;

  if v_ret.id is null then
    insert into public.gst_returns (dealer_id, gstin, return_type, period, computed, prepared_by, notes)
    values (v_dealer, p_gstin, p_type, v_period, app.gst_return_snapshot(p_type, p_gstin, v_period), auth.uid(), p_notes)
    returning * into v_ret;
  else
    -- Re-preparing replaces the figures, so any sign-off on the old ones lapses.
    update public.gst_returns
       set computed = app.gst_return_snapshot(p_type, p_gstin, v_period), prepared_by = auth.uid(),
           prepared_at = now(), status = 'PREPARED', signed_off_by = null, signed_off_at = null,
           notes = coalesce(p_notes, notes)
     where id = v_ret.id;
  end if;
  return v_ret.id;
end;
$$;

create or replace function public.sign_off_gst_return(p_return_id uuid)
returns void
language plpgsql
as $$
declare
  v_ret public.gst_returns;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to sign off GST returns.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null then
    raise exception 'Return not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.status <> 'PREPARED' then
    raise exception 'Only a prepared return can be signed off; this one is %.', lower(v_ret.status)
      using errcode = 'check_violation';
  end if;
  if v_ret.prepared_by = auth.uid() then
    raise exception 'The person who prepared a return cannot also sign it off.' using errcode = 'check_violation';
  end if;
  update public.gst_returns set status = 'SIGNED_OFF', signed_off_by = auth.uid(), signed_off_at = now()
   where id = p_return_id;
end;
$$;

create or replace function public.record_gst_filing(
  p_return_id      uuid,
  p_arn            text,
  p_filed_on       date,
  p_taxable        numeric,
  p_igst           numeric,
  p_cgst           numeric,
  p_sgst           numeric,
  p_itc_igst       numeric default null,
  p_itc_cgst       numeric default null,
  p_itc_sgst       numeric default null,
  p_challan_cpin   text default null,
  p_challan_cin    text default null,
  p_challan_amount numeric default null,
  p_notes          text default null
)
returns void
language plpgsql
as $$
declare
  v_ret public.gst_returns;
  v_f   date;
  v_t   date;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to record GST filings.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null then
    raise exception 'Return not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.status = 'FILED' then
    return;
  end if;
  if v_ret.status <> 'SIGNED_OFF' then
    raise exception 'Sign the return off before recording its filing.' using errcode = 'check_violation';
  end if;
  if coalesce(btrim(p_arn), '') = '' or p_filed_on is null then
    raise exception 'Enter the ARN and the date of filing from the portal.' using errcode = 'check_violation';
  end if;
  if p_filed_on > current_date then
    raise exception 'A filing date cannot be in the future.' using errcode = 'check_violation';
  end if;

  v_f := v_ret.period; v_t := app.month_end(v_ret.period);

  update public.gst_returns
     set status = 'FILED', arn = upper(btrim(p_arn)), filed_on = p_filed_on, filed_by = auth.uid(), filed_at = now(),
         filed_taxable = p_taxable, filed_igst = p_igst, filed_cgst = p_cgst, filed_sgst = p_sgst,
         filed_itc_igst = p_itc_igst, filed_itc_cgst = p_itc_cgst, filed_itc_sgst = p_itc_sgst,
         challan_cpin = nullif(btrim(coalesce(p_challan_cpin, '')), ''),
         challan_cin = nullif(btrim(coalesce(p_challan_cin, '')), ''),
         challan_amount = p_challan_amount, notes = coalesce(p_notes, notes)
   where id = p_return_id;

  if v_ret.return_type = 'GSTR1' then
    insert into public.gst_filed_documents
      (return_id, dealer_id, document_type, document_id, document_number, document_date, party_gstin,
       place_of_supply, section, taxable_value, cgst_amount, sgst_amount, igst_amount, total_amount)
    select p_return_id, v_ret.dealer_id, d.document_type, d.document_id, d.document_number, d.document_date,
           d.party_gstin, d.place_of_supply, d.section, d.taxable_value, d.cgst_amount, d.sgst_amount,
           d.igst_amount, d.total_amount
      from app.gst_outward_documents(v_f, v_t, v_ret.gstin) d;
  else
    insert into public.itc_claim_lines
      (return_id, dealer_id, claim_kind, purchase_bill_id, gst_note_id, igst_amount, cgst_amount, sgst_amount)
    select p_return_id, v_ret.dealer_id, c.claim_kind, c.purchase_bill_id, c.gst_note_id,
           c.igst_amount, c.cgst_amount, c.sgst_amount
      from public.itc_claimable(v_ret.gstin, v_ret.period) c
     where c.claimable;
  end if;
end;
$$;

-- The 3B's set-off, posted once filed: output tax cleared by input credit, the
-- rest (and reverse-charge tax) paid from the bank.
create or replace function public.post_gst_setoff(p_return_id uuid, p_bank_account_id uuid, p_date date default null)
returns uuid
language plpgsql
as $$
declare
  v_ret    public.gst_returns;
  v_bank   public.bank_accounts;
  v_branch uuid;
  v_lines  jsonb := '[]'::jsonb;
  v_cash   numeric := 0;
  v_entry  uuid;
  v_date   date;
  s        record;
  v_head   text;
begin
  if not app.has_permission('gst.returns.file') then
    raise exception 'You do not have permission to post the GST set-off.' using errcode = 'insufficient_privilege';
  end if;
  select * into v_ret from public.gst_returns where id = p_return_id and dealer_id = app.current_dealer_id() for update;
  if v_ret.id is null or v_ret.return_type <> 'GSTR3B' then
    raise exception 'GSTR-3B not found.' using errcode = 'no_data_found';
  end if;
  if v_ret.setoff_journal_id is not null then
    return v_ret.setoff_journal_id;
  end if;
  if v_ret.status <> 'FILED' then
    raise exception 'Record the filing before posting its set-off.' using errcode = 'check_violation';
  end if;
  select * into v_bank from public.bank_accounts where id = p_bank_account_id and dealer_id = v_ret.dealer_id and status = 'ACTIVE';
  if v_bank.id is null then
    raise exception 'Choose an active bank account.' using errcode = 'no_data_found';
  end if;
  select b.id into v_branch from public.branches b
   where b.dealer_id = v_ret.dealer_id and app.branch_gstin(b.id) = v_ret.gstin
   order by (b.id = v_bank.branch_id) desc, b.created_at limit 1;
  v_date := coalesce(p_date, v_ret.filed_on);

  for s in select * from jsonb_to_recordset(v_ret.computed->'setoff') as x(
             tax_head text, liability numeric, rcm_liability numeric, paid_by_igst numeric,
             paid_by_cgst numeric, paid_by_sgst numeric, cash_payable numeric) loop
    v_head := s.tax_head;
    -- The liability cleared: output tax, and reverse-charge tax, debited.
    if s.liability > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'SERVICE', 'INVOICE', v_head, v_branch),
        'debit', s.liability, 'credit', 0, 'narration', 'Output ' || v_head || ' set off ' || to_char(v_ret.period, 'Mon YYYY'));
    end if;
    if s.rcm_liability > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'INVENTORY', 'PURCHASE', 'RCM_PAYABLE', v_branch),
        'debit', s.rcm_liability, 'credit', 0, 'narration', 'Reverse-charge ' || v_head || ' paid');
    end if;
    v_cash := v_cash + s.cash_payable;
  end loop;

  -- The credit used, by the head it came from.
  for v_head in select unnest(array['IGST', 'CGST', 'SGST']) loop
    select sum(case v_head when 'IGST' then x.paid_by_igst when 'CGST' then x.paid_by_cgst else x.paid_by_sgst end)
      into s from jsonb_to_recordset(v_ret.computed->'setoff') as x(paid_by_igst numeric, paid_by_cgst numeric, paid_by_sgst numeric);
    if coalesce(s.sum, 0) > 0 then
      v_lines := v_lines || jsonb_build_object(
        'account_id', app.require_account(v_ret.dealer_id, 'INVENTORY', 'PURCHASE', 'INPUT_' || v_head, v_branch),
        'debit', 0, 'credit', s.sum, 'narration', 'Input ' || v_head || ' utilised');
    end if;
  end loop;

  if v_cash > 0 then
    v_lines := v_lines || jsonb_build_object('account_id', v_bank.ledger_account_id, 'debit', 0, 'credit', v_cash,
      'narration', 'GST paid ' || coalesce('CIN ' || v_ret.challan_cin, 'for ' || to_char(v_ret.period, 'Mon YYYY')));
  end if;
  if jsonb_array_length(v_lines) = 0 then
    raise exception 'Nothing to set off for this return.' using errcode = 'check_violation';
  end if;

  v_entry := app.post_journal(v_ret.dealer_id, v_branch, v_date, 'BANK',
    'GST set-off and payment — GSTR-3B ' || to_char(v_ret.period, 'Mon YYYY') || ' ' || v_ret.gstin,
    v_lines, 'GST_SETOFF', p_return_id, 'gst-setoff:' || p_return_id::text);
  if v_cash > 0 then
    perform app.bank_book_row(p_bank_account_id, v_date, 'PAYMENT', v_cash,
      'GST ' || to_char(v_ret.period, 'Mon YYYY'), 'GST_RETURN', p_return_id, v_entry);
  end if;
  update public.gst_returns set setoff_journal_id = v_entry where id = p_return_id;
  return v_entry;
end;
$$;

-- -----------------------------------------------------------------------------
-- Amendments and cross-checks
-- -----------------------------------------------------------------------------
-- Against every GSTR-1 already filed for this GSTIN before the period: a
-- document that changed or was cancelled after filing, or one dated in a filed
-- month that the filing never carried.
create or replace function public.gstr1_amendments(p_gstin text, p_period date)
returns table (
  kind            text,
  filed_period    date,
  document_type   text,
  document_id     uuid,
  document_number text,
  document_date   date,
  filed_taxable   numeric(18, 4),
  filed_tax       numeric(18, 4),
  current_taxable numeric(18, 4),
  current_tax     numeric(18, 4),
  detail          text
)
language sql
stable
as $$
  with filed as (
    select r.id, r.period from public.gst_returns r
     where r.dealer_id = app.current_dealer_id() and r.gstin = p_gstin and r.return_type = 'GSTR1'
       and r.status = 'FILED' and r.period < date_trunc('month', p_period)::date
  ),
  snap as (
    select f.period, d.* from filed f join public.gst_filed_documents d on d.return_id = f.id
  ),
  cur as (
    select f.period, d.* from filed f
    cross join lateral app.gst_outward_documents(f.period, app.month_end(f.period), p_gstin) d
  )
  select case when c.document_id is null then 'CANCELLED_AFTER_FILING' else 'CHANGED_AFTER_FILING' end,
         s.period, s.document_type, s.document_id, s.document_number, s.document_date,
         s.taxable_value, s.cgst_amount + s.sgst_amount + s.igst_amount,
         c.taxable_value, c.cgst_amount + c.sgst_amount + c.igst_amount,
         case when c.document_id is null then 'Reported, since cancelled: report the reversal as an amendment.'
              else concat_ws('; ',
                case when s.party_gstin is distinct from c.party_gstin then 'GSTIN ' || coalesce(s.party_gstin, 'none') || ' → ' || coalesce(c.party_gstin, 'none') end,
                case when s.place_of_supply is distinct from c.place_of_supply then 'place of supply ' || coalesce(s.place_of_supply, '—') || ' → ' || coalesce(c.place_of_supply, '—') end,
                case when s.taxable_value <> c.taxable_value then 'value changed' end) end
    from snap s
    left join cur c on c.document_type = s.document_type and c.document_id = s.document_id
   where c.document_id is null
      or s.party_gstin is distinct from c.party_gstin
      or s.place_of_supply is distinct from c.place_of_supply
      or s.taxable_value <> c.taxable_value
      or s.cgst_amount + s.sgst_amount + s.igst_amount <> c.cgst_amount + c.sgst_amount + c.igst_amount
  union all
  select 'MISSED_IN_FILING', c.period, c.document_type, c.document_id, c.document_number, c.document_date,
         null, null, c.taxable_value, c.cgst_amount + c.sgst_amount + c.igst_amount,
         'Dated in a filed month but not in that filing: report it in this return.'
    from cur c
   where not exists (select 1 from snap s where s.document_type = c.document_type and s.document_id = c.document_id)
   order by 2, 6;
$$;

create or replace function public.gst_cross_checks(p_gstin text, p_period date)
returns table (
  check_code  text,
  description text,
  left_label  text,
  left_value  numeric(18, 4),
  right_label text,
  right_value numeric(18, 4),
  difference  numeric(18, 4),
  status      text
)
language sql
stable
as $$
  with b as (select date_trunc('month', p_period)::date as f, app.month_end(p_period) as t),
  g1 as (
    select coalesce(sum(d.cgst_amount + d.sgst_amount + d.igst_amount), 0) as tax,
           coalesce(sum(d.taxable_value), 0) as taxable
      from b, app.gst_outward_documents(b.f, b.t, p_gstin) d
  ),
  w as (select * from public.gstr3b_working(p_gstin, p_period)),
  g3 as (
    select coalesce(sum(igst_amount + cgst_amount + sgst_amount) filter (where section in ('3.1(a)', '3.1(b)')), 0) as tax,
           coalesce(sum(igst_amount + cgst_amount + sgst_amount) filter (where section = '4(A)(5)'), 0) as itc
      from w
  ),
  -- Output tax in the ledger: the tax accounts the invoice rules post to,
  -- for this GSTIN's branches, apart from the set-off that clears them.
  books as (
    select coalesce(sum(l.credit - l.debit), 0) as tax
      from public.journal_entry_lines l
      join public.journal_entries je on je.id = l.journal_entry_id, b
     where je.dealer_id = app.current_dealer_id() and je.status in ('POSTED', 'REVERSED')
       and je.entry_date between b.f and b.t
       and coalesce(je.source_document_type, '') <> 'GST_SETOFF'
       and app.branch_gstin(coalesce(l.branch_id, je.branch_id)) = p_gstin
       and l.account_id in (select r.account_id from public.accounting_rules r
                             where r.dealer_id = app.current_dealer_id() and r.status = 'ACTIVE'
                               and r.event = 'INVOICE' and r.component in ('CGST', 'SGST', 'IGST'))
  ),
  twob as (
    select coalesce(sum(g.igst_amount + g.cgst_amount + g.sgst_amount) filter (where g.itc_available and not g.reverse_charge), 0) as itc
      from public.gstr2b_lines g
      join public.gstr2b_imports i on i.id = g.import_id and i.status = 'ACTIVE'
     where i.dealer_id = app.current_dealer_id() and i.gstin = p_gstin and i.period = date_trunc('month', p_period)::date
  ),
  bookitc as (
    select coalesce(sum(l.igst_amount + l.cgst_amount + l.sgst_amount), 0) as itc
      from public.purchase_bill_lines l join public.purchase_bills pb on pb.id = l.purchase_bill_id, b
     where pb.dealer_id = app.current_dealer_id() and pb.status = 'POSTED' and l.itc_eligible and not l.reverse_charge
       and pb.bill_date between b.f and b.t and app.branch_gstin(pb.branch_id) = p_gstin
  ),
  r1 as (select * from public.gst_returns where dealer_id = app.current_dealer_id() and gstin = p_gstin
           and return_type = 'GSTR1' and period = date_trunc('month', p_period)::date),
  r3 as (select * from public.gst_returns where dealer_id = app.current_dealer_id() and gstin = p_gstin
           and return_type = 'GSTR3B' and period = date_trunc('month', p_period)::date),
  checks as (
    select 1 as ord, 'BOOKS_VS_GSTR1' as code, 'Output tax in the ledger against GSTR-1' as descr,
           'Ledger' as ll, books.tax as lv, 'GSTR-1' as rl, g1.tax as rv from books, g1
    union all
    select 2, 'GSTR1_VS_GSTR3B', 'Output tax in GSTR-1 against GSTR-3B 3.1', 'GSTR-1', g1.tax, 'GSTR-3B', g3.tax from g1, g3
    union all
    select 3, 'FILED_GSTR1_VS_FILED_GSTR3B', 'Tax as filed: GSTR-1 against GSTR-3B',
           'GSTR-1 filed', (select filed_igst + filed_cgst + filed_sgst from r1 where status = 'FILED'),
           'GSTR-3B filed', (select filed_igst + filed_cgst + filed_sgst from r3 where status = 'FILED')
    union all
    select 4, 'FILED_VS_COMPUTED_GSTR1', 'GSTR-1: filed against the books today',
           'Filed', (select filed_igst + filed_cgst + filed_sgst from r1 where status = 'FILED'), 'Computed', g1.tax from g1
    union all
    select 5, 'FILED_VS_COMPUTED_GSTR3B', 'GSTR-3B output tax: filed against the books today',
           'Filed', (select filed_igst + filed_cgst + filed_sgst from r3 where status = 'FILED'), 'Computed', g3.tax from g3
    union all
    select 6, 'ITC_3B_VS_2B', 'Credit claimed in GSTR-3B 4(A)(5) against GSTR-2B',
           'GSTR-3B', coalesce((select filed_itc_igst + filed_itc_cgst + filed_itc_sgst from r3 where status = 'FILED'), g3.itc),
           'GSTR-2B', twob.itc from g3, twob
    union all
    select 7, 'ITC_BOOKS_VS_2B', 'Eligible credit on this month''s bills against GSTR-2B',
           'Books', bookitc.itc, 'GSTR-2B', twob.itc from bookitc, twob
  )
  select code, descr, ll, lv, rl, rv, lv - rv,
         case when lv is null or rv is null then 'PENDING'
              when abs(lv - rv) < 1 then 'OK'
              -- Claiming less credit than 2B offers is allowed; claiming more is not.
              when code = 'ITC_3B_VS_2B' and lv < rv then 'OK'
              else 'DIFFERENCE' end
    from checks order by ord;
$$;

do $$
begin
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then
    return;
  end if;
  execute 'grant select, insert, update, delete on public.gst_returns to authenticated';
  execute 'grant select, insert on public.gst_filed_documents, public.itc_claim_lines to authenticated';
  execute 'grant select, insert, update on public.gstr2b_imports, public.gstr2b_lines to authenticated';
  execute 'grant execute on function app.branch_gstin(uuid) to authenticated';
end $$;

insert into public.schema_migrations (version, name)
values ('0085', 'gst_returns_2b_3b') on conflict (version) do nothing;
