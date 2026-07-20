'use strict';

/* ============================ 설정 / 상태 ============================ */
const CONFIG = window.KIOSK_CONFIG || {};
const ENDPOINT = (CONFIG.SUPABASE_URL || '').replace(/\/$/, '') + '/functions/v1/kiosk_api';
const ANON = CONFIG.SUPABASE_ANON_KEY || '';

const STORAGE = {
  deviceId: 'kiosk.deviceId',
  token: 'kiosk.deviceToken',
  weather: 'kiosk.weatherCache',
};

const state = {
  deviceId: '',
  token: '',
  academy: null,
  announcement: null,
  students: [],
  selected: null,
  checkoutMode: false,
  pin: '',
  submitting: false,
  pollTimer: null,
  pairTimer: null,
};

/* ============================ 유틸 ============================ */
function $(id) { return document.getElementById(id); }

function uuidv4() {
  if (crypto && crypto.randomUUID) return crypto.randomUUID();
  return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, (c) => {
    const r = (Math.random() * 16) | 0;
    const v = c === 'x' ? r : (r & 0x3) | 0x8;
    return v.toString(16);
  });
}

function pick(obj, keys, fallback) {
  if (!obj) return fallback;
  for (const k of keys) {
    const v = obj[k];
    if (v !== undefined && v !== null) return v;
  }
  return fallback;
}
function pickStr(obj, keys, fallback = '') {
  const v = pick(obj, keys, null);
  return v === null ? fallback : String(v);
}
function pickBool(obj, keys, fallback = false) {
  const v = pick(obj, keys, null);
  if (typeof v === 'boolean') return v;
  if (typeof v === 'number') return v !== 0;
  if (typeof v === 'string') {
    return ['true', '1', 'yes', 'checked_in', 'completed'].includes(v.toLowerCase());
  }
  return fallback;
}
function asMap(obj, keys) {
  const v = pick(obj, keys, null);
  return v && typeof v === 'object' && !Array.isArray(v) ? v : null;
}
function asList(obj, keys) {
  const v = pick(obj, keys, null);
  if (Array.isArray(v)) return v;
  if (v && typeof v === 'object') {
    const nested = pick(v, ['items', 'students', 'results', 'data'], null);
    if (Array.isArray(nested)) return nested;
  }
  return [];
}

/* ============================ 한글 초성 검색 ============================ */
const CHO = ['ㄱ','ㄲ','ㄴ','ㄷ','ㄸ','ㄹ','ㅁ','ㅂ','ㅃ','ㅅ','ㅆ','ㅇ','ㅈ','ㅉ','ㅊ','ㅋ','ㅌ','ㅍ','ㅎ'];
function initialsOf(value) {
  let out = '';
  for (const ch of value) {
    const code = ch.codePointAt(0);
    if (code >= 0xac00 && code <= 0xd7a3) {
      out += CHO[Math.floor((code - 0xac00) / 588)];
    } else {
      out += ch;
    }
  }
  return out;
}
function koMatches(value, query) {
  const v = value.toLowerCase().replace(/\s+/g, '');
  const q = query.toLowerCase().replace(/\s+/g, '');
  if (!q) return true;
  if (v.includes(q)) return true;
  return initialsOf(v).includes(q);
}

/* ============================ API ============================ */
async function callApi(action, body = {}, withSession = false) {
  const payload = { action, ...body };
  const headers = {
    'Content-Type': 'application/json',
    'apikey': ANON,
    'Authorization': 'Bearer ' + ANON,
  };
  if (withSession && state.token) {
    payload.token = state.token;
    payload.device_token = state.token;
    payload.device_id = state.deviceId;
    payload.deviceId = state.deviceId;
    headers['X-Kiosk-Token'] = state.token;
  }
  let res;
  try {
    res = await fetch(ENDPOINT, {
      method: 'POST',
      headers,
      body: JSON.stringify(payload),
    });
  } catch (e) {
    throw { code: 'network', message: '네트워크에 연결할 수 없습니다.' };
  }
  let data = {};
  try { data = await res.json(); } catch (e) { /* ignore */ }
  if (!res.ok) {
    const err = asMap(data, ['error']) || data;
    const code = pickStr(err, ['code', 'error_code', 'error'], pickStr(data, ['error']));
    throw { code, message: errorMessage(code, data, res.status), status: res.status };
  }
  return data;
}

