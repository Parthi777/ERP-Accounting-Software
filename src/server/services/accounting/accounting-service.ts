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
