// BOOK.NOW: sends phone alerts (Web Push).
// Shops and the founder: new bookings, cancellations, moved bookings, payment proofs, shop reports.
// Customers (if they turned alerts on for a booking): confirmed, 2-hour reminder, thanks and review invite.
// Called only by the database (it must send the shared secret). It is not a public endpoint.
import { createClient } from "npm:@supabase/supabase-js@2";
import webpush from "npm:web-push@3.6.7";

const admin = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

const json = (data: unknown, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { "Content-Type": "application/json" } });

async function readConfig(): Promise<Record<string, string>> {
  const { data, error } = await admin.from("push_config").select("key, value");
  if (error) throw error;
  return Object.fromEntries((data ?? []).map((r: { key: string; value: string }) => [r.key, r.value]));
}

function when(date?: string, time?: string): string {
  if (!date) return "";
  const d = new Date(date + "T12:00:00Z").toLocaleDateString("en-ZA", {
    weekday: "short", day: "numeric", month: "short", timeZone: "UTC",
  });
  return time ? `${d} at ${time}` : d;
}

function whenAppointment(appointmentAt?: string | null, fallbackDate?: string, fallbackTime?: string): string {
  if (!appointmentAt) return when(fallbackDate, fallbackTime);
  const date = new Date(appointmentAt);
  if (Number.isNaN(date.getTime())) return when(fallbackDate, fallbackTime);
  const parts = Object.fromEntries(new Intl.DateTimeFormat("en-ZA", {
    timeZone: "Africa/Johannesburg",
    weekday: "short",
    day: "numeric",
    month: "short",
    hour: "2-digit",
    minute: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date).filter((part) => part.type !== "literal").map((part) => [part.type, part.value]));
  return `${parts.weekday} ${parts.day} ${parts.month} at ${parts.hour}:${parts.minute}`;
}

const clean = (s: unknown, max = 60) => String(s ?? "").replace(/[\r\n]+/g, " ").slice(0, max);

const REPORT_REASONS: Record<string, string> = {
  wrong_info: "wrong information",
  unsafe: "safety concern",
  scam: "possible scam",
  other: "other",
};

type Sub = { id: string; endpoint: string; p256dh: string; auth_secret: string };

Deno.serve(async (req) => {
  try {
    if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

    const cfg = await readConfig();
    if (!cfg.shared_secret || req.headers.get("x-push-secret") !== cfg.shared_secret) {
      return json({ error: "Unauthorized" }, 401);
    }
    const body = await req.json().catch(() => ({} as Record<string, unknown>));

    // First run: create this project's own key pair for phone alerts
    if (!cfg.vapid_public || !cfg.vapid_private) {
      const keys = webpush.generateVAPIDKeys();
      const { error } = await admin.from("push_config").upsert([
        { key: "vapid_public", value: keys.publicKey },
        { key: "vapid_private", value: keys.privateKey },
      ]);
      if (error) throw error;
      cfg.vapid_public = keys.publicKey;
      cfg.vapid_private = keys.privateKey;
    }
    if (body.kind === "init") return json({ ok: true, publicKeyLength: cfg.vapid_public.length });

    // Work out who to tell and what to say
    let table = "push_subscriptions";          // shops and founder phones
    let ownerColumn = "user_id";
    let ownerId: string | null = null;
    let title = "BOOK.NOW";
    let text = "";
    let url = "vendor.html";
    let always = false;                         // customers always get a visible alert
    const kind = String(body.kind ?? "");
    const who = clean(body.customer_name, 40) || "A customer";
    const guests = Number(body.party_size) > 1 ? ` · ${Number(body.party_size)} guests` : "";

    if (kind === "booking_new" || kind === "booking_cancelled" || kind === "booking_moved") {
      const { data: store } = await admin.from("stores").select("profile_id").eq("id", body.store_id).maybeSingle();
      ownerId = store?.profile_id ?? null;
      if (kind === "booking_new") { title = "New booking"; text = `${who} · ${whenAppointment(body.appointment_at as string | null, body.booking_date as string, body.booking_time as string)}${guests}`; }
      if (kind === "booking_cancelled") { title = "Booking cancelled"; text = `${who} cancelled ${when(body.booking_date as string, body.booking_time as string)}`; }
      if (kind === "booking_moved") { title = "Booking moved"; text = `${who} moved to ${when(body.booking_date as string, body.booking_time as string)}`; }
    } else if (kind === "payment_proof") {
      const { data: store } = await admin.from("stores").select("store_name").eq("id", body.store_id).maybeSingle();
      ownerId = cfg.founder_user_id ?? null;
      title = "Payment proof received";
      text = `${clean(store?.store_name, 50) || "A shop"} uploaded proof for R${Number(body.amount ?? 0)}`;
      url = "founder.html";
    } else if (kind === "shop_report") {
      const { data: store } = await admin.from("stores").select("store_name").eq("id", body.store_id).maybeSingle();
      ownerId = cfg.founder_user_id ?? null;
      title = "Shop reported";
      text = `${clean(store?.store_name, 50) || "A shop"}: ${REPORT_REASONS[String(body.reason)] ?? "other"}`;
      url = "founder.html";
    } else if (kind === "customer_confirmed" || kind === "customer_reminder" || kind === "customer_completed") {
      // Details come from the database, not from the request
      const { data: bk } = await admin.from("bookings")
        .select("id, store_id, booking_date, booking_time, appointment_at, payment_ref, status").eq("id", body.booking_id).maybeSingle();
      if (!bk) return json({ sent: 0, note: "No booking" });
      const status = String(bk.status ?? "").toLowerCase();
      if (kind === "customer_reminder" && status !== "pending" && status !== "confirmed") return json({ sent: 0, note: "Booking no longer active" });
      const { data: store } = await admin.from("stores").select("store_name").eq("id", bk.store_id).maybeSingle();
      const shop = clean(store?.store_name, 50) || "the shop";
      const slot = whenAppointment(bk.appointment_at, bk.booking_date, bk.booking_time);
      table = "customer_push_subscriptions";
      ownerColumn = "booking_id";
      ownerId = bk.id;
      always = true;
      url = `manage.html?ref=${encodeURIComponent(String(bk.payment_ref ?? ""))}`;
      if (kind === "customer_confirmed") { title = "Booking confirmed"; text = `${shop} confirmed your booking for ${slot}.`; }
      if (kind === "customer_reminder") { title = "Booking reminder"; text = `${shop} · ${slot}. See you soon!`; }
      if (kind === "customer_completed") { title = "How was your visit?"; text = `Thanks for visiting ${shop}. Tap to rate your visit.`; }
    } else if (kind === "test") {
      ownerId = String(body.user_id ?? "");
      title = "BOOK.NOW test";
      text = "Phone alerts are working.";
      url = String(body.url ?? "vendor.html");
    } else {
      return json({ error: "Unknown kind" }, 400);
    }

    if (!ownerId) return json({ sent: 0, note: "No recipient" });

    const { data: subs, error: subErr } = await admin
      .from(table).select("id, endpoint, p256dh, auth_secret").eq(ownerColumn, ownerId);
    if (subErr) throw subErr;
    let sent = 0, removed = 0, failed = 0;
    const results: Array<Record<string, unknown>> = [];

    // Web Push is optional: native OneSignal delivery must still run when
    // this vendor account has no browser push subscription.
    if (subs && subs.length > 0) {
      webpush.setVapidDetails(`mailto:${cfg.contact_email ?? "admin@example.com"}`, cfg.vapid_public, cfg.vapid_private);

      const payload = JSON.stringify({
        title, body: text, url, always,
        tag: `${kind}-${String(body.booking_id ?? body.store_id ?? "x")}`,
      });

      for (const s of subs as Sub[]) {
        try {
          const res = await webpush.sendNotification(
            { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth_secret } },
            payload,
            { TTL: 60 * 60 * 24, urgency: "high" },
          );
          sent++;
          results.push({ status: res.statusCode });
        } catch (err) {
          const status = (err as { statusCode?: number }).statusCode;
          if (status === 404 || status === 410) {
            await admin.from(table).delete().eq("id", s.id);
            removed++;
          } else {
            failed++;
          }
          results.push({ status: status ?? null, error: String((err as Error).message ?? err).slice(0, 120) });
        }
      }
    }
    // Native Median/OneSignal delivery for vendor and founder user accounts.
    // The Web Push channel above remains unchanged and continues working independently.
    let onesignalSent = false;
    let onesignalError: string | null = null;
    const onesignalAppId = Deno.env.get("ONESIGNAL_APP_ID");
    const onesignalRestKey = Deno.env.get("ONESIGNAL_REST_API_KEY");
    const vendorKinds = ["booking_new", "booking_cancelled", "booking_moved", "payment_proof", "shop_report", "test"];
    if (ownerId && vendorKinds.includes(kind) && onesignalAppId && onesignalRestKey) {
      try {
        const osResponse = await fetch("https://api.onesignal.com/notifications", {
          method: "POST",
          headers: {
            "Content-Type": "application/json; charset=utf-8",
            "Authorization": `Key ${onesignalRestKey}`,
          },
          body: JSON.stringify({
            app_id: onesignalAppId,
            target_channel: "push",
            include_aliases: { external_id: [ownerId] },
            headings: { en: title },
            contents: { en: text },
            url: new URL(url, "https://getbooknow.co.za/").toString(),
            data: {
              kind,
              store_id: body.store_id ?? null,
              booking_id: body.booking_id ?? null,
              targetUrl: new URL(url, "https://getbooknow.co.za/").toString(),
            },
          }),
        });
        const osBody = await osResponse.json().catch(() => ({}));
        if (!osResponse.ok) {
          onesignalError = String(osBody.errors?.[0] ?? osBody.message ?? `OneSignal HTTP ${osResponse.status}`).slice(0, 180);
          console.error("OneSignal delivery failed:", onesignalError);
        } else {
          onesignalSent = Boolean(osBody.id);
        }
      } catch (err) {
        onesignalError = String((err as Error).message ?? err).slice(0, 180);
        console.error("OneSignal request error:", onesignalError);
      }
    }
    // Native OneSignal delivery for customer bookings, targeted to exact device subscriptions.
    let customerOneSignalSent = 0;
    let customerOneSignalError: string | null = null;
    const customerKinds = ["customer_confirmed", "customer_reminder", "customer_completed"];
    if (ownerId && customerKinds.includes(kind) && onesignalAppId && onesignalRestKey) {
      const { data: nativeSubs, error: nativeSubErr } = await admin
        .from("customer_onesignal_subscriptions")
        .select("subscription_id")
        .eq("booking_id", ownerId);
      if (nativeSubErr) {
        customerOneSignalError = "Could not load customer notification subscriptions";
        console.error("Customer OneSignal lookup failed:", nativeSubErr);
      } else if (nativeSubs && nativeSubs.length) {
        try {
          const osResponse = await fetch("https://api.onesignal.com/notifications", {
            method: "POST",
            headers: {
              "Content-Type": "application/json; charset=utf-8",
              "Authorization": `Key ${onesignalRestKey}`,
            },
            body: JSON.stringify({
              app_id: onesignalAppId,
              target_channel: "push",
              include_subscription_ids: nativeSubs.map((s: { subscription_id: string }) => s.subscription_id),
              headings: { en: title },
              contents: { en: text },
              url: new URL(url, "https://getbooknow.co.za/").toString(),
              data: {
                kind,
                booking_id: ownerId,
                targetUrl: new URL(url, "https://getbooknow.co.za/").toString(),
              },
            }),
          });
          const osBody = await osResponse.json().catch(() => ({}));
          if (!osResponse.ok || !osBody.id) {
            customerOneSignalError = String(osBody.errors?.[0] ?? osBody.message ?? `OneSignal HTTP ${osResponse.status}`).slice(0, 180);
            console.error("Customer OneSignal delivery failed:", customerOneSignalError);
          } else {
            customerOneSignalSent = nativeSubs.length;
          }
        } catch (err) {
          customerOneSignalError = String((err as Error).message ?? err).slice(0, 180);
          console.error("Customer OneSignal request error:", customerOneSignalError);
        }
      }
    }
    return json({ kind, sent, removed, failed, results, onesignal_sent: onesignalSent, customer_onesignal_sent: customerOneSignalSent, customer_onesignal_error: customerOneSignalError,
      onesignal_configured: Boolean(onesignalAppId && onesignalRestKey) });
  } catch (err) {
    console.error("send-push error:", err);
    return json({ error: String((err as Error).message ?? err) }, 500);
  }
});
