// 사장님이 승인한 개념 검수 계획(JSON)을 DB에 반영한다. Think가 쓰는 것과 같은 RPC만 부른다:
// course_think_action_propose(카드 만들기) → course_think_action_apply(승인). 사장님 계정(운영자)으로 실행한다.
// 설계와 계획 파일 형식: docs/architecture/concept-library.md 4.8 "Cursor 에이전트가 대신 검수할 때".
//
//   node tools/concept_review/apply_plan.mjs send_otp <메일>
//   node tools/concept_review/apply_plan.mjs verify_otp <메일> <인증번호>
//   node tools/concept_review/apply_plan.mjs <check|edits|placements|records|all|verify> --plan <계획.json> [--only 21,25] [--size 8]
//
//   node tools/concept_review/apply_plan.mjs logout
//
// --only 는 목록 위치로 일부만 고른다(먼저 몇 개로 확인할 때). --size 는 검토 기록 한 카드의 건수다(기본 20).
// check 와 verify 는 아무것도 쓰지 않는다. 진행 상태는 <계획>.state.json 에 남아 중간에 멈춰도 이어서 돌릴 수 있다.
// 세션은 tool/textbook_batch.dart 와 같은 파일(%LOCALAPPDATA%\Yggdrasill\textbook_batch_session.json)을 쓴다.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

export const REQUIRED_SCOPES = ['notation', 'meaning', 'foundation', 'placement'];
const GAP_SCOPES = ['notation', 'meaning', 'placement'];

export const chunk = (list, size) => Array.from({ length: Math.ceil(list.length / size) }, (_, i) => list.slice(i * size, (i + 1) * size));
const norm = (s) => String(s ?? '').replace(/\r\n/g, '\n').trim();

/** 지금 본문이 판단할 때의 본문인지(as_judged), 이번에 고친 본문인지(edited), 그 사이 누가 바꿨는지(changed). */
export function classify(concept, liveContent, editedIds) {
  if (liveContent == null) return 'missing';
  const live = norm(liveContent);
  if (live === norm(concept.judged_content)) return 'as_judged';
  if (concept.edit && (live === norm(concept.edit.content) || editedIds.has(concept.id))) return 'edited';
  return 'changed';
}

/** 그 범위에 지금 본문 기준으로 유효한 '문제 없음' 또는 '근거 미확인' 기록이 이미 있는가. 있으면 다시 쓰지 않는다. */
export function recordIsGood(scope, latest) {
  if (!latest || latest.stale) return false;
  if (latest.outcome === 'no_issue_found') return true;
  const gaps = latest.detail?.evidence_gaps;
  return latest.outcome === 'unverified' && GAP_SCOPES.includes(scope) && Array.isArray(gaps) && gaps.length > 0;
}

/** 기록을 쓸 수 있는 개념인가: 본문이 최종 상태이고 계획한 배치가 모두 놓여 있어야 한다. */
export function readyForRecords(concept, kind, placedUnitIds) {
  if (kind === 'changed' || kind === 'missing') return false;
  if (concept.edit && kind !== 'edited') return false;
  return concept.placements.every((p) => placedUnitIds.has(p.unit_id));
}

// ---------- 연결 ----------
const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const sessionFile = path.join(process.env.LOCALAPPDATA ?? os.tmpdir(), 'Yggdrasill', 'textbook_batch_session.json');

export class Db {
  constructor() {
    const env = JSON.parse(fs.readFileSync(path.join(repoRoot, 'apps', 'yggdrasill_manager', 'env.local.json'), 'utf8'));
    this.url = String(env.SUPABASE_URL).replace(/\/$/, '');
    this.key = String(env.SUPABASE_ANON_KEY);
    this.token = null;
    this.expiresAt = 0;
  }

