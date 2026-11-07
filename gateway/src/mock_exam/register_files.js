// 파일명 규칙에 맞는 모의고사 PDF 를 mock_exams 에 올린다.
// queue 가 아니면 추출 대기열에 넣지 않는다. review 인 시험의 기존 PDF 는 바꾸지 않는다.
import crypto from 'node:crypto';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';

const FILE_RE =
  /^(\d{4})\s*고\s*([123])\s*(\d{1,2})\s*월\s*(교육청|평가원|수능)\s*(?:\(\s*(확통|확률과\s*통계|미적분?|기하)\s*\))?\s*(?:[-_]\s*(해설))?\s*$/;
const ORG = { 교육청: 'edu', 평가원: 'kice', 수능: 'csat' };
const ORG_LABEL = { edu: '교육청', kice: '평가원', csat: '수능' };
const MOCK_DIR_NAME = '- 모의고사';

function electiveOf(raw) {
  const s = String(raw || '').replace(/\s+/g, '');
  if (s.startsWith('확')) return 'probstats';
  if (s.startsWith('미')) return 'calculus';
  if (s.startsWith('기')) return 'geometry';
  return '';
}

export function parseMockFileName(file) {
  if (path.extname(file).toLowerCase() !== '.pdf') return null;
  const m = FILE_RE.exec(path.basename(file, path.extname(file)).trim());
  if (!m) return null;
  const grade = Number(m[2]);
  const elective = electiveOf(m[5]);
  if ((grade === 3) !== Boolean(elective)) return null;
  return {
    file,
    examYear: Number(m[1]),
    grade,
    month: Number(m[3]),
    org: ORG[m[4]],
    elective,
    kind: m[6] ? 'solution' : 'problem',
  };
}

export function collectPdfs(dir, out = []) {
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (ent.name === 'desktop.ini') continue;
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) collectPdfs(full, out);
    else if (ent.isFile() && path.extname(ent.name).toLowerCase() === '.pdf') out.push(full);
  }
  return out;
}

function dropboxRoots() {
  const roots = [];
  for (const key of ['APPDATA', 'LOCALAPPDATA']) {
    const base = process.env[key];
    if (!base) continue;
    const infoPath = path.join(base, 'Dropbox', 'info.json');
    if (fs.existsSync(infoPath)) {
      try {
        const data = JSON.parse(fs.readFileSync(infoPath, 'utf8'));
        for (const item of Object.values(data)) {
          if (item && typeof item === 'object' && item.path) roots.push(String(item.path));
        }
      } catch {
        // 드롭박스 정보 파일이 깨져 있으면 다음 후보로 넘어간다.
      }
    }
    const hostPath = path.join(base, 'Dropbox', 'host.db');
    if (fs.existsSync(hostPath)) {
      try {
        const lines = fs.readFileSync(hostPath, 'utf8').split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
        if (lines.length > 0) roots.push(Buffer.from(lines.at(-1), 'base64').toString('utf8'));
      } catch {
        // host.db 를 읽지 못하면 홈 폴더를 본다.
      }
    }
  }
  const home = path.join(os.homedir(), 'Dropbox');
  if (fs.existsSync(home)) roots.push(home);
  return roots;
}

function findNamed(root) {
  const direct = path.join(root, MOCK_DIR_NAME);
  if (fs.existsSync(direct)) return direct;
  let children = [];
  try {
    children = fs.readdirSync(root, { withFileTypes: true });
  } catch {
    return '';
  }
  for (const child of children) {
    if (!child.isDirectory()) continue;
    const nested = path.join(root, child.name, MOCK_DIR_NAME);
    if (fs.existsSync(nested)) return nested;
  }
  return '';
}

export function discoverMockExamDir() {
  const env = String(process.env.MOCK_EXAM_DIR || process.env.EXAM_DESK_MOCK || '').trim();
  if (env) return env;
  for (const root of dropboxRoots()) {
    const found = findNamed(root);
    if (found) return found;
  }
  return path.join(os.homedir(), 'Dropbox', MOCK_DIR_NAME);
}

export function syncStatePath() {
  const dir = process.platform === 'win32'
    ? path.join(process.env.LOCALAPPDATA || path.join(os.homedir(), 'AppData', 'Local'), 'Yggdrasill')
    : path.join(os.homedir(), '.local', 'share', 'yggdrasill');
  return path.join(dir, 'mock-exam-folder-sync.json');
}

export async function resolveAcademyId(supa, explicit = '') {
  const given = String(explicit || process.env.MOCK_EXAM_ACADEMY_ID || '').trim();
  if (given && given !== 'auto') return given;
  const { data, error } = await supa.from('academies').select('id');
  if (error) throw new Error(`academies: ${error.message}`);
  if (data?.length === 1) return data[0].id;
  throw new Error('학원이 하나가 아니라 모의고사 카드를 어느 학원에 올릴지 정하지 못했습니다');
}

