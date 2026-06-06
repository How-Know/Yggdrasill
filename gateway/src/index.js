import 'dotenv/config';
import mqtt from 'mqtt';
import { v4 as uuidv4 } from 'uuid';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, existsSync } from 'fs';
import Ajv from 'ajv';
import {
  createM5HomeworksEnvelope,
  sanitizeGroupsForDevicePayload as sanitizeM5GroupsForDevicePayload
} from './m5_sync_fingerprint.js';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY;
const SUPABASE_SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY || SUPABASE_ANON;
const MQTT_URL = process.env.MQTT_URL; // e.g. mqtts://broker:8883
const MQTT_USER = process.env.MQTT_USERNAME;
const MQTT_PASS = process.env.MQTT_PASSWORD;
const MQTT_CA_PATH = process.env.MQTT_CA_PATH;
const MQTT_CLIENT_ID = process.env.MQTT_CLIENT_ID || `ygg-gateway-${uuidv4()}`;
const MQTT_KEEPALIVE_SEC = Number.parseInt(process.env.MQTT_KEEPALIVE_SEC ?? '15', 10);
const MQTT_CONNECT_TIMEOUT_MS = Number.parseInt(process.env.MQTT_CONNECT_TIMEOUT_MS ?? '30000', 10);
const MQTT_RECONNECT_PERIOD_MS = Number.parseInt(process.env.MQTT_RECONNECT_PERIOD_MS ?? '3000', 10);
const MQTT_CLEAN_SESSION = String(process.env.MQTT_CLEAN_SESSION ?? 'false').toLowerCase() === 'true';
const GW_HEALTH_INTERVAL_MS = Number.parseInt(process.env.GW_HEALTH_INTERVAL_MS ?? '10000', 10);
const GW_STALE_WARN_MS = Number.parseInt(process.env.GW_STALE_WARN_MS ?? '90000', 10);
const GW_STALE_HARD_RESET_MS = Number.parseInt(process.env.GW_STALE_HARD_RESET_MS ?? '180000', 10);
// 인바운드 유휴(메시지 없음)만으로 연결을 강제 종료(close+reconnect)하지 않는다.
// 진짜 끊김은 MQTT keepalive가 감지해 자동 재접속하므로, 파괴적 hard reset은
// 명시적 opt-in일 때만 수행한다(기본 비활성). 재접속 순간 in-flight bind 유실 방지.
const GW_STALE_HARD_RESET_ENABLED =
  String(process.env.GW_STALE_HARD_RESET_ENABLED ?? 'false').toLowerCase() === 'true';
const GW_STALE_ACTIVITY_WINDOW_MS = Number.parseInt(process.env.GW_STALE_ACTIVITY_WINDOW_MS ?? '600000', 10);
const GW_RECOVERY_COOLDOWN_MS = Number.parseInt(process.env.GW_RECOVERY_COOLDOWN_MS ?? '60000', 10);
const M5_FULL_RESYNC_DELAY_MS = Number.parseInt(process.env.M5_FULL_RESYNC_DELAY_MS ?? '1500', 10);
const M5_FULL_RESYNC_COOLDOWN_MS = Number.parseInt(process.env.M5_FULL_RESYNC_COOLDOWN_MS ?? '30000', 10);

if (!SUPABASE_URL || !SUPABASE_SERVICE || !MQTT_URL) {
  console.error('[gateway] Missing envs');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE);

const schema = JSON.parse(readFileSync(new URL('../../infra/messaging/schemas/homework_command.v1.json', import.meta.url)));
const ajv = new Ajv({ allErrors: true, strict: false });
const validate = ajv.compile(schema);

const nowMs = () => Date.now();
const validInt = (value, fallback) =>
  Number.isFinite(value) && value > 0 ? Math.trunc(value) : fallback;

const cfg = {
  keepaliveSec: validInt(MQTT_KEEPALIVE_SEC, 15),
  connectTimeoutMs: validInt(MQTT_CONNECT_TIMEOUT_MS, 30000),
  reconnectPeriodMs: validInt(MQTT_RECONNECT_PERIOD_MS, 3000),
  cleanSession: MQTT_CLEAN_SESSION,
  healthIntervalMs: validInt(GW_HEALTH_INTERVAL_MS, 10000),
  staleWarnMs: validInt(GW_STALE_WARN_MS, 90000),
  staleHardMs: validInt(GW_STALE_HARD_RESET_MS, 180000),
  staleHardEnabled: GW_STALE_HARD_RESET_ENABLED,
  staleActivityWindowMs: validInt(GW_STALE_ACTIVITY_WINDOW_MS, 600000),
  recoveryCooldownMs: validInt(GW_RECOVERY_COOLDOWN_MS, 60000),
  m5FullResyncDelayMs: validInt(M5_FULL_RESYNC_DELAY_MS, 1500),
  m5FullResyncCooldownMs: validInt(M5_FULL_RESYNC_COOLDOWN_MS, 30000)
};
const GROUP_CMD_V2_DEVICE_ID = process.env.GROUP_CMD_V2_DEVICE_ID || 'm5-device-001';
const GROUP_CMD_V2_LOG_TAG = 'GROUP_CMD_V2';
const GROUP_CMD_V2_SUPPRESS_MS = validInt(
  Number.parseInt(process.env.GROUP_CMD_V2_SUPPRESS_MS ?? '1800', 10),
  1800
);
const HOMEWORK_PUSH_COALESCE_MS = validInt(
  Number.parseInt(process.env.HOMEWORK_PUSH_COALESCE_MS ?? '140', 10),
  140
);
const M5_BIND_CONFIRM_REFRESH_DELAY_MS = validInt(
  Number.parseInt(process.env.M5_BIND_CONFIRM_REFRESH_DELAY_MS ?? '1500', 10),
  1500
);
const M5_GROUP_CHILDREN_LIMIT = validInt(
  Number.parseInt(process.env.M5_GROUP_CHILDREN_LIMIT ?? '8', 10),
  8
);
const M5_GROUP_COUNT_LIMIT = validInt(
  Number.parseInt(process.env.M5_GROUP_COUNT_LIMIT ?? '8', 10),
  8
);

function logEvent(level, message, payload = {}) {
  const body = Object.keys(payload).length ? payload : undefined;
  if (body) console[level](message, body);
  else console[level](message);
}

const sampledLogState = new Map();
function logSampled(key, intervalMs, level, message, payload = {}) {
  const now = nowMs();
  const prev = sampledLogState.get(key) || 0;
  if (now - prev < intervalMs) return;
  sampledLogState.set(key, now);
  logEvent(level, message, payload);
}

const gatewayState = {
  connected: false,
  lastConnectTs: 0,
  lastDisconnectTs: 0,
  lastMessageTs: 0,
  lastPublishTs: 0,
  lastSoftRecoverTs: 0,
  lastHardRecoverTs: 0,
  softRecoveries: 0,
  hardRecoveries: 0,
  lastInboundTopic: ''
};

