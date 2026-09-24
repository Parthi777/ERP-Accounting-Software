import 'server-only';

import { requirePermission, type TenantContext } from '@/server/auth/tenant-context';
import type { JournalStatus } from '@/types/database.types';
import type { SourceModule } from '@/server/repositories/accounting-repository';
import * as repository from '@/server/repositories/accounting-repository';

export type { SourceModule } from '@/server/repositories/accounting-repository';

export type {
  ChartAccount,
  JournalSummary,
  JournalDetail,
  JournalLine,
  TrialBalanceRow,
  StatementRow,
  TieoutRow,
  AgeingRow,
  AgeingPartyType,
} from '@/server/repositories/accounting-repository';

/**
 * Accounting reads.
 *
 * Each function asserts its permission, then delegates. Branch scoping is
 * resolved the same way the dashboard does it: a user without all-branch access
 * sees their active branch, and a branch id they cannot reach is ignored rather
 * than honoured (spec §47).
 */

function resolveBranch(context: TenantContext, requested: string | null): string | null {
  if (!requested) {
    return context.hasAllBranchAccess ? null : (context.activeBranch?.id ?? null);
  }
  const allowed = context.accessibleBranches.some((branch) => branch.id === requested);
  return allowed ? requested : (context.activeBranch?.id ?? null);
}

export async function getChartOfAccounts() {
  await requirePermission('accounting.coa.view');
  return repository.listChartOfAccounts();
}

export async function getJournals(params: {
  readonly from: string;
  readonly to: string;
  readonly branchId: string | null;
  readonly module: SourceModule | null;
  readonly status: JournalStatus | null;
  /**
   * Row cap. Defaults to the repository's 200, which is all the screen shows;
   * the report exporter raises it, because a journal register that stops at 200
   * entries without saying so is not a register.
   */
  readonly limit?: number;
}) {
  const context = await requirePermission('accounting.journals.view');
  return repository.listJournals({ ...params, branchId: resolveBranch(context, params.branchId) });
}

export async function getJournalDetail(id: string) {
  await requirePermission('accounting.journals.view');
  return repository.getJournal(id);
}

export async function getTrialBalance(asOn: string, branchId: string | null) {
  const context = await requirePermission('accounting.reports.view');
  return repository.getTrialBalance(asOn, resolveBranch(context, branchId));
}

export async function getProfitAndLoss(from: string, to: string, branchId: string | null) {
  const context = await requirePermission('accounting.reports.view');
  return repository.getProfitAndLoss(from, to, resolveBranch(context, branchId));
}

export async function getBalanceSheet(asOn: string, branchId: string | null) {
  const context = await requirePermission('accounting.reports.view');
  return repository.getBalanceSheet(asOn, resolveBranch(context, branchId));
}

/**
 * Every control account against its sub-ledger (0077). Dealer-wide by nature:
 * a bank book or a supplier balance is not a branch's, so there is no branch
 * filter to honour here.
 */
export async function getControlTieout(asOn: string) {
  await requirePermission('accounting.reports.view');
  return repository.getControlTieout(asOn);
}

/**
 * Who owes what, and for how long (0080). Dealer-wide: a customer's balance is
 * not a branch's, and ageing it per branch would split one debt in two.
 */
export async function getPartyAgeing(partyType: repository.AgeingPartyType, asOn: string) {
  await requirePermission('accounting.ledgers.view');
  return repository.getPartyAgeing(partyType, asOn);
}
