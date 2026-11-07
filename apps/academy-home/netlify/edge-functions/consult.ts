const CONSULT_ORIGIN =
  "https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/consultation_request";

export default async (request: Request) => {
  if (request.method !== "POST") {
    return new Response(JSON.stringify({ ok: false, message: "허용되지 않은 요청입니다." }), {
      status: 405,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }

  const body = await request.text();
  if (body.length > 4000) {
    return new Response(JSON.stringify({ ok: false, message: "내용이 너무 깁니다." }), {
      status: 413,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }

  try {
    const upstream = await fetch(CONSULT_ORIGIN, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body,
    });
    const text = await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      },
    });
  } catch {
    return new Response(
      JSON.stringify({
        ok: false,
        message: "신청을 받지 못했습니다. 잠시 후 다시 부탁드리겠습니다.",
      }),
      {
        status: 502,
        headers: { "content-type": "application/json; charset=utf-8" },
      },
    );
  }
};