const BASE_SUBSCRIPTIONS = [
  'academies/+/students/+/homework/+/command',
  'academies/+/devices/+/command',
  'academies/+/devices/+/presence'
];

const tlsOpts = {};
if (MQTT_CA_PATH && existsSync(MQTT_CA_PATH)) {
  try {
    tlsOpts.ca = readFileSync(MQTT_CA_PATH);
    console.log('[gateway] TLS CA loaded');
  } catch (e) {
    console.warn('[gateway] TLS CA load failed', e);
  }
}

const client = mqtt.connect(MQTT_URL, {
  username: MQTT_USER,
  password: MQTT_PASS,
  protocolVersion: 5,
  clean: cfg.cleanSession,
  clientId: MQTT_CLIENT_ID,
  keepalive: cfg.keepaliveSec,
  reconnectPeriod: cfg.reconnectPeriodMs,
  connectTimeout: cfg.connectTimeoutMs,
  ...tlsOpts
});

const rawPublish = client.publish.bind(client);
function publish(topic, payload, options = { qos: 1, retain: false }) {
  gatewayState.lastPublishTs = nowMs();
  rawPublish(topic, payload, options);
}

function subscribeBaseTopics(reason = 'connect') {
  for (const topic of BASE_SUBSCRIPTIONS) {
    client.subscribe(topic, { qos: 1 }, (err) => {
      if (err) {
        logEvent('error', '[gateway] subscribe error', { reason, topic, error: err.message ?? String(err) });
      }
    });
  }
}

function softRecover(reason) {
  const now = nowMs();
  if (now - gatewayState.lastSoftRecoverTs < cfg.recoveryCooldownMs) return;
  gatewayState.lastSoftRecoverTs = now;
  gatewayState.softRecoveries += 1;
  logEvent('warn', '[gateway] watchdog soft recover', {
    reason,
    lastMessageAgeMs: gatewayState.lastMessageTs ? now - gatewayState.lastMessageTs : null,
    softRecoveries: gatewayState.softRecoveries
  });
  subscribeBaseTopics(`watchdog:${reason}`);
}

function hardRecover(reason) {
  const now = nowMs();
  if (now - gatewayState.lastHardRecoverTs < cfg.recoveryCooldownMs) return;
  gatewayState.lastHardRecoverTs = now;
  gatewayState.hardRecoveries += 1;
  logEvent('error', '[gateway] watchdog hard recover', {
    reason,
    lastMessageAgeMs: gatewayState.lastMessageTs ? now - gatewayState.lastMessageTs : null,
    hardRecoveries: gatewayState.hardRecoveries
  });
  try {
    client.end(true, () => {
      try {
        client.reconnect();
      } catch (e) {
        logEvent('error', '[gateway] hard recover reconnect failed', { error: e?.message ?? String(e) });
      }
    });
  } catch (e) {
    logEvent('error', '[gateway] hard recover end failed', { error: e?.message ?? String(e) });
    try {
      client.reconnect();
    } catch (ee) {
      logEvent('error', '[gateway] hard recover fallback reconnect failed', { error: ee?.message ?? String(ee) });
    }
  }
}

function maybePublishAck(academyId, idempotencyKey, body) {
  if (!idempotencyKey) {
    logEvent('warn', '[gateway] missing idempotency key for ack', { academyId, action: body?.action });
    return;
  }
  publish(`academies/${academyId}/ack/${idempotencyKey}`, JSON.stringify(body), { qos: 1, retain: false });
}

client.on('connect', (packet = {}) => {
  gatewayState.connected = true;
  gatewayState.lastConnectTs = nowMs();
  logEvent('log', '[gateway] connected', {
    clientId: MQTT_CLIENT_ID,
    sessionPresent: !!packet.sessionPresent,
    keepaliveSec: cfg.keepaliveSec,
    cleanSession: cfg.cleanSession
  });
  subscribeBaseTopics('connect');
});

// simple idempotency cache (10 minutes TTL)
const processed = new Map(); // key -> timestamp
const IDEMP_TTL_MS = 10 * 60 * 1000;
const groupTransitionInflightUntil = new Map();
setInterval(() => {
  const now = Date.now();
  for (const [k, ts] of processed.entries()) if (now - ts > IDEMP_TTL_MS) processed.delete(k);
  for (const [k, ts] of groupTransitionInflightUntil.entries()) if (ts <= now) groupTransitionInflightUntil.delete(k);
}, 60 * 1000);

setInterval(() => {
  const now = nowMs();
  const lastActivityTs = Math.max(
    gatewayState.lastConnectTs || 0,
    gatewayState.lastMessageTs || 0,
    gatewayState.lastPublishTs || 0
  );

  logEvent('log', '[gateway] health', {
    connected: gatewayState.connected,
    lastConnectAgeMs: gatewayState.lastConnectTs ? now - gatewayState.lastConnectTs : null,
    lastMessageAgeMs: gatewayState.lastMessageTs ? now - gatewayState.lastMessageTs : null,
    lastPublishAgeMs: gatewayState.lastPublishTs ? now - gatewayState.lastPublishTs : null,
    softRecoveries: gatewayState.softRecoveries,
    hardRecoveries: gatewayState.hardRecoveries,
    lastInboundTopic: gatewayState.lastInboundTopic || null
  });

  if (!gatewayState.connected) return;
  if (!gatewayState.lastMessageTs) return;
  if (!lastActivityTs || now - lastActivityTs > cfg.staleActivityWindowMs) return;

  const staleMs = now - gatewayState.lastMessageTs;
  // 유휴(인바운드 없음)만으로는 연결을 강제 종료하지 않는다. 파괴적 hard reset은
  // opt-in일 때만 — 평소엔 비파괴적 재구독(soft)만 수행해 in-flight bind 유실을 막는다.
  if (cfg.staleHardEnabled && staleMs >= cfg.staleHardMs) {
    hardRecover('inbound_message_stale_hard');
    return;
  }
  if (staleMs >= cfg.staleWarnMs) {
    softRecover('inbound_message_stale_soft');
  }
}, cfg.healthIntervalMs);

logEvent('log', '[gateway] mqtt runtime config', {
  cleanSession: cfg.cleanSession,
  keepaliveSec: cfg.keepaliveSec,
  reconnectPeriodMs: cfg.reconnectPeriodMs,
  connectTimeoutMs: cfg.connectTimeoutMs,
  healthIntervalMs: cfg.healthIntervalMs,
  staleWarnMs: cfg.staleWarnMs,
  staleHardMs: cfg.staleHardMs,
  staleHardEnabled: cfg.staleHardEnabled,
  staleActivityWindowMs: cfg.staleActivityWindowMs,
  recoveryCooldownMs: cfg.recoveryCooldownMs,
  m5FullResyncDelayMs: cfg.m5FullResyncDelayMs,
  m5FullResyncCooldownMs: cfg.m5FullResyncCooldownMs
});

