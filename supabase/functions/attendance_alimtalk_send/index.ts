import { corsHeaders } from '../_shared/cors.ts';
import { createAdminClient } from '../_shared/supabase.ts';

type QueueRow = {
  id: string;
  attendance_id: string;
  academy_id: string;
  student_id: string;
  event_type: 'arrival' | 'departure' | 'late';
  status: string;
  attempts: number;
};

const BIZ_DOMAIN = (Deno.env.get('BIZPPURIO_DOMAIN') ?? 'api.bizppurio.com').trim();
const BIZ_ACCOUNT = (Deno.env.get('BIZPPURIO_ACCOUNT') ?? '').trim();
const BIZ_PASSWORD = (Deno.env.get('BIZPPURIO_PASSWORD') ?? '').trim();
const CRON_SECRET = (Deno.env.get('ALIMTALK_CRON_SECRET') ?? '').trim();
const BATCH_SIZE = Number.parseInt(Deno.env.get('ALIMTALK_BATCH_SIZE') ?? '20', 10);
const MAX_ATTEMPTS = Number.parseInt(Deno.env.get('ALIMTALK_MAX_ATTEMPTS') ?? '5', 10);

function json(body: unknown) {
  return new Response(JSON.stringify(body), {
    status: 200,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

function ok(body: Record<string, unknown> = {}) {
  return json({ ok: true, ...body });
}

function fail(code: string, error: string) {
  return json({ ok: false, code, error });
}

function digitsOnly(value?: string | null) {
  return (value ?? '').replace(/[^0-9]/g, '');
}

function formatKstDate(d: Date) {
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(d);
}

function formatKstTime(d: Date) {
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(d);
}

function renderTemplate(template: string, params: Record<string, string>) {
  let out = template;
  for (const [key, value] of Object.entries(params)) {
    const safe = value ?? '';
    out = out.replaceAll(`#{${key}}`, safe);
    out = out.replaceAll(`{{${key}}}`, safe);
    out = out.replaceAll(`{${key}}`, safe);
  }
  return out;
}

async function fetchEgressIp(): Promise<string | null> {
  const endpoints = [
    'https://api64.ipify.org?format=json',
    'https://api.ipify.org?format=json',
    'https://ifconfig.me/ip',
  ];
  for (const endpoint of endpoints) {
    try {
      const res = await fetch(endpoint, { method: 'GET' });
      if (!res.ok) continue;
      const text = (await res.text()).trim();
      if (!text) continue;
      if (text.startsWith('{')) {
        try {
          const json = JSON.parse(text) as Record<string, unknown>;
          const ip = String(json.ip ?? '').trim();
          if (ip) return ip;
        } catch (_) {
          // ignore
        }
      }
      const match = text.match(/[0-9a-fA-F:.]{7,}/);
      if (match?.[0]) return match[0];
    } catch (_) {
      // ignore and try next endpoint
    }
  }
  return null;
}

async function issueBizppurioToken() {
  if (!BIZ_ACCOUNT || !BIZ_PASSWORD) {
    throw new Error('missing_bizppurio_credentials');
  }
  const basic = btoa(`${BIZ_ACCOUNT}:${BIZ_PASSWORD}`);
  const res = await fetch(`https://${BIZ_DOMAIN}/v1/token`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
    },
  });
  const text = await res.text();
  let data: Record<string, unknown> = {};
  try { data = JSON.parse(text); } catch (_) {}
  const token = String(data.accesstoken ?? '');
  const code = String(data.code ?? '');
  if (!res.ok || !token || (code && code !== '1000')) {
    throw new Error(`token_issue_failed:${code || res.status}`);
  }
  return token;
}

function buildRefKey(queueId: string, eventType: string) {
  const base = queueId.replace(/[^0-9a-f]/gi, '').slice(0, 24);
  const suffix = eventType.slice(0, 2);
  return `${base}${suffix}`;
}

async function sendBizppurioAlimtalk(token: string, payload: Record<string, unknown>) {
  const res = await fetch(`https://${BIZ_DOMAIN}/v3/message`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${token}`,
      'Content-Type': 'application/json',
      charset: 'utf-8',
    },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  let data: Record<string, unknown> = {};
  try { data = JSON.parse(text); } catch (_) {}
  const code = String(data.code ?? '');
  const messageId = String(data.messagekey ?? data.messageKey ?? '');
  const ok = res.ok && code === '1000';
  return { ok, code, messageId, raw: text, data };
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (req.method !== 'POST' && req.method !== 'GET') {
    return fail('method_not_allowed', 'Method not allowed');
  }
  let requestBody: Record<string, unknown> = {};
  if (req.method === 'POST') {
    try {
      requestBody = await req.json();
    } catch (_) {
      requestBody = {};
    }
  }
  const forceQueueId = String(requestBody?.queue_id ?? '').trim() || null;
  if (CRON_SECRET) {
    const secret = req.headers.get('x-cron-secret') ?? '';
    if (secret !== CRON_SECRET) {
      return fail('unauthorized', 'Invalid cron secret');
    }
  }
  if (!BIZ_ACCOUNT || !BIZ_PASSWORD) {
    return fail('missing_bizppurio_credentials', 'Missing Bizppurio account or password');
  }

  const admin = createAdminClient();
  const egressIp = await fetchEgressIp();
  let lateEnqueued = 0;
  try {
    const lateLimit = Math.max(BATCH_SIZE * 5, 50);
    const { data: lateData, error: lateErr } = await admin.rpc(
      'enqueue_due_late_notifications',
      { p_limit: lateLimit },
    );
    if (!lateErr) {
      const parsed = Number(lateData ?? 0);
      if (Number.isFinite(parsed)) lateEnqueued = parsed;
    } else {
      console.warn('[attendance_alimtalk_send] late enqueue rpc error', lateErr.message);
    }
  } catch (e) {
    console.warn('[attendance_alimtalk_send] late enqueue rpc exception', String(e));
  }

  let queueQuery = admin
    .from('attendance_notification_queue')
    .select('id, attendance_id, academy_id, student_id, event_type, status, attempts')
    .in('status', ['pending', 'error'])
    .lt('attempts', MAX_ATTEMPTS);
  if (forceQueueId) {
    queueQuery = queueQuery.eq('id', forceQueueId).limit(1);
  } else {
    queueQuery = queueQuery.order('created_at', { ascending: true }).limit(BATCH_SIZE);
  }
  const { data: queueRows, error: queueErr } = await queueQuery;

  if (queueErr) {
    return fail('queue_fetch_failed', queueErr.message);
  }
  if (!queueRows || queueRows.length === 0) {
    return ok({
      processed: 0,
      sent: 0,
      skipped: 0,
      failed: 0,
      lateEnqueued,
      requestedQueueId: forceQueueId,
      egressIp,
    });
  }

  let processed = 0;
  let sent = 0;
  let skipped = 0;
  let failed = 0;
  let token: string | null = null;

  const handledQueueIds: string[] = [];
  for (const row of queueRows as QueueRow[]) {
    handledQueueIds.push(row.id);
    processed += 1;
    const { data: locked } = await admin
      .from('attendance_notification_queue')
      .update({
        status: 'processing',
        attempts: row.attempts + 1,
        last_error: null,
      })
      .eq('id', row.id)
      .in('status', ['pending', 'error'])
      .select('id')
      .maybeSingle();

    if (!locked) continue;

    const { data: attendance, error: attendanceErr } = await admin
      .from('attendance_records')
      .select('id, academy_id, student_id, date, class_date_time, class_end_time, arrival_time, departure_time')
      .eq('id', row.attendance_id)
      .maybeSingle();
    if (attendanceErr || !attendance) {
      await admin.from('attendance_notification_queue').update({
        status: 'error',
        last_error: attendanceErr?.message ?? 'attendance_not_found',
      }).eq('id', row.id);
      failed += 1;
      continue;
    }

    const { data: student } = await admin
      .from('students')
      .select('id, name')
      .eq('id', attendance.student_id)
      .maybeSingle();

    const { data: basicInfo } = await admin
      .from('student_basic_info')
      .select('student_id, parent_phone_number, notification_consent')
      .eq('student_id', attendance.student_id)
      .maybeSingle();

    const { data: paymentInfo } = await admin
      .from('student_payment_info')
      .select('student_id, lateness_threshold, attendance_notification, departure_notification, lateness_notification')
      .eq('student_id', attendance.student_id)
      .maybeSingle();

    const { data: academySettings } = await admin
      .from('academy_settings')
      .select('academy_id, name')
      .eq('academy_id', attendance.academy_id)
      .maybeSingle();

    const { data: alimtalkSettings } = await admin
      .from('academy_alimtalk_settings')
      .select('academy_id, sender_key, sender_number, arrival_template_code, arrival_message_template, departure_template_code, departure_message_template, late_template_code, late_message_template, enabled')
      .eq('academy_id', attendance.academy_id)
      .maybeSingle();

    if (!alimtalkSettings) {
      await admin.from('attendance_notification_queue').update({
        status: 'error',
        last_error: 'missing_academy_alimtalk_settings',
      }).eq('id', row.id);
      failed += 1;
      continue;
    }

    if (!alimtalkSettings.sender_key || !alimtalkSettings.sender_number) {
      await admin.from('attendance_notification_queue').update({
        status: 'error',
        last_error: 'missing_sender_info',
      }).eq('id', row.id);
      failed += 1;
      continue;
    }

    const consented = basicInfo?.notification_consent === true;
    if (!consented) {
      await admin.from('attendance_notification_queue').update({
        status: 'skipped',
        last_error: 'notification_consent_required',
      }).eq('id', row.id);
      skipped += 1;
      continue;
    }

    const parentPhone = digitsOnly(basicInfo?.parent_phone_number);
    if (!parentPhone) {
      await admin.from('attendance_notification_queue').update({
        status: 'skipped',
        last_error: 'missing_parent_phone',
      }).eq('id', row.id);
      skipped += 1;
      continue;
    }

    if (!alimtalkSettings?.enabled) {
      await admin.from('attendance_notification_queue').update({
        status: 'skipped',
        last_error: 'alimtalk_disabled',
      }).eq('id', row.id);
      skipped += 1;
      continue;
    }

    const classDt = attendance.class_date_time ? new Date(attendance.class_date_time) : null;
    const arrivalDt = attendance.arrival_time ? new Date(attendance.arrival_time) : null;
    const departureDt = attendance.departure_time ? new Date(attendance.departure_time) : null;
    const threshold = Number(paymentInfo?.lateness_threshold ?? 10);
    const thresholdMs = Math.max(0, threshold) * 60 * 1000;
    const nowMs = Date.now();
    const lateByArrival = !!(arrivalDt && classDt && arrivalDt.getTime() > classDt.getTime() + thresholdMs);
    const lateByNoArrival = !!(classDt && !arrivalDt && nowMs > classDt.getTime() + thresholdMs);
    const lateReferenceMs = arrivalDt ? arrivalDt.getTime() : nowMs;
    const lateMinutes = classDt
      ? Math.max(0, Math.floor((lateReferenceMs - classDt.getTime()) / 60000))
      : 0;

    const params: Record<string, string> = {
      academyName: String(academySettings?.name ?? ''),
      studentName: String(student?.name ?? ''),
      date: classDt ? formatKstDate(classDt) : (arrivalDt ? formatKstDate(arrivalDt) : ''),
      classStartTime: classDt ? formatKstTime(classDt) : '',
      arrivalTime: arrivalDt ? formatKstTime(arrivalDt) : '',
      departureTime: departureDt ? formatKstTime(departureDt) : '',
      lateMinutes: lateMinutes ? String(lateMinutes) : '0',
      '학원명': String(academySettings?.name ?? ''),
      '학생명': String(student?.name ?? ''),
      '수업시작시간': classDt ? formatKstTime(classDt) : '',
      '등원시간': arrivalDt ? formatKstTime(arrivalDt) : '',
      '하원시간': departureDt ? formatKstTime(departureDt) : '',
      '지각분': lateMinutes ? String(lateMinutes) : '0',
    };

    const sendTargets: Array<'arrival' | 'departure' | 'late'> = [];
    if (row.event_type === 'arrival') {
      if (paymentInfo?.attendance_notification !== false) sendTargets.push('arrival');
    }
    if (row.event_type === 'departure') {
      if (paymentInfo?.departure_notification !== false) sendTargets.push('departure');
    }
    if (row.event_type === 'late') {
      if (arrivalDt) {
        await admin.from('attendance_notification_queue').update({
          status: 'skipped',
          last_error: 'already_arrived',
        }).eq('id', row.id);
        skipped += 1;
        continue;
      }
      if (lateByNoArrival && paymentInfo?.lateness_notification !== false) {
        sendTargets.push('late');
      }
    }

    if (sendTargets.length === 0) {
      const reason = row.event_type === 'late'
        ? (lateByArrival ? 'already_arrived_late' : 'late_not_due_or_notification_disabled')
        : 'notifications_disabled_or_not_applicable';
      await admin.from('attendance_notification_queue').update({
        status: 'skipped',
        last_error: reason,
      }).eq('id', row.id);
      skipped += 1;
      continue;
    }

    const errors: string[] = [];
    let lastMessageId = '';
    let anySent = false;

    for (const target of sendTargets) {
      const { data: alreadySent } = await admin
        .from('attendance_notification_logs')
        .select('id')
        .eq('attendance_id', attendance.id)
        .eq('event_type', target)
        .eq('status', 'sent')
        .limit(1);
      if (alreadySent && alreadySent.length > 0) {
        continue;
      }

      const templateCode = target === 'arrival'
        ? alimtalkSettings?.arrival_template_code
        : target === 'departure'
          ? alimtalkSettings?.departure_template_code
          : alimtalkSettings?.late_template_code;
      const templateMessage = target === 'arrival'
        ? alimtalkSettings?.arrival_message_template
        : target === 'departure'
          ? alimtalkSettings?.departure_message_template
          : alimtalkSettings?.late_message_template;

      if (!templateCode || !templateMessage) {
        errors.push(`missing_template:${target}`);
        await admin.from('attendance_notification_logs').insert({
          queue_id: row.id,
          attendance_id: attendance.id,
          academy_id: attendance.academy_id,
          student_id: attendance.student_id,
          event_type: target,
          status: 'error',
          provider: 'bizppurio',
          template_code: templateCode ?? null,
          phone: parentPhone,
          error: 'missing_template_or_message',
        });
        continue;
      }

      const message = renderTemplate(String(templateMessage), params);
      const payload = {
        account: BIZ_ACCOUNT,
        type: 'at',
        to: parentPhone,
        from: alimtalkSettings?.sender_number,
        refkey: buildRefKey(row.id, target),
        userinfo: attendance.student_id,
        content: {
          at: {
            message,
            senderkey: alimtalkSettings?.sender_key,
            templatecode: templateCode,
          },
        },
      };

      try {
        if (!token) token = await issueBizppurioToken();
        const result = await sendBizppurioAlimtalk(token, payload);
        await admin.from('attendance_notification_logs').insert({
          queue_id: row.id,
          attendance_id: attendance.id,
          academy_id: attendance.academy_id,
          student_id: attendance.student_id,
          event_type: target,
          status: result.ok ? 'sent' : 'error',
          provider: 'bizppurio',
          message_id: result.messageId || null,
          template_code: templateCode,
          phone: parentPhone,
          payload,
          error: result.ok ? null : `send_failed:${result.code}`,
        });
        if (result.ok) {
          anySent = true;
          lastMessageId = result.messageId || lastMessageId;
        } else {
          errors.push(`send_failed:${result.code || 'unknown'}`);
        }
      } catch (err) {
        const message = String((err as Error)?.message ?? err);
        const enrichedMessage = message.startsWith('token_issue_failed:3010') && egressIp
          ? `${message}:egress=${egressIp}`
          : message;
        errors.push(enrichedMessage);
        await admin.from('attendance_notification_logs').insert({
          queue_id: row.id,
          attendance_id: attendance.id,
          academy_id: attendance.academy_id,
          student_id: attendance.student_id,
          event_type: target,
          status: 'error',
          provider: 'bizppurio',
          template_code: templateCode,
          phone: parentPhone,
          payload,
          error: enrichedMessage,
        });
      }
    }

    if (errors.length > 0) {
      await admin.from('attendance_notification_queue').update({
        status: 'error',
        last_error: errors.slice(0, 3).join('|'),
        last_message_id: lastMessageId || null,
      }).eq('id', row.id);
      failed += 1;
      continue;
    }

    await admin.from('attendance_notification_queue').update({
      status: anySent ? 'sent' : 'skipped',
      sent_at: anySent ? new Date().toISOString() : null,
      last_message_id: lastMessageId || null,
      last_error: null,
    }).eq('id', row.id);
    if (anySent) sent += 1; else skipped += 1;
  }

  return ok({
    processed,
    sent,
    skipped,
    failed,
    lateEnqueued,
    requestedQueueId: forceQueueId,
    handledQueueIds,
    egressIp,
  });
});
