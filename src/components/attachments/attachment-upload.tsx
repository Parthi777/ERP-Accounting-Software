'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, Paperclip } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { getSupabaseBrowserClient } from '@/lib/supabase/client';
import { recordAttachmentAction } from '@/server/services/attachments/attachment-actions';
import type { AttachmentEntity } from '@/server/services/attachments/attachment-service';

const ACCEPT = '.pdf,.png,.jpg,.jpeg,.webp,.csv,.xlsx';
const MAX = 10 * 1024 * 1024;

/**
 * Uploads straight to the private bucket under the user's session (the bucket
 * admits only the dealer's own folder), then records it against the document.
 */
export function AttachmentUpload({
  dealerId,
  entityType,
  entityId,
  revalidate,
}: {
  readonly dealerId: string;
  readonly entityType: AttachmentEntity;
  readonly entityId: string;
  readonly revalidate: string;
}) {
  const router = useRouter();
  const input = React.useRef<HTMLInputElement>(null);
  const [error, setError] = React.useState<string | null>(null);
  const [pending, startTransition] = React.useTransition();

  const upload = (file: File) => {
    setError(null);
    if (file.size > MAX) return setError('Files are limited to 10 MB.');
    startTransition(async () => {
      const safe = file.name.replace(/[^A-Za-z0-9._-]+/g, '_').slice(-80);
      const path = `${dealerId}/${entityType}/${entityId}/${crypto.randomUUID()}-${safe}`;
      const supabase = getSupabaseBrowserClient();
      const { error: uploadError } = await supabase.storage
        .from('attachments')
        .upload(path, file, { contentType: file.type, upsert: false });
      if (uploadError) {
        setError(uploadError.message);
        return;
      }
      const result = await recordAttachmentAction(
        { entityType, entityId, storagePath: path, fileName: file.name, contentType: file.type, sizeBytes: file.size },
        revalidate,
      );
      if (!result.ok) {
        setError(result.error ?? 'The file uploaded but could not be recorded.');
        return;
      }
      router.refresh();
    });
  };

  return (
    <div className="flex flex-col gap-1">
      <input ref={input} type="file" accept={ACCEPT} className="hidden"
        onChange={(e) => { const f = e.target.files?.[0]; if (f) upload(f); e.target.value = ''; }} />
      <Button type="button" size="sm" variant="secondary" disabled={pending} onClick={() => input.current?.click()}>
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <Paperclip aria-hidden />}
        Attach a file
      </Button>
      {error && <span role="alert" className="text-xs text-danger-700">{error}</span>}
    </div>
  );
}
