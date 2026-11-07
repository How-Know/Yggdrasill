import { createAdminClient } from '../_shared/supabase.ts';

function seoulToday(): string {
  return new Intl.DateTimeFormat('en-CA', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(new Date());
}

function reply(status: number, body: unknown) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8' },
  });
}

Deno.serve(async (req) => {
  if (req.method !== 'GET') {
    return reply(405, { notices: [], message: '허용되지 않은 요청입니다.' });
  }

  const admin = createAdminClient();
  const academies = await admin.from('academies').select('id').limit(2);
  if (academies.error || academies.data?.length !== 1) {
    return reply(200, { notices: [] });
  }

  const today = seoulToday();
  const listed = await admin
    .from('academy_notices')
    .select('closure_date, audience, note')
    .eq('academy_id', academies.data[0].id)
    .eq('kind', 'closure')
    .order('closure_date', { ascending: true });
  if (listed.error || !listed.data) {
    return reply(500, { notices: [], message: '공지를 불러오지 못했습니다.' });
  }

  const notices = listed.data.map((row) => {
    const date = String(row.closure_date ?? '');
    return {
      date,
      audience: String(row.audience ?? '전체'),
      note: String(row.note ?? ''),
      upcoming: date >= today,
    };
  });
  return reply(200, { notices });
});