function errorMessage(code, payload, status) {
  switch (code) {
    case 'pairing_pending': return '관리자 승인을 기다리고 있습니다.';
    case 'pairing_not_found': return '연결 PIN을 찾을 수 없습니다.';
    case 'pairing_expired': return '연결 PIN이 만료되었습니다.';
    case 'invalid_token': return '기기 연결이 만료되었습니다.';
    case 'pin_setup_required': return '학생 PIN이 아직 설정되지 않았습니다.';
    case 'pin_invalid': {
      const left = pick(payload, ['attempts_left'], null);
      return left === null ? 'PIN이 올바르지 않습니다.' : `PIN이 올바르지 않습니다. (${left}회 남음)`;
    }
    case 'pin_locked': {
      const sec = pick(payload, ['locked_seconds'], null);
      return sec === null ? 'PIN 입력이 잠시 잠겼습니다.' : `PIN 입력이 잠겼습니다. ${sec}초 후 다시 시도해 주세요.`;
    }
    case 'already_checked_in': return '이미 등원 처리된 학생입니다.';
    case 'not_checked_in': return '아직 등원 기록이 없는 학생입니다.';
    case 'already_checked_out': return '이미 하원 처리된 학생입니다.';
    case 'not_scheduled': return '오늘 예정에 없는 학생입니다. 추가수업으로 다시 시도해 주세요.';
    case 'student_not_found': return '학생 정보를 찾을 수 없습니다.';
    default: return pickStr(payload, ['message', 'detail', 'error_description'], `서버 요청에 실패했습니다. (${status || ''})`);
  }
}

/* ============================ 모델 파싱 ============================ */
function parseStudent(json) {
  const s = asMap(json, ['student', 'profile']) || json;
  let time = pickStr(json, ['time', 'scheduled_time', 'scheduledTime', 'start_time', 'startTime', 'lesson_time']);
  if (!time) {
    const cdt = pickStr(json, ['class_date_time', 'classDateTime']);
    const d = cdt ? new Date(cdt) : null;
    if (d && !isNaN(d)) {
      time = String(d.getHours()).padStart(2, '0') + ':' + String(d.getMinutes()).padStart(2, '0');
    }
  }
  return {
    id: pickStr(s, ['id', 'student_id', 'studentId', 'user_id'], pickStr(json, ['student_id', 'studentId', 'id'])),
    name: pickStr(s, ['name', 'student_name', 'studentName', 'display_name'], pickStr(json, ['student_name', 'studentName', 'name'], '학생')),
    timeLabel: time,
    checkedIn: pickBool(json, ['checked_in', 'checkedIn', 'is_checked_in', 'attending']),
    scheduledToday: pickBool(json, ['scheduled_today', 'scheduledToday', 'is_scheduled'], true),
  };
}

/* ============================ 페어링 / 부트스트랩 ============================ */
async function initialize() {
  state.deviceId = localStorage.getItem(STORAGE.deviceId) || '';
  if (!state.deviceId) {
    state.deviceId = uuidv4();
    localStorage.setItem(STORAGE.deviceId, state.deviceId);
  }
  state.token = localStorage.getItem(STORAGE.token) || '';

  if (!ENDPOINT || !ANON) {
    showSetupMessage('키오스크 연결 설정이 없습니다. config.js 를 확인해 주세요.');
    return;
  }

  if (state.token) {
    try {
      await loadBootstrap();
      enterReady();
      return;
    } catch (e) {
      if (e && e.code === 'invalid_token') {
        state.token = '';
        localStorage.removeItem(STORAGE.token);
      } else {
        showSetupMessage((e && e.message) || '연결에 실패했습니다.', true);
        return;
      }
    }
  }
  await startPairing();
}

