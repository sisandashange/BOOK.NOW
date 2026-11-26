// BOOK.NOW service worker: network-first for known app files, with an offline shell.
const CACHE = "booknow-shell-v22";
const CORE_FILES = [
  "./",
  "./index.html",
  "./store.html",
  "./manage.html",
  "./account.html",
  "./customer-account.js",
  "./customer-account.css",
  "./vendor.html",
  "./partners.html",
  "./privacy.html",
  "./terms.html",
  "./booking-utils.js",
  "./qr.js",
  "./manifest.webmanifest",
  "./i18n.js",
  "./icon-192.png"
];
const CORE_PATHS = new Set(CORE_FILES.map(path => new URL(path, self.registration.scope).pathname));

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
        keys.filter(key => key.startsWith("booknow-shell-") && key !== CACHE)
          .map(key => caches.delete(key))
      ))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", event => {
  const req = event.request;
  const url = new URL(req.url);
  if (req.method !== "GET" || url.origin !== self.location.origin
      || /admin/i.test(url.pathname) || !CORE_PATHS.has(url.pathname)) return;

  // App pages are static: remove query parameters from cache keys so booking references
  // are never stored as separate offline cache entries.
  const cacheKey = new Request(url.origin + url.pathname, { method: "GET" });
  event.respondWith((async () => {
    let response;
    try {
      response = await fetch(req);
    } catch (_) {
      const cached = await caches.match(cacheKey);
      if (cached) return cached;
      if (req.mode === "navigate") {
        const shellUrl = new URL("./index.html", self.registration.scope).href;
        const shell = await caches.match(shellUrl);
        if (shell) return shell;
      }
      return new Response("You're offline. Reconnect to use BOOK.NOW.", {
        status: 503,
        headers: { "Content-Type": "text/plain; charset=utf-8" }
      });
    }

    // A cache-write failure must never turn a successful network response into an offline error.
    if (response.ok) {
      try {
        const cache = await caches.open(CACHE);
        await cache.put(cacheKey, response.clone());
      } catch (cacheError) {
        console.warn("BOOK.NOW offline cache update failed:", cacheError);
      }
    }
    return response;
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
      data: {
        url: data.url || (String(data.tag || "").startsWith("customer_") ? "manage.html" : "vendor.html"),
        tag: data.tag || ""
      }
    });
  })());
});

// Tapping an alert opens the app on the right page
self.addEventListener("notificationclick", event => {
  event.notification.close();
  const notificationData = event.notification.data || {};
  const fallbackUrl = String(notificationData.tag || "").startsWith("customer_") ? "manage.html" : "vendor.html";
  const target = new URL(notificationData.url || fallbackUrl, self.registration.scope).href;
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
