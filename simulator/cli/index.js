#!/usr/bin/env node
import mqtt from 'mqtt';
import yargs from 'yargs';
import { hideBin } from 'yargs/helpers';

const argv = yargs(hideBin(process.argv))
  .option('url', { type: 'string', demandOption: true, desc: 'MQTT broker URL (mqtt:// or wss://)' })
  .option('username', { type: 'string', desc: 'MQTT username' })
  .option('password', { type: 'string', desc: 'MQTT password' })
  .option('academy', { type: 'string', demandOption: true, desc: 'Academy ID (uuid)' })
  .option('device', { type: 'string', demandOption: true, desc: 'Device ID (text)' })
  .option('student', { type: 'string', desc: 'Student ID (uuid) for bind/list_homeworks' })
  .command('list-today', 'Request today students list')
  .command('bind', 'Bind device to student (requires --student)')
  .command('list-homeworks', 'List homeworks for student (requires --student)')
  .demandCommand(1)
  .help()
  .argv;

const clientId = `ygg-cli-${Math.random().toString(16).slice(2)}`;
const client = mqtt.connect(argv.url, {
  clientId,
  username: argv.username,
  password: argv.password,
  clean: true,
  reconnectPeriod: 2000
});

const base = `academies/${argv.academy}/devices/${argv.device}`;

client.on('connect', () => {
  log(`connected as ${clientId}`);
  client.subscribe(`${base}/#`, { qos: 1 });
  if (argv._[0] === 'list-today') publish(`${base}/command`, { action: 'list_today' });
  if (argv._[0] === 'bind') publish(`${base}/command`, { action: 'bind', student_id: argv.student });
  if (argv._[0] === 'list-homeworks') publish(`${base}/command`, { action: 'list_homeworks', student_id: argv.student });
});

client.on('message', (topic, payload) => {
  const text = payload.toString();
  let json = null; try { json = JSON.parse(text); } catch {}
  if (topic.endsWith('/ack')) return log(`ACK ${text}`);
  if (topic.endsWith('/students_today')) return log(`STUDENTS ${text}`);
  if (topic.endsWith('/homeworks')) return log(`HOMEWORKS ${text}`);
  log(`MSG ${topic} ${text}`);
});

client.on('error', (e) => log(`error: ${e.message}`));

function publish(topic, obj){
  const payload = JSON.stringify(obj);
  client.publish(topic, payload, { qos: 1 }, (err) => {
    if (err) log('publish error'); else log(`published ${obj.action}`);
  });
}

function log(msg){
  const ts = new Date().toLocaleTimeString();
  console.log(`[${ts}] ${msg}`);
}




