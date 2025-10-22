// Publish demo students_today payload to the device topic
// Usage:
//   MQTT_URL=mqtt://broker.emqx.io:1883 node scripts/publish_students_today_demo.js --academy-id=... --device-id=...

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
  console.error('[pub-students] Missing ACADEMY_ID or DEVICE_ID');
  process.exit(1);
}

const topic = `academies/${academyId}/devices/${deviceId}/students_today`;
const client = mqtt.connect(url);

client.on('connect', () => {
  console.log('[pub-students] connected', { url, topic });
  const payload = {
    students: [
      { name: '홍길동' },
      { name: '김철수' },
      { name: '이영희' },
    ],
  };
  client.publish(topic, JSON.stringify(payload), { qos: 1 }, () => {
    console.log('[pub-students] sent demo');
    client.end();
  });
});

client.on('error', (e) => {
  console.error('[pub-students] error', e);
  process.exit(2);
});





