import 'server-only';

import { requireTenantContext, type TenantContext } from '@/server/auth/tenant-context';
import { ForbiddenError } from '@/server/errors';
import { createSupabaseServerClient } from '@/lib/supabase/server';
import { add, fromDb, ZERO, type Paise } from '@/lib/money';
import type { Permission } from '@/lib/permissions';

/**
 * Party subsidiary ledgers — spec §11, §41.
 *
 * Derived from party-tagged journal lines rather than kept as a running total of
 * their own, so a ledger cannot drift from its control account: there is no
 * second source of truth to reconcile.
 *
 * Debit positive throughout, for every party. For a customer a positive balance
 * is money owed to the dealer; for a supplier it is the mirror, so a supplier's
 * balance is normally negative here and rendered `Cr`. Keeping one convention in
 * the data and inverting only for display is what lets both ledgers use the same
 * arithmetic.
 */

export type PartyType = 'CUSTOMER' | 'SUPPLIER';

/**
 * Reached from routes with different audiences and different permissions —
 * Customers, for someone checking what is owed, and Accounting, for someone
 * reading the subsidiary ledger. Either grants access.
 *
 * `requirePermission` is all-of, which is the wrong shape here.
 */
async function requireEither(...permissions: readonly Permission[]): Promise<TenantContext> {
  const context = await requireTenantContext();
  if (!permissions.some((permission) => context.permissions.has(permission))) {
    throw new ForbiddenError(permissions[0]!);
  }
  return context;
}

const CUSTOMER_PERMISSIONS = ['customers.view_ledger', 'accounting.ledgers.view'] as const;
const SUPPLIER_PERMISSIONS = ['masters.suppliers.view', 'accounting.ledgers.view'] as const;

export interface LedgerLine {
  readonly date: string;
  readonly entryNumber: string;
  readonly narration: string | null;
  readonly debit: Paise;
  readonly credit: Paise;
  readonly balance: Paise;
}

export interface PartyLedger {
  readonly partyType: PartyType;
  readonly partyId: string;
  readonly partyName: string;
  readonly partyCode: string;
  readonly contact: string | null;
  readonly from: string;
  readonly to: string;
  readonly opening: Paise;
  readonly closing: Paise;
  readonly totalDebit: Paise;
  readonly totalCredit: Paise;
  readonly lines: readonly LedgerLine[];
}

export interface LedgerPartyOption {
  readonly id: string;
  readonly label: string;
}

/** Back-compat alias: the customer ledger was this shape before it generalised. */
export type CustomerLedger = PartyLedger;
export type LedgerCustomerOption = LedgerPartyOption;

interface PartyRecord {
  readonly id: string;
  readonly name: string;
  readonly code: string;
  readonly contact: string | null;
}

/**
 * Reads the party row, which is also what enforces tenancy: RLS returns nothing
 * for another dealer's id, and without a party there is no ledger to render.
 *
 * The two branches are spelled out rather than built from a table name in a
 * variable, because a computed `select` string defeats the generated types and
 * a mistyped column would then only surface at runtime, as an empty ledger.
 */
async function readParty(partyType: PartyType, id: string): Promise<PartyRecord | null> {
  const supabase = await createSupabaseServerClient();

  if (partyType === 'CUSTOMER') {
    const { data, error } = await supabase
      .from('customers')
      .select('id, name, customer_code, mobile')
      .eq('id', id)
      .maybeSingle();
    if (error) throw new Error(`Failed to load the customer: ${error.message}`);
    return data
      ? { id: data.id, name: data.name, code: data.customer_code, contact: data.mobile }
      : null;
  }

  const { data, error } = await supabase
    .from('suppliers')
    .select('id, name, supplier_code, mobile')
    .eq('id', id)
    .maybeSingle();
  if (error) throw new Error(`Failed to load the supplier: ${error.message}`);
  return data
    ? { id: data.id, name: data.name, code: data.supplier_code, contact: data.mobile }
    : null;
}

function optionLabel(party: PartyRecord): string {
  return `${party.code} · ${party.name}${party.contact ? ` · ${party.contact}` : ''}`;
}

/**
 * One loader for both parties, so the two statements can never diverge in how
 * they compute a balance.
 */
