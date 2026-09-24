import 'server-only';

import { requirePermission, requireTenantContext } from '@/server/auth/tenant-context';
import { createSupabaseServerClient } from '@/lib/supabase/server';

/**
 * Supporting files — spec §46; audit checklist §03 (0081).
 *
 * The file travels from the browser straight to the private `attachments`
 * bucket under the user's own session — the bucket's policy admits a path only
 * inside the user's dealer folder — and this records it against the document.
 * The row is append-only: evidence that can be removed is not evidence.
 */

export type AttachmentEntity =
  | 'JOURNAL_ENTRY' | 'PURCHASE_BILL' | 'SALE' | 'SERVICE_INVOICE' | 'BANK_TRANSACTION'
  | 'CASH_TRANSACTION' | 'APPROVAL_REQUEST' | 'FIXED_ASSET' | 'PARTY_NOTE' | 'GST_FILING'
  | 'PAYROLL_RUN' | 'LOAN';

export const ATTACHMENT_TYPES = [
  'application/pdf', 'image/png', 'image/jpeg', 'image/webp', 'text/csv',
  'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
] as const;
export const ATTACHMENT_MAX_BYTES = 10 * 1024 * 1024;

export interface Attachment {
  readonly id: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly sizeBytes: number;
  readonly createdAt: string;
  readonly uploadedBy: string;
  readonly url: string | null;
}

export async function listAttachments(entityType: AttachmentEntity, entityId: string): Promise<Attachment[]> {
  await requireTenantContext();
  const supabase = await createSupabaseServerClient();

  const { data, error } = await supabase
    .from('document_attachments')
    .select('id, storage_path, file_name, content_type, size_bytes, created_at, uploaded_by')
    .eq('entity_type', entityType)
    .eq('entity_id', entityId)
    .order('created_at');
  if (error) {
    throw new Error(`Failed to load attachments: ${error.message}`);
  }
  const rows = data ?? [];
  if (rows.length === 0) return [];

  // Short-lived links: an attachment URL copied out of the page stops working
  // in ten minutes, so access stays tied to a signed-in session.
  const { data: signed } = await supabase.storage
    .from('attachments')
    .createSignedUrls(rows.map((r) => r.storage_path), 600);
  const urlOf = new Map((signed ?? []).map((s) => [s.path, s.signedUrl]));

  const { data: people } = await supabase
    .from('user_profiles')
    .select('id, full_name')
    .in('id', [...new Set(rows.map((r) => r.uploaded_by))]);
  const nameOf = new Map((people ?? []).map((p) => [p.id, p.full_name]));

  return rows.map((r) => ({
    id: r.id,
    fileName: r.file_name,
    contentType: r.content_type,
    sizeBytes: Number(r.size_bytes),
    createdAt: r.created_at,
    uploadedBy: nameOf.get(r.uploaded_by) ?? 'Unknown',
    url: urlOf.get(r.storage_path) ?? null,
  }));
}

/** Records a file the browser has already placed in the dealer's folder. */
export async function recordAttachment(input: {
  readonly entityType: AttachmentEntity;
  readonly entityId: string;
  readonly storagePath: string;
  readonly fileName: string;
  readonly contentType: string;
  readonly sizeBytes: number;
}): Promise<{ ok: boolean; error?: string }> {
  const context = await requirePermission('attachments.upload');
  if (!context.dealerId || !input.storagePath.startsWith(`${context.dealerId}/`)) {
    return { ok: false, error: 'That file is not in your dealer’s folder.' };
  }
  if (!(ATTACHMENT_TYPES as readonly string[]).includes(input.contentType)) {
    return { ok: false, error: 'Attach a PDF, an image, a CSV or an Excel file.' };
  }
  if (input.sizeBytes <= 0 || input.sizeBytes > ATTACHMENT_MAX_BYTES) {
    return { ok: false, error: 'Files are limited to 10 MB.' };
  }

  const supabase = await createSupabaseServerClient();
  const { error } = await supabase.from('document_attachments').insert({
    dealer_id: context.dealerId,
    entity_type: input.entityType,
    entity_id: input.entityId,
    storage_path: input.storagePath,
    file_name: input.fileName.slice(0, 200),
    content_type: input.contentType,
    size_bytes: input.sizeBytes,
    uploaded_by: context.userId,
  });
  if (error) {
    return { ok: false, error: error.message };
  }
  return { ok: true };
}
