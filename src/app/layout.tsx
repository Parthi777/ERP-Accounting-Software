import type { Metadata, Viewport } from 'next';

import './globals.css';

export const metadata: Metadata = {
  title: {
    default: 'TW ERP — Two Wheeler Dealer ERP',
    template: '%s · TW ERP',
  },
  description:
    'Multi-tenant, accounting-first ERP for two-wheeler dealers: sales, inventory, service, finance and double-entry accounting.',
  robots: { index: false, follow: false },
};

export const viewport: Viewport = {
  themeColor: '#f2f7ff',
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-IN">
      <body className="antialiased">{children}</body>
    </html>
  );
}
