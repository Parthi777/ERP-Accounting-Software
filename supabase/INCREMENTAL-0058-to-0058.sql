-- =============================================================================
-- INCREMENTAL 0058 → 0058
-- =============================================================================
-- GENERATED FILE. Regenerate with:
--   FROM=0058 bash scripts/build-incremental.sh
--
-- For a database that ALREADY has migrations up to 0057.
-- Running the full ALL-IN-ONE.sql on such a database fails on the first table
-- that already exists; this contains only what is missing.
--
-- Wrapped in one transaction. If any statement fails the whole thing rolls back
-- and the database is left exactly as it was — there is no half-applied state to
-- clean up, and it is safe to fix the cause and run again.
--
-- Paste into the Supabase SQL Editor and Run.
-- =============================================================================

begin;



-- ═══════════════════════════════════════════════════════════════════════════
-- SOURCE: supabase/migrations/0058_gst_input_tax.sql
-- ═══════════════════════════════════════════════════════════════════════════

-- =============================================================================
-- 0058 — Input tax credit: the half of GST the product could not report
-- =============================================================================
-- Spec §16, §21, §24, §40, §41, §59.
--
-- What is missing. public.gst_summary() from 0026 reads sale_lines and
-- service_lines — outward supplies only. That was complete when it was written,
-- because nothing in the product recorded a purchase. 0052 then introduced
-- purchase bills and accounts 1900/1910/1920 for input CGST/SGST/IGST, and 0057
-- taught purchase returns to reverse them, and neither migration taught the GST
-- screens that any of it existed.
--
-- So a dealer's input tax credit sits correctly on the balance sheet and appears
-- nowhere in GST → Summary or GST → Reports. The figure a dealer actually needs
-- at filing time is not output tax, it is
--
--     output tax  −  input tax credit  =  what is paid to the government
--
-- and the product could state only the first term. A dealer reading these
-- screens would overstate their liability by exactly the ITC they are entitled
-- to claim, which for a live dealership after one month of stock purchases is
-- a large number in the wrong direction.
--
-- ── Where the HSN comes from ────────────────────────────────────────────────
--
-- Purchase lines do not carry an hsn_code column the way sale lines do: a sale
-- line freezes the HSN onto the invoice because that invoice is a legal document
-- the dealer issues, whereas a purchase line is evidence of someone else's
-- invoice, and its HSN belongs to the item. So this resolves HSN through the
-- item for counted goods and through the model for a vehicle, rather than
-- inventing a column that would only ever be copied from those.
--
-- ── Returns net off, they do not subtract separately ────────────────────────
--
-- A debit note reverses the ITC on the goods sent back (0057). It belongs in the
-- same HSN bucket as a negative, not in a separate "returns" report: the number
-- a dealer claims is the net for the period, and a report that shows purchases
-- and returns in two places invites claiming the gross.
--
-- ── Why the HSN description is not looked up by code ────────────────────────
--
-- hsn_codes is dealer-scoped: two tenants legitimately hold the same code, and
-- 87141090 exists for both dealers on the live system today. So a description
-- join written `on h.code = lines.hsn` matches once per tenant holding that
-- code, and because it is a join rather than a lookup, every matching line is
-- emitted twice and the aggregate doubles.
--
-- Under RLS that stays hidden — a signed-in user sees only their own tenant's
-- hsn_codes row, so the join matches once — which is exactly what makes it
-- dangerous: correct in the application, wrong for anything that reads with RLS
-- bypassed, and silently a factor of two rather than an error. gst_summary()
-- from 0026 carries the same join and is corrected below.
--
-- Rollback: drop function public.gst_input_summary(date, date, uuid);
--           restore public.gst_summary(date, date, uuid) from 0026.
-- =============================================================================

