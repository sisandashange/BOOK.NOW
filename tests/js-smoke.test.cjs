"use strict";

const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

function read(file) {
  return fs.readFileSync(file, "utf8");
}

function checkInlineScripts(file) {
  const source = read(file);
  const scripts = [...source.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script\s*>/gi)]
    .filter(([, attrs, body]) => !/\bsrc\s*=/.test(attrs) && body.trim());
  for (let i = 0; i < scripts.length; i++) {
    new vm.Script(scripts[i][2], { filename: file + "#inline-" + (i + 1) });
  }
  return scripts.length;
}

const htmlFiles = ["index.html", "store.html", "manage.html", "vendor.html", "partners.html", "account.html"];
let inlineCount = 0;
for (const file of htmlFiles) inlineCount += checkInlineScripts(file);

for (const file of ["booking-utils.js", "qr.js", "i18n.js", "sw.js", "customer-account.js"]) {
  new vm.Script(read(file), { filename: file });
}

const utilityContext = { window: {}, TextEncoder };
vm.runInNewContext(read("booking-utils.js"), utilityContext);
const utils = utilityContext.window.BookingUtils;
assert.equal(utils.toMin("08:30"), 510);
assert.equal(utils.toMin("08:30:00"), 510);
assert.equal(utils.toMin("24:00"), 1440);
assert.ok(Number.isNaN(utils.toMin("24:01")));
assert.ok(Number.isNaN(utils.toMin("09:60")));
assert.ok(Number.isNaN(utils.toMin("not-a-time")));
assert.equal(utils.fmtMin(1440), "00:00");
assert.equal(utils.fmtMin(Number.NaN), "");
const expectedInstant = Date.parse("2026-02-28T00:00:00+02:00") + 1500 * 60_000;
assert.equal(utils.appointmentInstant("2026-02-28", 1500).getTime(), expectedInstant);
assert.ok(Number.isNaN(utils.appointmentInstant("2026-02-31", 600).getTime()));
assert.ok(Number.isNaN(utils.appointmentInstant("2026-02-28", Number.NaN).getTime()));

const qrContext = { window: {}, TextEncoder };
vm.runInNewContext(read("qr.js"), qrContext);
const qrSize = svg => {
  const match = svg.match(/viewBox="0 0 ([0-9]+) [0-9]+"/);
  assert.ok(match, "QR SVG should contain a viewBox");
  return Number(match[1]);
};
const asciiQrSize = qrSize(qrContext.window.BNQR.svg("A".repeat(50), { margin: 0 }));
const unicodeQrSize = qrSize(qrContext.window.BNQR.svg("🌸".repeat(25), { margin: 0 }));
assert.ok(unicodeQrSize > asciiQrSize, "QR encoder must count UTF-8 bytes for non-ASCII text");

const index = read("index.html");
assert.ok(index.indexOf('id="marketplace-status"') < index.indexOf('id="load-more-wrap"'),
  "Marketplace status must remain visible when pagination ends");
const customerNav = read("customer-account.js");
assert.ok(customerNav.includes('href="apps.html"'), "The navigation drawer must link to the separate apps page");
assert.ok(!index.includes("get-app-link") && !index.includes("partner-link"), "The homepage header must keep app and partner actions inside the drawer");
assert.ok(index.includes("store-favorite") && index.includes("customer_favorite_stores"), "Homepage must provide saved shop favourites");
assert.ok(index.includes('id="app-install-prompt"'), "Homepage must contain the app discovery prompt");
assert.ok(index.includes("booknow_app_download_started_at"), "Dismissed download prompts must stay suppressed after a download starts");
assert.ok(index.includes('new URLSearchParams(window.location.search).get("inapp") === "1"'), "The native wrapper can explicitly mark its in-app context");
assert.ok(!index.includes('class="app-downloads container"'), "Full APK cards must not remain on the homepage");
const apps = read("apps.html");
assert.ok(apps.includes("BOOK.NOW for Android"));
assert.ok(apps.includes("getbooknow.co.za"));
assert.ok(apps.includes("not Google Play Store listings"), "Direct APK distribution must be clearly disclosed");
assert.ok(apps.includes("BOOK.NOW.apk?download=BOOK.NOW.apk"), "Customer APK download must remain available");
assert.ok(apps.includes("BOOK.NOW%20PARTNER.apk?download=BOOK.NOW%20PARTNER.apk"), "Business APK download must remain available");
assert.ok(apps.includes("booknow_app_download_started_at"), "Starting an APK download must suppress later app prompts");
assert.ok(!apps.includes("window.location.replace(\"index.html\")"), "Apps page must remain accessible inside the installed app");
assert.ok(index.includes("MIN_REFRESH_GAP_MS"));
assert.match(index, /\.order\("created_at", \{ ascending: false \}\)\s*\.order\("id", \{ ascending: true \}\)/,
  "Marketplace pagination must use a stable unique tie-breaker");