async function startPairing() {
  showSetupLoading('연결 PIN을 발급받는 중...');
  try {
    const json = await callApi('begin_pairing', {
      device_id: state.deviceId,
      device_name: 'StanbyME 출석 키오스크',
    });
    const src = asMap(json, ['data', 'pairing']) || json;
    const pin = pickStr(src, ['pairing_pin', 'pairingPin', 'pin', 'code']);
    if (!pin) throw { code: 'no_pin', message: '연결 PIN을 받지 못했습니다.' };
    showPairing(pin);
    startPollPairing();
  } catch (e) {
    showSetupMessage((e && e.message) || '연결 PIN 발급에 실패했습니다.', true);
  }
}

function startPollPairing() {
  clearInterval(state.pairTimer);
  state.pairTimer = setInterval(async () => {
    try {
      const json = await callApi('poll_pairing', { device_id: state.deviceId, code: currentPin });
      const root = asMap(json, ['data', 'result', 'device']) || json;
      const token = pickStr(root, ['token', 'device_token', 'deviceToken', 'kiosk_token']);
      if (token) {
        state.token = token;
        localStorage.setItem(STORAGE.token, token);
        clearInterval(state.pairTimer);
        await loadBootstrap();
        enterReady();
      }
    } catch (e) {
      if (e && (e.code === 'pairing_expired' || e.code === 'pairing_not_found')) {
        clearInterval(state.pairTimer);
        startPairing();
      }
      // pairing_pending 등은 계속 폴링
    }
  }, 3000);
}

async function loadBootstrap() {
  const json = await callApi('bootstrap', {}, true);
  const root = asMap(json, ['data', 'result']) || json;
  const academy = asMap(root, ['academy', 'organization', 'tenant', 'institute']) || {};
  state.academy = {
    name: pickStr(academy, ['name', 'academy_name', 'academyName'], pickStr(root, ['academy_name', 'academyName'], 'Yggdrasill')),
    address: pickStr(academy, ['address', 'road_address', 'roadAddress', 'location'], pickStr(root, ['academy_address', 'academyAddress'])),
  };
  const ann = asMap(root, ['announcement', 'active_announcement', 'activeAnnouncement']);
  const active = ann ? pickBool(ann, ['active', 'is_active'], true) : false;
  state.announcement = (ann && active)
    ? { title: pickStr(ann, ['title', 'subject', 'name'], '공지사항'), body: pickStr(ann, ['body', 'content', 'message', 'text']) }
    : null;
}

async function refreshStudents() {
  try {
    const json = await callApi('list_today', {}, true);
    const root = asMap(json, ['data', 'result']) || json;
    const list = asList(root, ['students', 'items', 'visits', 'schedules', 'results', 'data']);
    state.students = list.map(parseStudent);
    state.students.sort((a, b) => a.timeLabel.localeCompare(b.timeLabel));
    renderStudents();
  } catch (e) {
    // 유지
  }
}

async function searchStudents(query) {
  try {
    const json = await callApi('search_students', { query, q: query }, true);
    const root = asMap(json, ['data', 'result']) || json;
    return asList(root, ['students', 'items', 'results', 'data'])
      .map(parseStudent)
      .map((s) => ({ ...s, scheduledToday: false }));
  } catch (e) {
    return [];
  }
}

async function checkIn(student, pin) {
  const requestId = Date.now() + '-' + Math.floor(Math.random() * 1e9);
  try {
    const json = await callApi('check_in', {
      student_id: student.id, studentId: student.id,
      pin, request_id: requestId, walk_in: !student.scheduledToday,
    }, true);
    const root = asMap(json, ['data', 'result']) || json;
    const ok = pickBool(root, ['success', 'ok', 'checked_in']);
    return { success: ok, message: pickStr(root, ['message', 'detail'], ok ? '등원이 완료되었습니다.' : '등원 처리에 실패했습니다.') };
  } catch (e) {
    return { success: false, message: (e && e.message) || '등원 처리에 실패했습니다.' };
  }
}

