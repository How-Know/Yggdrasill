import 'dotenv/config';
import mqtt from 'mqtt';
import { randomUUID } from 'crypto';

const args = process.argv.slice(2);
function arg(name, fallback) {
  const i = args.indexOf('--' + name);
  return i !== -1 ? args[i + 1] : fallback;
}

const academy = arg('academy');
const student = arg('student');
const item = arg('item');
const action = arg('action', 'submit');

const url = process.env.MQTT_URL;
const user = process.env.MQTT_USERNAME;
const pass = process.env.MQTT_PASSWORD;

if (!academy || !item || !url) {
  console.error('usage: node scripts/publish_example.js --academy <id> --student <id> --item <id> --action <submit>');
  process.exit(1);
}

const client = mqtt.connect(url, { username: user, password: pass, protocolVersion: 5, clean: false });
client.on('connect', () => {
  const topic = `academies/${academy}/students/${student}/homework/${item}/command`;
  const payload = JSON.stringify({
    action,
    academy_id: academy,
    student_id: student,
    item_id: item,
    idempotency_key: randomUUID(),
    at: new Date().toISOString()
  });
  client.publish(topic, payload, { qos: 1, retain: false }, (err) => {
    if (err) console.error(err);
    else console.log('published', { topic, action });
    client.end(true);
  });
});