assert.ok(index.includes("Top rated (loaded shops)"), "Sorting must remain usable before every shop is loaded");
assert.ok(index.includes("Name A to Z (loaded shops)"), "Name sorting must explain its loaded-results scope");
assert.ok(!/let\s+lastRefreshAt\s*=/.test(index));
assert.ok(!/Date\.now\(\)\s*-\s*lastRefreshAt/.test(index));

const store = read("store.html");
const manage = read("manage.html");
assert.ok(store.includes("const isShisanyamaOrder ="));
assert.ok(store.includes("Number(storeData.table_count)"));
assert.ok(store.includes("p_party_size: guests"));
assert.ok(!store.includes("Save receipt as image") && !store.includes("receipt-download"), "Booking confirmation must not export receipt images");
assert.ok(!manage.includes("Save receipt as image") && !manage.includes("receipt-download"), "Guest booking management must not export receipt images");
assert.ok(read("customer-account.js").includes('db.rpc("list_my_customer_booking_receipts")'), "Customer account must load in-app booking receipts");
assert.ok(read("account.html").includes('src="qr.js" defer'), "Customer account must load the QR renderer");

const vendor = read("vendor.html");
assert.ok(vendor.includes('.eq("status", "completed").eq("payment_status", "PAID")'),
  "Money Store must include only completed and paid bookings");
assert.ok(vendor.includes("confirmed your place among the first five launch businesses"),
  "First-five launch offer must be disclosed without granting it automatically");
assert.ok(vendor.includes('class:"staff-details"') && vendor.includes('class:"staff-summary"'),
  "Staff must be presented as a compact expandable directory");
assert.ok(vendor.includes('text:"Save weekly hours"') && vendor.includes('async function saveStaffWeek'),
  "Staff weekly hours must be saved together in one schedule action");
assert.ok(vendor.includes('.upsert(schedule, { onConflict: "staff_id,day_of_week" })'),
  "Weekly staff hours must retain the existing per-day upsert key");
assert.ok(vendor.includes('text:member.is_active?"Active":"Inactive"'),
  "Staff directory must show each worker's active status");
assert.ok(vendor.includes('text:"Permanently remove staff member"') && vendor.includes("async function deleteStaff(id,name,button)"),
  "Every staff member, including linked-login workers, must have a permanent removal action");
assert.ok(vendor.includes('.delete().eq("id",id).eq("store_id",storeId).select("id")'),
  "Permanent staff removal must be scoped to the active shop and verify the deletion");
assert.ok(vendor.includes("async function deleteService(service, button)") && vendor.includes("Service permanently deleted."),
  "Service removal must confirm permanent deletion and preserve booking history");
const subscriptionIntegrityMigration = read("supabase/migrations/20261128090000_harden_subscription_payment_requests.sql");
assert.ok(subscriptionIntegrityMigration.includes("guard_subscription_payment_request_insert"),
  "Subscription requests must be validated server-side");
assert.ok(subscriptionIntegrityMigration.includes("file_size_limit = 5242880"),
  "Subscription proof uploads must have a server-side 5 MB limit");
assert.ok(subscriptionIntegrityMigration.includes("allowed_mime_types"),
  "Subscription proof uploads must have a server-side MIME allowlist");
assert.ok(subscriptionIntegrityMigration.includes("Partners and founders can read platform settings"),
  "Platform bank settings must be limited to partners and founders");
assert.ok(vendor.includes('db.from("booking_items").select("item_title,quantity,unit_price,line_total")'), "Owner scanner must load itemised orders");
assert.ok(vendor.includes('db.from("store_bank_details")'));
assert.ok(!vendor.includes('db.from("stores").update({\n          bank_name'));
assert.ok(vendor.includes("Reserved for you · Accept to confirm the assignment"));
assert.ok(vendor.includes("available.length + reservedForMe.length"));

assert.ok(manage.includes('e.key === "ArrowRight"'));
assert.ok(manage.includes("requestedInstant.getTime()"));

const sw = read("sw.js");
assert.ok(sw.includes("CORE_PATHS.has(url.pathname)"));
assert.ok(sw.includes("url.origin + url.pathname"));
assert.ok(sw.includes("await cache.put(cacheKey, response.clone())"));
assert.ok(!/event\.waitUntil\(caches\.open\(CACHE\)/.test(sw));

const i18n = read("i18n.js");
assert.ok(i18n.includes("Object.prototype.hasOwnProperty.call(D, text)"));

console.log("BOOK.NOW smoke checks passed: " + inlineCount + " inline scripts, shared date helpers, UTF-8 QR, marketplace, Shisanyama, vendor privacy, accessibility and service worker.");