async function checkOut(student, pin) {
  const requestId = Date.now() + '-' + Math.floor(Math.random() * 1e9);
  try {
    const json = await callApi('check_out', {
      student_id: student.id, studentId: student.id, pin, request_id: requestId,
    }, true);
    const root = asMap(json, ['data', 'result']) || json;
    const ok = pickBool(root, ['success', 'ok', 'checked_out']);
    return { success: ok, message: pickStr(root, ['message', 'detail'], ok ? '하원이 완료되었습니다.' : '하원 처리에 실패했습니다.') };
  } catch (e) {
    return { success: false, message: (e && e.message) || '하원 처리에 실패했습니다.' };
  }
}

/* ============================ 화면 전환 ============================ */
let currentPin = '';

function showSetup() { $('setup').classList.remove('hidden'); $('main').classList.add('hidden'); }
function showSetupLoading(msg) {
  showSetup();
  $('setupBody').innerHTML = `<div class="setup-msg">${escapeHtml(msg)}</div><div class="spinner"></div>`;
}
function showSetupMessage(msg, retry) {
  showSetup();
  const btn = retry ? `<button class="setup-btn" id="retryBtn">다시 시도</button>` : '';
  $('setupBody').innerHTML = `<div class="setup-msg">${escapeHtml(msg)}</div>${btn}`;
  if (retry) $('retryBtn').addEventListener('click', () => initialize());
}
function showPairing(pin) {
  currentPin = pin;
  showSetup();
  $('setupBody').innerHTML =
    `<div class="setup-title">기기 연결 PIN</div>
     <div class="setup-pin">${escapeHtml(pin)}</div>
     <div class="setup-hint">관리자 화면에서 PIN을 입력하면 자동으로 연결됩니다.</div>
     <div class="spinner"></div>`;
}

function enterReady() {
  $('setup').classList.add('hidden');
  $('main').classList.remove('hidden');
  renderHeaderMeta();
  renderAnnouncement();
  refreshStudents();
  loadWeather();
  startClock();
  clearInterval(state.pollTimer);
  state.pollTimer = setInterval(async () => {
    try { await loadBootstrap(); renderAnnouncement(); renderHeaderMeta(); } catch (e) {}
    refreshStudents();
  }, 30000);
}

/* ============================ 렌더 ============================ */
function renderHeaderMeta() {
  $('academyText').textContent = state.academy ? state.academy.name : '';
}
function renderAnnouncement() {
  const has = !!state.announcement;
  $('app').classList.toggle('has-announcement', has);
  $('announcement').classList.toggle('hidden', !has);
  $('poster').classList.toggle('hidden', has);
  if (has) {
    $('annTitle').textContent = state.announcement.title;
    $('annBody').textContent = state.announcement.body;
  }
}

function renderStudents() {
  const list = $('studentList');
  list.innerHTML = '';
  if (!state.students.length) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = '표시할 학생이 없습니다.';
    list.appendChild(e);
    return;
  }
  for (const student of state.students) {
    const card = document.createElement('div');
    card.className = 'student-card' + (state.selected && state.selected.id === student.id ? ' selected' : '');
    const time = document.createElement('div');
    time.className = 'time' + (student.scheduledToday ? '' : ' extra');
    time.textContent = student.timeLabel || '추가수업';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = student.name;
    card.appendChild(time);
    card.appendChild(name);
    if (student.checkedIn) {
      const st = document.createElement('div');
      st.className = 'status';
      st.textContent = '등원중';
      card.appendChild(st);
    } else {
      const chev = document.createElement('div');
      chev.className = 'chev';
      chev.textContent = '›';
      card.appendChild(chev);
    }
    card.addEventListener('click', () => selectStudent(student));
    list.appendChild(card);
  }
}

/* ============================ 시트 / PIN ============================ */
function openSheet() {
  $('sheet').classList.add('open');
  $('sheet').setAttribute('aria-hidden', 'false');
  $('fab').classList.add('hidden-fade');
}
function closeSheet() {
  $('sheet').classList.remove('open');
  $('sheet').setAttribute('aria-hidden', 'true');
  $('fab').classList.remove('hidden-fade');
  clearSelection();
}

