'use client';

import * as React from 'react';
import { useRouter } from 'next/navigation';
import { Loader2, PackageCheck } from 'lucide-react';

import { Button } from '@/components/ui/button';
import { receiveTransferAction } from '@/server/services/vehicles/transfer-actions';

/**
 * Taking receipt at the destination — spec §35.
 *
 * Only offered to someone who can act for the receiving branch. Confirming a
 * transfer from the despatching end would make the handover a formality, and
 * the point of the in-transit state is that someone at the other end says the
 * vehicle actually arrived.
 */
export function TransferReceiveAction({
  transferId,
  toBranchName,
}: {
  readonly transferId: string;
  readonly toBranchName: string;
}) {
  const router = useRouter();
  const [pending, startTransition] = React.useTransition();
  const [error, setError] = React.useState<string | null>(null);

  const receive = () => {
    setError(null);
    startTransition(async () => {
      const result = await receiveTransferAction(transferId);
      if (!result.ok) {
        setError(result.error ?? 'The transfer could not be received.');
        return;
      }
      router.refresh();
    });
  };

  return (
    <div className="flex items-center justify-end gap-2">
      {error && <span className="text-[11px] text-danger-700">{error}</span>}
      <Button
        size="sm"
        variant="secondary"
        disabled={pending}
        onClick={receive}
        title={`Confirm arrival at ${toBranchName}`}
      >
        {pending ? <Loader2 className="animate-spin" aria-hidden /> : <PackageCheck aria-hidden />}
        Receive
      </Button>
    </div>
  );
}
