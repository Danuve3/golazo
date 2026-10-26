// Golazo Infinito · service worker
// La app funciona sin conexión. La página y config.js se piden primero a la red
// para que cada visita reciba la última versión; si no hay red (o tarda), se usa
// la copia guardada. Iconos, imágenes y fuentes salen directamente de la caché.
const SHELL_CACHE = 'golazo-shell-v1';
const FONT_CACHE = 'golazo-fonts-v1';
const SHELL = [
  './',
  './index.html',
  './config.js',
  './manifest.webmanifest',
  './favicon.svg',
  './icons/icon-192.png',
  './icons/icon-512.png',
  './icons/apple-touch-icon.png'
];
const FRESH = /\/(index\.html|config\.js|manifest\.webmanifest)?$/;

self.addEventListener('install', event => {
  event.waitUntil(caches.open(SHELL_CACHE).then(cache => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(k => k.startsWith('golazo-') && k !== SHELL_CACHE && k !== FONT_CACHE).map(k => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

function networkFirst(request, cacheKey) {
  return caches.open(SHELL_CACHE).then(cache => new Promise(resolve => {
    let settled = false;
    const fromCache = () => cache.match(cacheKey, { ignoreSearch: true }).then(hit => hit || cache.match('./index.html'));
    const timer = setTimeout(() => {
      fromCache().then(hit => { if (hit && !settled) { settled = true; resolve(hit); } });
    }, 2500);
    fetch(request, { cache: 'no-cache' }).then(res => {
      if (res.ok) cache.put(cacheKey, res.clone());
      if (!settled) { settled = true; clearTimeout(timer); resolve(res); }
    }).catch(() => {
      clearTimeout(timer);
      fromCache().then(hit => { if (!settled) { settled = true; resolve(hit || Response.error()); } });
    });
  }));
}

self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;
  const url = new URL(req.url);

  if (url.origin === self.location.origin) {
    if (req.mode === 'navigate') { event.respondWith(networkFirst(req, './index.html')); return; }
    if (FRESH.test(url.pathname)) { event.respondWith(networkFirst(req, url.pathname)); return; }
    event.respondWith(
      caches.match(req, { ignoreSearch: true }).then(hit => hit || fetch(req).then(res => {
        if (res.ok) { const copy = res.clone(); caches.open(SHELL_CACHE).then(c => c.put(req, copy)); }
        return res;
      }))
    );
    return;
  }

  // Google Fonts: se guardan la primera vez y ya no hace falta red
  if (url.hostname === 'fonts.googleapis.com' || url.hostname === 'fonts.gstatic.com') {
    event.respondWith(caches.open(FONT_CACHE).then(async cache => {
      const hit = await cache.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === 'opaque') cache.put(req, res.clone());
      return res;
    }));
  }
  // Todo lo demás (el ranking en Supabase) va siempre a la red
});
