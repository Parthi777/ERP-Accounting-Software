import { Bike } from 'lucide-react';

export default function AuthLayout({ children }: { children: React.ReactNode }) {
  return (
    <div className="flex min-h-dvh items-center justify-center px-4 py-12">
      <div className="w-full max-w-md">
        <div className="mb-8 flex items-center justify-center gap-3">
          <div className="flex size-12 items-center justify-center rounded-2xl bg-brand-600 text-white shadow-sm">
            <Bike className="size-7" aria-hidden />
          </div>
          <div>
            <p className="text-xl font-bold tracking-tight text-ink-900">TW ERP</p>
            <p className="text-xs text-ink-500">Two Wheeler Dealer ERP</p>
          </div>
        </div>

        {children}

        <p className="mt-6 text-center text-xs text-ink-400">
          © {new Date().getFullYear()} TW ERP · Accounting-first dealer management
        </p>
      </div>
    </div>
  );
}
