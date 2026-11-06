/* =========================================================
   SureTrack · Service Worker
   - Abre al instante y funciona sin conexión: guarda la app, el manifest, los iconos,
     las fuentes y las librerías (Tailwind, Chart.js y Supabase).
   - La página se sirve desde la caché y se comprueba en segundo plano si hay versión nueva:
     si la hay, se guarda y la app muestra «Hay una versión nueva · Actualizar».
   - Nunca guarda ni toca los datos de Supabase: cuentas y sincronización van siempre por internet.
   Si cambias la versión de una librería en index.html, cambia también CDN y sube VERSION.
   ========================================================= */
const VERSION = 'suretrack-v1';
const SHELL = ['./', './manifest.json', './icon.svg', './icon-192.png', './icon-512.png', './icon-maskable-512.png', './apple-touch-icon.png'];
const CDN = [
  'https://cdn.jsdelivr.net/npm/@tailwindcss/browser@4.1.18/dist/index.global.js',
  'https://cdn.jsdelivr.net/npm/chart.js@4.4.1/dist/chart.umd.js',
  'https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.117.3/dist/umd/supabase.js',
];
const FONTS_CSS = 'https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700;800&family=JetBrains+Mono:wght@400;500;600;700&display=swap';
const CDN_HOSTS = ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];
const SCOPE = self.registration.scope;   // https://danielrubio2005-jpg.github.io/suretrack/
const PAGE = SCOPE;                      // clave única de la página en la caché

const corsFetch = url => fetch(new Request(url, { mode: 'cors', credentials: 'omit' }));

/* ---------- Instalación: se guarda todo lo necesario para abrir sin conexión ---------- */
self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(VERSION);
    const put = (key, res) => (res && res.ok ? cache.put(key, res) : null);
    await Promise.all([
      ...SHELL.map(u => cache.add(new Request(u, { cache: 'reload' })).catch(() => {})),
      ...CDN.map(u => corsFetch(u).then(r => put(u, r)).catch(() => {})),
      // Fuentes: la hoja de estilos y los archivos de letra que enlaza
      corsFetch(FONTS_CSS).then(async r => {
        if (!r.ok) return;
        const css = await r.clone().text();
        await put(FONTS_CSS, r);
        const files = [...css.matchAll(/url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/g)].map(m => m[1]);
        await Promise.all(files.map(f => corsFetch(f).then(x => put(f, x)).catch(() => {})));
      }).catch(() => {}),
    ]);
    await self.skipWaiting();
  })());
});

/* ---------- Activación: borra cachés de versiones anteriores ---------- */
self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (key.startsWith('suretrack-') && key !== VERSION) await caches.delete(key);
    await self.clients.claim();
  })());
});

/* ---------- Peticiones ---------- */
self.addEventListener('fetch', event => {
  const req = event.request;
  if (req.method !== 'GET') return;                                   // guardar datos, iniciar sesión…: red
  const url = new URL(req.url);
  if (req.mode === 'navigate' && url.href.startsWith(SCOPE)) { event.respondWith(page(event)); return; }
  if (url.href.startsWith(SCOPE)) { event.respondWith(fresh(event)); return; }        // manifest e iconos
  if (CDN_HOSTS.includes(url.hostname)) { event.respondWith(stored(event)); return; } // librerías y fuentes
  // Todo lo demás (Supabase incluido) va directo a internet, sin caché.
});

/** La página: al instante desde la caché; en segundo plano se descarga la última y se avisa si cambió. */
async function page(event) {
  const cache = await caches.open(VERSION);
  const cached = await cache.match(PAGE);
  const oldText = cached ? cached.clone().text() : null;
  const update = fetch(PAGE, { cache: 'no-cache', credentials: 'same-origin' }).then(async res => {
    if (!res || !res.ok) return null;
    const changed = oldText && (await oldText) !== (await res.clone().text());
    await cache.put(PAGE, res.clone());
    if (changed) notify(event.resultingClientId);
    return res;
  }).catch(() => null);
  if (cached) { event.waitUntil(update); return cached; }
  return (await update) || new Response(
    '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width"><body style="background:#060709;color:#e4e4e7;font:16px system-ui;padding:32px">' +
    '<h1 style="font-size:20px">Sin conexión</h1><p>Abre SureTrack una vez con internet para poder usarla después sin conexión.</p></body>',
    { status: 503, headers: { 'Content-Type': 'text/html; charset=utf-8' } });
}

/** Manifest e iconos: desde la caché y se renuevan en segundo plano. */
async function fresh(event) {
  const req = event.request, cache = await caches.open(VERSION);
  const hit = await cache.match(req, { ignoreSearch: true });
  const net = fetch(req).then(res => { if (res && res.ok) event.waitUntil(cache.put(req, res.clone())); return res; }).catch(() => null);
  if (hit) { event.waitUntil(net); return hit; }
  return (await net) || Response.error();
}

/** Librerías y fuentes (con versión fija en la dirección): caché primero; si falta, se descarga y se guarda. */
async function stored(event) {
  const req = event.request, cache = await caches.open(VERSION);
  const hit = await cache.match(req.url);
  if (hit) return hit;
  try {
    let res = await corsFetch(req.url).catch(() => null);
    if (!res || !res.ok) res = await fetch(req);
    if (res.ok && res.type !== 'opaque') event.waitUntil(cache.put(req.url, res.clone()));
    return res;
  } catch { return Response.error(); }
}

/** Avisa a la página recién abierta de que hay una versión nueva. */
async function notify(clientId) {
  for (let i = 0; i < 10; i++) {
    const one = clientId ? await self.clients.get(clientId) : null;
    const list = one ? [one] : await self.clients.matchAll({ type: 'window' });
    if (list.length) { list.forEach(c => c.postMessage({ type: 'suretrack:update' })); return; }
    await new Promise(r => setTimeout(r, 500));
  }
}
