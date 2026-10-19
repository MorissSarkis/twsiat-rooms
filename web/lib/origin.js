// Public origin of the site. Behind Caddy, request.url is http://0.0.0.0:3000, so never trust it in production.
export function siteOrigin(request) {
  if (process.env.NEXT_PUBLIC_SITE_URL) return process.env.NEXT_PUBLIC_SITE_URL;
  const h = request.headers;
  const host = h.get('x-forwarded-host') || h.get('host');
  const proto = (h.get('x-forwarded-proto') || 'https').split(',')[0].trim();
  if (host && !host.startsWith('0.0.0.0')) return `${proto}://${host}`;
  return new URL(request.url).origin;
}
