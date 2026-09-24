import { FileText } from 'lucide-react';

import { listAttachments, type AttachmentEntity } from '@/server/services/attachments/attachment-service';
import { requireTenantContext } from '@/server/auth/tenant-context';
import { Panel, PanelContent, PanelHeader, PanelTitle } from '@/components/ui/panel';
import { AttachmentUpload } from '@/components/attachments/attachment-upload';
import { formatDateTime } from '@/lib/format';

/** The paper behind a document — checklist §03 "source and attachments". */
export async function AttachmentsPanel({
  entityType,
  entityId,
  revalidate,
}: {
  readonly entityType: AttachmentEntity;
  readonly entityId: string;
  readonly revalidate: string;
}) {
  const [context, files] = await Promise.all([requireTenantContext(), listAttachments(entityType, entityId)]);
  const canUpload = context.permissions.has('attachments.upload') && !!context.dealerId;

  return (
    <Panel>
      <PanelHeader>
        <PanelTitle>Attachments</PanelTitle>
        {canUpload && (
          <AttachmentUpload dealerId={context.dealerId!} entityType={entityType} entityId={entityId} revalidate={revalidate} />
        )}
      </PanelHeader>
      <PanelContent>
        {files.length === 0 ? (
          <p className="text-sm text-ink-500">No supporting files yet. Attach the bill, statement or approval behind this entry.</p>
        ) : (
          <ul className="space-y-2">
            {files.map((f) => (
              <li key={f.id} className="clay-pit flex items-center gap-3 rounded-xl px-3 py-2">
                <FileText className="size-4 shrink-0 text-brand-600" aria-hidden />
                <span className="min-w-0 flex-1">
                  {f.url ? (
                    <a href={f.url} target="_blank" rel="noreferrer" className="block truncate text-sm font-semibold text-brand-700 hover:underline">
                      {f.fileName}
                    </a>
                  ) : (
                    <span className="block truncate text-sm font-semibold text-ink-800">{f.fileName}</span>
                  )}
                  <span className="block text-[11px] text-ink-500">
                    {Math.max(1, Math.round(f.sizeBytes / 1024))} KB · {f.uploadedBy} · {formatDateTime(f.createdAt)}
                  </span>
                </span>
              </li>
            ))}
          </ul>
        )}
      </PanelContent>
    </Panel>
  );
}
