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
  experimental: {
    /**
     * Turbopack's persistent build cache, off on Railway only.
     *
     * Next 16.3 turned this on by default. It writes to `.next/cache`, which
     * Railway mounts as a volume shared across builds — so the cache outlives
     * the container that wrote it, and a single partial write poisons every
     * later build:
     *
     *   Cache corruption detected: checksum mismatch in block 273 of 00000109.sst
     *   TurbopackInternalError: Restore failures
     *
     * That is a hard build failure with nothing to do with the code being
     * deployed, and nothing in the repository can clear a Railway cache volume.
     * A warm cache is worth a minute of build time; it is not worth a deploy
     * pipeline that fails on its own history.
     *
     * Left on locally, where `.next/cache` sits in a stable working directory
     * that the same machine wrote, and where `npm run verify` builds often.
     */
    turbopackFileSystemCacheForBuild: !process.env.RAILWAY_ENVIRONMENT,
  },
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
