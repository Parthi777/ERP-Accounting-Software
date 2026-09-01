import type { NextConfig } from 'next';

const nextConfig: NextConfig = {
  // Railway runs the app from a self-contained server bundle.
  output: 'standalone',
  reactStrictMode: true,
  poweredByHeader: false,
  turbopack: {
    // Pin the workspace root. Without this, Turbopack walks up looking for a
    // lockfile and can settle on the user's home directory.
    root: import.meta.dirname,
  },
  // The PDF exporter reads two TTFs at runtime. Tracing only follows imports, so
  // a file opened by path is invisible to it and would be missing from the
  // standalone bundle — the export would still work, but silently fall back to
  // Helvetica and print INR instead of ₹. Naming the directory here makes Next
  // copy it. Both key forms are listed because the route path contains brackets,
  // which picomatch would otherwise read as a character class.
  outputFileTracingIncludes: {
    '/api/export/*': ['src/server/export/fonts/**'],
    '/api/export/\\[report\\]': ['src/server/export/fonts/**'],
  },
  // pdfkit and exceljs are CommonJS with dynamic requires; bundling them into
  // the server chunk breaks their internal resolution, so they stay external.
  serverExternalPackages: ['pdfkit', 'exceljs'],
  async headers() {
    return [
      {
        source: '/:path*',
        headers: [
          { key: 'X-Frame-Options', value: 'DENY' },
          { key: 'X-Content-Type-Options', value: 'nosniff' },
          { key: 'Referrer-Policy', value: 'strict-origin-when-cross-origin' },
          { key: 'Permissions-Policy', value: 'camera=(), microphone=(), geolocation=()' },
        ],
      },
    ];
  },
};

export default nextConfig;