/** 학생 단위로 RPC+푸시를 직렬화해 빠른 연속 DB 이벤트 시 스냅샷 역전·중간 상태 유실 완화 */
const homeworkPublishChains = new Map();
const homeworkPublishCoalesce = new Map();
const m5SyncSequences = new Map();
let m5FullResyncTimer = null;
let m5FullResyncInFlight = false;
let m5FullResyncPendingReason = null;
let m5FullResyncLastRunTs = 0;

function sanitizeGroupsForDevicePayload(groups) {
  return sanitizeM5GroupsForDevicePayload(groups, {
    groupLimit: M5_GROUP_COUNT_LIMIT,
    childrenLimit: M5_GROUP_CHILDREN_LIMIT
  });
}

function nextM5SyncSeq(academy_id, device_id, student_id) {
  const key = `${academy_id}::${device_id}::${student_id}`;
  const next = ((m5SyncSequences.get(key) || 0) + 1) >>> 0;
  m5SyncSequences.set(key, next);
  return next;
}

function publishHomeworksToDevice(academy_id, student_id, device_id, groups, source = 'unknown') {
  const payloadGroups = sanitizeGroupsForDevicePayload(groups || []);
  const envelope = createM5HomeworksEnvelope({
    academyId: academy_id,
    deviceId: device_id,
    studentId: student_id,
    groups: payloadGroups,
    source,
    syncSeq: nextM5SyncSeq(academy_id, device_id, student_id)
  });
  publish(
    `academies/${academy_id}/devices/${device_id}/homeworks`,
    JSON.stringify(envelope),
    { qos: 1, retain: false }
  );
  logEvent('log', '[gateway][m5-sync] publish', envelope.meta);
  return envelope;
}

// Active homework groups + take-home (숙제) groups merged. The homework-only
// RPC is additive; if it's not deployed yet we degrade gracefully to active-only.
async function listM5GroupsWithHomework(academy_id, student_id) {
  const [act, hw, flags, pcFlags] = await Promise.all([
    supa.rpc('m5_list_homework_groups', { p_academy_id: academy_id, p_student_id: student_id }),
    supa.rpc('m5_list_homework_only_groups', { p_academy_id: academy_id, p_student_id: student_id }),
    supa.rpc('m5_group_test_naesin_flags', { p_academy_id: academy_id, p_student_id: student_id }),
    supa.rpc('m5_group_pending_complete_flags', { p_academy_id: academy_id, p_student_id: student_id })
  ]);
  if (act.error) return { data: null, error: act.error };
  const missingFnRe = /42883|PGRST202|does not exist|could not find the function|schema cache/i;
  // group_id → { is_test, is_naesin }
  const flagMap = new Map();
  if (flags.error) {
    const msg = `${flags.error.code || ''} ${flags.error.message || ''}`;
    if (!missingFnRe.test(msg)) {
      console.warn('[gateway] group_test_naesin_flags error', flags.error);
    }
  } else if (Array.isArray(flags.data)) {
    for (const f of flags.data) flagMap.set(f.group_id, { is_test: !!f.is_test, is_naesin: !!f.is_naesin });
  }
  // group_id → pending_complete (확인 vs 완료 구분: 완료 예정이면 인디케이터 4칸)
  const pendingCompleteMap = new Map();
  if (pcFlags.error) {
    const msg = `${pcFlags.error.code || ''} ${pcFlags.error.message || ''}`;
    if (!missingFnRe.test(msg)) {
      console.warn('[gateway] group_pending_complete_flags error', pcFlags.error);
    }
  } else if (Array.isArray(pcFlags.data)) {
    for (const f of pcFlags.data) pendingCompleteMap.set(f.group_id, !!f.pending_complete);
  }
  const applyFlags = (g) => {
    const f = flagMap.get(g.group_id);
    return {
      ...g,
      is_test: !!(f && f.is_test),
      is_naesin: !!(f && f.is_naesin),
      pending_complete: !!pendingCompleteMap.get(g.group_id)
    };
  };
  const active = (Array.isArray(act.data) ? act.data : []).map(applyFlags);
  let homework = [];
  if (hw.error) {
    const msg = `${hw.error.code || ''} ${hw.error.message || ''}`;
    if (!/42883|PGRST202|does not exist|could not find the function|schema cache/i.test(msg)) {
      console.warn('[gateway] homework_only_groups error', hw.error);
    }
  } else if (Array.isArray(hw.data)) {
    homework = hw.data.map((g) => ({ ...applyFlags(g), is_homework: true }));
  }
  return { data: [...active, ...homework], error: null };
}

async function publishHomeworksToBoundDevicesImpl(academy_id, student_id, source = 'unknown') {
  const { data: binds, error: bErr } = await supa
    .from('m5_device_bindings')
    .select('device_id')
    .eq('academy_id', academy_id)
    .eq('student_id', student_id)
    .eq('active', true)
    .limit(10);
  if (bErr) {
    console.error('[gateway] realtime bindings error', { source, error: bErr });
    return;
  }
  if (!binds || binds.length === 0) return;

  const { data: groups, error } = await listM5GroupsWithHomework(academy_id, student_id);
  if (error) {
    console.error('[gateway] realtime list_homework_groups error', { source, error });
    return;
  }
  const payloadGroups = sanitizeGroupsForDevicePayload(groups || []);

  for (const b of binds) {
    const device_id = b.device_id;
    publishHomeworksToDevice(academy_id, student_id, device_id, payloadGroups, source);
  }
}

// Publish today's student list to a single device, excluding students that are
// actively bound to OTHER devices (matches the historic list_today filter).
async function publishStudentsTodayToDevice(academy_id, device_id, source = 'list') {
  const { data, error } = await supa.rpc('m5_get_students_today_basic', { p_academy_id: academy_id });
  if (error) { console.error('[gateway] students_today error', { source, error }); return 0; }
  const { data: binds, error: bErr } = await supa
    .from('m5_device_bindings')
    .select('student_id,device_id')
    .eq('academy_id', academy_id)
    .eq('active', true);
  if (bErr) { console.error('[gateway] students_today bindings error', { source, error: bErr }); return 0; }
  const boundToOther = new Set(
    (binds || []).filter(b => b.device_id !== device_id).map(b => b.student_id)
  );
  const filtered = (data || []).filter(s => !boundToOther.has(s.student_id));
  publish(`academies/${academy_id}/devices/${device_id}/students_today`, JSON.stringify({ students: filtered }), { qos: 1, retain: false });
  return filtered.length;
}

