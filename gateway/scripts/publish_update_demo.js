// Publish demo update response to the device's update topic
// Usage:
//   MQTT_URL=mqtt://broker.emqx.io:1883 node scripts/publish_update_demo.js --academy-id=... --device-id=...

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
  console.error('[pub-update] Missing ACADEMY_ID or DEVICE_ID');
  process.exit(1);
}

const topic = `academies/${academyId}/devices/${deviceId}/update`;
const client = mqtt.connect(url);

client.on('connect', () => {
  console.log('[pub-update] connected', { url, topic });
  const payload = {
    available: true,
    version: '1.2.3',
    notes: '버그 수정 및 안정화',
  };
  client.publish(topic, JSON.stringify(payload), { qos: 1 }, () => {
    console.log('[pub-update] sent update demo');
    client.end();
  });
});

client.on('error', (e) => {
  console.error('[pub-update] error', e);
  process.exit(2);
});





