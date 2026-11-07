const NOTICES_ORIGIN =
  "https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/academy_notices_public";

export default async (request: Request) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response(JSON.stringify({ notices: [], message: "허용되지 않은 요청입니다." }), {
      status: 405,
      headers: { "content-type": "application/json; charset=utf-8" },
    });
  }

  try {
    const upstream = await fetch(NOTICES_ORIGIN, { method: "GET" });
    const text = request.method === "HEAD" ? null : await upstream.text();
    return new Response(text, {
      status: upstream.status,
      headers: {
        "content-type": "application/json; charset=utf-8",
        "cache-control": "no-store",
      },
    });
  } catch {
    return new Response(
      JSON.stringify({ notices: [], message: "공지를 불러오지 못했습니다." }),
      {
        status: 502,
        headers: { "content-type": "application/json; charset=utf-8" },
      },
    );
  }
};
