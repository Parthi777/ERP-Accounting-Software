import type { Metadata, Viewport } from 'next';
import { Plus_Jakarta_Sans } from 'next/font/google';

import './globals.css';

// Self-hosted by next/font at build time: no request reaches Google from the
// browser. Exposed as a variable so globals.css owns where it applies.
const jakarta = Plus_Jakarta_Sans({
  subsets: ['latin'],
  variable: '--font-jakarta',
  display: 'swap',
});

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
  themeColor: '#e9eff8',
  width: 'device-width',
  initialScale: 1,
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-IN" className={jakarta.variable}>
      <body className="antialiased">{children}</body>
    </html>
  );
}
