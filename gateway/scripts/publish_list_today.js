// Simple helper to publish list_today to the device command topic
// Usage:
//   MQTT_URL=mqtt://broker.emqx.io:1883 ACADEMY_ID=... DEVICE_ID=... node scripts/publish_list_today.js

import 'dotenv/config';
import mqtt from 'mqtt';

const url = process.env.MQTT_URL || 'mqtt://broker.emqx.io:1883';

const argv = process.argv.slice(2);
const getArg = (name) => {
  const p = `--${name}=`;
  const f = argv.find((a) => a.startsWith(p));
  return f ? f.slice(p.length) : null;
};

const academyId = getArg('academy-id') || process.env.ACADEMY_ID;
const deviceId = getArg('device-id') || process.env.DEVICE_ID;

if (!academyId || !deviceId) {
  console.error('[pub] Missing ACADEMY_ID or DEVICE_ID');
  process.exit(1);
}

const topic = `academies/${academyId}/devices/${deviceId}/command`;
const client = mqtt.connect(url);

client.on('connect', () => {
  console.log('[pub] connected', { url, topic });
  client.publish(topic, JSON.stringify({ action: 'list_today' }), { qos: 1 }, () => {
    console.log('[pub] sent list_today');
    client.end();
  });
});

client.on('error', (e) => {
  console.error('[pub] error', e);
  process.exit(2);
});


