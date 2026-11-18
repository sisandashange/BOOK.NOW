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
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders(origin) });
  }
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
      return json({ error: "Staff invitations are not configured on the server." }, 500, origin);
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
    const email = String(body?.email || "").trim().toLowerCase();
    if (!staffId || !storeId || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
      return json({ error: "Enter a valid staff email address." }, 400, origin);
    }

    // Verify ownership with the caller's RLS-scoped client before using admin privileges.
    const { data: store, error: storeError } = await caller
      .from("stores").select("id").eq("id", storeId)
      .eq("profile_id", userData.user.id).maybeSingle();
    if (storeError || !store) return json({ error: "You do not own this business." }, 403, origin);

    const { data: staff, error: staffError } = await caller
      .from("staff_members").select("id, full_name, is_active, user_id")
      .eq("id", staffId).eq("store_id", storeId).maybeSingle();
    if (staffError || !staff || !staff.is_active) return json({ error: "Active staff member not found." }, 404, origin);
    if (staff.user_id) return json({ error: "This staff member already has a login." }, 409, origin);

    const redirectTo = "https://getbooknow.co.za/vendor.html?staff_invite=1";
    const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { full_name: staff.full_name },
      redirectTo,
    });
    if (inviteError || !invited.user) {
      return json({ error: inviteError?.message || "Could not send the invitation." }, 400, origin);
    }

    const { data: linkedStaff, error: linkError } = await admin.from("staff_members")
      .update({
        user_id: invited.user.id,
        invited_email: email,
        invite_status: "invited",
        invited_at: new Date().toISOString(),
      })
      .eq("id", staffId).eq("store_id", storeId).is("user_id", null)
      .select("id").maybeSingle();

    if (linkError || !linkedStaff) {
      // Do not delete the Auth user here: a concurrent invite may already have
      // linked this same identity to the staff row. An unlinked account has no
      // staff-row access and can be cleaned up safely by an administrator.
      return json({ error: "Invitation could not be linked to the staff record. No staff login was activated." }, 500, origin);
    }

    return json({ ok: true, message: "Invitation sent." }, 200, origin);
  } catch (error) {
    console.error("invite-staff error", error);
    return json({ error: "The invitation could not be sent. Please try again." }, 500, origin);
  }
});
