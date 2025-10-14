const el = document.getElementById('app');
const state = {
  connected: false,
  academyId: '',
  deviceId: '',
  url: 'wss://broker.emqx.io:8084/mqtt',
  username: '',
  password: '',
  students: [],
  log: []
};

function log(msg) {
  state.log.push(`[${new Date().toLocaleTimeString()}] ${msg}`);
  render();
}

let client;

function connectMqtt() {
  if (client) try { client.end(true); } catch {}
  const { url, username, password } = state;
  if (!window.mqtt || !window.mqtt.connect) {
    log('mqtt 라이브러리가 로드되지 않았습니다. 네트워크를 확인 후 새로고침(F5) 해주세요.');
    return;
  }
  client = window.mqtt.connect(url, { username, password, clean: true, reconnectPeriod: 2000 });
  client.on('connect', () => { state.connected = true; log('MQTT connected'); subscribe(); render(); });
  client.on('reconnect', () => log('reconnecting...'));
  client.on('error', (e) => log('error: ' + e.message));
  client.on('message', (topic, payload) => onMessage(topic, payload));
}

function subscribe() {
  const topic = `academies/${state.academyId}/devices/${state.deviceId}/students_today`;
  client.subscribe(topic, { qos: 1 }, (err) => err ? log('subscribe error') : log('subscribed ' + topic));
  const ack = `academies/${state.academyId}/devices/${state.deviceId}/ack`;
  client.subscribe(ack, { qos: 1 }, (err) => err ? log('ack subscribe error') : log('subscribed ' + ack));
  const hw = `academies/${state.academyId}/devices/${state.deviceId}/homeworks`;
  client.subscribe(hw, { qos: 1 }, (err) => err ? log('homeworks subscribe error') : log('subscribed ' + hw));
}

function requestToday() {
  const topic = `academies/${state.academyId}/devices/${state.deviceId}/command`;
  client.publish(topic, JSON.stringify({ action: 'list_today' }), { qos: 1 });
  log('published list_today');
}

function bindStudent(studentId) {
  const topic = `academies/${state.academyId}/devices/${state.deviceId}/command`;
  client.publish(topic, JSON.stringify({ action: 'bind', student_id: studentId }), { qos: 1 });
  log('published bind ' + studentId);
}

function onMessage(topic, payload) {
  try {
    const msg = JSON.parse(new TextDecoder().decode(payload));
    if (topic.endsWith('/students_today')) {
      state.students = msg.students || [];
      log('students received: ' + state.students.length);
      render();
    }
    if (topic.endsWith('/ack')) {
      log('ack: ' + JSON.stringify(msg));
    }
    if (topic.endsWith('/homeworks')) {
      log('homeworks: ' + (msg.items?.length || 0));
      renderHomeworks(msg.items || []);
    }
  } catch (e) {
    log('message parse error');
  }
}

function render() {
  el.innerHTML = `
  <div style="font-family: system-ui, sans-serif; padding: 16px; max-width: 760px;">
    <h2>M5 Web Simulator</h2>
    <div style="display:flex; gap:12px; flex-wrap:wrap;">
      <label>Broker URL <input id="url" value="${state.url}" style="width:260px"/></label>
      <label>Username <input id="username" value="${state.username}"/></label>
      <label>Password <input id="password" value="${state.password}" type="password"/></label>
    </div>
    <div style="display:flex; gap:12px; margin-top:8px;">
      <label>Academy ID <input id="academyId" value="${state.academyId}" style="width:340px"/></label>
      <label>Device ID <input id="deviceId" value="${state.deviceId}" style="width:240px"/></label>
      <button id="connect">${state.connected ? 'Reconnect' : 'Connect'}</button>
    </div>
    <div style="margin-top:16px;">
      <button id="listToday" ${!state.connected?'disabled':''}>오늘 등원 목록 요청</button>
      <button id="unbind" ${!state.connected?'disabled':''} style="margin-left:8px;">언바인드</button>
    </div>
    <div style="margin-top:16px; display:grid; grid-template-columns: repeat(auto-fill, minmax(220px, 1fr)); gap:12px;">
      ${state.students.map(s => `
        <div style="border:1px solid #ccc; border-radius:8px; padding:12px;">
          <div style="font-weight:600; margin-bottom:8px;">${s.name || s.student_name || s.student_id || s.id}</div>
          <button data-bind="${s.student_id || s.id}">이 학생으로 바인딩</button>
        </div>
      `).join('')}
    </div>
  <div id="homeworks" style="margin-top:12px;"></div>
    <pre style="margin-top:16px; background:#111; color:#9f9; padding:12px; border-radius:8px; max-height:200px; overflow:auto;">${state.log.slice(-100).join('\n')}</pre>
  </div>`;

  document.getElementById('url').oninput = (e) => state.url = e.target.value;
  document.getElementById('username').oninput = (e) => state.username = e.target.value;
  document.getElementById('password').oninput = (e) => state.password = e.target.value;
  document.getElementById('academyId').oninput = (e) => state.academyId = e.target.value;
  document.getElementById('deviceId').oninput = (e) => state.deviceId = e.target.value;
  document.getElementById('connect').onclick = () => connectMqtt();
  const listBtn = document.getElementById('listToday');
  if (listBtn) listBtn.onclick = () => requestToday();
  const unbindBtn = document.getElementById('unbind');
  if (unbindBtn) unbindBtn.onclick = () => {
    const topic = `academies/${state.academyId}/devices/${state.deviceId}/command`;
    client.publish(topic, JSON.stringify({ action: 'unbind' }), { qos: 1 });
    log('published unbind');
  };
  document.querySelectorAll('button[data-bind]').forEach(btn => {
    btn.onclick = () => bindStudent(btn.getAttribute('data-bind'));
  });
}

render();

function renderHomeworks(items){
  const root = document.getElementById('homeworks');
  if (!root) return;
  if (!items.length) { root.innerHTML = '<i>과제가 없습니다</i>'; return; }
  root.innerHTML = `
    <div style="display:grid; gap:8px;">
      ${items.map(it => `
        <div style="border:1px solid #ddd; border-radius:8px; padding:8px;">
          <b>${it.title}</b> <span style="opacity:.7">[${it.phase==2?'수행':it.phase==3?'제출':it.phase==4?'확인':'대기'}]</span>
        </div>
      `).join('')}
    </div>
  `;
}


