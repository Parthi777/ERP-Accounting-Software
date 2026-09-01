import Link from 'next/link';
import { FileQuestion } from 'lucide-react';

import { Button } from '@/components/ui/button';

export default function NotFound() {
  return (
    <div className="flex min-h-dvh items-center justify-center px-4">
      <div className="glass w-full max-w-md rounded-2xl p-6 text-center">
        <div className="mx-auto mb-4 flex size-12 items-center justify-center rounded-2xl bg-ink-100 text-ink-500">
          <FileQuestion className="size-6" aria-hidden />
        </div>
        <h1 className="text-lg font-semibold text-ink-900">Page not found</h1>
        <p className="mt-2 text-sm text-ink-600">
          That page does not exist, or your role does not have access to it.
        </p>
        <Button asChild className="mt-5">
          <Link href="/dashboard">Back to dashboard</Link>
        </Button>
      </div>
    </div>
  );
}
