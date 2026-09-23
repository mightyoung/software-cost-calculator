'use strict';
// Filled by tool/build_web_offline.py after Flutter has emitted final assets.
const RELEASE = '__SUPPLIER_RELEASE__';
const ASSETS = __SUPPLIER_ASSETS__;
const PREFIX = 'supplier-offline-' + encodeURIComponent(self.registration.scope) + '-';
const CACHE = PREFIX + RELEASE;
const root = new URL('./', self.location.href);
const hex = bytes => Array.from(new Uint8Array(bytes), x => x.toString(16).padStart(2, '0')).join('');
async function verifiedResource(path, expected) {
  const response = await fetch(new URL(path, root), {cache: 'no-store'});
  if (!response.ok || response.type === 'opaque') throw Error('Unavailable resource: ' + path);
  const actual = hex(await crypto.subtle.digest('SHA-256', await response.clone().arrayBuffer()));
  if (actual !== expected) throw Error('Resource version mismatch: ' + path);
  return response;
}

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    try {
      for (const [path, expected] of Object.entries(ASSETS)) {
        const url = new URL(path, root);
        await cache.put(url, await verifiedResource(path, expected));
      }
    } catch (error) {
      await caches.delete(CACHE);
      throw error;
    }
    // Deliberately no skipWaiting: never replace resources under open clients.
  })());
});

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const name of await caches.keys()) {
      if (name.startsWith(PREFIX) && name !== CACHE) await caches.delete(name);
    }
    // No clients.claim(): an uncontrolled first page reloads before Flutter.
  })());
});

self.addEventListener('message', event => {
  if (event.data?.type === 'supplier-release') event.ports[0]?.postMessage({release: RELEASE});
});

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (event.request.method !== 'GET' || url.origin !== root.origin || !url.pathname.startsWith(root.pathname)) return;
  let path = decodeURIComponent(url.pathname.slice(root.pathname.length));
  if (!path) path = 'index.html';
  if (!Object.hasOwn(ASSETS, path)) return;
  event.respondWith((async () => {
    // Repair cache eviction only with the exact pinned bytes. Never consume a
    // different release. Do not touch OPFS, IndexedDB, or business backups.
    const cache = await caches.open(CACHE);
    const url = new URL(path, root);
    const cached = await cache.match(url);
    if (cached) return cached;
    try {
      const response = await verifiedResource(path, ASSETS[path]);
      await cache.put(url, response.clone());
      return response;
    } catch (_) {
      return new Response('Cached application resource is missing. Reopen online with the matching release available.', {status: 503});
    }
  })());
});
