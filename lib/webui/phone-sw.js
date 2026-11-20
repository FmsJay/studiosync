// StudioSync's phone app (record.html installed on the phone; lib/phonerec.lua has the why): the Record page and the files it needs, kept
// here so it opens with no studio computer to reach. Only these files: every other page and the API go to the computer as they always did.
// GPL-3.0-or-later.
'use strict';
const CACHE = 'ss-phone-2';
const SHELL = ['record.html', 'record.js', 'record.css', 'recworklet.js', 'phonefile.js', 'style.css', 'phone.webmanifest', 'phone-icon-192.png', 'phone-icon-512.png',
  'phonedaw.js', 'phonedaw.css', 'sheet.css']; // (stage 2: the Project view, monitoring and the sheet; sheet.css is the Sheet page's own look, reused)
self.addEventListener('install', (e) => { e.waitUntil(caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())); });
self.addEventListener('activate', (e) => {
  e.waitUntil(caches.keys().then((ks) => Promise.all(ks.filter((k) => k !== CACHE).map((k) => caches.delete(k)))).then(() => self.clients.claim()));
});
self.addEventListener('fetch', (e) => {
  const u = new URL(e.request.url);
  const name = u.pathname.replace(/^\//, '');
  if (e.request.method === 'GET' && u.origin === location.origin && SHELL.includes(name)) e.respondWith(fresh(e.request, name));
});
// The computer's copy when it answers within a few seconds (kept for next time), else the kept one: a computer that's off can take 20 s to
// fail. A 403 (the studio's cookie gone) still opens the kept page, which says the link is needed; ?t='s redirect goes through untouched.
async function fresh(req, name) {
  const cache = await caches.open(CACHE);
  const kept = await cache.match(name);
  try {
    const r = await Promise.race([fetch(req), new Promise((res, rej) => setTimeout(() => rej(new Error('slow')), kept ? 3000 : 15000))]);
    if (r.type === 'opaqueredirect') return r;
    if (r.ok) { await cache.put(name, r.clone()); return r; }
    return kept || r;
  } catch (err) {
    if (kept) return kept;
    throw err;
  }
}
