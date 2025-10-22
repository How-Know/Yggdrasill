// Subscribe students_today for a device and print payload
// Usage:
//   MQTT_URL=mqtt://broker.emqx.io:1883 node scripts/sub_students_today.js --academy-id=... --device-id=...

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
  console.error('[sub] Missing ACADEMY_ID or DEVICE_ID');
  process.exit(1);
}

const topic = `academies/${academyId}/devices/${deviceId}/students_today`;
const client = mqtt.connect(url);

client.on('connect', () => {
  console.log('[sub] connected', { url, topic });
  client.subscribe(topic, { qos: 1 }, (err) => {
    if (err) {
      console.error('[sub] subscribe error', err);
      process.exit(2);
    }
    console.log('[sub] subscribed');
  });
});

client.on('message', (t, payload) => {
  if (t === topic) {
    console.log('[sub] received students_today:', payload.toString());
    process.exit(0);
  }
});

client.on('error', (e) => {
  console.error('[sub] error', e);
  process.exit(3);
});



