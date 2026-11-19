import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const SUPABASE_URL = Deno.env.get("SUPABASE_URL")!;
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
const BUCKET = "receipt-downloads";
const ALLOWED_ORIGINS = new Set(["https://getbooknow.co.za", "https://www.getbooknow.co.za"]);

function headers(origin: string | null) {
  const allowed = origin && ALLOWED_ORIGINS.has(origin) ? origin : "https://getbooknow.co.za";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

async function storage(path: string, init: RequestInit) {
  return fetch(`${SUPABASE_URL}/storage/v1/${path}`, {
    ...init,
    headers: {
      "apikey": SERVICE_ROLE_KEY,
      "Authorization": `Bearer ${SERVICE_ROLE_KEY}`,
      ...(init.headers || {}),
    },
  });
}

Deno.serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const cors = headers(origin);
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST" || (origin && !ALLOWED_ORIGINS.has(origin))) {
    return new Response(JSON.stringify({ error: "Not allowed" }), { status: 403, headers: { ...cors, "Content-Type": "application/json" } });
  }

  try {
    const clientIp = req.headers.get("cf-connecting-ip") || req.headers.get("x-real-ip");
    if (!clientIp || clientIp.length > 64) {
      return new Response(JSON.stringify({ error: "Unable to verify download request" }), { status: 503, headers: { ...cors, "Content-Type": "application/json" } });
    }
    const limited = await fetch(SUPABASE_URL + "/rest/v1/rpc/consume_receipt_download_limit", {
      method: "POST",
      headers: { "apikey": SERVICE_ROLE_KEY, "Authorization": "Bearer " + SERVICE_ROLE_KEY, "Content-Type": "application/json" },
      body: JSON.stringify({ p_client_ip: clientIp }),
    });
    if (!limited.ok) throw new Error("Receipt download rate-limit check failed");
    if (await limited.json() !== true) {
      return new Response(JSON.stringify({ error: "Too many receipt downloads. Please try again in a few minutes." }), {
        status: 429, headers: { ...cors, "Content-Type": "application/json", "Retry-After": "600" },
      });
    }

    const body = await req.json();
    const encoded = typeof body?.imageBase64 === "string" ? body.imageBase64.replace(/^data:image\/png;base64,/, "") : "";
    if (!encoded || encoded.length > 2_100_000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(encoded)) {
      return new Response(JSON.stringify({ error: "Invalid receipt image" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
    }

    const binary = Uint8Array.from(atob(encoded), c => c.charCodeAt(0));
    if (binary.length < 8 || binary.length > 1_572_864 ||
        binary[0] !== 137 || binary[1] !== 80 || binary[2] !== 78 || binary[3] !== 71 ||
        binary[4] !== 13 || binary[5] !== 10 || binary[6] !== 26 || binary[7] !== 10) {
      return new Response(JSON.stringify({ error: "Invalid PNG image" }), { status: 400, headers: { ...cors, "Content-Type": "application/json" } });
    }

    // Opportunistically remove expired receipt files. Signed links last only 10 minutes.
    try {
      const listed = await storage(`object/list/${BUCKET}`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ prefix: "", limit: 1000, offset: 0, sortBy: { column: "created_at", order: "asc" } }),
      });
      if (listed.ok) {
        const items = await listed.json();
        const cutoff = Date.now() - 15 * 60 * 1000;
        const stale = (Array.isArray(items) ? items : [])
          .filter((item: any) => item.id && item.created_at && new Date(item.created_at).getTime() < cutoff)
          .map((item: any) => item.name)
          .filter((name: unknown) => typeof name === "string");
        if (stale.length) {
          await storage(`object/${BUCKET}`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: stale }) });
        }
      }
    } catch (_) { /* A cleanup failure must not block a customer's receipt. */ }

    const objectPath = `${crypto.randomUUID()}.png`;
    const uploaded = await storage(`object/${BUCKET}/${objectPath}`, {
      method: "POST",
      headers: { "Content-Type": "image/png", "x-upsert": "false" },
      body: binary,
    });
    if (!uploaded.ok) throw new Error("Receipt upload failed");

    const signed = await storage(`object/sign/${BUCKET}/${objectPath}`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ expiresIn: 600 }),
    });
    if (!signed.ok) {
      await storage(`object/${BUCKET}`, { method: "DELETE", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ prefixes: [objectPath] }) });
      throw new Error("Could not create secure download link");
    }
    const result = await signed.json();
    const signedPath = result.signedURL || result.signedUrl;
    if (typeof signedPath !== "string") throw new Error("Invalid signed download response");
    const url = signedPath.startsWith("http") ? signedPath : `${SUPABASE_URL}/storage/v1${signedPath.startsWith("/") ? "" : "/"}${signedPath}`;
    return new Response(JSON.stringify({ url, expiresIn: 600 }), { status: 200, headers: { ...cors, "Content-Type": "application/json", "Cache-Control": "no-store" } });
  } catch (error) {
    console.error("receipt-download:", error);
    return new Response(JSON.stringify({ error: "Unable to prepare receipt download" }), { status: 500, headers: { ...cors, "Content-Type": "application/json" } });
  }
});