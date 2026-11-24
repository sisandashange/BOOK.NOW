import "jsr:@supabase/functions-js/edge-runtime.d.ts";

const ALLOWED_ORIGINS = new Set([
  "https://getbooknow.co.za",
  "https://www.getbooknow.co.za",
]);

function corsHeaders(origin) {
  const allowed = origin && ALLOWED_ORIGINS.has(origin)
    ? origin
    : "https://getbooknow.co.za";
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
    "Cache-Control": "no-store",
  };
}

Deno.serve((req) => {
  const origin = req.headers.get("origin");
  const headers = corsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers });
  }

  return new Response(
    JSON.stringify({
      error: "Receipt image downloads are no longer available. Open your receipt inside BOOK.NOW instead.",
    }),
    {
      status: 410,
      headers: { ...headers, "Content-Type": "application/json" },
    },
  );
});
