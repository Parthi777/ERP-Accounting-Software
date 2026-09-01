import 'server-only';

import { headers } from 'next/headers';

import { createSupabaseAdminClient } from '@/lib/supabase/server';
import { serverEnv } from '@/config/env';

/**
 * Records a non-table audit event.
 *
 * Row changes are captured automatically by `app.audit_trigger()` in migration
 * 0005. This covers the events that have no row behind them — a login, a branch
 * switch, an export — which spec §46 requires just the same.
 *
 * Writes go through the service-role client because `audit_logs` deliberately has
 * no INSERT policy and no INSERT grant for `authenticated`: a session must not be
 * able to forge its own audit trail.
 */

export type AuditAction =
  | 'CREATE'
  | 'UPDATE'
  | 'DELETE'
  | 'APPROVE'
  | 'REJECT'
  | 'POST'
  | 'CANCEL'
  | 'REVERSE'
  | 'LOGIN'
  | 'LOGIN_FAILED'
  | 'LOGOUT'
  | 'BRANCH_SWITCH'
  | 'PERMISSION_CHANGE'
  | 'ROLE_CHANGE'
  | 'STOCK_ADJUST'
  | 'PRICE_CHANGE'
  | 'GST_CHANGE'
  | 'DAY_CLOSE'
  | 'RECONCILE'
  | 'IMPORT'
  | 'EXPORT';

export interface AuditEvent {
  readonly action: AuditAction;
  readonly entityType: string;
  readonly entityId?: string | null;
  readonly dealerId?: string | null;
  readonly branchId?: string | null;
  readonly userId?: string | null;
  readonly userEmail?: string | null;
  readonly oldData?: unknown;
  readonly newData?: unknown;
  readonly changedFields?: readonly string[];
  /** Required for reversals and adjustments (spec §23, §36). */
  readonly reason?: string;
}

export async function recordAudit(event: AuditEvent): Promise<void> {
  try {
    const { ip, userAgent } = await requestMetadata();
    const supabase = createSupabaseAdminClient();

    const { error } = await supabase.from('audit_logs').insert({
      action: event.action,
      entity_type: event.entityType,
      entity_id: event.entityId ?? null,
      dealer_id: event.dealerId ?? null,
      branch_id: event.branchId ?? null,
      user_id: event.userId ?? null,
      user_email: event.userEmail ?? null,
      old_data: (event.oldData ?? null) as never,
      new_data: (event.newData ?? null) as never,
      changed_fields: event.changedFields ? [...event.changedFields] : null,
      reason: event.reason ?? null,
      ip_address: ip,
      user_agent: userAgent,
    });

    if (error) {
      console.error('[audit] failed to record event', { action: event.action, error: error.message });
    }
  } catch (error) {
    // An audit write must never take down the operation it is describing. It is
    // logged loudly instead — a missing audit row is a defect worth seeing.
    console.error('[audit] failed to record event', {
      action: event.action,
      error: error instanceof Error ? error.message : String(error),
    });
  }
}

async function requestMetadata(): Promise<{ ip: string | null; userAgent: string | null }> {
  try {
    const headerList = await headers();
    const forwardedFor = headerList.get('x-forwarded-for');
    return {
      ip: forwardedFor?.split(',')[0]?.trim() ?? headerList.get('x-real-ip') ?? null,
      userAgent: headerList.get('user-agent'),
    };
  } catch {
    // Called outside a request (a background job); metadata simply isn't available.
    return { ip: null, userAgent: null };
  }
}

/** True when audit writes can actually reach the database. */
export function canRecordAudit(): boolean {
  try {
    return Boolean(serverEnv().SUPABASE_SERVICE_ROLE_KEY);
  } catch {
    return false;
  }
}
