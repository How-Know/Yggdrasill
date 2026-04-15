import 'dotenv/config';
import mqtt from 'mqtt';
import { v4 as uuidv4 } from 'uuid';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, existsSync } from 'fs';
import Ajv from 'ajv';

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
const GW_STALE_ACTIVITY_WINDOW_MS = Number.parseInt(process.env.GW_STALE_ACTIVITY_WINDOW_MS ?? '600000', 10);
const GW_RECOVERY_COOLDOWN_MS = Number.parseInt(process.env.GW_RECOVERY_COOLDOWN_MS ?? '60000', 10);

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
  staleActivityWindowMs: validInt(GW_STALE_ACTIVITY_WINDOW_MS, 600000),
  recoveryCooldownMs: validInt(GW_RECOVERY_COOLDOWN_MS, 60000)
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
  if (staleMs >= cfg.staleHardMs) {
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
  staleActivityWindowMs: cfg.staleActivityWindowMs,
  recoveryCooldownMs: cfg.recoveryCooldownMs
});

/** 학생 단위로 RPC+푸시를 직렬화해 빠른 연속 DB 이벤트 시 스냅샷 역전·중간 상태 유실 완화 */
const homeworkPublishChains = new Map();
const homeworkPublishCoalesce = new Map();

function sanitizeGroupsForDevicePayload(groups) {
  if (!Array.isArray(groups)) return [];
  const trimmed = groups.slice(0, M5_GROUP_COUNT_LIMIT);
  return trimmed.map((group) => {
    if (!group || typeof group !== 'object') return group;
    const children = Array.isArray(group.children)
      ? group.children.slice(0, M5_GROUP_CHILDREN_LIMIT)
      : group.children;
    return { ...group, children };
  });
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

  const { data: groups, error } = await supa.rpc('m5_list_homework_groups', {
    p_academy_id: academy_id,
    p_student_id: student_id
  });
  if (error) {
    console.error('[gateway] realtime list_homework_groups error', { source, error });
    return;
  }
  const payloadGroups = sanitizeGroupsForDevicePayload(groups || []);

  for (const b of binds) {
    const device_id = b.device_id;
    publish(
      `academies/${academy_id}/devices/${device_id}/homeworks`,
      JSON.stringify({ groups: payloadGroups }),
      { qos: 1, retain: false }
    );
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
    if (error) console.error('[gateway] rpc error', error);

    maybePublishAck(academy_id, idempotency_key, { ok: !error, action });
    if (!error) {
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
          await queueHomeworksToBoundDevices(academy_id, student_id, `${GROUP_CMD_V2_LOG_TAG}:device_command`);
        }
        return;
      }
      if (action === 'bind') {
        const student_id = msg.student_id;
        const { error } = await supa.rpc('m5_bind_device', { p_academy_id: academy_id, p_device_id: device_id, p_student_id: student_id });
        if (error) console.error('[gateway] bind rpc error', error);
        // Record arrival time (upsert attendance)
        const { error: arrivalErr } = await supa.rpc('m5_record_arrival', { p_academy_id: academy_id, p_student_id: student_id });
        if (arrivalErr) console.error('[gateway] record_arrival error', arrivalErr);
        // after bind, ensure attendance and list homeworks
        const { data: groups, error: lerr } = await supa.rpc('m5_list_homework_groups', { p_academy_id: academy_id, p_student_id: student_id });
        if (lerr) console.error('[gateway] list_homework_groups error', lerr);
        publish(
          `academies/${academy_id}/devices/${device_id}/homeworks`,
          JSON.stringify({ groups: sanitizeGroupsForDevicePayload(groups || []) }),
          { qos: 1, retain: false }
        );
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error && !lerr, action: 'bind', error: error?.message || lerr?.message, student_id }), { qos: 1, retain: false });
        return;
      }
      if (action === 'unbind') {
        const student_id = msg.student_id;
        // Record departure time before unbinding (if student_id provided)
        if (student_id) {
          const { error: depErr } = await supa.rpc('m5_record_departure', { p_academy_id: academy_id, p_student_id: student_id });
          if (depErr) console.error('[gateway] record_departure error', depErr);
        }
        const { error } = await supa.rpc('m5_unbind_device', { p_academy_id: academy_id, p_device_id: device_id });
        if (error) console.error('[gateway] unbind rpc error', error);
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind', error: error?.message }), { qos: 1, retain: false });
        return;
      }
      if (action === 'unbind_by_student') {
        const student_id = msg.student_id;
        const { error } = await supa.rpc('m5_unbind_by_student', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) console.error('[gateway] unbind_by_student rpc error', error);
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind_by_student', error: error?.message, student_id }), { qos: 1, retain: false });
        return;
      }
      if (action === 'list_today') {
        const { data, error } = await supa.rpc('m5_get_students_today_basic', { p_academy_id: academy_id });
        if (error) { console.error('[gateway] list_today error', error); return; }
        const { data: binds } = await supa
          .from('m5_device_bindings')
          .select('student_id,device_id')
          .eq('academy_id', academy_id)
          .eq('active', true);
        const boundToOther = new Set(
          (binds || []).filter(b => b.device_id !== device_id).map(b => b.student_id)
        );
        const filtered = (data || []).filter(s => !boundToOther.has(s.student_id));
        publish(`academies/${academy_id}/devices/${device_id}/students_today`, JSON.stringify({ students: filtered }), { qos: 1, retain: false });
        publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: true, action: 'list_today', count: filtered.length }), { qos: 1, retain: false });
        return;
      }
      if (action === 'list_homeworks') {
        const student_id = msg.student_id;
        const { data: groups, error } = await supa.rpc('m5_list_homework_groups', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) { console.error('[gateway] list_homework_groups error', error); return; }
        publish(
          `academies/${academy_id}/devices/${device_id}/homeworks`,
          JSON.stringify({ groups: sanitizeGroupsForDevicePayload(groups || []) }),
          { qos: 1, retain: false }
        );
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
  rt.onOpen(() => console.log('[gateway][rt] socket open'));
  rt.onClose(() => console.log('[gateway][rt] socket close'));
  rt.onError((e) => console.log('[gateway][rt] socket error', e));
} catch (_) {}


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
    .subscribe((status) => console.log('[gateway][rt]', status));
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
    .subscribe((status) => console.log('[gateway][rt] homework_assignments', status));
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
    .subscribe((status) => console.log('[gateway][rt] homework_groups', status));
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
    .subscribe((status) => console.log('[gateway][rt] homework_group_items', status));
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
          await queueHomeworksToBoundDevices(academy_id, student_id, 'homework_group_runtime');
        } catch (e) {
          console.error('[gateway] realtime homework_group_runtime handler error', e);
        }
      }
    )
    .subscribe((status) => console.log('[gateway][rt] homework_group_runtime', status));
  console.log('[gateway] realtime: homework_group_runtime subscribed init');
} catch (e) {
  console.warn('[gateway] realtime homework_group_runtime subscribe failed', e);
}

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
          }
        } catch (e) {
          console.error('[gateway] realtime m5_device_bindings handler error', e);
        }
      }
    )
    .subscribe((status) => console.log('[gateway][rt] m5_device_bindings', status));
  console.log('[gateway] realtime: m5_device_bindings subscribed init');
} catch (e) {
  console.warn('[gateway] realtime m5_device_bindings subscribe failed', e);
}

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


