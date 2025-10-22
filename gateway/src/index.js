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

if (!SUPABASE_URL || !SUPABASE_SERVICE || !MQTT_URL) {
  console.error('[gateway] Missing envs');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_SERVICE);

const schema = JSON.parse(readFileSync(new URL('../../infra/messaging/schemas/homework_command.v1.json', import.meta.url)));
const ajv = new Ajv({ allErrors: true, strict: false });
const validate = ajv.compile(schema);

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
  clean: true,
  clientId: MQTT_CLIENT_ID,
  keepalive: 30,
  ...tlsOpts
});

client.on('connect', () => {
  console.log('[gateway] connected', { clientId: MQTT_CLIENT_ID });
  client.subscribe('academies/+/students/+/homework/+/command', { qos: 1 }, (err) => {
    if (err) console.error('[gateway] subscribe error', err);
  });
  client.subscribe('academies/+/devices/+/command', { qos: 1 }, (err) => {
    if (err) console.error('[gateway] subscribe device command error', err);
  });
  // presence topics: retained online/offline
  client.subscribe('academies/+/devices/+/presence', { qos: 1 }, (err) => {
    if (err) console.error('[gateway] subscribe presence error', err);
  });
});

// simple idempotency cache (10 minutes TTL)
const processed = new Map(); // key -> timestamp
const IDEMP_TTL_MS = 10 * 60 * 1000;
setInterval(() => {
  const now = Date.now();
  for (const [k, ts] of processed.entries()) if (now - ts > IDEMP_TTL_MS) processed.delete(k);
}, 60 * 1000);

client.on('message', async (topic, payload) => {
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
    const rpc = rpcMap[action];
    if (!rpc) return;

    let params = { p_item_id: item_id, p_academy_id: academy_id };
    if (action === 'start') params.p_student_id = student_id;
    if (action === 'pause_all') params = { p_student_id: student_id, p_academy_id: academy_id };
    // Add updated_by if provided
    if (msg.updated_by) params.p_updated_by = msg.updated_by;
    const { error } = await supa.rpc(rpc, params);
    if (error) console.error('[gateway] rpc error', error);

    // Immediately publish fresh list to bound devices for this student (optimistic refresh)
    try {
      const { data: binds, error: bErr } = await supa
        .from('m5_device_bindings')
        .select('device_id')
        .eq('academy_id', academy_id)
        .eq('student_id', student_id)
        .eq('active', true)
        .limit(10);
      if (!bErr && Array.isArray(binds) && binds.length > 0) {
        const { data: items, error: lerr } = await supa.rpc('m5_list_homeworks', { p_academy_id: academy_id, p_student_id: student_id });
        if (!lerr) {
          for (const b of binds) {
            const device_id2 = b.device_id;
            client.publish(`academies/${academy_id}/devices/${device_id2}/homeworks`, JSON.stringify({ items: items || [] }), { qos: 1, retain: false });
          }
        }
      }
    } catch (e) {
      console.warn('[gateway] immediate refresh failed', e);
    }

      // Optional: publish ack
      client.publish(`academies/${academy_id}/ack/${idempotency_key}`, JSON.stringify({ ok: !error, action }), { qos: 1, retain: false });
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
      if (action === 'bind') {
        const student_id = msg.student_id;
        const { error } = await supa.rpc('m5_bind_device', { p_academy_id: academy_id, p_device_id: device_id, p_student_id: student_id });
        if (error) console.error('[gateway] bind rpc error', error);
        // Record arrival time (upsert attendance)
        const { error: arrivalErr } = await supa.rpc('m5_record_arrival', { p_academy_id: academy_id, p_student_id: student_id });
        if (arrivalErr) console.error('[gateway] record_arrival error', arrivalErr);
        // after bind, ensure attendance and list homeworks
        const { data: items, error: lerr } = await supa.rpc('m5_list_homeworks', { p_academy_id: academy_id, p_student_id: student_id });
        if (lerr) console.error('[gateway] list_homeworks error', lerr);
        client.publish(`academies/${academy_id}/devices/${device_id}/homeworks`, JSON.stringify({ items: items || [] }), { qos: 1, retain: false });
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error && !lerr, action: 'bind', error: error?.message || lerr?.message, student_id }), { qos: 1, retain: false });
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
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind', error: error?.message }), { qos: 1, retain: false });
        return;
      }
      if (action === 'unbind_by_student') {
        const student_id = msg.student_id;
        const { error } = await supa.rpc('m5_unbind_by_student', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) console.error('[gateway] unbind_by_student rpc error', error);
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error, action: 'unbind_by_student', error: error?.message, student_id }), { qos: 1, retain: false });
        return;
      }
      if (action === 'list_today') {
        const { data, error } = await supa.rpc('m5_get_students_today_basic', { p_academy_id: academy_id });
        if (error) { console.error('[gateway] list_today error', error); return; }
        client.publish(`academies/${academy_id}/devices/${device_id}/students_today`, JSON.stringify({ students: data || [] }), { qos: 1, retain: false });
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: true, action: 'list_today', count: (data||[]).length }), { qos: 1, retain: false });
        return;
      }
      if (action === 'list_homeworks') {
        const student_id = msg.student_id;
        const { data: items, error } = await supa.rpc('m5_list_homeworks', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) { console.error('[gateway] list_homeworks error', error); return; }
        client.publish(`academies/${academy_id}/devices/${device_id}/homeworks`, JSON.stringify({ items: items || [] }), { qos: 1, retain: false });
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: true, action: 'list_homeworks', count: (items||[]).length }), { qos: 1, retain: false });
        return;
      }
      if (action === 'student_info') {
        const student_id = msg.student_id;
        const { data, error } = await supa.rpc('m5_get_student_info', { p_academy_id: academy_id, p_student_id: student_id });
        if (error) { console.error('[gateway] student_info error', error); return; }
        client.publish(`academies/${academy_id}/devices/${device_id}/student_info`, JSON.stringify({ info: data && data[0] ? data[0] : null }), { qos: 1, retain: false });
        return;
      }
      return;
    }
  } catch (e) {
    console.error('[gateway] message error', e);
  }
});

client.on('error', (e) => console.error('[gateway] error', e));
client.on('close', () => console.log('[gateway] close'));
client.on('reconnect', () => console.log('[gateway] reconnecting...'));
client.on('offline', () => console.log('[gateway] offline'));

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
          if (!academy_id || !student_id) return;

          // find currently bound device(s) for the student
          const { data: binds, error: bErr } = await supa
            .from('m5_device_bindings')
            .select('device_id')
            .eq('academy_id', academy_id)
            .eq('student_id', student_id)
            .eq('active', true)
            .limit(10);
          if (bErr) { console.error('[gateway] realtime bindings error', bErr); return; }
          if (!binds || binds.length === 0) return;

          // fetch latest homeworks
          const { data: items, error } = await supa.rpc('m5_list_homeworks', { p_academy_id: academy_id, p_student_id: student_id });
          if (error) { console.error('[gateway] realtime list_homeworks error', error); return; }

          for (const b of binds) {
            const device_id = b.device_id;
            client.publish(`academies/${academy_id}/devices/${device_id}/homeworks`, JSON.stringify({ items: items || [] }), { qos: 1, retain: false });
          }
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


