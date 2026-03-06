import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BIZ_DOMAIN = (process.env.BIZPPURIO_DOMAIN || 'api.bizppurio.com').trim();
const BIZ_ACCOUNT = (process.env.BIZPPURIO_ACCOUNT || '').trim();
const BIZ_PASSWORD = (process.env.BIZPPURIO_PASSWORD || '').trim();
const BATCH_SIZE = Number.parseInt(process.env.ALIMTALK_BATCH_SIZE || '20', 10);
const MAX_ATTEMPTS = Number.parseInt(process.env.ALIMTALK_MAX_ATTEMPTS || '5', 10);
const WORKER_INTERVAL_MS = Number.parseInt(process.env.WORKER_INTERVAL_MS || '60000', 10);
const PROCESS_ONCE = process.argv.includes('--once') || process.env.ALIMTALK_PROCESS_ONCE === '1';

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('[alimtalk-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
if (!BIZ_ACCOUNT || !BIZ_PASSWORD) {
  console.error('[alimtalk-worker] Missing BIZPPURIO_ACCOUNT or BIZPPURIO_PASSWORD');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function digitsOnly(value) {
  return String(value ?? '').replace(/[^0-9]/g, '');
}

function formatKstDate(d) {
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).format(d);
}

function formatKstTime(d) {
  return new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).format(d);
}

function renderTemplate(template, params) {
  let out = template;
  for (const [key, value] of Object.entries(params)) {
    const safe = String(value ?? '');
    out = out.replaceAll(`#{${key}}`, safe);
    out = out.replaceAll(`{{${key}}}`, safe);
    out = out.replaceAll(`{${key}}`, safe);
  }
  return out;
}

async function fetchEgressIp() {
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
          const json = JSON.parse(text);
          const ip = String(json?.ip ?? '').trim();
          if (ip) return ip;
        } catch (_) {
          // noop
        }
      }
      const match = text.match(/[0-9a-fA-F:.]{7,}/);
      if (match?.[0]) return match[0];
    } catch (_) {
      // noop
    }
  }
  return null;
}

async function issueBizppurioToken() {
  const basic = Buffer.from(`${BIZ_ACCOUNT}:${BIZ_PASSWORD}`).toString('base64');
  const res = await fetch(`https://${BIZ_DOMAIN}/v1/token`, {
    method: 'POST',
    headers: {
      Authorization: `Basic ${basic}`,
    },
  });
  const text = await res.text();
  let data = {};
  try {
    data = JSON.parse(text);
  } catch (_) {
    // noop
  }
  const code = String(data?.code ?? '');
  const accessToken = String(data?.accesstoken ?? '');
  if (!res.ok || !accessToken || (code && code !== '1000')) {
    throw new Error(`token_issue_failed:${code || res.status}`);
  }
  return accessToken;
}

function buildRefKey(queueId, eventType) {
  const base = String(queueId).replace(/[^0-9a-f]/gi, '').slice(0, 24);
  const suffix = String(eventType || '').slice(0, 2);
  return `${base}${suffix}`;
}

async function sendBizppurioAlimtalk(token, payload) {
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
  let data = {};
  try {
    data = JSON.parse(text);
  } catch (_) {
    // noop
  }
  const code = String(data?.code ?? '');
  const messageId = String(data?.messagekey ?? data?.messageKey ?? '');
  return {
    ok: res.ok && code === '1000',
    code,
    messageId,
    raw: text,
  };
}

async function setQueueStatus(id, fields) {
  await supa.from('attendance_notification_queue').update(fields).eq('id', id);
}

