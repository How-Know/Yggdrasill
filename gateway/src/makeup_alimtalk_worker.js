import 'dotenv/config';
import { createClient } from '@supabase/supabase-js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY;
const BIZ_DOMAIN = (process.env.BIZPPURIO_DOMAIN || 'api.bizppurio.com').trim();
const BIZ_ACCOUNT = (process.env.BIZPPURIO_ACCOUNT || '').trim();
const BIZ_PASSWORD = (process.env.BIZPPURIO_PASSWORD || '').trim();
const BATCH_SIZE = Number.parseInt(process.env.MAKEUP_ALIMTALK_BATCH_SIZE || process.env.ALIMTALK_BATCH_SIZE || '20', 10);
const MAX_ATTEMPTS = Number.parseInt(process.env.MAKEUP_ALIMTALK_MAX_ATTEMPTS || process.env.ALIMTALK_MAX_ATTEMPTS || '5', 10);
const WORKER_INTERVAL_MS = Number.parseInt(process.env.MAKEUP_WORKER_INTERVAL_MS || process.env.WORKER_INTERVAL_MS || '60000', 10);
const ONLY_TODAY_QUEUE = process.env.MAKEUP_ALIMTALK_ONLY_TODAY_QUEUE !== '0';
const PROCESS_ONCE = process.argv.includes('--once') || process.env.MAKEUP_ALIMTALK_PROCESS_ONCE === '1';
const ENABLED = process.env.MAKEUP_ALIMTALK_ENABLED === '1';
const KST_OFFSET_MS = 9 * 60 * 60 * 1000;

