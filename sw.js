// BOOK.NOW service worker: fast repeat visits and a cached app shell on weak networks.
const CACHE = "booknow-shell-v10";
const CORE_FILES = [
  "./",
  "./index.html",
  "./store.html",
  "./manage.html",
  "./vendor.html",
  "./booking-utils.js",
  "./qr.js",
  "./manifest.webmanifest",
  "./i18n.js",
  "./icon-192.png"
];

self.addEventListener("install", event => {
  event.waitUntil((async () => {
    const cache = await caches.open(CACHE);
    // Do not activate a partial shell: retain the previous worker if a core asset is missing.
    await Promise.all(CORE_FILES.map(async path => {
      const response = await fetch(path, { cache: "reload" });
      if (!response.ok) throw new Error("Required offline asset unavailable: " + path);
      await cache.put(path, response);
    }));
    await self.skipWaiting();
  })());
});

self.addEventListener("activate", event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(
        keys.filter(key => key.startsWith("booknow-") && key !== CACHE)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin || /admin/i.test(url.pathname)) return;

  // Serve a saved page or asset immediately, while refreshing it for the next visit.
  const networkPromise = fetch(req).then(response => {
    if (response.ok) {
      const copy = response.clone();
      event.waitUntil(caches.open(CACHE).then(cache => cache.put(req, copy)));
    }
    return response;
  });

  event.waitUntil(networkPromise.then(() => undefined).catch(() => undefined));
  event.respondWith((async () => {
    const cached = await caches.match(req);
    if (cached) return cached;

    try {
      return await networkPromise;
    } catch (_) {
      if (req.mode === "navigate") {
        const shell = await caches.match("./index.html") || await caches.match("./");
        if (shell) return shell;
      }
      return new Response("You're offline. Reconnect to use BOOK.NOW.", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" }
      });
    }
  })());
});

// ---- Phone alerts sent by the server (they arrive even when the app is closed) ----
self.addEventListener("push", event => {
  let data = {};
  try { data = event.data ? event.data.json() : {}; }
  catch (e) { data = { title: "BOOK.NOW", body: event.data ? event.data.text() : "" }; }

  event.waitUntil((async () => {
    const windows = await self.clients.matchAll({ type: "window", includeUncontrolled: true });
    const mine = windows.filter(w => w.url.startsWith(self.registration.scope));
    // Open pages are told to refresh. If the shop app is open in front it shows its own banner, so skip a second alert.
    // Customer alerts (data.always) are always shown, because the customer page does not show a banner.
    mine.forEach(w => w.postMessage({ type: "push", kind: data.tag || "" }));
    if (!data.always && mine.some(w => w.visibilityState === "visible")) return;
    await self.registration.showNotification(data.title || "BOOK.NOW", {
      body: data.body || "",
      icon: "icon-192.png",
      badge: "icon-192.png",
      tag: data.tag || "booknow",
      renotify: true,
      vibrate: [200, 100, 200],
      data: { url: data.url || "vendor.html" }
    });
  })());
});

// Tapping an alert opens the app on the right page
self.addEventListener("notificationclick", event => {
  event.notification.close();
  const target = new URL((event.notification.data && event.notification.data.url) || "vendor.html", self.registration.scope).href;
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then(async list => {
      for (const c of list) {
        if (c.url.startsWith(self.registration.scope) && "focus" in c) {
          // Reuse an existing app window, but navigate it to the notification's destination first.
          if ("navigate" in c && c.url !== target) {
            try { await c.navigate(target); } catch (_) { /* Focus remains a safe fallback. */ }
          }
          return c.focus();
        }
      }
      return self.clients.openWindow(target);
    })
  );
});