async function processBatch() {
  const summary = {
    processed: 0,
    sent: 0,
    skipped: 0,
    failed: 0,
    lateEnqueued: 0,
    egressIp: await fetchEgressIp(),
  };

  try {
    const lateLimit = Math.max(BATCH_SIZE * 5, 50);
    const { data: lateData, error: lateErr } = await supa.rpc(
      'enqueue_due_late_notifications',
      { p_limit: lateLimit },
    );
    if (!lateErr) {
      const parsed = Number(lateData ?? 0);
      if (Number.isFinite(parsed)) summary.lateEnqueued = parsed;
    } else {
      console.warn('[alimtalk-worker] enqueue_due_late_notifications failed:', lateErr.message);
    }
  } catch (e) {
    console.warn('[alimtalk-worker] enqueue_due_late_notifications exception:', String(e));
  }

  const { data: queueRows, error: queueErr } = await supa
    .from('attendance_notification_queue')
    .select('id, attendance_id, academy_id, student_id, event_type, status, attempts')
    .in('status', ['pending', 'error'])
    .lt('attempts', MAX_ATTEMPTS)
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);

  if (queueErr) {
    throw new Error(`queue_fetch_failed:${queueErr.message}`);
  }
  if (!queueRows || queueRows.length === 0) {
    return summary;
  }

  let token = null;

  for (const row of queueRows) {
    summary.processed += 1;
    try {
      const { data: locked } = await supa
        .from('attendance_notification_queue')
        .update({
          status: 'processing',
          attempts: Number(row.attempts || 0) + 1,
          last_error: null,
        })
        .eq('id', row.id)
        .in('status', ['pending', 'error'])
        .select('id')
        .maybeSingle();
      if (!locked) continue;

      const { data: attendance, error: attendanceErr } = await supa
        .from('attendance_records')
        .select('id, academy_id, student_id, date, class_date_time, class_end_time, arrival_time, departure_time')
        .eq('id', row.attendance_id)
        .maybeSingle();
      if (attendanceErr || !attendance) {
        await setQueueStatus(row.id, {
          status: 'error',
          last_error: attendanceErr?.message || 'attendance_not_found',
        });
        summary.failed += 1;
        continue;
      }

      const { data: student } = await supa
        .from('students')
        .select('id, name')
        .eq('id', attendance.student_id)
        .maybeSingle();

      const { data: basicInfo } = await supa
        .from('student_basic_info')
        .select('student_id, parent_phone_number')
        .eq('student_id', attendance.student_id)
        .maybeSingle();

      const { data: paymentInfo } = await supa
        .from('student_payment_info')
        .select('student_id, lateness_threshold, attendance_notification, departure_notification, lateness_notification')
        .eq('student_id', attendance.student_id)
        .maybeSingle();

      const { data: academySettings } = await supa
        .from('academy_settings')
        .select('academy_id, name')
        .eq('academy_id', attendance.academy_id)
        .maybeSingle();

      const { data: alimtalkSettings } = await supa
        .from('academy_alimtalk_settings')
        .select('academy_id, sender_key, sender_number, arrival_template_code, arrival_message_template, departure_template_code, departure_message_template, late_template_code, late_message_template, enabled')
        .eq('academy_id', attendance.academy_id)
        .maybeSingle();

      if (!alimtalkSettings) {
        await setQueueStatus(row.id, { status: 'error', last_error: 'missing_academy_alimtalk_settings' });
        summary.failed += 1;
        continue;
      }
      if (!alimtalkSettings.sender_key || !alimtalkSettings.sender_number) {
        await setQueueStatus(row.id, { status: 'error', last_error: 'missing_sender_info' });
        summary.failed += 1;
        continue;
      }

      const parentPhone = digitsOnly(basicInfo?.parent_phone_number);
      if (!parentPhone) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'missing_parent_phone' });
        summary.skipped += 1;
        continue;
      }
      if (!alimtalkSettings.enabled) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'alimtalk_disabled' });
        summary.skipped += 1;
        continue;
      }

      const classDt = attendance.class_date_time ? new Date(attendance.class_date_time) : null;
      const arrivalDt = attendance.arrival_time ? new Date(attendance.arrival_time) : null;
      const departureDt = attendance.departure_time ? new Date(attendance.departure_time) : null;
      const threshold = Number(paymentInfo?.lateness_threshold ?? 10);
      const thresholdMs = Math.max(0, threshold) * 60 * 1000;
      const nowMs = Date.now();
      const lateByArrival = Boolean(arrivalDt && classDt && arrivalDt.getTime() > classDt.getTime() + thresholdMs);
      const lateByNoArrival = Boolean(classDt && !arrivalDt && nowMs > classDt.getTime() + thresholdMs);
      const lateReferenceMs = arrivalDt ? arrivalDt.getTime() : nowMs;
      const lateMinutes = classDt
        ? Math.max(0, Math.floor((lateReferenceMs - classDt.getTime()) / 60000))
        : 0;

      const params = {
        academyName: String(academySettings?.name ?? ''),
        studentName: String(student?.name ?? ''),
        date: classDt ? formatKstDate(classDt) : (arrivalDt ? formatKstDate(arrivalDt) : ''),
        classStartTime: classDt ? formatKstTime(classDt) : '',
        arrivalTime: arrivalDt ? formatKstTime(arrivalDt) : '',
        departureTime: departureDt ? formatKstTime(departureDt) : '',
        lateMinutes: lateMinutes ? String(lateMinutes) : '0',
        학원명: String(academySettings?.name ?? ''),
        학생명: String(student?.name ?? ''),
        수업시작시간: classDt ? formatKstTime(classDt) : '',
        등원시간: arrivalDt ? formatKstTime(arrivalDt) : '',
        하원시간: departureDt ? formatKstTime(departureDt) : '',
        지각분: lateMinutes ? String(lateMinutes) : '0',
      };

      const sendTargets = [];
      if (row.event_type === 'arrival') {
        if (paymentInfo?.attendance_notification !== false) sendTargets.push('arrival');
      }
      if (row.event_type === 'departure') {
        if (paymentInfo?.departure_notification !== false) sendTargets.push('departure');
      }
      if (row.event_type === 'late') {
        if (arrivalDt) {
          await setQueueStatus(row.id, { status: 'skipped', last_error: 'already_arrived' });
          summary.skipped += 1;
          continue;
        }
        if (lateByNoArrival && paymentInfo?.lateness_notification !== false) sendTargets.push('late');
      }

      if (sendTargets.length === 0) {
        const reason = row.event_type === 'late'
          ? (lateByArrival ? 'already_arrived_late' : 'late_not_due_or_notification_disabled')
          : 'notifications_disabled_or_not_applicable';
        await setQueueStatus(row.id, { status: 'skipped', last_error: reason });
        summary.skipped += 1;
        continue;
      }

      const errors = [];
      let anySent = false;
      let lastMessageId = null;

      for (const target of sendTargets) {
        const { data: alreadySent } = await supa
          .from('attendance_notification_logs')
          .select('id')
          .eq('attendance_id', attendance.id)
          .eq('event_type', target)
          .eq('status', 'sent')
          .limit(1);
        if (alreadySent && alreadySent.length > 0) continue;

        const templateCode = target === 'arrival'
          ? alimtalkSettings.arrival_template_code
          : target === 'departure'
            ? alimtalkSettings.departure_template_code
            : alimtalkSettings.late_template_code;
        const templateMessage = target === 'arrival'
          ? alimtalkSettings.arrival_message_template
          : target === 'departure'
            ? alimtalkSettings.departure_message_template
            : alimtalkSettings.late_message_template;

        if (!templateCode || !templateMessage) {
          errors.push(`missing_template:${target}`);
          await supa.from('attendance_notification_logs').insert({
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

        const payload = {
          account: BIZ_ACCOUNT,
          type: 'at',
          to: parentPhone,
          from: alimtalkSettings.sender_number,
          refkey: buildRefKey(row.id, target),
          userinfo: attendance.student_id,
          content: {
            at: {
              message: renderTemplate(String(templateMessage), params),
              senderkey: alimtalkSettings.sender_key,
              templatecode: templateCode,
            },
          },
        };

        try {
          if (!token) token = await issueBizppurioToken();
          const result = await sendBizppurioAlimtalk(token, payload);
          await supa.from('attendance_notification_logs').insert({
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
        } catch (e) {
          let err = String(e?.message || e);
          if (err.startsWith('token_issue_failed:3010') && summary.egressIp) {
            err = `${err}:egress=${summary.egressIp}`;
          }
          errors.push(err);
          await supa.from('attendance_notification_logs').insert({
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
            error: err,
          });
        }
      }

      if (errors.length > 0) {
        await setQueueStatus(row.id, {
          status: 'error',
          last_error: errors.slice(0, 3).join('|'),
          last_message_id: lastMessageId,
        });
        summary.failed += 1;
        continue;
      }

      await setQueueStatus(row.id, {
        status: anySent ? 'sent' : 'skipped',
        last_error: null,
        last_message_id: lastMessageId,
        sent_at: anySent ? new Date().toISOString() : null,
      });
      if (anySent) summary.sent += 1;
      else summary.skipped += 1;
    } catch (e) {
      const err = String(e?.message || e);
      console.error('[alimtalk-worker] row processing failed:', row?.id, err);
      await setQueueStatus(row.id, { status: 'error', last_error: err });
      summary.failed += 1;
    }
  }

  return summary;
}

let tickRunning = false;

async function runTick() {
  if (tickRunning) {
    console.log('[alimtalk-worker] Previous tick still running. Skip this round.');
    return;
  }
  tickRunning = true;
  const startedAt = Date.now();
  try {
    const summary = await processBatch();
    const elapsedMs = Date.now() - startedAt;
    console.log('[alimtalk-worker] summary:', { ...summary, elapsedMs });
  } catch (e) {
    console.error('[alimtalk-worker] tick failed:', String(e?.message || e));
  } finally {
    tickRunning = false;
  }
}

async function main() {
  console.log('[alimtalk-worker] starting...', {
    batchSize: BATCH_SIZE,
    maxAttempts: MAX_ATTEMPTS,
    intervalMs: WORKER_INTERVAL_MS,
    processOnce: PROCESS_ONCE,
    bizDomain: BIZ_DOMAIN,
  });

  await runTick();

  if (PROCESS_ONCE) {
    console.log('[alimtalk-worker] process-once done.');
    process.exit(0);
  }

  setInterval(runTick, WORKER_INTERVAL_MS);
}

main().catch((e) => {
  console.error('[alimtalk-worker] fatal:', String(e?.message || e));
  process.exit(1);
});

