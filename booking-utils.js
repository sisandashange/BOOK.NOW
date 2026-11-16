/* BOOK.NOW shared South-African booking date/time helpers. */
(() => {
  "use strict";
  if (window.BookingUtils) return;
  function saNow() {
    const parts = new Intl.DateTimeFormat("en-GB", { timeZone: "Africa/Johannesburg", year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hourCycle: "h23" }).formatToParts(new Date());
    return Object.fromEntries(parts.filter(p => p.type !== "literal").map(p => [p.type, p.value]));
  }
  function toMin(hhmm) {
    const [h, m] = String(hhmm || "00:00").slice(0, 5).split(":").map(Number);
    return h * 60 + m;
  }
  function fmtMin(minutes) {
    const m = ((Number(minutes) % 1440) + 1440) % 1440;
    return String(Math.floor(m / 60)).padStart(2, "0") + ":" + String(m % 60).padStart(2, "0");
  }
  function saTodayStr() {
    const n = saNow();
    return n.year + "-" + n.month + "-" + n.day;
  }
  function currentBusinessDate(shop) {
    const now = saNow();
    const open = toMin(String((shop && shop.opening_time) || "08:00"));
    const closeRaw = toMin(String((shop && shop.closing_time) || "17:00"));
    const close = closeRaw <= open ? closeRaw + 1440 : closeRaw;
    const nowMin = Number(now.hour) * 60 + Number(now.minute);
    if (close > 1440 && nowMin < close - 1440) {
      const previous = new Date(Date.UTC(Number(now.year), Number(now.month) - 1, Number(now.day) - 1));
      return previous.toISOString().slice(0, 10);
    }
    return now.year + "-" + now.month + "-" + now.day;
  }
  function appointmentInstant(dateStr, minutes) {
    const midnight = new Date(String(dateStr) + "T00:00:00+02:00");
    return new Date(midnight.getTime() + Number(minutes) * 60000);
  }
  function fmtAppt(instant, duration) {
    const start = new Date(instant);
    if (!Number.isFinite(start.getTime())) return "Not set";
    const dateOptions = { weekday: "short", day: "numeric", month: "short", year: "numeric", timeZone: "Africa/Johannesburg" };
    const timeOptions = { hour: "2-digit", minute: "2-digit", hourCycle: "h23", timeZone: "Africa/Johannesburg" };
    const dateText = start.toLocaleDateString("en-ZA", dateOptions);
    const timeText = start.toLocaleTimeString("en-GB", timeOptions);
    let result = dateText + " at " + timeText;
    const minutes = Number(duration) || 0;
    if (minutes > 0) {
      const end = new Date(start.getTime() + minutes * 60000);
      const endTime = end.toLocaleTimeString("en-GB", timeOptions);
      const endDate = end.toLocaleDateString("en-ZA", dateOptions);
      result += " to " + (endDate !== dateText ? endDate + " " : "") + endTime;
    }
    return result;
  }
  window.BookingUtils = Object.freeze({ saNow, saTodayStr, toMin, fmtMin, currentBusinessDate, appointmentInstant, fmtAppt });
})();
