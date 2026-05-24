import 'dotenv/config';
import mqtt from 'mqtt';
import { createClient } from '@supabase/supabase-js';
import { existsSync, readFileSync } from 'fs';
import { spawn } from 'child_process';
import readline from 'readline';
import {
  computeM5SyncFingerprint,
  sanitizeGroupsForDevicePayload
} from '../src/m5_sync_fingerprint.js';

const args = process.argv.slice(2);

function hasArg(name) {
  return args.includes(name);
}

function argValue(name, fallback = '') {
  const index = args.indexOf(name);
  if (index >= 0 && index + 1 < args.length) return args[index + 1];
  return fallback;
}

function intArg(name, fallback) {
  const parsed = Number.parseInt(argValue(name, ''), 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_SERVICE = process.env.SUPABASE_SERVICE_ROLE_KEY || process.env.SUPABASE_ANON_KEY;
const MQTT_URL = process.env.MQTT_URL;
const MQTT_USER = process.env.MQTT_USERNAME;
const MQTT_PASS = process.env.MQTT_PASSWORD;
const MQTT_CA_PATH = process.env.MQTT_CA_PATH;

if (!SUPABASE_URL || !SUPABASE_SERVICE || !MQTT_URL) {
  console.error('[m5-sync-watch] Missing SUPABASE_URL, SUPABASE_SERVICE_ROLE_KEY/SUPABASE_ANON_KEY, or MQTT_URL');
  process.exit(1);
}

const deviceId = argValue('--device-id', process.env.M5_WATCH_DEVICE_ID || 'm5-device-011');
let academyId = argValue('--academy-id', process.env.M5_WATCH_ACADEMY_ID || '');
const serialCommand = hasArg('--wireless') || hasArg('--no-serial')
  ? ''
  : argValue('--serial-command', process.env.M5_WATCH_SERIAL_COMMAND || '');
const serialCwd = argValue('--serial-cwd', process.env.M5_WATCH_SERIAL_CWD || process.cwd());
const dbPollMs = intArg('--db-poll-ms', Number.parseInt(process.env.M5_SYNC_DB_POLL_MS || '5000', 10));
const staleMs = intArg('--stale-ms', Number.parseInt(process.env.M5_SYNC_STALE_MS || '12000', 10));
const serialSilentMs = intArg('--serial-silent-ms', Number.parseInt(process.env.M5_SYNC_SERIAL_SILENT_MS || '0', 10));
const statusMs = intArg('--status-ms', Number.parseInt(process.env.M5_SYNC_STATUS_MS || '15000', 10));
const alertCooldownMs = intArg('--alert-cooldown-ms', Number.parseInt(process.env.M5_SYNC_ALERT_COOLDOWN_MS || '300000', 10));
const groupLimit = intArg('--group-limit', Number.parseInt(process.env.M5_GROUP_COUNT_LIMIT || '8', 10));
const childrenLimit = intArg('--children-limit', Number.parseInt(process.env.M5_GROUP_CHILDREN_LIMIT || '8', 10));

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE);

const tlsOpts = {};
if (MQTT_CA_PATH && existsSync(MQTT_CA_PATH)) {
  tlsOpts.ca = readFileSync(MQTT_CA_PATH);
}

const state = {
  binding: null,
  db: null,
  mqtt: null,
  m5: null,
  m5Acks: new Map(),
  lastSerialLineAt: 0,
  lastStatusAt: 0,
  mqttSubscribedTopics: new Set(),
  mqttConnected: false
};

const lastAlerts = new Map();

function nowIso() {
  return new Date().toISOString();
}

function ageMs(entry) {
  return entry?.at ? Date.now() - entry.at : Number.POSITIVE_INFINITY;
}

function emitAlert(type, payload = {}) {
  const key = `${type}:${payload.student_id || ''}:${payload.db_fp || ''}:${payload.mqtt_fp || ''}:${payload.m5_fp || ''}`;
  const now = Date.now();
  const previous = lastAlerts.get(key) || 0;
  if (now - previous < alertCooldownMs) return;
  lastAlerts.set(key, now);
  console.log(`AGENT_M5_SYNC_ALERT ${JSON.stringify({
    type,
    at: nowIso(),
    device_id: deviceId,
    academy_id: academyId || undefined,
    ...payload
  })}`);
}

function statusLine(extra = {}) {
  const now = Date.now();
  if (now - state.lastStatusAt < statusMs) return;
  state.lastStatusAt = now;
  console.log(`[m5-sync-watch] status ${JSON.stringify({
    at: nowIso(),
    device_id: deviceId,
    student_id: state.binding?.student_id,
    db_fp: state.db?.fp,
    mqtt_fp: state.mqtt?.fp,
    m5_fp: state.m5?.fp,
    mqtt_connected: state.mqttConnected,
    ...extra
  })}`);
}

async function loadBinding() {
  let query = supa
    .from('m5_device_bindings')
    .select('academy_id,student_id,device_id,active,updated_at,bound_at')
    .eq('device_id', deviceId)
    .eq('active', true)
    .order('updated_at', { ascending: false })
    .limit(1);
  if (academyId) query = query.eq('academy_id', academyId);

  const { data, error } = await query;
  if (error) {
    emitAlert('device_offline_or_unbound', { reason: `binding_query_failed:${error.message}` });
    return null;
  }
  const row = data?.[0] || null;
  if (row?.academy_id && !academyId) {
    academyId = row.academy_id;
    subscribeMqttTopics();
  }
  return row;
}

async function pollDbSnapshot() {
  const binding = await loadBinding();
  state.binding = binding;

  if (!binding?.academy_id || !binding?.student_id) {
    statusLine({ state: 'device_offline_or_unbound' });
    return;
  }

  const { data, error } = await supa.rpc('m5_list_homework_groups', {
    p_academy_id: binding.academy_id,
    p_student_id: binding.student_id
  });
  if (error) {
    emitAlert('db_to_gateway_stale', {
      reason: `canonical_rpc_failed:${error.message}`,
      student_id: binding.student_id
    });
    return;
  }

  const groups = sanitizeGroupsForDevicePayload(data || [], { groupLimit, childrenLimit });
  const fp = computeM5SyncFingerprint(groups);
  if (state.db?.fp !== fp || state.db?.student_id !== binding.student_id) {
    const hadPreviousSnapshot = Boolean(state.db);
    const observedAt = Date.now();
    state.db = {
      fp,
      at: observedAt,
      changed_at: hadPreviousSnapshot ? observedAt : 0,
      student_id: binding.student_id,
      group_count: groups.length
    };
    console.log(`[m5-sync-watch] db snapshot ${JSON.stringify(state.db)}`);
  }
  checkSyncHealth();
}

function handleMqttPayload(topic, payload) {
  if (topic.endsWith('/sync_ack')) {
    handleSyncAckPayload(topic, payload);
    return;
  }

  try {
    const doc = JSON.parse(payload.toString('utf8'));
    const groups = sanitizeGroupsForDevicePayload(doc.groups || [], { groupLimit, childrenLimit });
    const meta = doc.meta || {};
    state.mqtt = {
      fp: meta.sync_fp || computeM5SyncFingerprint(groups),
      seq: Number(meta.sync_seq || 0),
      at: Date.now(),
      topic,
      source: meta.source || 'unknown',
      student_id: meta.student_id || state.binding?.student_id,
      group_count: Number(meta.group_count || groups.length)
    };
    console.log(`[m5-sync-watch] mqtt homeworks ${JSON.stringify(state.mqtt)}`);
    checkSyncHealth();
  } catch (error) {
    emitAlert('gateway_to_m5_stale', { reason: `mqtt_payload_parse_failed:${error.message}` });
  }
}

function handleSyncAckPayload(topic, payload) {
  try {
    const doc = JSON.parse(payload.toString('utf8'));
    const ack = {
      fp: doc.sync_fp || '',
      seq: Number(doc.sync_seq || 0),
      at: Date.now(),
      topic,
      source: doc.source || 'unknown',
      student_id: doc.student_id || doc.meta_student_id || state.binding?.student_id,
      meta_student_id: doc.meta_student_id || '',
      group_count: Number(doc.group_count || 0),
      ok: doc.ok !== false
    };
    const ackKey = `${ack.student_id || ''}:${ack.seq}:${ack.fp}`;
    state.m5Acks.set(ackKey, ack);
    if (state.m5Acks.size > 200) {
      const oldestKey = state.m5Acks.keys().next().value;
      if (oldestKey) state.m5Acks.delete(oldestKey);
    }
    if (!state.m5 ||
        ack.seq > (state.m5.seq || 0) ||
        (ack.seq === state.m5.seq && ack.at >= state.m5.at)) {
      state.m5 = ack;
    }
    console.log(`[m5-sync-watch] m5 sync_ack ${JSON.stringify(state.m5)}`);
    checkSyncHealth();
  } catch (error) {
    emitAlert('gateway_to_m5_stale', { reason: `sync_ack_parse_failed:${error.message}` });
  }
}

const mqttClient = mqtt.connect(MQTT_URL, {
  username: MQTT_USER,
  password: MQTT_PASS,
  protocolVersion: 5,
  clean: true,
  clientId: `m5-sync-watch-${deviceId}-${Date.now()}`,
  keepalive: 15,
  reconnectPeriod: 3000,
  connectTimeout: 30000,
  ...tlsOpts
});

function subscribeMqttTopics() {
  if (!state.mqttConnected) return;
  const prefix = academyId
    ? `academies/${academyId}/devices/${deviceId}`
    : `academies/+/devices/${deviceId}`;
  const topics = [`${prefix}/homeworks`, `${prefix}/sync_ack`];
  for (const topic of topics) {
    if (state.mqttSubscribedTopics.has(topic)) continue;
    state.mqttSubscribedTopics.add(topic);
    mqttClient.subscribe(topic, { qos: 1 }, (error) => {
      if (error) emitAlert('gateway_to_m5_stale', { reason: `mqtt_subscribe_failed:${error.message}`, topic });
      else console.log(`[m5-sync-watch] subscribed ${topic}`);
    });
  }
}

mqttClient.on('connect', () => {
  state.mqttConnected = true;
  subscribeMqttTopics();
});
mqttClient.on('reconnect', () => {
  state.mqttConnected = false;
});
mqttClient.on('close', () => {
  state.mqttConnected = false;
});
mqttClient.on('error', (error) => {
  emitAlert('gateway_to_m5_stale', { reason: `mqtt_error:${error.message}` });
});
mqttClient.on('message', handleMqttPayload);

function handleSerialLine(line) {
  state.lastSerialLineAt = Date.now();
  if (line.includes('[M5SYNC]') || line.includes('[MQTT][WATCHDOG]') || line.includes('MQTT disconnect')) {
    console.log(line);
  }
  const match = line.match(/\[M5SYNC\]\[apply\].*?student=([^ ]*).*?sync_seq=(\d+).*?sync_fp=([^ ]*).*?source=([^ ]*)/);
  if (!match) return;
  state.m5 = {
    student_id: match[1],
    seq: Number(match[2] || 0),
    fp: match[3],
    source: match[4],
    at: Date.now(),
    line
  };
  checkSyncHealth();
}

function startSerialMonitor() {
  if (!serialCommand) return;
  console.log(`[m5-sync-watch] starting serial command: ${serialCommand}`);
  const child = spawn(serialCommand, {
    cwd: serialCwd,
    shell: true,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  const stdout = readline.createInterface({ input: child.stdout });
  const stderr = readline.createInterface({ input: child.stderr });
  stdout.on('line', handleSerialLine);
  stderr.on('line', (line) => {
    state.lastSerialLineAt = Date.now();
    console.error(`[m5-sync-watch][serial] ${line}`);
  });
  child.on('exit', (code, signal) => {
    emitAlert('serial_silent', { reason: `serial_monitor_exit:${code ?? signal ?? 'unknown'}` });
  });
}

function checkSyncHealth() {
  const binding = state.binding;
  if (!binding?.student_id) return;

  const dbChangeAgeMs = state.db?.changed_at ? Date.now() - state.db.changed_at : 0;
  const mqttIsBehindDb = !state.mqtt?.at || state.mqtt.at < state.db.changed_at;
  if (state.db?.changed_at &&
      state.db?.fp &&
      state.mqtt?.fp !== state.db.fp &&
      mqttIsBehindDb &&
      dbChangeAgeMs >= staleMs) {
    emitAlert('db_to_gateway_stale', {
      student_id: binding.student_id,
      db_fp: state.db.fp,
      mqtt_fp: state.mqtt?.fp,
      db_change_age_ms: dbChangeAgeMs,
      mqtt_age_ms: ageMs(state.mqtt)
    });
  }

  const mqttStudentId = state.mqtt?.student_id || binding.student_id;
  const matchingAckKey = state.mqtt
    ? `${mqttStudentId}:${state.mqtt.seq}:${state.mqtt.fp}`
    : '';
  const matchingAck = matchingAckKey ? state.m5Acks.get(matchingAckKey) : null;
  const m5MatchesMqtt = state.mqtt?.fp &&
    (matchingAck ||
      (state.m5?.fp === state.mqtt.fp &&
        state.m5?.student_id === mqttStudentId &&
        (state.mqtt.seq === 0 || (state.m5?.seq || 0) >= state.mqtt.seq)));

  if (state.mqtt?.fp && !m5MatchesMqtt && ageMs(state.mqtt) >= staleMs) {
    emitAlert('gateway_to_m5_stale', {
      student_id: binding.student_id,
      mqtt_fp: state.mqtt.fp,
      m5_fp: state.m5?.fp,
      sync_seq: state.mqtt.seq,
      m5_sync_seq: state.m5?.seq,
      mqtt_age_ms: ageMs(state.mqtt),
      m5_age_ms: ageMs(state.m5),
      source: state.mqtt.source
    });
  }
  statusLine();
}

function checkSerialSilence() {
  if (serialSilentMs <= 0) return;
  if (!serialCommand) return;
  if (state.lastSerialLineAt === 0) return;
  const silentFor = Date.now() - state.lastSerialLineAt;
  if (silentFor >= serialSilentMs) {
    emitAlert('serial_silent', {
      student_id: state.binding?.student_id,
      silent_for_ms: silentFor,
      last_m5_fp: state.m5?.fp
    });
  }
}

process.on('SIGINT', () => {
  console.log('[m5-sync-watch] stopping');
  mqttClient.end(true, () => process.exit(0));
});

startSerialMonitor();
await pollDbSnapshot();
setInterval(pollDbSnapshot, dbPollMs);
if (serialSilentMs > 0) {
  setInterval(checkSerialSilence, Math.min(serialSilentMs, 10000));
}