// After any bind/unbind, push a fresh student list to every UNBOUND online device
// so the just-(un)bound student appears/disappears immediately on all selectors.
async function republishStudentListToUnboundDevices(academy_id, source = 'rebind') {
  try {
    const [studentsRes, devicesRes, bindsRes] = await Promise.all([
      supa.rpc('m5_get_students_today_basic', { p_academy_id: academy_id }),
      supa.from('m5_devices').select('device_id').eq('academy_id', academy_id).eq('is_online', true),
      supa.from('m5_device_bindings').select('student_id,device_id').eq('academy_id', academy_id).eq('active', true)
    ]);
    if (studentsRes.error) { console.error('[gateway][list-resync] students error', { source, error: studentsRes.error }); return; }
    if (devicesRes.error) { console.error('[gateway][list-resync] devices error', { source, error: devicesRes.error }); return; }
    if (bindsRes.error) { console.error('[gateway][list-resync] bindings error', { source, error: bindsRes.error }); return; }
    const binds = bindsRes.data || [];
    const boundStudents = new Set(binds.map(b => b.student_id));
    const boundDevices = new Set(binds.map(b => b.device_id));
    const filtered = (studentsRes.data || []).filter(s => !boundStudents.has(s.student_id));
    const targets = (devicesRes.data || [])
      .map(d => d.device_id)
      .filter(id => id && !boundDevices.has(id));
    const payload = JSON.stringify({ students: filtered });
    for (const device_id of targets) {
      publish(`academies/${academy_id}/devices/${device_id}/students_today`, payload, { qos: 1, retain: false });
    }
    console.log('[gateway][list-resync] republished', { source, targets: targets.length, students: filtered.length });
  } catch (e) {
    console.error('[gateway][list-resync] error', { source, error: e?.message || e });
  }
}

async function publishHomeworksToBoundDevices(academy_id, student_id, source = 'unknown') {
  if (!academy_id || !student_id) return;
  const key = `${academy_id}::${student_id}`;
  const prev = homeworkPublishChains.get(key) ?? Promise.resolve();
  const job = prev
    .catch(() => {})
    .then(() => publishHomeworksToBoundDevicesImpl(academy_id, student_id, source))
    .catch((e) => {
      console.error('[gateway] publishHomeworksToBoundDevices chain', { source, key, error: e?.message ?? e });
    });
  homeworkPublishChains.set(key, job);
  return job;
}

function scheduleBindConfirmHomeworksRefresh(academy_id, student_id, device_id) {
  if (!academy_id || !student_id || !device_id || M5_BIND_CONFIRM_REFRESH_DELAY_MS <= 0) return;
  setTimeout(async () => {
    try {
      const { data: groups, error } = await listM5GroupsWithHomework(academy_id, student_id);
      if (error) {
        console.error('[gateway] bind confirm list_homework_groups error', {
          academy_id,
          device_id,
          student_id,
          error: error.message
        });
        return;
      }
      publishHomeworksToDevice(
        academy_id,
        student_id,
        device_id,
        groups || [],
        'bind_confirm_refresh'
      );
    } catch (e) {
      console.error('[gateway] bind confirm refresh error', {
        academy_id,
        device_id,
        student_id,
        error: e?.message || e
      });
    }
  }, M5_BIND_CONFIRM_REFRESH_DELAY_MS);
}

async function queueHomeworksToBoundDevices(academy_id, student_id, source = 'unknown') {
  if (!academy_id || !student_id) return;
  if (HOMEWORK_PUSH_COALESCE_MS <= 0) {
    return publishHomeworksToBoundDevices(academy_id, student_id, source);
  }

  const key = `${academy_id}::${student_id}`;
  let slot = homeworkPublishCoalesce.get(key);
  if (!slot) {
    slot = { timer: null, sources: new Set(), waiters: [] };
    homeworkPublishCoalesce.set(key, slot);
  }
  slot.sources.add(source);

  return new Promise((resolve, reject) => {
    slot.waiters.push({ resolve, reject });
    if (slot.timer) return;
    slot.timer = setTimeout(() => {
      const packedSource = Array.from(slot.sources).join(',');
      const waiters = slot.waiters.slice();
      homeworkPublishCoalesce.delete(key);
      publishHomeworksToBoundDevices(academy_id, student_id, packedSource)
        .then(() => waiters.forEach((w) => w.resolve()))
        .catch((err) => waiters.forEach((w) => w.reject(err)));
    }, HOMEWORK_PUSH_COALESCE_MS);
  });
}

async function runFullM5HomeworkResync(source = 'unknown') {
  const startedAt = nowMs();
  const { data: binds, error } = await supa
    .from('m5_device_bindings')
    .select('academy_id,student_id,device_id')
    .eq('active', true);

  if (error) {
    console.error('[gateway][m5-resync] bindings query error', { source, error });
    return;
  }

  const uniqueStudents = new Map();
  for (const row of binds || []) {
    const academy_id = (row?.academy_id || '').toString();
    const student_id = (row?.student_id || '').toString();
    if (!academy_id || !student_id) continue;
    const key = `${academy_id}::${student_id}`;
    const entry = uniqueStudents.get(key) || { academy_id, student_id, deviceCount: 0 };
    entry.deviceCount += 1;
    uniqueStudents.set(key, entry);
  }

  let okStudents = 0;
  let failedStudents = 0;
  let targetDevices = 0;
  for (const entry of uniqueStudents.values()) {
    targetDevices += entry.deviceCount;
    try {
      await publishHomeworksToBoundDevices(
        entry.academy_id,
        entry.student_id,
        `full_resync:${source}`
      );
      okStudents += 1;
    } catch (e) {
      failedStudents += 1;
      console.error('[gateway][m5-resync] student publish failed', {
        source,
        academy_id: entry.academy_id,
        student_id: entry.student_id,
        error: e?.message ?? e
      });
    }
  }

  console.log('[gateway][m5-resync] completed', {
    source,
    students: uniqueStudents.size,
    targetDevices,
    okStudents,
    failedStudents,
    elapsedMs: nowMs() - startedAt
  });
}

function scheduleFullM5HomeworkResync(reason = 'unknown', force = false) {
  const now = nowMs();
  if (!force && m5FullResyncLastRunTs && now - m5FullResyncLastRunTs < cfg.m5FullResyncCooldownMs) {
    logSampled(
      `m5_resync_cooldown:${reason}`,
      5000,
      'log',
      '[gateway][m5-resync] skip cooldown',
      { reason, ageMs: now - m5FullResyncLastRunTs, cooldownMs: cfg.m5FullResyncCooldownMs }
    );
    return;
  }

  if (m5FullResyncTimer) {
    m5FullResyncPendingReason = `${m5FullResyncPendingReason || 'pending'},${reason}`;
    return;
  }

  m5FullResyncPendingReason = reason;
  m5FullResyncTimer = setTimeout(async () => {
    const source = m5FullResyncPendingReason || reason;
    m5FullResyncTimer = null;
    m5FullResyncPendingReason = null;

    if (m5FullResyncInFlight) {
      scheduleFullM5HomeworkResync(`inflight:${source}`, true);
      return;
    }

    m5FullResyncInFlight = true;
    m5FullResyncLastRunTs = nowMs();
    console.log('[gateway][m5-resync] starting', { source });
    try {
      await runFullM5HomeworkResync(source);
    } catch (e) {
      console.error('[gateway][m5-resync] failed', { source, error: e?.message ?? e });
    } finally {
      m5FullResyncInFlight = false;
    }
  }, cfg.m5FullResyncDelayMs);
}