if (!SUPABASE_URL || !SUPABASE_SERVICE_ROLE_KEY) {
  console.error('[makeup-alimtalk-worker] Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
  process.exit(1);
}
if (!BIZ_ACCOUNT || !BIZ_PASSWORD) {
  console.error('[makeup-alimtalk-worker] Missing BIZPPURIO_ACCOUNT or BIZPPURIO_PASSWORD');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY, {
  auth: { persistSession: false, autoRefreshToken: false },
});

function digitsOnly(value) {
  return String(value ?? '').replace(/[^0-9]/g, '');
}

function formatKstMakeupDisplay(isoOrMs) {
  const d = new Date(isoOrMs);
  const parts = new Intl.DateTimeFormat('ko-KR', {
    timeZone: 'Asia/Seoul',
    month: 'numeric',
    day: 'numeric',
    weekday: 'short',
    hour: '2-digit',
    minute: '2-digit',
    hour12: false,
  }).formatToParts(d);
  const pick = (t) => parts.find((p) => p.type === t)?.value ?? '';
  const m = pick('month');
  const day = pick('day');
  const wd = pick('weekday');
  const h = pick('hour');
  const min = pick('minute');
  return `${m}/${day}(${wd}) ${h}:${min}`;
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

function getKstDayStartUtcIso(nowMs = Date.now()) {
  const kstNow = new Date(nowMs + KST_OFFSET_MS);
  const kstDayStartUtcMs = Date.UTC(
    kstNow.getUTCFullYear(),
    kstNow.getUTCMonth(),
    kstNow.getUTCDate(),
    0,
    0,
    0,
  ) - KST_OFFSET_MS;
  return new Date(kstDayStartUtcMs).toISOString();
}

function getKstDateKey(value = Date.now()) {
  if (value == null) return null;
  const d = new Date(value);
  if (Number.isNaN(d.getTime())) return null;
  const kst = new Date(d.getTime() + KST_OFFSET_MS);
  const y = kst.getUTCFullYear();
  const m = String(kst.getUTCMonth() + 1).padStart(2, '0');
  const day = String(kst.getUTCDate()).padStart(2, '0');
  return `${y}-${m}-${day}`;
}

async function isAcademyNotificationPaused(academyId, eventDateKey) {
  if (!academyId || !eventDateKey) return false;
  const { data, error } = await supa
    .from('academy_notification_pause_dates')
    .select('id')
    .eq('academy_id', academyId)
    .eq('pause_date', eventDateKey)
    .limit(1);
  if (error) {
    console.warn('[makeup-alimtalk-worker] pause-date check failed:', error.message);
    return false;
  }
  return Boolean(data && data.length > 0);
}

async function fetchEgressIp() {
  const endpoints = [
    'https://api64.ipify.org?format=json',
    'https://api.ipify.org?format=json',
  ];
  for (const endpoint of endpoints) {
    try {
      const res = await fetch(endpoint, { method: 'GET' });
      if (!res.ok) continue;
      const text = (await res.text()).trim();
      if (text.startsWith('{')) {
        const json = JSON.parse(text);
        const ip = String(json?.ip ?? '').trim();
        if (ip) return ip;
      }
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
    headers: { Authorization: `Basic ${basic}` },
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
  await supa.from('makeup_notification_queue').update(fields).eq('id', id);
}

/** PostgREST .or(created_at…,updated_at…) 조합이 환경에 따라 빈 결과/오류를 낼 수 있어 분리 조회 후 병합 */
async function fetchMakeupQueueRows(kstDayStartIso) {
  const selectCols =
    'id, session_override_id, academy_id, student_id, event_type, status, attempts, created_at, updated_at';
  const base = () =>
    supa
      .from('makeup_notification_queue')
      .select(selectCols)
      .in('status', ['pending', 'error'])
      .lt('attempts', MAX_ATTEMPTS);

  if (!ONLY_TODAY_QUEUE) {
    const { data, error } = await base()
      .order('created_at', { ascending: true })
      .limit(BATCH_SIZE);
    if (error) throw new Error(error.message);
    return data || [];
  }

  const { data: byCreated, error: errCreated } = await base()
    .gte('created_at', kstDayStartIso)
    .order('created_at', { ascending: true })
    .limit(BATCH_SIZE);
  if (errCreated) throw new Error(errCreated.message);

  const { data: byUpdated, error: errUpdated } = await base()
    .gte('updated_at', kstDayStartIso)
    .order('updated_at', { ascending: true })
    .limit(BATCH_SIZE);
  if (errUpdated) throw new Error(errUpdated.message);

  const byId = new Map();
  for (const r of [...(byCreated || []), ...(byUpdated || [])]) {
    byId.set(r.id, r);
  }
  const merged = Array.from(byId.values()).sort(
    (a, b) => new Date(a.created_at).getTime() - new Date(b.created_at).getTime(),
  );
  return merged.slice(0, BATCH_SIZE);
}

async function processBatch() {
  const kstDayStartIso = getKstDayStartUtcIso();
  const todayKstDateKey = getKstDateKey();
  const summary = {
    processed: 0,
    sent: 0,
    skipped: 0,
    failed: 0,
    egressIp: await fetchEgressIp(),
    onlyTodayQueue: ONLY_TODAY_QUEUE,
    kstDayStartIso,
    todayKstDateKey,
    enabled: true,
  };

  let queueRows;
  try {
    queueRows = await fetchMakeupQueueRows(kstDayStartIso);
  } catch (e) {
    throw new Error(`queue_fetch_failed:${String(e?.message || e)}`);
  }
  if (!queueRows || queueRows.length === 0) {
    return summary;
  }

  let token = null;

  for (const row of queueRows) {
    summary.processed += 1;
    try {
      const { data: locked } = await supa
        .from('makeup_notification_queue')
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

      const { data: ov, error: ovErr } = await supa
        .from('session_overrides')
        .select(
          'id, academy_id, student_id, override_type, original_class_datetime, replacement_class_datetime, change_reason, reason, status',
        )
        .eq('id', row.session_override_id)
        .maybeSingle();

      if (ovErr || !ov) {
        await setQueueStatus(row.id, {
          status: 'error',
          last_error: ovErr?.message || 'session_override_not_found',
        });
        summary.failed += 1;
        continue;
      }

      if (ov.status === 'canceled') {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'override_canceled' });
        summary.skipped += 1;
        continue;
      }

      const eventDateKey = getKstDateKey(ov.replacement_class_datetime);
      if (eventDateKey && eventDateKey < todayKstDateKey) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'expired_event_date' });
        summary.skipped += 1;
        continue;
      }
      if (await isAcademyNotificationPaused(ov.academy_id, eventDateKey)) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'academy_notification_paused' });
        summary.skipped += 1;
        continue;
      }

      const { data: student } = await supa
        .from('students')
        .select('id, name')
        .eq('id', ov.student_id)
        .maybeSingle();

      const { data: basicInfo } = await supa
        .from('student_basic_info')
        .select('student_id, parent_phone_number, notification_consent')
        .eq('student_id', ov.student_id)
        .maybeSingle();

      const { data: academySettings } = await supa
        .from('academy_settings')
        .select('academy_id, name')
        .eq('academy_id', ov.academy_id)
        .maybeSingle();

      const { data: alimtalkSettings } = await supa
        .from('academy_alimtalk_settings')
        .select(
          'academy_id, sender_key, sender_number, enabled, makeup_template_code, makeup_message_template, makeup_alimtalk_enabled',
        )
        .eq('academy_id', ov.academy_id)
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

      const consented = basicInfo?.notification_consent === true;
      if (!consented) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'notification_consent_required' });
        summary.skipped += 1;
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

      if (!alimtalkSettings.makeup_alimtalk_enabled) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'makeup_alimtalk_disabled' });
        summary.skipped += 1;
        continue;
      }

      const templateCode = alimtalkSettings.makeup_template_code;
      const templateMessage = alimtalkSettings.makeup_message_template;
      if (!templateCode || !templateMessage) {
        await setQueueStatus(row.id, { status: 'skipped', last_error: 'missing_makeup_template' });
        summary.skipped += 1;
        continue;
      }

      const origMs = ov.original_class_datetime ? new Date(ov.original_class_datetime).getTime() : null;
      const repMs = ov.replacement_class_datetime ? new Date(ov.replacement_class_datetime).getTime() : null;
      const 원래수업일시 =
        origMs != null && !Number.isNaN(origMs) ? formatKstMakeupDisplay(origMs) : '—';
      const 보강수업일시 =
        repMs != null && !Number.isNaN(repMs) ? formatKstMakeupDisplay(repMs) : '—';
      const rawReason = String(ov.change_reason ?? '').trim();
      const 변경사유 = rawReason.length > 0 ? rawReason : '없음';

      const params = {
        academyName: String(academySettings?.name ?? ''),
        studentName: String(student?.name ?? ''),
        원래수업일시,
        보강수업일시,
        변경사유,
        학원명: String(academySettings?.name ?? ''),
        학생명: String(student?.name ?? ''),
      };

      // 최초 예약만 중복 차단. 보강 수정(scheduled_updated)은 별도 발송 허용
      if (row.event_type === 'scheduled_created') {
        const { data: alreadySent } = await supa
          .from('makeup_notification_logs')
          .select('id')
          .eq('session_override_id', ov.id)
          .eq('event_type', 'scheduled_created')
          .eq('status', 'sent')
          .limit(1);
        if (alreadySent && alreadySent.length > 0) {
          await setQueueStatus(row.id, { status: 'skipped', last_error: 'already_sent' });
          summary.skipped += 1;
          continue;
        }
      }

      const payload = {
        account: BIZ_ACCOUNT,
        type: 'at',
        to: parentPhone,
        from: alimtalkSettings.sender_number,
        refkey: buildRefKey(row.id, row.event_type),
        userinfo: ov.student_id,
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
        await supa.from('makeup_notification_logs').insert({
          queue_id: row.id,
          session_override_id: ov.id,
          academy_id: ov.academy_id,
          student_id: ov.student_id,
          event_type: row.event_type,
          status: result.ok ? 'sent' : 'error',
          provider: 'bizppurio',
          message_id: result.messageId || null,
          template_code: templateCode,
          phone: parentPhone,
          payload,
          error: result.ok ? null : `send_failed:${result.code}`,
        });

        if (result.ok) {
          await setQueueStatus(row.id, {
            status: 'sent',
            last_error: null,
            last_message_id: result.messageId || null,
            sent_at: new Date().toISOString(),
          });
          summary.sent += 1;
        } else {
          let err = `send_failed:${result.code || 'unknown'}`;
          if (String(result.code) === '3010' && summary.egressIp) {
            err = `${err}:egress=${summary.egressIp}`;
          }
          await setQueueStatus(row.id, { status: 'error', last_error: err });
          summary.failed += 1;
        }
      } catch (e) {
        let err = String(e?.message || e);
        if (err.startsWith('token_issue_failed:3010') && summary.egressIp) {
          err = `${err}:egress=${summary.egressIp}`;
        }
        await supa.from('makeup_notification_logs').insert({
          queue_id: row.id,
          session_override_id: ov.id,
          academy_id: ov.academy_id,
          student_id: ov.student_id,
          event_type: row.event_type,
          status: 'error',
          provider: 'bizppurio',
          template_code: templateCode,
          phone: parentPhone,
          payload,
          error: err,
        });
        await setQueueStatus(row.id, { status: 'error', last_error: err });
        summary.failed += 1;
      }
    } catch (e) {
      const err = String(e?.message || e);
      console.error('[makeup-alimtalk-worker] row processing failed:', row?.id, err);
      await setQueueStatus(row.id, { status: 'error', last_error: err });
      summary.failed += 1;
    }
  }

  return summary;
}

