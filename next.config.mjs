/** @type {import('next').NextConfig} */
// Served under yashx.xyz/lifegame via the portfolio's rewrite, so every
// page, link and _next asset must live under /lifegame. Without this,
// assets resolve to /_next/... on the portfolio and the app is unstyled
// and the dashboard never renders.
const nextConfig = {
  basePath: "/lifegame",
};

export default nextConfig;