create or replace function public.gst_input_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code       text,
  description    text,
  taxable_value  numeric(18, 4),
  cgst_amount    numeric(18, 4),
  sgst_amount    numeric(18, 4),
  igst_amount    numeric(18, 4),
  total_tax      numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    -- What was bought.
    select coalesce(h.code, 'UNSPECIFIED') as hsn,
           coalesce(h.description, '') as descr,
           l.taxable_value, l.cgst_amount, l.sgst_amount, l.igst_amount,
           b.id as doc
      from public.purchase_bill_lines l
      join public.purchase_bills b on b.id = l.purchase_bill_id
      left join public.inventory_items i on i.id = l.item_id
      left join public.vehicles v on v.id = l.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where b.status = 'POSTED'
       and b.bill_date between p_from and p_to
       and (p_branch_id is null or b.branch_id = p_branch_id)

    union all

    -- What went back, as negatives in the same bucket: the claim is the net.
    select coalesce(h.code, 'UNSPECIFIED'),
           coalesce(h.description, ''),
           -rl.taxable_value, -rl.cgst_amount, -rl.sgst_amount, -rl.igst_amount,
           r.id
      from public.purchase_return_lines rl
      join public.purchase_returns r on r.id = rl.purchase_return_id
      left join public.inventory_items i on i.id = rl.item_id
      left join public.vehicles v on v.id = rl.vehicle_id
      left join public.vehicle_models m on m.id = v.model_id
      left join public.hsn_codes h on h.id = coalesce(i.hsn_code_id, m.hsn_code_id)
     where r.status = 'POSTED'
       and r.return_date between p_from and p_to
       and (p_branch_id is null or r.branch_id = p_branch_id)
  )
  -- No join back to hsn_codes here: the description already travelled with the
  -- line, from the row identified by id. Matching on code would match once per
  -- tenant holding it (see the note above).
  select lines.hsn,
         max(lines.descr),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_input_summary(date, date, uuid) is
  'HSN-wise input tax credit for a period (spec §40, §41): purchase bills less '
  'the debit notes that reversed them. The counterpart to gst_summary(), which '
  'reports only outward supplies.';

do $$
begin
  if exists (select 1 from pg_roles where rolname = 'authenticated') then
    execute 'grant execute on function public.gst_input_summary(date, date, uuid) to authenticated';
  end if;
end;
$$;

-- -----------------------------------------------------------------------------
-- public.gst_summary() — the same description join, corrected
-- -----------------------------------------------------------------------------
-- Identical body to 0026 apart from the description lookup, which is now scoped
-- by dealer. A sale line freezes its HSN as text, so there is no id to travel
-- with the line as there is above; the join therefore has to carry the tenant.
-- -----------------------------------------------------------------------------
create or replace function public.gst_summary(
  p_from      date,
  p_to        date,
  p_branch_id uuid default null
)
returns table (
  hsn_code      text,
  description   text,
  taxable_value numeric(18, 4),
  cgst_amount   numeric(18, 4),
  sgst_amount   numeric(18, 4),
  igst_amount   numeric(18, 4),
  total_tax     numeric(18, 4),
  document_count bigint
)
language sql
stable
as $$
  with lines as (
    select coalesce(l.hsn_code, 'UNSPECIFIED') hsn, s.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, s.id doc
      from public.sale_lines l
      join public.sales s on s.id = l.sale_id
     where s.status in ('POSTED', 'DELIVERED')
       and s.invoice_date between p_from and p_to
       and (p_branch_id is null or s.branch_id = p_branch_id)
    union all
    select coalesce(l.hsn_code, 'UNSPECIFIED'), si.dealer_id, l.taxable_value,
           l.cgst_amount, l.sgst_amount, l.igst_amount, si.id
      from public.service_lines l
      join public.service_invoices si on si.id = l.invoice_id
     where si.status = 'POSTED'
       and si.invoice_date between p_from and p_to
       and (p_branch_id is null or si.branch_id = p_branch_id)
  )
  select lines.hsn,
         coalesce(max(h.description), ''),
         sum(lines.taxable_value), sum(lines.cgst_amount), sum(lines.sgst_amount),
         sum(lines.igst_amount),
         sum(lines.cgst_amount + lines.sgst_amount + lines.igst_amount),
         count(distinct lines.doc)
    from lines
    -- Scoped by dealer: the same code in another tenant is a different row and
    -- must not multiply this one.
    left join public.hsn_codes h
      on h.code = lines.hsn and h.dealer_id = lines.dealer_id
   group by lines.hsn
   order by lines.hsn;
$$;

comment on function public.gst_summary(date, date, uuid) is
  'HSN-wise output tax for a period (spec §41). Reads the tax stored on each line, '
  'not the current tax master, so historical figures never move (spec §16).';


commit;