function handleRealtimeSubscribeStatus(label, status) {
  console.log(`[gateway][rt] ${label}`, status);
  if (status === 'SUBSCRIBED') {
    scheduleFullM5HomeworkResync(`rt:${label}:subscribed`);
  }
}

async function syncPauseAllRuntimeState(academy_id, student_id) {
  const { data: runtimeRows, error: listErr } = await supa
    .from('homework_group_runtime')
    .select('group_id,phase,run_start')
    .eq('academy_id', academy_id)
    .eq('student_id', student_id)
    .limit(24);

  if (listErr) {
    console.error('[gateway] pause_all runtime list error', { academy_id, student_id, error: listErr });
    return listErr;
  }

  const runningRows = (runtimeRows || []).filter((row) => {
    const phase = Number(row?.phase ?? 0);
    return phase === 2 || row?.run_start != null;
  });

  for (const row of runningRows) {
    const group_id = row?.group_id;
    if (!group_id) continue;
    const { error: syncErr } = await supa.rpc('m5_group_transition_state_v3', {
      p_academy_id: academy_id,
      p_group_id: group_id,
      p_from_phase: 4
    });
    if (syncErr) {
      console.error('[gateway] pause_all runtime sync error', { academy_id, student_id, group_id, error: syncErr });
      return syncErr;
    }
  }

  return null;
}

