import 'dotenv/config';
import mqtt from 'mqtt';
import { v4 as uuidv4 } from 'uuid';
import { createClient } from '@supabase/supabase-js';
import { readFileSync, existsSync } from 'fs';
import Ajv from 'ajv';

const SUPABASE_URL = process.env.SUPABASE_URL;
const SUPABASE_ANON = process.env.SUPABASE_ANON_KEY;
const MQTT_URL = process.env.MQTT_URL; // e.g. mqtts://broker:8883
const MQTT_USER = process.env.MQTT_USERNAME;
const MQTT_PASS = process.env.MQTT_PASSWORD;
const MQTT_CA_PATH = process.env.MQTT_CA_PATH;
const MQTT_CLIENT_ID = process.env.MQTT_CLIENT_ID || `ygg-gateway-${uuidv4()}`;

if (!SUPABASE_URL || !SUPABASE_ANON || !MQTT_URL) {
  console.error('[gateway] Missing envs');
  process.exit(1);
}

const supa = createClient(SUPABASE_URL, SUPABASE_ANON);

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
      complete: 'homework_complete'
    };
    const rpc = rpcMap[action];
    if (!rpc) return;

    const params = { p_item_id: item_id, p_academy_id: academy_id };
    if (action === 'start') params.p_student_id = student_id;
    const { error } = await supa.rpc(rpc, params);
    if (error) console.error('[gateway] rpc error', error);

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
        // after bind, ensure attendance and list homeworks
        const { data: items, error: lerr } = await supa.rpc('m5_list_homeworks', { p_academy_id: academy_id, p_student_id: student_id });
        if (lerr) console.error('[gateway] list_homeworks error', lerr);
        client.publish(`academies/${academy_id}/devices/${device_id}/homeworks`, JSON.stringify({ items: items || [] }), { qos: 1, retain: false });
        client.publish(`academies/${academy_id}/devices/${device_id}/ack`, JSON.stringify({ ok: !error && !lerr, action: 'bind', error: error?.message || lerr?.message, student_id }), { qos: 1, retain: false });
        return;
      }
      if (action === 'unbind') {
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
      return;
    }
  } catch (e) {
    console.error('[gateway] message error', e);
  }
});

client.on('error', (e) => console.error('[gateway] error', e));
client.on('close', () => console.log('[gateway] close'));