async function uploadPaper(supa, academyId, examId, parsed) {
  const bytes = fs.readFileSync(parsed.file);
  const sha256 = crypto.createHash('sha256').update(bytes).digest('hex');
  const { data: existing, error: readErr } = await supa
    .from('mock_exam_papers')
    .select('id, sha256')
    .eq('exam_id', examId)
    .eq('kind', parsed.kind)
    .eq('elective', parsed.elective)
    .maybeSingle();
  if (readErr) throw new Error(`mock_exam_papers read: ${readErr.message}`);
  if (existing?.sha256 === sha256) return 'same';
  const suffix = `${Date.now()}_${crypto.randomBytes(3).toString('hex')}`;
  const objectPath = `${academyId}/mock-exams/${examId}/${parsed.kind}_${parsed.elective || 'common'}_${suffix}.pdf`;
  const up = await supa.storage
    .from('problem-documents')
    .upload(objectPath, bytes, { contentType: 'application/pdf', upsert: false });
  if (up.error) throw new Error(`storage upload: ${up.error.message}`);
  const row = {
    academy_id: academyId,
    exam_id: examId,
    kind: parsed.kind,
    elective: parsed.elective,
    storage_bucket: 'problem-documents',
    storage_path: objectPath,
    file_name: path.basename(parsed.file),
    sha256,
    size_bytes: bytes.length,
    page_count: null,
  };
  const { error: paperErr } = await supa.from('mock_exam_papers').upsert(row, {
    onConflict: 'exam_id,kind,elective',
  });
  if (paperErr) throw new Error(`mock_exam_papers upsert: ${paperErr.message}`);
  return existing ? 'replaced' : 'created';
}

export async function registerMockPdfs(supa, academyId, parsed, { queue = false, quiet = false } = {}) {
  const groups = new Map();
  for (const item of parsed) {
    const key = `${item.grade}|${item.examYear}|${item.month}|${item.org}`;
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key).push(item);
  }
  const summary = { exams: 0, created: 0, same: 0, replaced: 0, kept: 0, skipped: 0 };
  for (const group of groups.values()) {
    const head = group[0];
    const title = `${head.examYear} 고${head.grade} ${head.month}월 ${ORG_LABEL[head.org]}`;
    const { data: exam, error } = await supa
      .from('mock_exams')
      .upsert(
        {
          academy_id: academyId,
          grade: head.grade,
          exam_year: head.examYear,
          school_year: head.grade === 3 ? head.examYear + 1 : head.examYear,
          exam_month: head.month,
          org: head.org,
          title,
        },
        { onConflict: 'academy_id,grade,exam_year,exam_month,org' },
      )
      .select('id, status')
      .single();
    if (error) throw new Error(`mock_exams upsert: ${error.message}`);
    summary.exams += 1;
    if (exam.status === 'queued' || exam.status === 'running') {
      summary.skipped += group.length;
      if (!quiet) console.log(`skip (추출 중): ${title}`);
      continue;
    }
    for (const item of group) {
      if (!queue && exam.status === 'review') {
        const { data: existing, error: readErr } = await supa
          .from('mock_exam_papers')
          .select('id')
          .eq('exam_id', exam.id)
          .eq('kind', item.kind)
          .eq('elective', item.elective)
          .maybeSingle();
        if (readErr) throw new Error(`mock_exam_papers read: ${readErr.message}`);
        if (existing) {
          summary.kept += 1;
          continue;
        }
      }
      const result = await uploadPaper(supa, academyId, exam.id, item);
      summary[result] += 1;
    }
    if (queue) {
      const { error: qErr } = await supa
        .from('mock_exams')
        .update({ status: 'queued', stage: '', last_error: '', progress: { request: 'all' } })
        .eq('id', exam.id);
      if (qErr) throw new Error(`queue: ${qErr.message}`);
      if (!quiet) console.log(`queued ${title} (${exam.id}) files=${group.length}`);
    } else if (!quiet) {
      console.log(`registered ${title} (${exam.id}) status=${exam.status} files=${group.length}`);
    }
  }
  return summary;
}

function readState(file) {
  try {
    const data = JSON.parse(fs.readFileSync(file, 'utf8'));
    return data && typeof data === 'object' ? data : {};
  } catch {
    return {};
  }
}

export async function syncMockExamFolder(supa, {
  academyId,
  dir = discoverMockExamDir(),
  statePath = syncStatePath(),
} = {}) {
  if (!dir || !fs.existsSync(dir)) {
    return { dir, missing: true, pending: 0, created: 0, same: 0, replaced: 0, kept: 0, skipped: 0 };
  }
  const resolvedAcademy = await resolveAcademyId(supa, academyId);
  const state = readState(statePath);
  const pending = [];
  for (const file of collectPdfs(dir)) {
    const st = fs.statSync(file);
    const key = path.resolve(file);
    const prev = state[key];
    if (prev && prev.size === st.size && prev.mtimeMs === st.mtimeMs) continue;
    const parsed = parseMockFileName(file);
    if (!parsed) continue;
    pending.push({ parsed, key, size: st.size, mtimeMs: st.mtimeMs });
  }
  if (pending.length === 0) {
    return { dir, missing: false, pending: 0, created: 0, same: 0, replaced: 0, kept: 0, skipped: 0 };
  }
  const summary = await registerMockPdfs(
    supa,
    resolvedAcademy,
    pending.map((item) => item.parsed),
    { queue: false, quiet: true },
  );
  for (const item of pending) {
    state[item.key] = { size: item.size, mtimeMs: item.mtimeMs };
  }
  fs.mkdirSync(path.dirname(statePath), { recursive: true });
  fs.writeFileSync(statePath, JSON.stringify(state));
  return { dir, missing: false, pending: pending.length, ...summary };
}