client.on('message', async (topic, payload) => {
  gatewayState.lastMessageTs = nowMs();
  gatewayState.lastInboundTopic = topic;
  try {
    const msg = JSON.parse(payload.toString());
    const parts = topic.split('/');
    if (parts.length >= 6 && parts[0] === 'academies' && parts[2] === 'students' && parts[4] === 'homework') {
      if (!validate(msg)) {
        console.warn('[gateway] invalid payload', validate.errors);
        return;
      }
      const [, academy_id, , student_id, , item_id] = parts;
      const action = msg.action;
      const idempotency_key = msg.idempotency_key;
      console.log('[gateway] recv', { action, academy_id, student_id, item_id });

    if (idempotency_key) {
      if (processed.has(idempotency_key)) {
        console.log('[gateway] skip duplicate', idempotency_key);
        return;
      }
      processed.set(idempotency_key, Date.now());
    }

    // TODO: idempotency check storage (e.g., memory + TTL or Redis)

    const rpcMap = {
      start: 'homework_start',
      pause: 'homework_pause',
      submit: 'homework_submit',
      confirm: 'homework_confirm',
      wait: 'homework_wait',
      complete: 'homework_complete',
      pause_all: 'homework_pause_all'
    };
    if (action === 'group_transition') {
      const group_id = (msg.group_id || '').toString().trim();
      if (!group_id) {
        console.error('[gateway] group_transition missing group_id', { academy_id, student_id });
        maybePublishAck(academy_id, idempotency_key, { ok: false, action, error: 'missing_group_id' });
        return;
      }
      const from_phase = Number.isFinite(Number(msg.from_phase))
        ? Number(msg.from_phase)
        : null;
      const { data, error } = await supa.rpc('homework_group_bulk_transition', {
        p_group_id: group_id,
        p_academy_id: academy_id,
        p_from_phase: from_phase
      });
      if (error) {
        console.error('[gateway] group_transition rpc error', error);
      }

      // Non-v2(device scoped) transition path must also keep runtime in sync,
      // otherwise m5_list_homework_groups may render stale phase from runtime.
      let runtimeSyncError = null;
      if (!error) {
        if (from_phase === 99) {
          const { error: commitErr } = await supa.rpc('m5_group_commit_children_v3', {
            p_academy_id: academy_id,
            p_group_id: group_id
          });
          runtimeSyncError = commitErr ?? null;
        } else {
          const { error: runtimeErr } = await supa.rpc('m5_group_transition_state_v3', {
            p_academy_id: academy_id,
            p_group_id: group_id,
            p_from_phase: from_phase
          });
          runtimeSyncError = runtimeErr ?? null;
        }
        if (runtimeSyncError) {
          console.error('[gateway] group_transition runtime sync rpc error', runtimeSyncError);
        }
      }

      const ok = !error && !runtimeSyncError;
      maybePublishAck(academy_id, idempotency_key, {
        ok,
        action,
        changed: data ?? 0,
        error: runtimeSyncError?.message ?? error?.message
      });
      if (ok) {
        // 수행 단일성 보강(방법 A): state_v3가 phase guard로 다른 그룹 pause를
        // 건너뛸 수 있어, 학생의 모든 그룹 runtime을 children 기준 재동기화.
        const { error: recErr } = await supa.rpc('m5_reconcile_student_group_runtimes', {
          p_academy_id: academy_id,
          p_student_id: student_id
        });
        if (recErr) {
          const msg = `${recErr.code || ''} ${recErr.message || ''}`;
          if (!/42883|PGRST202|does not exist|could not find the function|schema cache/i.test(msg)) {
            console.error('[gateway] reconcile runtimes error', recErr);
          }
        }
        await publishHomeworksToBoundDevices(academy_id, student_id, 'group_transition');
      }
      return;
    }
    const rpc = rpcMap[action];
    if (!rpc) return;

    const updated_by = msg.updated_by ?? null;
    let params = { p_item_id: item_id, p_academy_id: academy_id, p_updated_by: updated_by };
    if (action === 'start') params.p_student_id = student_id;
    if (action === 'pause_all') params = { p_student_id: student_id, p_academy_id: academy_id, p_updated_by: updated_by };
    const { error } = await supa.rpc(rpc, params);
    let runtimeSyncError = null;
    if (!error && action === 'pause_all') {
      runtimeSyncError = await syncPauseAllRuntimeState(academy_id, student_id);
    }
    if (error || runtimeSyncError) {
      console.error('[gateway] rpc error', runtimeSyncError ?? error);
    }

    const ok = !error && !runtimeSyncError;
    maybePublishAck(academy_id, idempotency_key, {
      ok,
      action,
      error: runtimeSyncError?.message ?? error?.message
    });
    if (ok) {
      await publishHomeworksToBoundDevices(academy_id, student_id, action);
    }
    return;
    }

    // presence handler: academies/{academy_id}/devices/{device_id}/presence
    if (parts.length >= 4 && parts[0] === 'academies' && parts[2] === 'devices' && parts[4] === 'presence') {
      const academy_id = parts[1];
      const device_id = parts[3];
      const online = !!msg.online;
      const at = msg.at || new Date().toISOString();
      const { error } = await supa.rpc('m5_device_presence', { p_academy_id: academy_id, p_device_id: device_id, p_online: online, p_at: at });
      if (error) console.error('[gateway] presence rpc error', error);
      return;
    }

    // device command: academies/{academy_id}/devices/{device_id}/command
    if (parts.length >= 4 && parts[0] === 'academies' && parts[2] === 'devices' && parts[4] === 'command') {
      const academy_id = parts[1];
      const device_id = parts[3];
      const action = msg.action; // e.g., bind, unbind, list_today
      console.log('[gateway] device command', { action, academy_id, device_id });
      if (action === 'group_transition') {
        const group_id = (msg.group_id || '').toString().trim();
        const student_id = (msg.student_id || '').toString().trim();
        const request_id = (msg.request_id || msg.idempotency_key || '').toString().trim();
        const from_phase = Number.isFinite(Number(msg.from_phase)) ? Number(msg.from_phase) : null;
        const ackTopic = `academies/${academy_id}/devices/${device_id}/ack`;

        if (device_id !== GROUP_CMD_V2_DEVICE_ID) {
          publish(
            ackTopic,
            JSON.stringify({
              ok: false,
              action: 'group_transition',
              request_id: request_id || null,
              error: 'group_transition_v2_disabled_for_device'
            }),
            { qos: 1, retain: false }
          );
          return;
        }

        if (!group_id || !student_id || !request_id) {
          publish(
            ackTopic,
            JSON.stringify({
              ok: false,
              action: 'group_transition',
              request_id: request_id || null,
              error: 'missing_group_or_student_or_request_id'
            }),
            { qos: 1, retain: false }
          );
          return;
        }

        const inflightKey = `${academy_id}::${student_id}::${group_id}`;
        const now = nowMs();
        const inflightUntil = groupTransitionInflightUntil.get(inflightKey) || 0;
        if (inflightUntil > now) {
          publish(
            ackTopic,
            JSON.stringify({
              ok: true,
              action: 'group_transition',
              request_id,
              group_id,
              student_id,
              changed: 0,
              dedup: true,
              suppressed: 'inflight'
            }),
            { qos: 1, retain: false }
          );
          logSampled(
            `${GROUP_CMD_V2_LOG_TAG}:suppressed:${inflightKey}`,
            1000,
            'log',
            `[${GROUP_CMD_V2_LOG_TAG}] suppressed duplicate transition`,
            { academy_id, device_id, student_id, group_id, request_id, inflightUntil }
          );
          return;
        }
        groupTransitionInflightUntil.set(inflightKey, now + GROUP_CMD_V2_SUPPRESS_MS);

        const { data, error } = await supa.rpc('m5_group_transition_command', {
          p_academy_id: academy_id,
          p_group_id: group_id,
          p_from_phase: from_phase,
          p_request_id: request_id,
          p_device_id: device_id
        });
        const row = data && typeof data === 'object' ? data : {};
        const ok = !error && row.ok !== false;
        if (error || !ok) {
          console.error(`[${GROUP_CMD_V2_LOG_TAG}] rpc error`, {
            academy_id,
            device_id,
            student_id,
            group_id,
            request_id,
            error: error?.message ?? row.error ?? 'unknown'
          });
        }

        publish(
          ackTopic,
          JSON.stringify({
            ok,
            action: 'group_transition',
            request_id,
            group_id,
            student_id,
            from_phase,
            mode: row.mode || (from_phase === 99 ? 'commit' : 'state'),
            changed: Number(row.changed ?? 0) || 0,
            dedup: !!row.dedup,
            error: error?.message ?? row.error
          }),
          { qos: 1, retain: false }
        );

        if (ok) {
          // 수행 단일성 보강(방법 A): 전환으로 pause된 다른 그룹들의 runtime이
          // phase=2로 잔존해 M5가 stale 초록불을 보이는 문제를 막는다. 실제
          // 적용된 경우(dedup 아님)에만, 해당 학생의 모든 그룹 runtime을
          // children 기준으로 재동기화한다.
          if (!row.dedup) {
            const { error: recErr } = await supa.rpc('m5_reconcile_student_group_runtimes', {
              p_academy_id: academy_id,
              p_student_id: student_id
            });
            if (recErr) {
              const msg = `${recErr.code || ''} ${recErr.message || ''}`;
              if (!/42883|PGRST202|does not exist|could not find the function|schema cache/i.test(msg)) {
                console.error(`[${GROUP_CMD_V2_LOG_TAG}] reconcile runtimes error`, recErr);
              }
            }
          }
          await queueHomeworksToBoundDevices(academy_id, student_id, `${GROUP_CMD_V2_LOG_TAG}:device_command`);
        }
        return;
      }
      if (action === 'bind') {
        const student_id = msg.student_id;
        const pin = (msg.pin === undefined || msg.pin === null) ? null : String(msg.pin);
        let status = 'ok';
        let bindMeta = {};
        const { data: bindRes, error: bindErr } = await supa.rpc('m5_bind_device_safe', {
          p_academy_id: academy_id, p_device_id: device_id, p_student_id: student_id, p_pin: pin
        });
        if (bindErr) {
          // Rollout safety: if the safe-bind RPC isn't migrated yet, fall back to the
          // legacy bind so logins keep working (no PIN / no race guard in that case).
          const missingFn = bindErr.code === '42883' || bindErr.code === 'PGRST202'
            || /does not exist|could not find the function|schema cache/i.test(bindErr.message || '');
          if (missingFn) {
            console.warn('[gateway] m5_bind_device_safe unavailable → legacy bind fallback');
            const { error: legErr } = await supa.rpc('m5_bind_device', { p_academy_id: academy_id, p_device_id: device_id, p_student_id: student_id });
            if (legErr) {
              console.error('[gateway] legacy bind rpc error', legErr);
              publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: false, action: 'bind', reason: 'server_error', error: legErr.message, student_id }), { qos: 1, retain: false });
              return;
            }
            status = 'ok';
          } else {
            console.error('[gateway] bind_safe rpc error', bindErr);
            publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: false, action: 'bind', reason: 'server_error', error: bindErr.message, student_id }), { qos: 1, retain: false });
            return;
          }
        } else {
          status = (bindRes && bindRes.status) || 'error';
          bindMeta = bindRes || {};
        }
        if (status !== 'ok') {
          // bind refused (already_bound / pin_invalid / locked / pin_setup_required):
          // surface the reason and refresh THIS device's (possibly stale) list.
          console.log('[gateway] bind refused', { device_id, student_id, status });
          publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({
            ok: false, action: 'bind', reason: status,
            attempts_left: bindMeta.attempts_left, locked_seconds: bindMeta.locked_seconds,
            student_id
          }), { qos: 1, retain: false });
          await publishStudentsTodayToDevice(academy_id, device_id, `bind:${status}`);
          return;
        }
        // Record arrival time (upsert attendance)
        const { error: arrivalErr } = await supa.rpc('m5_record_arrival', { p_academy_id: academy_id, p_student_id: student_id });
        if (arrivalErr) console.error('[gateway] record_arrival error', arrivalErr);
        // after bind, ensure attendance and list homeworks (active + 숙제)
        const { data: groups, error: lerr } = await listM5GroupsWithHomework(academy_id, student_id);
        if (lerr) console.error('[gateway] list_homework_groups error', lerr);
        publishHomeworksToDevice(academy_id, student_id, device_id, groups || [], 'bind');
        scheduleBindConfirmHomeworksRefresh(academy_id, student_id, device_id);
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !lerr, action: 'bind', error: lerr?.message, student_id }), { qos: 1, retain: false });
        // refresh other unbound devices so the bound student disappears from their lists
        await republishStudentListToUnboundDevices(academy_id, `bind:${device_id}`);
        return;
      }
      if (action === 'unbind') {
        const { error } = await supa.rpc('m5_unbind_device', { p_academy_id: academy_id, p_device_id: device_id });
        if (error) console.error('[gateway] unbind rpc error', error);
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind', error: error?.message }), { qos: 1, retain: false });
        await republishStudentListToUnboundDevices(academy_id, `unbind:${device_id}`);
        return;
      }
      if (action === 'unbind_by_student') {
        const student_id = msg.student_id;
        const { error } = await supa.rpc('m5_unbind_by_student', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) console.error('[gateway] unbind_by_student rpc error', error);
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind_by_student', error: error?.message, student_id }), { qos: 1, retain: false });
        await republishStudentListToUnboundDevices(academy_id, `unbind_by_student:${student_id}`);
        return;
      }
      if (action === 'list_today') {
        const count = await publishStudentsTodayToDevice(academy_id, device_id, 'list_today');
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: true, action: 'list_today', count }), { qos: 1, retain: false });
        return;
      }
      if (action === 'list_homeworks') {
        const student_id = msg.student_id;
        const { data: groups, error } = await listM5GroupsWithHomework(academy_id, student_id);
        if (error) { console.error('[gateway] list_homework_groups error', error); return; }
        publishHomeworksToDevice(academy_id, student_id, device_id, groups || [], 'list_homeworks');
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: true, action: 'list_homeworks', count: (groups||[]).length }), { qos: 1, retain: false });
        return;
      }
      if (action === 'student_info') {
        const student_id = msg.student_id;
        const { data, error } = await supa.rpc('m5_get_student_info', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) { console.error('[gateway] student_info error', error); return; }
        publish(`academies/${academy_id}/devices/${device_id}/student_info`, JSON.stringify({ info: data && data[0] ? data[0] : null }), { qos: 1, retain: false });
        return;
      }
      if (action === 'raise_question') {
        const student_id = (msg.student_id || '').toString().trim() || null;
        const { data: reqId, error } = await supa.rpc('m5_raise_student_question', {
          p_academy_id: academy_id,
          p_device_id: device_id,
          p_student_id: student_id
        });
        if (error) console.error('[gateway] raise_question rpc error', error);
        publish(
          `academies/${academy_id}/devices/${device_id}/ack`,
          JSON.stringify({
            ok: !error,
            action: 'raise_question',
            error: error?.message,
            request_id: reqId || null
          }),
          { qos: 1, retain: false }
        );
        return;
      }
      if (action === 'create_descriptive_writing') {
        const student_id_opt = (msg.student_id || '').toString().trim() || null;
        const { data: created, error } = await supa.rpc('m5_create_descriptive_writing_group', {
          p_academy_id: academy_id,
          p_device_id: device_id,
          p_student_id: student_id_opt || null
        });
        if (error) console.error('[gateway] create_descriptive_writing rpc error', error);
        const row = created && typeof created === 'object' ? created : null;
        const sid = row && row.student_id ? String(row.student_id) : null;
        const gid = row && row.group_id ? String(row.group_id) : null;
        const iid = row && row.item_id ? String(row.item_id) : null;
        publish(
          `academies/${academy_id}/devices/${device_id}/ack`,
          JSON.stringify({
            ok: !error,
            action: 'create_descriptive_writing',
            error: error?.message,
            group_id: gid,
            item_id: iid,
            student_id: sid
          }),
          { qos: 1, retain: false }
        );
        if (!error && sid) {
          await publishHomeworksToBoundDevices(academy_id, sid, 'create_descriptive_writing');
        }
        return;
      }
      return;
    }
  } catch (e) {
    console.error('[gateway] message error', e);
  }
});

