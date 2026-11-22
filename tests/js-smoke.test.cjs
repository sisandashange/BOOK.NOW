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

const htmlFiles = ["index.html", "store.html", "manage.html", "vendor.html", "partners.html"];
let inlineCount = 0;
for (const file of htmlFiles) inlineCount += checkInlineScripts(file);

for (const file of ["booking-utils.js", "qr.js", "i18n.js", "sw.js"]) {
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
assert.ok(index.includes(".app-downloads { margin: 28px auto 8px;"));
assert.ok(index.includes("MIN_REFRESH_GAP_MS"));
assert.ok(!index.includes("lastRefreshAt"));

const store = read("store.html");
assert.ok(store.includes("const isShisanyamaOrder ="));
assert.ok(store.includes("Number(storeData.table_count)"));
assert.ok(store.includes("p_party_size: guests"));

const vendor = read("vendor.html");
assert.ok(vendor.includes('db.from("store_bank_details")'));
assert.ok(!vendor.includes('db.from("stores").update({\n          bank_name'));

const manage = read("manage.html");
assert.ok(manage.includes('e.key === "ArrowRight"'));
assert.ok(manage.includes("requestedInstant.getTime()"));

const sw = read("sw.js");
assert.ok(sw.includes("CORE_PATHS.has(url.pathname)"));
assert.ok(sw.includes("url.origin + url.pathname"));

const i18n = read("i18n.js");
assert.ok(i18n.includes("Object.prototype.hasOwnProperty.call(D, text)"));

console.log("BOOK.NOW smoke checks passed: " + inlineCount + " inline scripts, shared date helpers, UTF-8 QR, marketplace, Shisanyama, vendor privacy, accessibility and service worker.");