function selectStudent(student) {
  state.selected = student;
  state.checkoutMode = student.checkedIn;
  state.pin = '';
  const fb = student.checkedIn
    ? '등원 중인 학생입니다. PIN을 입력하면 하원 처리됩니다.'
    : (student.scheduledToday ? '' : '오늘 예정에 없는 학생입니다. 추가수업으로 등원 처리됩니다.');
  showPinPanel(fb, false);
  renderStudents();
}

function clearSelection() {
  state.selected = null;
  state.checkoutMode = false;
  state.pin = '';
  $('pinPanel').classList.add('hidden');
  $('studentList').classList.remove('shrink');
  renderStudents();
}

function showPinPanel(feedback, isOk) {
  const s = state.selected;
  if (!s) return;
  $('pinPanel').classList.remove('hidden');
  $('studentList').classList.add('shrink');
  $('pinTitle').textContent = state.checkoutMode
    ? `${s.name} 학생 하원 PIN`
    : `${s.name} 학생 PIN`;
  updatePinDots();
  const fb = $('pinFeedback');
  fb.textContent = feedback || '';
  fb.classList.toggle('ok', !!isOk);
}

function updatePinDots() {
  $('pinDots').textContent = '●'.repeat(state.pin.length).split('').join(' ');
}

function pressKey(value) {
  if (state.submitting || !state.selected) return;
  if (value === 'delete') {
    state.pin = state.pin.slice(0, -1);
    updatePinDots();
    return;
  }
  if (value === 'cancel') { clearSelection(); return; }
  if (state.pin.length >= 4) return;
  state.pin += value;
  updatePinDots();
  $('pinFeedback').textContent = '';
  $('pinFeedback').classList.remove('ok');
  if (state.pin.length === 4) submitPin();
}

async function submitPin() {
  const student = state.selected;
  if (!student || state.pin.length === 0 || state.submitting) return;
  state.submitting = true;
  const result = state.checkoutMode
    ? await checkOut(student, state.pin)
    : await checkIn(student, state.pin);
  state.submitting = false;
  state.pin = '';
  updatePinDots();
  if (result.success) {
    const fb = $('pinFeedback');
    fb.textContent = result.message;
    fb.classList.add('ok');
    state.selected = null;
    state.checkoutMode = false;
    await refreshStudents();
    setTimeout(() => {
      $('pinPanel').classList.add('hidden');
      $('studentList').classList.remove('shrink');
    }, 900);
  } else {
    const fb = $('pinFeedback');
    fb.textContent = result.message;
    fb.classList.remove('ok');
  }
}

function buildKeypad() {
  const keys = ['1','2','3','4','5','6','7','8','9','취소','0','지우기'];
  const pad = $('keypad');
  pad.innerHTML = '';
  for (const k of keys) {
    const b = document.createElement('button');
    b.type = 'button';
    b.textContent = k;
    if (k === '취소' || k === '지우기') b.className = 'small';
    b.addEventListener('click', () => {
      if (k === '취소') pressKey('cancel');
      else if (k === '지우기') pressKey('delete');
      else pressKey(k);
    });
    pad.appendChild(b);
  }
}

/* ============================ 검색 다이얼로그 ============================ */
let searchDebounce = null;
let searchRemote = [];

function openSearch() {
  closeSheet();
  setTimeout(() => {
    $('searchOverlay').classList.remove('hidden');
    $('searchInput').value = '';
    searchRemote = [];
    renderSearchResults();
    $('searchInput').focus();
  }, 380);
}
function closeSearch() {
  $('searchOverlay').classList.add('hidden');
  clearTimeout(searchDebounce);
}

function onSearchInput() {
  clearTimeout(searchDebounce);
  searchRemote = [];
  renderSearchResults();
  const q = $('searchInput').value.trim();
  if (!q) return;
  searchDebounce = setTimeout(async () => {
    const results = await searchStudents(q);
    if ($('searchInput').value.trim() === q) {
      searchRemote = results;
      renderSearchResults();
    }
  }, 450);
}

function searchResultList() {
  const q = $('searchInput').value.trim();
  if (!q) return state.students;
  const local = state.students.filter((s) => koMatches(s.name, q));
  const known = new Set(local.map((s) => s.id));
  const extra = searchRemote.filter((s) => !known.has(s.id));
  return [...local, ...extra];
}