client.on('error', (e) => logEvent('error', '[gateway] error', { error: e?.message ?? String(e) }));
client.on('close', () => {
  gatewayState.connected = false;
  gatewayState.lastDisconnectTs = nowMs();
  logSampled('mqtt_close', 5000, 'warn', '[gateway] close');
});
client.on('reconnect', () => logSampled('mqtt_reconnect', 5000, 'warn', '[gateway] reconnecting'));
client.on('offline', () => logSampled('mqtt_offline', 5000, 'warn', '[gateway] offline'));

// extra realtime connection lifecycle logs
try {
  const rt = supa.realtime;
  rt.onOpen(() => {
    console.log('[gateway][rt] socket open');
    scheduleFullM5HomeworkResync('rt:socket_open');
  });
  rt.onClose(() => console.log('[gateway][rt] socket close'));
  rt.onError((e) => console.log('[gateway][rt] socket error', e));
} catch (_) {}


async function queueHomeworksFromDirectStudentPayload(payload, source) {
  const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
  const academy_id = rec.academy_id;
  const student_id = rec.student_id;
  if (!academy_id || !student_id) {
    console.warn('[gateway][rt] skip homework push; missing owner', {
      source,
      eventType: payload?.eventType,
      id: rec.id ?? null
    });
    return;
  }
  await queueHomeworksToBoundDevices(academy_id, student_id, source);
}

function subscribeDirectStudentHomeworkTable(tableName) {
  try {
    try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
    const channel = supa
      .channel(`public:${tableName}:m5`)
      .on(
        'postgres_changes',
        { event: '*', schema: 'public', table: tableName },
        async (payload) => {
          try {
            await queueHomeworksFromDirectStudentPayload(payload, tableName);
          } catch (e) {
            console.error(`[gateway] realtime ${tableName} handler error`, e);
          }
        }
      )
      .subscribe((status) => handleRealtimeSubscribeStatus(tableName, status));
    console.log(`[gateway] realtime: ${tableName} subscribed init`);
    return channel;
  } catch (e) {
    console.warn(`[gateway] realtime ${tableName} subscribe failed`, e);
    return null;
  }
}

