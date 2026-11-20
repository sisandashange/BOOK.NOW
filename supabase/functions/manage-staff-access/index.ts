import { createClient } from "npm:@supabase/supabase-js@2";

const allowedOrigins = new Set([
  "https://getbooknow.co.za",
  "https://www.getbooknow.co.za",
]);

function readKey(mapName: string, legacyName: string): string | null {
  const raw = Deno.env.get(mapName);
  if (raw) {
    try {
      const parsed = JSON.parse(raw);
      if (typeof parsed?.default === "string" && parsed.default) return parsed.default;
    } catch {
      return raw;
    }
  }
  return Deno.env.get(legacyName) || null;
}

function corsHeaders(origin: string | null) {
  const allowed = origin && allowedOrigins.has(origin) ? origin : "https://getbooknow.co.za";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(body: unknown, status: number, origin: string | null) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders(origin), "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders(origin) });
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405, origin);
  if (origin && !allowedOrigins.has(origin)) return json({ error: "Origin not allowed." }, 403, origin);

  try {
    const authorization = req.headers.get("Authorization") || "";
    const token = authorization.replace(/^Bearer\s+/i, "");
    if (!token || token === authorization) return json({ error: "Sign in is required." }, 401, origin);

    const url = Deno.env.get("SUPABASE_URL");
    const publishableKey = readKey("SUPABASE_PUBLISHABLE_KEYS", "SUPABASE_ANON_KEY");
    const secretKey = readKey("SUPABASE_SECRET_KEYS", "SUPABASE_SERVICE_ROLE_KEY");
    if (!url || !publishableKey || !secretKey) {
      return json({ error: "Staff access management is not configured on the server." }, 500, origin);
    }

    const caller = createClient(url, publishableKey, {
      auth: { autoRefreshToken: false, persistSession: false },
      global: { headers: { Authorization: `Bearer ${token}` } },
    });
    const admin = createClient(url, secretKey, {
      auth: { autoRefreshToken: false, persistSession: false },
    });

    const { data: userData, error: userError } = await caller.auth.getUser(token);
    if (userError || !userData.user) return json({ error: "Your session is invalid. Please sign in again." }, 401, origin);

    const body = await req.json();
    const staffId = String(body?.staff_id || "");
    const storeId = String(body?.store_id || "");
    if (!staffId || !storeId || typeof body?.is_active !== "boolean") {
      return json({ error: "A staff member and valid access status are required." }, 400, origin);
    }

    const { data: store, error: storeError } = await caller
      .from("stores").select("id").eq("id", storeId)
      .eq("profile_id", userData.user.id).maybeSingle();
    if (storeError || !store) return json({ error: "You do not own this business." }, 403, origin);

    const { data: staff, error: staffError } = await caller
      .from("staff_members").select("id, store_id, user_id, is_active")
      .eq("id", staffId).eq("store_id", storeId).maybeSingle();
    if (staffError || !staff) return json({ error: "Staff member not found." }, 404, origin);

    const nextActive = body.is_active;

    if (nextActive) {
      // Unban before restoring the active row. If the row update fails, reapply the ban.
      if (staff.user_id) {
        const { error: authError } = await admin.auth.admin.updateUserById(staff.user_id, { ban_duration: "none" });
        if (authError) return json({ error: "Could not restore the staff login. No access changes were saved." }, 500, origin);
      }
      const { error: updateError } = await admin.from("staff_members")
        .update({ is_active: true, updated_at: new Date().toISOString() })
        .eq("id", staffId).eq("store_id", storeId);
      if (updateError) {
        if (staff.user_id) await admin.auth.admin.updateUserById(staff.user_id, { ban_duration: "876000h" });
        return json({ error: "Could not restore staff access. The login remains blocked." }, 500, origin);
      }
    } else {
      // Disable the RLS-protected staff row first. This immediately blocks protected
      // booking reads and acceptance, even if the Auth ban operation later fails.
      const { error: updateError } = await admin.from("staff_members")
        .update({ is_active: false, updated_at: new Date().toISOString() })
        .eq("id", staffId).eq("store_id", storeId);
      if (updateError) return json({ error: "Could not disable staff data access." }, 500, origin);

      if (staff.user_id) {
        const { error: authError } = await admin.auth.admin.updateUserById(staff.user_id, { ban_duration: "876000h" });
        if (authError) {
          return json({ error: "Booking access is disabled, but the login ban failed. Please retry this action." }, 500, origin);
        }
      }
    }

    return json({
      ok: true,
      message: nextActive ? "Staff access restored." : "Staff access disabled.",
    }, 200, origin);
  } catch (error) {
    console.error("manage-staff-access error", error);
    return json({ error: "Staff access could not be updated. Please try again." }, 500, origin);
  }
});