function renderSearchResults() {
  const box = $('searchResults');
  box.innerHTML = '';
  const results = searchResultList();
  if (!results.length) {
    const e = document.createElement('div');
    e.className = 'empty';
    e.textContent = '검색 결과가 없습니다.';
    box.appendChild(e);
    return;
  }
  for (const student of results) {
    const row = document.createElement('div');
    row.className = 'row';
    const name = document.createElement('div');
    name.className = 'name';
    name.textContent = student.name;
    const status = document.createElement('div');
    status.className = 'status' + (student.checkedIn ? ' in' : '');
    status.textContent = student.checkedIn ? '등원중' : (student.scheduledToday ? '오늘 예정' : '추가수업');
    row.appendChild(name);
    row.appendChild(status);
    row.addEventListener('click', () => {
      closeSearch();
      setTimeout(() => { openSheet(); selectStudent(student); }, 200);
    });
    box.appendChild(row);
  }
}

/* ============================ 시계 / 날씨 ============================ */
const DAYS = ['일요일', '월요일', '화요일', '수요일', '목요일', '금요일', '토요일'];
let clockTimer = null;
function startClock() {
  updateClock();
  clearInterval(clockTimer);
  clockTimer = setInterval(updateClock, 10000);
}
function updateClock() {
  const now = new Date();
  $('dateText').textContent = `${now.getMonth() + 1}월 ${now.getDate()}일 ${DAYS[now.getDay()]}`;
  $('clock').textContent = String(now.getHours()).padStart(2, '0') + ':' + String(now.getMinutes()).padStart(2, '0');
}

async function loadWeather() {
  const address = state.academy && state.academy.address;
  if (!address) return;
  try {
    const cached = JSON.parse(localStorage.getItem(STORAGE.weather) || 'null');
    if (cached && cached.address === address && (Date.now() - cached.at) < 20 * 60 * 1000) {
      showWeather(cached.temp, cached.desc);
      return;
    }
  } catch (e) {}
  try {
    const geo = await fetch(`https://geocoding-api.open-meteo.com/v1/search?name=${encodeURIComponent(address)}&count=1&language=ko&format=json`).then((r) => r.json());
    const loc = geo && geo.results && geo.results[0];
    if (!loc) return;
    const fc = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${loc.latitude}&longitude=${loc.longitude}&current=temperature_2m,weather_code&timezone=Asia%2FSeoul`).then((r) => r.json());
    const cur = fc && fc.current;
    if (!cur) return;
    const temp = Math.round(cur.temperature_2m);
    const desc = describeWeather(cur.weather_code);
    showWeather(temp, desc);
    localStorage.setItem(STORAGE.weather, JSON.stringify({ address, at: Date.now(), temp, desc }));
  } catch (e) {}
}
function showWeather(temp, desc) {
  $('weatherText').textContent = `${temp}° ${desc}`;
  $('weatherText').classList.remove('hidden');
  $('sep2').classList.remove('hidden');
}
function describeWeather(code) {
  if (code === 0) return '맑음';
  if (code <= 3) return '구름';
  if (code === 45 || code === 48) return '안개';
  if (code <= 57) return '이슬비';
  if (code <= 67) return '비';
  if (code <= 77) return '눈';
  if (code <= 82) return '소나기';
  if (code <= 86) return '눈 소나기';
  return '뇌우';
}

/* ============================ 기타 ============================ */
function escapeHtml(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ============================ 시작 ============================ */
window.addEventListener('DOMContentLoaded', () => {
  buildKeypad();
  $('fab').addEventListener('click', openSheet);
  $('closeBtn').addEventListener('click', closeSheet);
  $('searchBtn').addEventListener('click', openSearch);
  $('searchClose').addEventListener('click', closeSearch);
  $('searchInput').addEventListener('input', onSearchInput);
  $('searchOverlay').addEventListener('click', (e) => { if (e.target.id === 'searchOverlay') closeSearch(); });
  initialize();
});
