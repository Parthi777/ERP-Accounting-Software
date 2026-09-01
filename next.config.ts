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
