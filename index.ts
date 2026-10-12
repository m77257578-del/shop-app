// دالة Supabase Edge Function باسم "kashier": تنشئ جلسة دفع وتتحقق من نتيجتها.
// المفاتيح السرية تتخزن كـ Secrets على Supabase فقط، ولا تظهر في المتصفح.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};
const json = (o: unknown, status = 200) =>
  new Response(JSON.stringify(o), { status, headers: { ...cors, "Content-Type": "application/json" } });

async function hmacHex(key: string, msg: string) {
  const k = await crypto.subtle.importKey("raw", new TextEncoder().encode(key), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", k, new TextEncoder().encode(msg));
  return [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

// ترتيب الحقول المُوقَّعة في رابط العودة من Kashier (الحقل الغائب يُوقَّع بالكلمة null)
const FIELDS = ["paymentStatus", "cardDataToken", "maskedCard", "merchantOrderId", "orderId", "cardBrand", "orderReference", "transactionId", "amount", "currency"];

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  try {
    const body = await req.json();
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!);
    const orderId = Number(body.order_id), token = String(body.token ?? "");
    if (!orderId || !token) return json({ error: "bad_request" }, 400);

    const { data: o } = await sb.from("orders").select("*").eq("id", orderId).eq("token", token).maybeSingle();
    if (!o) return json({ error: "not_found" }, 404);
    const orderNo = `AS-${o.id}`;
    const base = { order_no: orderNo, total: o.total };

    // ---------- إنشاء جلسة الدفع ----------
    if (body.action === "create") {
      if (o.status !== "awaiting_payment") return json({ error: "bad_status" }, 400);
      if (o.session_url) return json({ url: o.session_url });
      const mid = Deno.env.get("KASHIER_MID"), apiKey = Deno.env.get("KASHIER_API_KEY"), secret = Deno.env.get("KASHIER_SECRET_KEY");
      if (!mid || !apiKey || !secret) return json({ error: "kashier_not_configured" }, 500);
      const live = (Deno.env.get("KASHIER_MODE") ?? "test").toLowerCase() === "live";
      const site = (Deno.env.get("SITE_URL") ?? req.headers.get("referer") ?? "").replace(/[?#].*$/, "");
      if (!site) return json({ error: "no_site_url" }, 500);
      const phone = String(o.customer?.phone ?? "").replace(/\D/g, "");
      const res = await fetch(`https://${live ? "" : "test-"}api.kashier.io/v3/payment/sessions`, {
        method: "POST",
        headers: { Authorization: secret, "api-key": apiKey, "Content-Type": "application/json" },
        body: JSON.stringify({
          expireAt: new Date(Date.now() + 60 * 60 * 1000).toISOString(),
          maxFailureAttempts: 3,
          paymentType: "credit",
          amount: Number(o.total).toFixed(2),
          currency: "EGP",
          order: orderNo,
          merchantId: mid,
          merchantRedirect: site,
          display: "ar",
          type: "one-time",
          description: `طلب ${orderNo}`,
          customer: { email: `${phone || "customer"}@example.com`, reference: phone || orderNo },
        }),
      });
      const j = await res.json().catch(() => ({}));
      if (!res.ok || !j.sessionUrl) return json({ error: "kashier_error", detail: j }, 502);
      await sb.from("orders").update({ session_url: j.sessionUrl }).eq("id", o.id);
      return json({ url: j.sessionUrl });
    }

    // ---------- التحقق من نتيجة الدفع ----------
    if (body.action === "verify") {
      if (o.status === "paid" || o.status === "delivered") return json({ status: "paid", ...base });
      if (o.status === "cancelled") return json({ status: "failed", ...base });
      const q = new URLSearchParams(String(body.query ?? ""));
      const apiKey = Deno.env.get("KASHIER_API_KEY");
      if (!apiKey || !q.get("signature")) return json({ status: "pending", ...base });
      const signed = FIELDS.map((f) => `${f}=${q.get(f) ?? "null"}`).join("&");
      const expected = await hmacHex(apiKey, signed);
      const okSig = expected === String(q.get("signature")).toLowerCase();
      const okOrder = q.get("merchantOrderId") === orderNo;
      const okAmount = Math.abs(Number(q.get("amount")) - Number(o.total)) < 0.01;
      if (!okSig || !okOrder || !okAmount) return json({ status: "pending", ...base });
      if (String(q.get("paymentStatus")).toUpperCase() === "SUCCESS") {
        await sb.from("orders").update({ status: "paid" }).eq("id", o.id).eq("status", "awaiting_payment");
        return json({ status: "paid", ...base });
      }
      await sb.rpc("internal_cancel_order", { p_id: o.id });
      return json({ status: "failed", ...base });
    }
    return json({ error: "bad_action" }, 400);
  } catch (e) {
    return json({ error: "server_error" }, 500);
  }
});