  async auth(pathname, body) {
    const res = await fetch(`${this.url}/auth/v1/${pathname}`, {
      method: 'POST', headers: { apikey: this.key, 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`로그인 요청 실패(${res.status}): ${text.slice(0, 300)}`);
    return text ? JSON.parse(text) : {};
  }

  saveSession(s) {
    if (!s?.refresh_token) throw new Error('세션을 받지 못했습니다.');
    fs.mkdirSync(path.dirname(sessionFile), { recursive: true });
    fs.writeFileSync(sessionFile, JSON.stringify({ refresh_token: s.refresh_token }));
    this.token = s.access_token;
    this.expiresAt = Date.now() + (Number(s.expires_in) || 3600) * 1000;
  }

  /** 갱신 토큰은 쓸 때마다 바뀌므로 받는 즉시 다시 저장한다. */
  async ensure() {
    if (this.token && Date.now() < this.expiresAt - 120000) return;
    if (!fs.existsSync(sessionFile)) throw new Error('로그인 세션이 없습니다. send_otp, verify_otp 를 먼저 실행하세요.');
    const saved = JSON.parse(fs.readFileSync(sessionFile, 'utf8'));
    this.saveSession(await this.auth('token?grant_type=refresh_token', { refresh_token: saved.refresh_token }));
  }

  async rest(method, pathname, body, prefer) {
    await this.ensure();
    const res = await fetch(`${this.url}/rest/v1/${pathname}`, {
      method,
      headers: {
        apikey: this.key, Authorization: `Bearer ${this.token}`, 'Content-Type': 'application/json',
        ...(prefer ? { Prefer: prefer } : {}),
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await res.text();
    if (!res.ok) throw new Error(`${method} ${pathname.split('?')[0]} 실패(${res.status}): ${text.slice(0, 500)}`);
    return text ? JSON.parse(text) : null;
  }

  rpc(name, params) {
    return this.rest('POST', `rpc/${name}`, params);
  }

  async selectIn(table, columns, column, ids, size = 40) {
    const out = [];
    for (const part of chunk(ids, size)) {
      out.push(...await this.rest('GET', `${table}?select=${columns}&${column}=in.(${part.join(',')})&limit=10000`));
    }
    return out;
  }
}

// ---------- 실행 ----------
class Run {
  constructor(db, planPath, only) {
    this.db = db;
    this.plan = JSON.parse(fs.readFileSync(planPath, 'utf8'));
    this.statePath = planPath.replace(/\.json$/, '') + '.state.json';
    this.state = fs.existsSync(this.statePath) ? JSON.parse(fs.readFileSync(this.statePath, 'utf8')) : { conversation_id: null, edited: [], actions: [] };
    this.concepts = only ? this.plan.concepts.filter((c) => only.has(c.pos)) : this.plan.concepts;
    this.ids = this.concepts.map((c) => c.id);
  }

  save() {
    fs.writeFileSync(this.statePath, JSON.stringify(this.state, null, 1));
  }

  async conversation() {
    if (!this.state.conversation_id) {
      const rows = await this.db.rest('POST', 'ai_conversations?select=id', { title: this.plan.title, origin: 'cursor' }, 'return=representation');
      this.state.conversation_id = rows[0].id;
      this.save();
      console.log(`대화를 만들었습니다: ${this.plan.title}`);
    }
    return this.state.conversation_id;
  }

  /** 카드 하나를 만들고 바로 승인한다. 항목별 결과를 돌려준다. 하나도 반영되지 않으면 카드를 거절로 닫고 멈춘다. */
  async act(step, kind, payload) {
    const conversationId = await this.conversation();
    const card = await this.db.rpc('course_think_action_propose', {
      p_conversation_id: conversationId, p_kind: kind, p_payload: { ...payload, reason: this.plan.reason },
    });
    let done;
    try {
      done = await this.db.rpc('course_think_action_apply', { p_id: card.id, p_overrides: {} });
    } catch (e) {
      // 승인이 통째로 실패하면(예: 시간 초과) 아무것도 반영되지 않는다. 대기 카드가 남지 않게 닫는다.
      await this.db.rpc('ai_action_reject', { p_id: card.id }).catch(() => {});
      this.state.actions.push({ step, kind, id: card.id, status: 'rejected', error: e.message.slice(0, 200) });
      this.save();
      throw e;
    }
    const items = done.result?.items ?? [];
    const failed = items.filter((x) => x.status !== 'applied');
    this.state.actions.push({ step, kind, id: card.id, status: done.status, applied: items.length - failed.length, failed: failed.map((x) => ({ i: x.i, code: x.code })) });
    this.save();
    if (done.status !== 'applied') {
      await this.db.rpc('ai_action_reject', { p_id: card.id });
      throw new Error(`${step}: 카드가 하나도 반영되지 않아 닫았습니다. ${done.error ?? ''}`);
    }
    return items;
  }

  async live() {
    const rows = await this.db.selectIn('concepts', 'id,name,content', 'id', this.ids);
    const content = new Map(rows.map((r) => [r.id, r.content]));
    const edited = new Set(this.state.edited);
    const kind = new Map(this.concepts.map((c) => [c.id, classify(c, content.get(c.id), edited)]));
    const placed = new Map(this.ids.map((id) => [id, new Set()]));
    for (const a of await this.db.selectIn('concept_appearances', 'concept_id,course_unit_id', 'concept_id', this.ids)) {
      placed.get(a.concept_id)?.add(a.course_unit_id);
    }
    return { kind, placed };
  }

  async statuses(ids) {
    const out = new Map();
    for (const part of chunk(ids, 20)) {
      for (const s of await this.db.rpc('concept_review_status', { p_concept_ids: part })) out.set(s.id, s);
    }
    return out;
  }

  async todo() {
    const { kind, placed } = await this.live();
    const edits = this.concepts.filter((c) => c.edit && kind.get(c.id) === 'as_judged');
    const places = [];
    for (const c of this.concepts) {
      if (['changed', 'missing'].includes(kind.get(c.id))) continue;
      for (const p of c.placements) if (!placed.get(c.id).has(p.unit_id)) places.push({ concept: c, ...p });
    }
    const ready = this.concepts.filter((c) => readyForRecords(c, kind.get(c.id), placed.get(c.id)));
    const status = await this.statuses(ready.map((c) => c.id));
    const records = [];
    let pending = 0;
    for (const c of ready) {
      const s = status.get(c.id);
      for (const scope of REQUIRED_SCOPES) {
        if (recordIsGood(scope, s.scopes?.[scope]?.latest)) continue;
        if ((s.pending ?? []).some((p) => p.scope === scope)) {
          pending++;
          continue;
        }
        records.push({ concept: c, scope, revision: s.revision });
      }
    }
    return { kind, edits, places, ready, records, pending };
  }

  async check() {
    const t = await this.todo();
    const count = (k) => [...t.kind.values()].filter((x) => x === k).length;
    console.log(`개념 ${this.concepts.length}개: 판단 때와 같은 본문 ${count('as_judged')} · 이번에 고친 본문 ${count('edited')} · 그 사이 바뀜 ${count('changed')} · 없음 ${count('missing')}`);
    for (const c of this.concepts) if (['changed', 'missing'].includes(t.kind.get(c.id))) console.log(`  건너뜀 ${c.pos} ${c.name} (${t.kind.get(c.id)})`);
    console.log(`남은 본문 고침 ${t.edits.length} · 남은 배치 ${t.places.length} · 기록을 쓸 수 있는 개념 ${t.ready.length}`);
    console.log(`지금 쓸 기록 ${t.records.length}건: ` + REQUIRED_SCOPES.map((s) => `${s} ${t.records.filter((r) => r.scope === s).length}`).join(', ') + (t.pending ? ` · 대기 카드가 있어 건너뛴 범위 ${t.pending}` : ''));
    return t;
  }

  async edits() {
    const { edits } = await this.todo();
    for (const part of chunk(edits, 20)) {
      const items = await this.act('edits', 'concept_library_change', { items: part.map((c) => ({ op: 'edit', concept_id: c.id, content: c.edit.content })) });
      items.forEach((x, i) => {
        if (x.status === 'applied') this.state.edited.push(part[i].id);
        else console.log(`  본문 고침 실패 ${part[i].pos} ${part[i].name}: ${x.code}`);
      });
      this.save();
      console.log(`본문 고침 ${items.filter((x) => x.status === 'applied').length}/${part.length}`);
    }
  }

  async placements() {
    const { places } = await this.todo();
    const byCourse = new Map();
    for (const p of places) byCourse.set(p.course_id, [...(byCourse.get(p.course_id) ?? []), p]);
    for (const [courseId, list] of byCourse) {
      for (const part of chunk(list, 50)) {
        const items = await this.act('placements', 'concept_placement_change', {
          course_id: courseId,
          items: part.map((p) => ({ op: 'place', concept_id: p.concept.id, unit_id: p.unit_id, basis: p.basis, evidence: p.evidence })),
        });
        items.forEach((x, i) => {
          if (x.status !== 'applied') console.log(`  배치 실패 ${part[i].concept.pos} ${part[i].concept.name}: ${x.code}`);
        });
        console.log(`배치(${part[0].course}) ${items.filter((x) => x.status === 'applied').length}/${part.length}`);
      }
    }
  }

  /** 이 대화에 남은 대기 카드(승인 도중 끊긴 것)를 닫는다. 남겨 두면 그 범위를 다시 쓸 수 없다. */
  async closeLeftovers() {
    if (!this.state.conversation_id) return;
    const rows = await this.db.rest('GET', `ai_actions?select=id&status=eq.proposed&conversation_id=eq.${this.state.conversation_id}`);
    for (const r of rows) await this.db.rpc('ai_action_reject', { p_id: r.id });
    if (rows.length) console.log(`끊긴 대기 카드 ${rows.length}장을 닫았습니다.`);
  }

  /** 승인 한 번이 8초 제한을 넘기면 통째로 실패한다. 그때는 묶음을 절반으로 줄여 잇는다. */
  async records(size = 20) {
    await this.closeLeftovers();
    const { records } = await this.todo();
    let ok = 0;
    let at = 0;
    while (at < records.length) {
      const part = records.slice(at, at + size);
      let items;
      try {
        items = await this.act('records', 'concept_review_record', {
          items: part.map((r) => ({ concept_id: r.concept.id, scope: r.scope, revision: r.revision, fixes: [], ...r.concept.records[r.scope] })),
        });
      } catch (e) {
        if (!/statement timeout/.test(e.message) || size === 1) throw e;
        size = Math.max(1, Math.floor(size / 2));
        console.log(`  시간 초과: 묶음을 ${size}건으로 줄여 다시 합니다.`);
        continue;
      }
      at += part.length;
      items.forEach((x, i) => {
        if (x.status === 'applied') ok++;
        else console.log(`  기록 실패 ${part[i].concept.pos} ${part[i].scope}: ${x.code}`);
      });
    }
    console.log(`검토 기록 ${ok}/${records.length}`);
  }

  /** 네 필수 범위가 모두 유효한 '문제 없음' 또는 '근거 미확인'인 개념 수를 다시 센다. */
  async verify() {
    const status = await this.statuses(this.ids);
    let met = 0;
    let gap = 0;
    const open = [];
    for (const c of this.concepts) {
      const scopes = status.get(c.id)?.scopes ?? {};
      const bad = REQUIRED_SCOPES.filter((s) => !recordIsGood(s, scopes[s]?.latest));
      if (bad.length) open.push(`${c.pos}(${bad.join(',')})`);
      else if (REQUIRED_SCOPES.some((s) => scopes[s].latest.outcome === 'unverified')) gap++;
      else met++;
    }
    console.log(`네 범위 충족 ${met + gap}/${this.concepts.length} (문제 없음 ${met} · 근거 미확인 포함 ${gap})`);
    if (open.length) console.log(`남은 개념 ${open.length}: ${open.slice(0, 60).join(' ')}${open.length > 60 ? ' …' : ''}`);
    if (this.plan.walk_job_id) {
      const job = await this.db.rpc('concept_review_job_status', { p_job_id: this.plan.walk_job_id }).catch((e) => ({ error: e.message }));
      const line = job?.first_pass_line ?? job?.job?.first_pass_line ?? job?.error;
      if (line) console.log(`Think 검수 작업 표시: ${String(line).slice(0, 200)}`);
    }
  }
}

async function main() {
  const [command, ...rest] = process.argv.slice(2);
  const db = new Db();
  if (command === 'send_otp') {
    await db.auth('otp', { email: rest[0], create_user: false });
    console.log(`인증번호를 ${rest[0]} 로 보냈습니다.`);
    return;
  }
  if (command === 'verify_otp') {
    const s = await db.auth('verify', { type: 'email', email: rest[0], token: rest[1] });
    db.saveSession(s);
    console.log(`로그인했습니다: ${s.user?.email ?? rest[0]}`);
    return;
  }
  if (command === 'logout') {
    // 이 PC의 세션만 끊는다(scope=local). 매니저 앱 등 다른 기기의 로그인은 그대로다.
    if (fs.existsSync(sessionFile)) {
      try {
        await db.ensure();
        const res = await fetch(`${db.url}/auth/v1/logout?scope=local`, {
          method: 'POST', headers: { apikey: db.key, Authorization: `Bearer ${db.token}` },
        });
        if (!res.ok) console.error(`서버 로그아웃 실패(${res.status}). 파일만 지웁니다.`);
      } catch (e) {
        console.error(`서버 로그아웃 실패: ${e.message}. 파일만 지웁니다.`);
      }
      fs.rmSync(sessionFile, { force: true });
    }
    console.log('로그아웃했습니다. 이 PC의 로그인 정보를 지웠습니다.');
    return;
  }
  const arg = (name) => (rest.includes(name) ? rest[rest.indexOf(name) + 1] : null);
  const planPath = arg('--plan');
  if (!planPath || !['check', 'edits', 'placements', 'records', 'all', 'verify'].includes(command)) {
    throw new Error('사용법: apply_plan.mjs <check|edits|placements|records|all|verify> --plan <계획.json> [--only 위치,위치]');
  }
  const only = arg('--only') ? new Set(arg('--only').split(',').map(Number)) : null;
  const run = new Run(db, path.resolve(planPath), only);
  if (command === 'check') await run.check();
  if (command === 'edits' || command === 'all') await run.edits();
  if (command === 'placements' || command === 'all') await run.placements();
  if (command === 'records' || command === 'all') await run.records(Number(arg('--size')) || 20);
  if (command === 'verify' || command === 'all') await run.verify();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((e) => {
    console.error(e.message);
    process.exitCode = 1;
  });
}
