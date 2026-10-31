const SHEET_ORIGIN =
  "https://jkanrdxaidumlvpntudy.supabase.co/functions/v1/todo_sheet_public";

export default async (request: Request) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return new Response("허용되지 않은 요청입니다.", {
      status: 405,
      headers: { "content-type": "text/plain; charset=utf-8" },
    });
  }

  const incoming = new URL(request.url);
  const target = new URL(SHEET_ORIGIN);
  target.search = incoming.search;

  try {
    const upstream = await fetch(target, {
      method: "GET",
      headers: { accept: "text/html" },
    });
    const headers = new Headers();
    headers.set("content-type", "text/html; charset=utf-8");
    headers.set("cache-control", "private, no-store");
    headers.set("referrer-policy", "no-referrer");
    headers.set("x-robots-tag", "noindex");
    const body = request.method === "HEAD" ? null : await upstream.arrayBuffer();
    return new Response(body, { status: upstream.status, headers });
  } catch {
    return new Response(
      "<!doctype html><meta charset=utf-8><title>알림장</title><p>알림장을 열지 못했습니다.</p>",
      {
        status: 502,
        headers: { "content-type": "text/html; charset=utf-8" },
      },
    );
  }
};