let tickRunning = false;

async function runTick() {
  if (!ENABLED) {
    return { skipped: true, reason: 'MAKEUP_ALIMTALK_ENABLED is not 1' };
  }
  if (tickRunning) {
    console.log('[makeup-alimtalk-worker] Previous tick still running. Skip.');
    return { skipped: true, reason: 'concurrent_tick' };
  }
  tickRunning = true;
  const startedAt = Date.now();
  try {
    const summary = await processBatch();
    const elapsedMs = Date.now() - startedAt;
    console.log('[makeup-alimtalk-worker] summary:', { ...summary, elapsedMs });
    return summary;
  } catch (e) {
    console.error('[makeup-alimtalk-worker] tick failed:', String(e?.message || e));
    throw e;
  } finally {
    tickRunning = false;
  }
}

async function main() {
  console.log('[makeup-alimtalk-worker] starting...', {
    enabled: ENABLED,
    batchSize: BATCH_SIZE,
    maxAttempts: MAX_ATTEMPTS,
    intervalMs: WORKER_INTERVAL_MS,
    processOnce: PROCESS_ONCE,
    onlyTodayQueue: ONLY_TODAY_QUEUE,
    bizDomain: BIZ_DOMAIN,
  });

  if (!ENABLED) {
    console.log('[makeup-alimtalk-worker] Disabled (set MAKEUP_ALIMTALK_ENABLED=1 to process). Exiting.');
    process.exit(0);
  }

  await runTick();

  if (PROCESS_ONCE) {
    console.log('[makeup-alimtalk-worker] process-once done.');
    process.exit(0);
  }

  setInterval(() => {
    runTick().catch((e) => console.error('[makeup-alimtalk-worker] tick:', e));
  }, WORKER_INTERVAL_MS);
}

main().catch((e) => {
  console.error('[makeup-alimtalk-worker] fatal:', String(e?.message || e));
  process.exit(1);
});