// Realtime: listen homework_items changes and push updated homeworks to bound devices
try {
  // ensure realtime auth is set (especially if anon/service token rotates)
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const channel = supa
    .channel('public:homework_items')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'homework_items' },
      async (payload) => {
        try {
          const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
          const academy_id = rec.academy_id;
          const student_id = rec.student_id;
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_items');
        } catch (e) {
          console.error('[gateway] realtime homework_items handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('homework_items', status));
  console.log('[gateway] realtime: homework_items subscribed init');
} catch (e) {
  console.warn('[gateway] realtime subscribe failed', e);
}

// Realtime: listen homework_assignments changes and push updated homeworks to bound devices
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const assignChannel = supa
    .channel('public:homework_assignments')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'homework_assignments' },
      async (payload) => {
        try {
          const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
          const academy_id = rec.academy_id;
          const student_id = rec.student_id;
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_assignments');
        } catch (e) {
          console.error('[gateway] realtime homework_assignments handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('homework_assignments', status));
  console.log('[gateway] realtime: homework_assignments subscribed init');
} catch (e) {
  console.warn('[gateway] realtime homework_assignments subscribe failed', e);
}

// Realtime: listen homework_groups changes (order/title/status) and push to bound devices
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const groupChannel = supa
    .channel('public:homework_groups')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'homework_groups' },
      async (payload) => {
        try {
          const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
          const academy_id = rec.academy_id;
          const student_id = rec.student_id;
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_groups');
        } catch (e) {
          console.error('[gateway] realtime homework_groups handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('homework_groups', status));
  console.log('[gateway] realtime: homework_groups subscribed init');
} catch (e) {
  console.warn('[gateway] realtime homework_groups subscribe failed', e);
}

// Realtime: listen homework_group_items changes (child order/membership) and push updates
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const groupItemsChannel = supa
    .channel('public:homework_group_items')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'homework_group_items' },
      async (payload) => {
        try {
          const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
          let academy_id = rec.academy_id;
          let student_id = rec.student_id;
          if ((!academy_id || !student_id) && rec.group_id) {
            const { data: g } = await supa
              .from('homework_groups')
              .select('academy_id,student_id')
              .eq('id', rec.group_id)
              .limit(1)
              .maybeSingle();
            if (g) {
              academy_id = academy_id || g.academy_id;
              student_id = student_id || g.student_id;
            }
          }
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_group_items');
        } catch (e) {
          console.error('[gateway] realtime homework_group_items handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('homework_group_items', status));
  console.log('[gateway] realtime: homework_group_items subscribed init');
} catch (e) {
  console.warn('[gateway] realtime homework_group_items subscribe failed', e);
}

// Realtime: homework_group_runtime changes → push updated homeworks to bound devices
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const runtimeChannel = supa
    .channel('public:homework_group_runtime')
    .on(
      'postgres_changes',
      { event: '*', schema: 'public', table: 'homework_group_runtime' },
      async (payload) => {
        try {
          const rec = payload?.new ?? payload?.old ?? payload?.record ?? {};
          const academy_id = rec.academy_id;
          const student_id = rec.student_id;
          logSampled(
            `rt_homework_group_runtime:${academy_id}:${student_id}`,
            5000,
            'log',
            '[gateway][rt] homework_group_runtime event',
            { academy_id, student_id, group_id: rec.group_id, eventType: payload?.eventType }
          );
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_group_runtime');
        } catch (e) {
          console.error('[gateway] realtime homework_group_runtime handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('homework_group_runtime', status));
  console.log('[gateway] realtime: homework_group_runtime subscribed init');
} catch (e) {
  console.warn('[gateway] realtime homework_group_runtime subscribe failed', e);
}

// Realtime: detailed homework tables also affect the M5 payload. Without these
// subscriptions, M5 only catches up on its stale watchdog refresh.
subscribeDirectStudentHomeworkTable('homework_item_units');
subscribeDirectStudentHomeworkTable('homework_item_pages');
subscribeDirectStudentHomeworkTable('homework_item_problems');
subscribeDirectStudentHomeworkTable('homework_assignment_checks');

// Realtime: listen m5_device_bindings changes → notify device on unbind
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const bindChannel = supa
    .channel('public:m5_device_bindings')
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'm5_device_bindings' },
      async (payload) => {
        try {
          const rec = payload?.new ?? {};
          const old = payload?.old ?? {};
          if (old.active === true && rec.active === false && rec.device_id && rec.academy_id) {
            // Check if device already has a new active binding (rebind case → skip)
            const { data: cur } = await supa
              .from('m5_device_bindings')
              .select('id')
              .eq('academy_id', rec.academy_id)
              .eq('device_id', rec.device_id)
              .eq('active', true)
              .limit(1);
            if (cur && cur.length > 0) {
              console.log('[gateway] binding replaced (rebind), skip unbound', { device_id: rec.device_id });
              return;
            }
            console.log('[gateway] binding deactivated', { device_id: rec.device_id, student_id: rec.student_id });
            publish(
              `academies/${rec.academy_id}/devices/${rec.device_id}/unbound`,
              JSON.stringify({ action: 'unbound', student_id: rec.student_id }),
              { qos: 1, retain: false }
            );
            await republishStudentListToUnboundDevices(rec.academy_id, 'realtime_unbound');
          }
        } catch (e) {
          console.error('[gateway] realtime m5_device_bindings handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('m5_device_bindings', status));
  console.log('[gateway] realtime: m5_device_bindings subscribed init');
} catch (e) {
  console.warn('[gateway] realtime m5_device_bindings subscribe failed', e);
}

// Realtime: listen attendance departures → refresh student lists on unbound devices.
// 매니저가 (바인딩 없이) 하원 처리하면 바인딩 변경이 없어 목록 재발행 트리거가 없다.
// 그 결과 다른 기기의 학생 리스트에 하원 학생이 남아있던 문제를 해결한다.
try {
  try { supa.realtime.setAuth?.(SUPABASE_SERVICE); } catch (_) {}
  const attChannel = supa
    .channel('public:attendance_records')
    .on(
      'postgres_changes',
      { event: 'UPDATE', schema: 'public', table: 'attendance_records' },
      async (payload) => {
        try {
          const rec = payload?.new ?? {};
          const old = payload?.old ?? {};
          // departure_time 이 새로 설정된 경우만(하원 처리)
          if (rec.academy_id && rec.departure_time && !old.departure_time) {
            console.log('[gateway] attendance departure → list resync', { student_id: rec.student_id });
            await republishStudentListToUnboundDevices(rec.academy_id, 'realtime_departure');
          }
        } catch (e) {
          console.error('[gateway] realtime attendance_records handler error', e);
        }
      }
    )
    .subscribe((status) => handleRealtimeSubscribeStatus('attendance_records', status));
  console.log('[gateway] realtime: attendance_records subscribed init');
} catch (e) {
  console.warn('[gateway] realtime attendance_records subscribe failed', e);
}

scheduleFullM5HomeworkResync('startup', true);

function shutdown(signal) {
  logEvent('warn', '[gateway] shutdown signal received', { signal });
  try {
    client.end(true, () => process.exit(0));
  } catch (_) {
    process.exit(0);
  }
}

process.on('SIGINT', () => shutdown('SIGINT'));
process.on('SIGTERM', () => shutdown('SIGTERM'));


