'use strict';
// Leader installation support only. No Cache API, offline records or API interception.
self.addEventListener('install', event => event.waitUntil(self.skipWaiting()));
self.addEventListener('activate', event => event.waitUntil(self.clients.claim()));
self.addEventListener('fetch', event => {
  const request = event.request;
  const url = new URL(request.url);
  const scope = new URL(self.registration.scope);
  // Never handle authentication, database, rider, or non-GET requests.
  if (request.method !== 'GET' || url.origin !== scope.origin ||
      !url.pathname.startsWith(scope.pathname)) return;
  event.respondWith(fetch(request, { cache: 'no-store' }).catch(() => {
    if (request.mode !== 'navigate') return Response.error();
    // Generic offline page contains no account or operational information.
    return new Response('<!doctype html><html lang="ar" dir="rtl"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>ToGo Leader</title><body style="font:18px sans-serif;padding:32px;background:#f5f1e9;color:#0f2238"><h1>ToGo Leader</h1><p>الاتصال بالإنترنت غير متاح. اتصل بالإنترنت ثم أعد فتح التطبيق.</p></body></html>', {
      status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-store' }
    });
  }));
});
