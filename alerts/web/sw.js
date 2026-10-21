// Service worker: shows the alert notifications and opens the app when one is tapped.
self.addEventListener("install", () => self.skipWaiting());
self.addEventListener("activate", (e) => e.waitUntil(self.clients.claim()));

self.addEventListener("push", (event) => {
  let d = {};
  try { d = event.data ? event.data.json() : {}; } catch (_) { d = { title: "تنبيه", body: event.data && event.data.text() }; }
  const important = ["down", "up", "break"].includes(d.action);
  event.waitUntil(
    self.registration.showNotification(d.title || "تنبيه", {
      body: d.body || "",
      tag: d.tag || d.id,
      renotify: true,
      icon: "/icon-192.png",
      badge: "/badge.png",
      dir: "rtl",
      lang: "ar",
      requireInteraction: d.action === "break",
      vibrate: important ? [200, 100, 200] : [100],
      data: { url: d.url || "/#alerts" },
    })
  );
});

self.addEventListener("notificationclick", (event) => {
  event.notification.close();
  const url = (event.notification.data && event.notification.data.url) || "/#alerts";
  event.waitUntil(
    self.clients.matchAll({ type: "window", includeUncontrolled: true }).then((list) => {
      for (const c of list) {
        if ("focus" in c) { c.navigate(url); return c.focus(); }
      }
      return self.clients.openWindow(url);
    })
  );
});

// Network only: prices must always be live, never cached.
self.addEventListener("fetch", () => {});