async function loadPartyLedger(
  partyType: PartyType,
  params: { readonly partyId: string; readonly from: string; readonly to: string },
): Promise<PartyLedger | null> {
  const supabase = await createSupabaseServerClient();

  const [party, opening, ledger] = await Promise.all([
    readParty(partyType, params.partyId),
    supabase.rpc('party_ledger_opening', {
      p_party_type: partyType,
      p_party_id: params.partyId,
      p_as_on: params.from,
    }),
    supabase.rpc('party_ledger', {
      p_party_type: partyType,
      p_party_id: params.partyId,
      p_from: params.from,
      p_to: params.to,
    }),
  ]);

  if (!party) {
    return null;
  }
  if (opening.error) {
    throw new Error(`Failed to load the opening balance: ${opening.error.message}`);
  }
  if (ledger.error) {
    throw new Error(`Failed to load the ledger: ${ledger.error.message}`);
  }

  const openingBalance = fromDb((opening.data ?? 0) as string | number);

  const lines: LedgerLine[] = (ledger.data ?? []).map((row) => ({
    date: row.entry_date,
    entryNumber: row.entry_number,
    narration: row.narration,
    debit: fromDb(row.debit),
    credit: fromDb(row.credit),
    balance: fromDb(row.running_balance),
  }));

  // The closing balance comes from the last line's running balance where there
  // is one, and from the opening where the window is empty — a party that did
  // nothing this month still has a balance, and reporting nil would be wrong.
  const closing = lines.length > 0 ? lines[lines.length - 1]!.balance : openingBalance;

  return {
    partyType,
    partyId: party.id,
    partyName: party.name,
    partyCode: party.code,
    contact: party.contact,
    from: params.from,
    to: params.to,
    opening: openingBalance,
    closing,
    totalDebit: lines.reduce((sum, line) => add(sum, line.debit), ZERO),
    totalCredit: lines.reduce((sum, line) => add(sum, line.credit), ZERO),
    lines,
  };
}

async function loadPartyOptions(
  partyType: PartyType,
  search?: string,
): Promise<readonly LedgerPartyOption[]> {
  const supabase = await createSupabaseServerClient();
  const term = search?.trim();

  if (partyType === 'CUSTOMER') {
    let query = supabase
      .from('customers')
      .select('id, name, customer_code, mobile')
      .order('name')
      .limit(500);
    if (term) {
      query = query.or(
        `name.ilike.%${term}%,customer_code.ilike.%${term}%,mobile.ilike.%${term}%`,
      );
    }
    const { data, error } = await query;
    if (error) throw new Error(`Failed to load customers: ${error.message}`);
    return (data ?? []).map((row) => ({
      id: row.id,
      label: optionLabel({
        id: row.id,
        name: row.name,
        code: row.customer_code,
        contact: row.mobile,
      }),
    }));
  }

  let query = supabase
    .from('suppliers')
    .select('id, name, supplier_code, mobile')
    .order('name')
    .limit(500);
  if (term) {
    query = query.or(
      `name.ilike.%${term}%,supplier_code.ilike.%${term}%,mobile.ilike.%${term}%`,
    );
  }
  const { data, error } = await query;
  if (error) throw new Error(`Failed to load suppliers: ${error.message}`);
  return (data ?? []).map((row) => ({
    id: row.id,
    label: optionLabel({
      id: row.id,
      name: row.name,
      code: row.supplier_code,
      contact: row.mobile,
    }),
  }));
}

export async function getCustomerLedger(params: {
  readonly customerId: string;
  readonly from: string;
  readonly to: string;
}): Promise<PartyLedger | null> {
  await requireEither(...CUSTOMER_PERMISSIONS);
  return loadPartyLedger('CUSTOMER', {
    partyId: params.customerId,
    from: params.from,
    to: params.to,
  });
}

export async function getLedgerCustomerOptions(search?: string): Promise<readonly LedgerPartyOption[]> {
  await requireEither(...CUSTOMER_PERMISSIONS);
  return loadPartyOptions('CUSTOMER', search);
}

export async function getSupplierLedger(params: {
  readonly supplierId: string;
  readonly from: string;
  readonly to: string;
}): Promise<PartyLedger | null> {
  await requireEither(...SUPPLIER_PERMISSIONS);
  return loadPartyLedger('SUPPLIER', {
    partyId: params.supplierId,
    from: params.from,
    to: params.to,
  });
}

export async function getLedgerSupplierOptions(search?: string): Promise<readonly LedgerPartyOption[]> {
  await requireEither(...SUPPLIER_PERMISSIONS);
  return loadPartyOptions('SUPPLIER', search);
}
