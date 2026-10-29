import { assert, assertEquals } from 'jsr:@std/assert@1';
import { FakeAiProvider, type FakeTurn } from '../_shared/ai/fake.ts';
import type { AiRequest } from '../_shared/ai/types.ts';
import { runThinkChat, type ChatInput } from './chat.ts';
import {
  BATCH_PROMPT_VERSION,
  BATCH_TOOL_NAME,
  JUDGE_INSTRUCTIONS,
  assignRefLists,
  conceptRefAllowList,
  foundationReview,
  runReviewBatch,
  stage1Of,
  type BatchDeps,
} from './concept_review_batch.ts';
import { diagnosisFromReason, failureReport } from './concept_review_diagnosis.ts';
import { CONCEPT_REVIEW_REF_LIMIT, type ReviewJobRpc, type ReviewJobToolContext } from './concept_review_job_tools.ts';
import { COURSE_MAP_TOOLS, REVIEW_PROPOSE_TOOL_NAME } from './course_map_tools.ts';
import { computeFeatures } from './features.ts';
import { THINK_PROMPT_VERSION, thinkInstructions } from './prompts.ts';
import { thinkToolsFor } from './tools.ts';
import { EventLog, MemoryThinkStore, RunLog, testEnv } from './test_support.ts';

type Rec = Record<string, unknown>;
const JOB = 'abababab-0000-4000-8000-000000000001';
const cid = (i: number) => `cccccccc-0000-4000-8000-${String(i).padStart(12, '0')}`;
const parse = (r: { output: string }) => JSON.parse(r.output);

const ALL_TODO = ['notation', 'meaning', 'foundation', 'placement'];
interface SimConcept {
  id: string; name: string; content: string; rev: number; gone?: boolean; todo: string[]; supplement?: boolean;
  sources?: Rec[]; placements?: Rec[]; resume_scopes?: string[]; created_concepts?: Rec[];
  relations?: Rec[]; same_concept_reviews?: Rec[];
  /** 32자 지문. 있으면 revision 앞 12자와 맞추고, 같은 호출의 전문 비교 근거가 된다. */
  textMark?: string;
  statements?: Rec[];
}
interface SimItem { pos: number; concept_id: string; state: string; revision: string; reviews: Rec[] | null; reason: string | null }
interface SimCard { id: string; kind: string; positions: number[]; reviews: number; status: 'proposed' | 'approved'; items?: Rec[] }

/** 검수 작업 RPC 흉내(임대 gen 확인·위치별 저장·카드당 검토 20개·대기 한도·끝난 위치 건너뛰기). DB 쪽 실제 검사는 db_test 가 한다. */
class JobSim {
  concepts: SimConcept[];
  items = new Map<number, SimItem>();
  cards: SimCard[] = [];
  logs: Rec[] = [];
  calls: { fn: string; args: Rec }[] = [];
  gen = 0;
  checkpoint = 0;
  served = 0;
  limits = { max_pending_cards: 15, max_cards_per_request: 13, max_batch: 50 };
  failOnce = new Map<string, string>();
  loseResponseOnce = new Set<string>();
  /** 이어 읽기 중(offset>0) 판을 한 번 바꿀 위치 */
  bumpOnRead = new Set<number>();
  /** 묶어 읽기 때 지워진 것으로 볼 위치 */
  goneOnRead = new Set<number>();
  /** 기초 개념 후보 검색에 걸리는 라이브러리 개념 */
  library: { id: string; name: string; content: string }[] = [];
  /** 다음 실행에서 먼저 다시 판단할 위치. 없으면 빈 배열로 둔다. */
  recheck: Rec[] = [];
  /** 검토는 보류하고 고치기 카드만 내는 제출 */
  holdReviews = false;
  courses: Rec[] = [];
  /** 상태 응답에 1차 검수 집계를 넣지 않는다. 엣지는 0이 아니라 미집계로 전한다. */
  omitFirstPass = false;
  /** 상태 조회를 끝내지 않는다. 바깥 제한이 진단을 돌려야 한다. */
  blockStatus = false;
  /** 상태 응답의 저장 집계 신선도. 있으면 1차 검수 수가 있어도 현재 수로 쓰지 않는다. */
  progressFreshness: string | null = null;
  statusDiags: Rec[] = [];

  constructor(n: number, content: (i: number) => string = (i) => `개념 ${i}의 정의 문장`) {
    this.concepts = Array.from({ length: n }, (_, k) => ({
      id: cid(k + 1), name: `개념${k + 1}`, content: content(k + 1), rev: 1, todo: [...ALL_TODO],
    }));
  }

  get total() {
    return this.concepts.length;
  }
  rev(pos: number) {
    const mark = this.concepts[pos - 1].textMark;
    if (mark) return `${mark.slice(0, 12)}-cccccccccccc-rrrrrrrrrrrr`;
    return `r${pos}-${this.concepts[pos - 1].rev}`;
  }
  pending() {
    return this.cards.filter((c) => c.status === 'proposed').length;
  }
  lock(gen: unknown) {
    if (gen !== this.gen) throw new Error('lock: concept_review_job_lease_lost');
  }
  advance() {
    while (this.items.has(this.checkpoint + 1)) this.checkpoint += 1;
  }

  rpc = (fn: ReviewJobRpc, a: Rec): Promise<unknown> => {
    this.calls.push({ fn, args: structuredClone(a) });
    const fail = this.failOnce.get(fn);
    if (fail) {
      this.failOnce.delete(fn);
      return Promise.reject(new Error(`${fn}: ${fail}`));
    }
    if (fn === 'concept_review_job_status' && this.blockStatus) return new Promise(() => {});
    try {
      const out = this.run(fn, a);
      if (this.loseResponseOnce.delete(fn)) return Promise.reject(new Error('fetch failed: connection reset'));
      return Promise.resolve(structuredClone(out));
    } catch (e) {
      return Promise.reject(e);
    }
  };

  private run(fn: ReviewJobRpc, a: Rec): unknown {
    switch (fn) {
      case 'concept_review_job_claim':
        this.gen += 1;
        return { gen: this.gen };
      case 'concept_review_job_batch_begin': {
        this.lock(a.p_gen);
        const all = [...this.items.values()].sort((x, y) => x.pos - y.pos);
        return {
          pending_cards: this.pending(), ...this.limits,
          drafted: all.filter((i) => i.state === 'drafted').length,
          deferred: all.filter((i) => i.state === 'deferred').length,
          retry: all.filter((i) => i.state === 'failed' && /^(concept_review_stale|concept_review_compared_changed|judge_)/.test(i.reason ?? ''))
            .slice(0, 50).map((i) => ({ position: i.pos, concept_id: i.concept_id, reason: i.reason })),
          recheck: this.recheck,
          checkpoint: this.checkpoint, served_through: this.served, total: this.total,
        };
      }
      case 'concept_review_job_targets': {
        this.lock(a.p_gen);
        const count = Math.min(Math.max(Number(a.p_count ?? 50), 1), 50);
        const batch: Rec[] = [];
        let pos = this.checkpoint;
        while (pos < this.total && batch.length < count) {
          pos += 1;
          if (this.items.has(pos)) continue;
          const c = this.concepts[pos - 1];
          batch.push({ position: pos, concept_id: c.id, todo: c.todo, supplement: c.supplement === true });
        }
        this.served = Math.max(this.served, pos);
        return {
          batch, auto_saved: { reused: 0, missing: 0, waiting: 0, open: 0 }, held: 0,
          supplement: batch.filter((b) => b.supplement).length, reached_end: pos >= this.total,
        };
      }
      case 'concept_review_job_courses':
        this.lock(a.p_gen);
        return this.courses;
      case 'concept_review_job_search': {
        this.lock(a.p_gen);
        const terms = a.p_terms as string[];
        const results = terms.map((t) => ({ term: t, ids: this.library.filter((x) => x.name.includes(t) || x.content.includes(t)).map((x) => x.id) }));
        const ids = new Set(results.flatMap((r) => r.ids));
        return {
          results, types: ['정의', '성질'], roots: ['수와 연산'],
          concepts: this.library.filter((x) => ids.has(x.id)).map((x) => ({
            ...x, type: '정의', folder: ['수와 연산', '초등'], placements: [], elementary: true, content_chars: x.content.length, truncated: false,
          })),
        };
      }
      case 'concept_review_job_material': {
        this.lock(a.p_gen);
        const positions = a.p_positions as number[];
        if (positions.length > 60) throw new Error('material: concept_review_job_too_many');
        const offsets = (a.p_offsets ?? {}) as Record<string, number>;
        const budget = Math.min(Math.max(Number(a.p_budget), 4000), 120000);
        const items: Rec[] = [];
        const rest: number[] = [];
        let used = 0;
        for (const pos of positions) {
          if (rest.length > 0) {
            rest.push(pos);
            continue;
          }
          const c = this.concepts[pos - 1];
          if (this.goneOnRead.has(pos)) c.gone = true;
          if (c.gone) {
            items.push({ position: pos, concept_id: c.id, missing: true });
            continue;
          }
          const off = Math.min(offsets[String(pos)] ?? 0, c.content.length);
          if (off > 0 && this.bumpOnRead.delete(pos)) c.rev += 1;
          const base = {
            name: c.name, type: '정의', folder: ['수'], revision: this.rev(pos), relations: [], todo: c.todo,
            ...(c.resume_scopes ? { resume_scopes: c.resume_scopes } : {}),
            ...(c.created_concepts ? { created_concepts: c.created_concepts } : {}),
            ...(c.relations ? { relations: c.relations } : {}),
            ...(c.same_concept_reviews ? { same_concept_reviews: c.same_concept_reviews } : {}),
            sources: c.sources ?? [], placements: c.placements ?? [],
            ...(c.statements ? { statements: c.statements } : {}),
            ...(c.textMark ? { text_mark: c.textMark } : {}),
          };
          const baseLen = JSON.stringify(base).length;
          if (used > 0 && used + baseLen + (c.content.length - off) > budget) {
            rest.push(pos);
            continue;
          }
          const take = Math.max(Math.min(c.content.length - off, budget - used - baseLen), Math.min(c.content.length - off, 2000));
          items.push({
            ...base, position: pos, concept_id: c.id, content: c.content.slice(off, off + take), content_offset: off,
            content_chars: c.content.length, content_next_offset: off + take < c.content.length ? off + take : null,
          });
          used += baseLen + take;
        }
        return { items, rest, budget, used };
      }
      case 'concept_review_job_save': {
        this.lock(a.p_gen);
        const out: Rec[] = [];
        for (const e of a.p_items as Rec[]) {
          const pos = Number(e.position);
          const c = this.concepts[pos - 1];
          const err = (code: string) => out.push({ position: pos, status: 'error', code });
          if (pos > this.served && !this.items.has(pos)) {
            err('concept_review_job_not_served');
            continue;
          }
          if (c.gone) {
            err('concept_review_concept_not_found');
            continue;
          }
          if (e.state === 'drafted') {
            if (e.read_complete !== true) {
              err('concept_review_job_read_incomplete');
              continue;
            }
            if (e.revision !== this.rev(pos)) {
              err('concept_review_stale');
              continue;
            }
          } else if (!e.reason || !e.next_action) {
            err('concept_review_job_next_required');
            continue;
          }
          this.items.set(pos, {
            pos, concept_id: c.id, state: String(e.state), revision: String(e.revision),
            reviews: (e.reviews as Rec[] | null) ?? null, reason: (e.reason as string | null) ?? null,
          });
          out.push({ position: pos, status: 'saved' });
        }
        this.advance();
        return { items: out, saved: out.filter((o) => o.status === 'saved').length, checkpoint: this.checkpoint };
      }
      case 'concept_review_job_submit': {
        this.lock(a.p_gen);
        if (this.pending() >= this.limits.max_pending_cards) throw new Error('submit: concept_review_job_pending_full');
        const room = Math.min(this.limits.max_pending_cards - this.pending(), a.p_max_cards == null ? 99 : Number(a.p_max_cards));
        const failed: Rec[] = [];
        const positions: number[] = [];
        let reviews = 0;
        const fixOps: Record<string, Rec[]> = {};
        for (const it of [...this.items.values()].filter((i) => i.state === 'drafted').sort((x, y) => x.pos - y.pos)) {
          if (it.revision !== this.rev(it.pos)) {
            it.state = 'failed';
            it.reason = 'concept_review_stale';
            failed.push({ position: it.pos, code: 'concept_review_stale' });
            continue;
          }
          const n = it.reviews!.length;
          const kinds = new Set([...Object.keys(fixOps), ...it.reviews!.filter((r) => r.fix).map((r) => String(rec(r.fix).kind))]);
          if (reviews + n > 20 || 1 + kinds.size > room) break;
          reviews += n;
          positions.push(it.pos);
          for (const r of it.reviews!) {
            if (r.fix) (fixOps[String(rec(r.fix).kind)] ??= []).push(...(rec(r.fix).ops as Rec[]));
          }
        }
        if (positions.length === 0) return { submitted: false, failed, blocked: [], room };
        const make = (kind: string, items: Rec[] = []) => {
          const card: SimCard = { id: `act-${this.cards.length + 1}`, kind, positions, reviews, status: 'proposed', items };
          this.cards.push(card);
          return { id: card.id, conversation_id: a.p_conversation_id, kind, status: 'proposed', payload: { items }, preview: {} };
        };
        const fixActions = Object.entries(fixOps).map(([k, ops]) =>
          make(k === 'library' ? 'concept_library_change' : 'concept_placement_change', ops)
        );
        if (this.holdReviews) {
          for (const p of positions) this.items.get(p)!.state = 'held';
          return { submitted: true, existing: false, positions: [], failed, blocked: [], action: null, fix_actions: fixActions };
        }
        const action = make('concept_review_record');
        for (const p of positions) this.items.get(p)!.state = 'submitted';
        return { submitted: true, existing: false, positions, failed, blocked: [], action, fix_actions: fixActions };
      }
      case 'concept_review_job_status': {
        const complete = [...this.items.values()].filter((i) => i.state === 'complete').length;
        const line = `1차 검수 3조건 충족: 7 / ${this.total}개(1.2%)`;
        return {
          progress_line: `${this.total}개 중 ${complete}개 통합 완료`,
          condition_line: `조건별 충족(승인 기준): 표기·의미 0 · 기초 개념 0 · 배치 0`,
          counts: { complete }, conditions: { text: 0, foundation: 0, placement: 0 },
          ...(this.omitFirstPass ? {} : {
            first_pass: { met: 7, total: this.total, percent: 1.2, line },
            first_pass_line: line,
          }),
          ...(this.progressFreshness ? {
            progress_freshness: this.progressFreshness,
            progress_last_success: { progress_line: '옛 집계', first_pass_line: '옛 1차' },
          } : {}),
        };
      }
      case 'concept_review_job_batch_log':
        this.logs.push(structuredClone(a));
        return `log-${this.logs.length}`;
      case 'concept_review_job_status_diag_put':
        this.statusDiags.push(structuredClone(a.p_diag as Rec));
        return { saved: true };
      case 'concept_review_job_status_diag_get':
        return { diagnosis: this.statusDiags.at(-1) ?? null };
      default:
        throw new Error(`${fn}: not_simulated`);
    }
  }

  cardPositions() {
    return this.cards.filter((c) => c.kind === 'concept_review_record').flatMap((c) => c.positions);
  }
}

function rec(v: unknown): Rec {
  return v && typeof v === 'object' && !Array.isArray(v) ? v as Rec : {};
}

const payloadOf = (req: AiRequest): Rec => {
  const text = (req.input[0] as { parts: { text: string }[] }).parts[0].text;
  return JSON.parse(text.slice(text.indexOf('\n') + 1));
};
const review = (scope: string, over: Rec = {}) => ({
  scope, outcome: 'no_issue_found', checked: `${scope} 확인`, findings: '이번 범위에서 문제를 찾지 못함', basis: '본문 첫 문장',
  unverified: null, follow_up: null, compared_ids: [], to_compare_ids: [], basis_kind: null, fix: null, ...over,
});

/** 판단 모델 흉내. 1단계: 위치마다 judge_scopes 중 요청한 범위의 판단(또는 보류)과 기초 개념 필요 목록, 2단계: 기초 개념 결정. */
function judge(opts: {
  scopes?: string[];
  defer?: (pos: number) => boolean;
  delayMs?: (i: number) => number;
  error?: (i: number) => boolean;
  reviews?: (d: Rec) => Rec[] | null;
  foundation?: (d: Rec) => Rec | null;
  decide?: (need: Rec) => Rec;
  foundationError?: boolean;
} = {}) {
  return (req: AiRequest, i: number): FakeTurn => {
    if (req.jsonSchema?.name === 'concept_review_foundation_judgment') {
      if (opts.foundationError) return { text: '', error: 'boom' };
      const data = payloadOf(req);
      const concepts = (data.concepts as Rec[]).map((d) => ({
        position: d.position, checked: '후보 본문과 비교', findings: '기초 개념 판단', basis: '후보 본문',
        needs: (d.needs as Rec[]).map((n) => ({
          name: n.name, decision: 'unverified', reuse_id: null, compared_ids: [], why: '판단', create: null, ...(opts.decide?.(n) ?? {}),
        })),
      }));
      return { text: JSON.stringify({ concepts }) };
    }
    const data = payloadOf(req);
    const concepts = (data.concepts as Rec[]).map((d) => {
      const position = Number(d.position);
      if (opts.defer?.(position)) {
        return {
          position, status: 'deferred', reviews: [], foundation: null,
          reason: '교재 원본 쪽 확인이 필요함', unread: '교재 원본', next_action: '원본 쪽을 열어 본 뒤 다시 검수',
        };
      }
      const scopes = (d.judge_scopes as string[]);
      return {
        position, status: 'judged', reason: null, unread: null, next_action: null,
        reviews: opts.reviews?.(d) ?? (opts.scopes ?? ['notation']).filter((s) => scopes.includes(s)).map((s) => review(s)),
        foundation: d.foundation_needed === true ? (opts.foundation?.(d) ?? null) : null,
      };
    });
    return { text: JSON.stringify({ concepts }), delayMs: opts.delayMs?.(i), error: opts.error?.(i) ? 'boom' : undefined };
  };
}

const newState = (): ReviewJobToolContext => ({ holder: `think:conv:${crypto.randomUUID()}`, leases: new Map(), cards: 0 });

async function batch(
  sim: JobSim,
  provider: FakeAiProvider,
  opts: { state?: ReviewJobToolContext; target?: number | null; deadlineMs?: number; timing?: BatchDeps['timing']; statusTimeoutMs?: number; runs?: RunLog } = {},
) {
  const now = Date.now();
  return await runReviewBatch(
    {
      callId: 'call-1', rawArguments: JSON.stringify({ job_id: JOB, target: opts.target ?? 50 }), conversationId: 'conv-1',
      userId: 'user-1', safetyId: 'hash', signal: new AbortController().signal, deadline: now + (opts.deadlineMs ?? 110000),
      round: 1, startedAt: now,
    },
    opts.state ?? newState(),
    { provider, store: { reviewJobRpc: sim.rpc }, recordRun: (opts.runs ?? new RunLog()).record, env: testEnv, now: Date.now, timing: opts.timing, statusTimeoutMs: opts.statusTimeoutMs },
  );
}

const judgeRequests = (p: FakeAiProvider) => p.requests.filter((r) => r.jsonSchema?.name === 'concept_review_batch_judgment');
const unique = (xs: number[]) => new Set(xs).size === xs.length;

Deno.test('50개 × 범위 1개: 한 요청에서 50개 판단·저장, 카드 3장(20·20·10)을 내고 실행 기록을 남긴다', async () => {
  const sim = new JobSim(60);
  const provider = new FakeAiProvider(judge());
  const runs = new RunLog();
  const r = await batch(sim, provider, { runs });
  const v = parse(r);
  assertEquals([v.end_reason, v.served, v.read, v.judged_saved, v.cards, v.submitted_concepts, v.drafted_not_submitted], [
    'target_reached', 50, 50, 50, 3, 50, 0,
  ]);
  assertEquals(sim.cards.map((c) => c.reviews), [20, 20, 10]);
  assertEquals(r.actions?.map((a) => a.id), ['act-1', 'act-2', 'act-3']);
  assertEquals(sim.cardPositions().sort((a, b) => a - b), Array.from({ length: 50 }, (_, k) => k + 1));
  assertEquals(v.failed.count + v.deferred.count, 0);

  const judges = judgeRequests(provider);
  assertEquals(judges.length, 7, '8개씩 나눠 판단한다');
  for (const j of judges) assert(!JSON.stringify(j.input).includes('"revision"'), '판은 서버가 쥐고 모델에 넘기지 않는다');
  assertEquals(sim.calls.filter((c) => c.fn === 'concept_review_job_material').length <= 3, true, '묶어 읽는다');

  assertEquals(sim.logs.length, 1);
  const log = sim.logs[0];
  assertEquals([log.p_end_reason, log.p_target], ['target_reached', 50]);
  assert(!JSON.stringify(log).includes('정의 문장'), '실행 기록에 본문을 남기지 않는다');
  assertEquals(runs.runs.map((x) => x.feature), ['think_review_batch']);
});

Deno.test('여러 범위·긴 본문: 이어 읽어 판을 맞추고, 너무 긴 것은 미결로, 카드는 20개 이하로 나눈다', async () => {
  const sim = new JobSim(30, (i) => (i === 15 ? '가'.repeat(45000) : i % 10 === 0 ? `${i}번 긴 본문 `.repeat(3500) : `개념 ${i}의 정의 문장`));
  sim.bumpOnRead.add(20);
  const provider = new FakeAiProvider(judge({ scopes: ['notation', 'meaning', 'classification'] }));
  const v = parse(await batch(sim, provider));
  assertEquals([v.end_reason, v.served, v.read, v.judged_saved, v.deferred.count], ['reached_end', 30, 29, 29, 1]);
  assertEquals(v.deferred.items[0].position, 15);
  assert(String(v.deferred.items[0].unread).includes('45000'), '못 읽은 부분을 남긴다');
  assertEquals(sim.items.get(15)!.state, 'deferred');

  const reads = sim.calls.filter((c) => c.fn === 'concept_review_job_material');
  assert(reads.some((c) => Object.values(c.args.p_offsets as Rec).some((o) => Number(o) > 0)), '긴 본문은 이어 읽는다');
  assertEquals(sim.items.get(20)!.revision, sim.rev(20), '읽는 중 판이 바뀌면 처음부터 다시 읽고 새 판으로 저장한다');
  const judged20 = judgeRequests(provider).map((r) => JSON.stringify(r.input)).find((t) => t.includes('20번 긴 본문'))!;
  assertEquals(judged20.split('20번 긴 본문').length - 1, 3500, '판단 모델은 본문 전체를 한 번씩 받는다');

  assertEquals(v.cards, 5);
  for (const c of sim.cards) assert(c.reviews <= 20);
  assert(unique(sim.cardPositions()));
  assertEquals(sim.cardPositions().length, 29);
});

Deno.test({
  name: '시간 부족: 판단한 것은 저장·제출, 못 한 것은 judge_timeout 으로 저장 → 다음 요청이 먼저 다시 판단(중복 카드 없음)',
  sanitizeOps: false,
  sanitizeResources: false,
  fn: async () => {
    const sim = new JobSim(50);
    const slow = new FakeAiProvider(judge({ delayMs: (i) => (i < 2 ? 0 : 1500) }));
    const v = parse(await batch(sim, slow, { deadlineMs: 700, timing: { saveReserveMs: 100, minJudgeMs: 200, minGroupMs: 50 } }));
    assertEquals([v.end_reason, v.judged_saved, v.failed.count, v.cards], ['time_budget', 16, 34, 1]);
    assert(v.failed.items.every((f: Rec) => String(f.reason).startsWith('judge_timeout')));
    assertEquals([...sim.items.values()].filter((i) => i.state === 'failed').length, 34, '판단 못 한 위치도 이유와 함께 저장된다');
    assertEquals(sim.logs[0].p_end_reason, 'time_budget');

    const fast = new FakeAiProvider(judge());
    const w = parse(await batch(sim, fast));
    assertEquals([w.retried, w.judged_saved, w.cards, w.failed.count], [34, 34, 2, 0]);
    assert(unique(sim.cardPositions()));
    assertEquals(sim.cardPositions().length, 50);
  },
});

Deno.test('저장 뒤 제출 실패: 다음 요청은 다시 판단하지 않고 저장된 초안을 먼저 제출한다', async () => {
  const sim = new JobSim(50);
  sim.failOnce.set('concept_review_job_submit', 'boom');
  const v = parse(await batch(sim, new FakeAiProvider(judge())));
  assertEquals([v.end_reason, v.judged_saved, v.cards, v.drafted_not_submitted], ['tool_error', 50, 0, 50]);

  const again = new FakeAiProvider(judge());
  const w = parse(await batch(sim, again));
  assertEquals(judgeRequests(again).length, 0, '다시 판단하지 않는다');
  assertEquals([w.earlier_drafts, w.cards, w.submitted_concepts, w.end_reason], [50, 3, 50, 'reached_end']);
});

Deno.test('응답 유실·동시 요청: 같은 위치가 두 카드에 들어가지 않는다', async () => {
  const sim = new JobSim(50);
  sim.loseResponseOnce.add('concept_review_job_submit');
  const v = parse(await batch(sim, new FakeAiProvider(judge())));
  assertEquals([v.end_reason, v.cards], ['tool_error', 0], '응답을 못 받은 카드는 냈다고 세지 않는다');
  assertEquals(sim.cards.length, 1);
  await batch(sim, new FakeAiProvider(judge()));
  assertEquals(sim.cards.length, 3);
  assert(unique(sim.cardPositions()));

  const race = new JobSim(50);
  const [a, b] = await Promise.all([batch(race, new FakeAiProvider(judge())), batch(race, new FakeAiProvider(judge()))]);
  const results = [parse(a), parse(b)];
  assert(results.some((x) => x.error === 'concept_review_job_lease_lost' || x.end_reason === 'lease_lost'), '먼저 잡은 쪽은 넘겨받기에 밀려 멈춘다');
  assert(unique(race.cardPositions()));
  assertEquals(race.cardPositions().length, 50);
});

Deno.test('원본 필요·지워진 개념·판단 호출 실패: 이유를 남기고 나머지는 계속, 미결·실패는 완료로 세지 않는다', async () => {
  const sim = new JobSim(20);
  sim.goneOnRead.add(5);
  const provider = new FakeAiProvider(judge({ defer: (p) => p === 3, error: (i) => i === 1 }));
  const v = parse(await batch(sim, provider));
  assertEquals([v.end_reason, v.served, v.judged_saved, v.deferred.count, v.cards], ['reached_end', 20, 10, 1, 1]);
  assertEquals(v.deferred.items[0].position, 3);
  assert(v.deferred.items[0].next_action);
  const reasons = new Map<number, string>(v.failed.items.map((f: Rec) => [Number(f.position), String(f.reason)]));
  assertEquals(reasons.get(5), 'concept_missing');
  assertEquals([...reasons.values()].filter((x) => x.startsWith('judge_error')).length, 8);
  assertEquals(v.progress_line, '20개 중 0개 통합 완료', '카드 승인 전에는 완료가 아니다');
  assertEquals(v.first_pass, { met: 7, total: 20, percent: 1.2, line: '1차 검수 3조건 충족: 7 / 20개(1.2%)' });
  assertEquals(v.first_pass_state, 'counted');
  assert(String(v.note).includes('1차 검수 3조건 충족: 7 / 20개(1.2%)'));
  assert(!sim.cardPositions().includes(3));

  const next = parse(await batch(sim, new FakeAiProvider(judge())));
  assertEquals(next.retried, 8, '판단 호출 실패는 다음 요청에서 먼저 다시 판단한다');
  assertEquals(sim.items.get(3)!.state, 'deferred', '미결은 자동으로 다시 판단하지 않는다');
});

Deno.test('카드 한도: 대기 카드가 차 있으면 읽지 않고 승인을 기다리며, 남은 장수만큼만 새로 판단한다', async () => {
  const full = new JobSim(50);
  full.cards = Array.from({ length: 15 }, (_, k) => ({ id: `old-${k}`, kind: 'concept_review_record', positions: [], reviews: 1, status: 'proposed' as const }));
  const p = new FakeAiProvider(judge());
  const v = parse(await batch(full, p));
  assertEquals([v.end_reason, v.served, v.cards], ['awaiting_approval', 0, 0]);
  assertEquals(judgeRequests(p).length, 0);
  assert(!full.calls.some((c) => c.fn === 'concept_review_job_material' || c.fn === 'concept_review_job_next'));

  const almost = new JobSim(50);
  almost.cards = Array.from({ length: 13 }, (_, k) => ({ id: `old-${k}`, kind: 'concept_review_record', positions: [], reviews: 1, status: 'proposed' as const }));
  const w = parse(await batch(almost, new FakeAiProvider(judge())));
  assertEquals([w.capacity_target, w.served, w.cards, w.end_reason], [10, 10, 1, 'target_reached'], '남은 2장 × 카드당 개념 5개(범위 넷 기준)');

  const state = { ...newState(), cards: 13 };
  assertEquals(parse(await batch(new JobSim(5), new FakeAiProvider(judge()), { state })).end_reason, 'card_limit');
  const once = newState();
  await batch(new JobSim(5), new FakeAiProvider(judge()), { state: once });
  assertEquals(parse(await batch(new JobSim(5), new FakeAiProvider(judge()), { state: once })).error, 'review_batch_once');
});

Deno.test('보완: 부족한 범위만 판단하고, 기초 개념은 후보를 찾아 본문 비교 뒤 재사용으로 저장한다', async () => {
  const sim = new JobSim(3);
  for (const c of sim.concepts) {
    c.todo = ['foundation', 'placement'];
    c.supplement = true;
    c.sources = [{ book: '개념책', grade: '중1-1', course_key: 'M1-1', unit_path: ['Ⅰ. 소인수분해'], printed_page: 12, pdf_page: 14 }];
  }
  sim.library = [{ id: cid(901), name: '약수', content: '어떤 수를 나누어떨어지게 하는 수' }];
  const provider = new FakeAiProvider(judge({
    reviews: () => [review('placement', { basis_kind: 'source', checked: '출처와 배치 대조', basis: '출처 학년·책 단원' })],
    foundation: () => ({ needs: [{ name: '약수', why: '정의에 약수를 씀', terms: ['약수'] }], none_basis: null }),
    decide: (n) => ({ decision: 'reuse', reuse_id: rec((n.candidates as Rec[])[0]).id, compared_ids: [rec((n.candidates as Rec[])[0]).id] }),
  }));
  const v = parse(await batch(sim, provider));
  assertEquals([v.served, v.supplemented, v.judged_saved, v.cards_by_kind.review], [3, 3, 3, 1]);
  const first = judgeRequests(provider)[0];
  const view = payloadOf(first).concepts as Rec[];
  assertEquals(view[0].judge_scopes, ['placement'], '표기·의미가 이미 충족이면 그 범위는 다시 보지 않는다');
  assertEquals(view[0].foundation_needed, true);
  assertEquals((view[0].sources as Rec[])[0].pdf_page, 14, 'PDF 쪽과 인쇄 쪽을 그대로 넘긴다');
  const search = sim.calls.filter((c) => c.fn === 'concept_review_job_search');
  assertEquals(search.length, 1, '묶음마다 한 번 찾는다');
  assertEquals(search[0].args.p_terms, ['약수']);
  const second = provider.requests.filter((r) => r.jsonSchema?.name === 'concept_review_foundation_judgment');
  assertEquals(second.length, 1);
  assert(JSON.stringify(second[0].input).includes('나누어떨어지게'), '2단계는 후보 본문을 받는다');

  const saved = sim.items.get(1)!.reviews!;
  assertEquals(saved.map((r) => r.scope), ['placement', 'foundation']);
  const f = saved[1];
  assertEquals([f.outcome, f.compared_ids], ['no_issue_found', [cid(901)]]);
  assertEquals(rec(rec(f.detail).needs as unknown as Rec[] && (rec(f.detail).needs as Rec[])[0]).decision, 'reuse');
  assertEquals(rec(saved[0].detail).viewed_original, false, '원본을 보지 않았다고 남긴다');
  assertEquals(v.progress_line, '3개 중 0개 통합 완료');
  assert(String(v.condition_line).includes('기초 개념'));
});

Deno.test('의존이 풀린 범위만 다시 판단한다. 나머지 범위와 재개 표시는 판단에 넣지 않는다', async () => {
  const sim = new JobSim(1);
  const c = sim.concepts[0];
  c.todo = [...ALL_TODO];
  c.resume_scopes = ['foundation'];
  c.created_concepts = [{ id: cid(77), name: '분수' }];
  sim.items.set(1, { pos: 1, concept_id: c.id, state: 'held', revision: sim.rev(1), reviews: [], reason: null });
  sim.recheck = [{ position: 1, concept_id: c.id, scopes: ['foundation'], reason: 'resume' }];
  const provider = new FakeAiProvider(judge({
    reviews: () => [],
    foundation: () => ({ needs: [], none_basis: '이미 있는 기초로 충분' }),
  }));
  const v = parse(await batch(sim, provider));
  const view = (payloadOf(judgeRequests(provider)[0]).concepts as Rec[])[0];
  assertEquals(view.judge_scopes, [], '다시 판단할 범위에 표기·의미·배치를 붙이지 않는다');
  assertEquals(view.foundation_needed, true);
  assertEquals(view.resume_scopes, undefined);
  assertEquals((view.created_concepts as Rec[])[0].id, cid(77));
  assertEquals(sim.items.get(1)!.reviews!.map((r) => r.scope), ['foundation']);
  const saved = sim.calls.find((call) => call.fn === 'concept_review_job_save');
  assertEquals((saved!.args.p_items as Rec[])[0].rework, true);
  assertEquals([v.rechecked, v.served, v.judged_saved], [1, 1, 1]);
});

Deno.test('검토를 보류한 제출은 고치기 카드만 세고, 빈 검토 카드로 반복하지 않는다', async () => {
  const sim = new JobSim(1);
  sim.holdReviews = true;
  const provider = new FakeAiProvider(judge({
    scopes: ['notation'],
    reviews: () => [review('notation', {
      outcome: 'issue_found',
      fix: { ops: [{ op: 'edit', name: null, content: '고친 본문', type: null, folder: null, basis: null, evidence: null, unit_id: null, placement_id: null }] },
    })],
  }));
  const r = await batch(sim, provider);
  const v = parse(r);
  assertEquals(v.cards_by_kind, { review: 0, library: 1, placement: 0 });
  assertEquals(sim.items.get(1)!.state, 'held');
  assert(r.actions!.every((a) => typeof a.id === 'string' && a.id.length > 0));
  assertEquals(sim.calls.filter((c) => c.fn === 'concept_review_job_submit').length, 2, '고치기만 낸 뒤 다음 제출은 바로 끝난다');
});

Deno.test('기초 개념 추가·같은 이름 있음·필요 없음: 추가는 개념 고치기 카드로, 같은 이름은 비교 필요로, 필요 없음은 모델 근거로', async () => {
  const sim = new JobSim(3);
  for (const c of sim.concepts) c.todo = ['foundation'];
  sim.library = [{ id: cid(902), name: '분모', content: '분수에서 가로선 아래의 수' }];
  const provider = new FakeAiProvider(judge({
    reviews: () => [],
    foundation: (d) =>
      d.position === 3
        ? { needs: [], none_basis: '자연수 덧셈만 쓰는 정의라 따로 필요한 초등 개념이 없음' }
        : { needs: [{ name: d.position === 1 ? '분수의 뜻' : '분모', why: '정의에 씀', terms: ['분'] }], none_basis: null },
    decide: (n) =>
      n.name === '분수의 뜻'
        ? { decision: 'add', create: { name: '분수의 뜻', type: '정의', folder: ['수와 연산', '초등'], content: '전체를 똑같이 나눈 것 중 부분' } }
        : { decision: 'add', create: { name: '분모', type: '정의', folder: ['수와 연산', '초등'], content: '아래 수' } },
  }));
  const v = parse(await batch(sim, provider));
  assertEquals(v.judged_saved, 3);
  const [add, same, none] = [1, 2, 3].map((p) => sim.items.get(p)!.reviews![0]);
  assertEquals([add.outcome, rec(add.fix).kind], ['issue_found', 'library']);
  const op = (rec(add.fix).ops as Rec[])[0];
  assertEquals([op.op, op.name, op.place_unit_id], ['create', '분수의 뜻', undefined], '새 기초 개념은 배치하지 않는다');
  assertEquals([same.outcome, same.to_compare_ids, same.fix], ['needs_comparison', [cid(902)], undefined], '같은 이름이 있으면 새로 만들지 않는다');
  assertEquals([none.outcome, none.basis], ['no_issue_found', '자연수 덧셈만 쓰는 정의라 따로 필요한 초등 개념이 없음']);
  assertEquals(v.cards_by_kind, { review: 1, library: 1, placement: 0 });
  assertEquals(v.cards, 2, '고치기 카드도 카드 수에 든다');
  const r = await batch(new JobSim(0), new FakeAiProvider(judge()));
  assertEquals(parse(r).cards, 0);
});

Deno.test('배치 고치기: 이 개념의 배치·과정 단원 목록 안에서만 받고, 벗어나면 형식 오류로 다음에 다시 판단한다', async () => {
  const sim = new JobSim(2);
  const course = cid(800);
  sim.courses = [{ id: course, name: '중1-1', course_key: 'M1-1', units: [{ id: cid(801), path: 'Ⅰ › 1' }, { id: cid(802), path: 'Ⅰ › 2' }] }];
  for (const c of sim.concepts) {
    c.todo = ['placement'];
    c.placements = [{ id: `${c.id.slice(0, -3)}777`, course_id: course, unit_id: cid(801), path: '중1-1 › Ⅰ › 1' }];
    c.sources = [{ grade: '중1-1', course_key: 'M1-1', unit_path: ['Ⅰ', '2'], printed_page: null, pdf_page: 30 }];
  }
  const provider = new FakeAiProvider(judge({
    reviews: (d) => {
      const own = rec((d.placements as Rec[])[0]).id;
      const unit = d.position === 1 ? cid(802) : cid(899);
      return [review('placement', {
        outcome: 'issue_found', findings: '책 단원과 다른 소단원', basis_kind: 'source',
        fix: { ops: [{ op: 'move', placement_id: own, unit_id: unit, evidence: '출처 책 단원 2', name: null, content: null, type: null, folder: null, basis: null }] },
      })];
    },
  }));
  const v = parse(await batch(sim, provider));
  const view = payloadOf(judgeRequests(provider)[0]);
  assertEquals((view.courses as Rec[]).map((c) => c.id), [course], '출처 과정 키·지금 배치의 과정 단원만 넘긴다');
  assertEquals(sim.items.get(1)!.state, 'submitted');
  assertEquals(rec(sim.items.get(1)!.reviews![0].fix), {
    kind: 'placement', ops: [{ op: 'move', placement_id: `${cid(1).slice(0, -3)}777`, unit_id: cid(802), evidence: '출처 책 단원 2' }],
  });
  assertEquals(sim.items.get(2)!.state, 'failed');
  assert(String(sim.items.get(2)!.reason).startsWith('judge_invalid'));
  assertEquals(v.cards_by_kind, { review: 1, library: 0, placement: 1 });
});

Deno.test('기초 개념 2단계 실패: 1단계 판단은 저장하고 기초 개념은 판단 안 함으로 남겨 다음에 보완한다', async () => {
  const sim = new JobSim(2);
  sim.library = [{ id: cid(903), name: '약수', content: '나누어떨어지게 하는 수' }];
  const provider = new FakeAiProvider(judge({
    scopes: ['notation', 'meaning'],
    foundation: () => ({ needs: [{ name: '약수', why: '씀', terms: ['약수'] }], none_basis: null }),
    foundationError: true,
  }));
  const v = parse(await batch(sim, provider));
  assertEquals([v.judged_saved, v.foundation_not_judged], [2, 2]);
  assertEquals(sim.items.get(1)!.reviews!.map((r) => r.scope), ['notation', 'meaning']);
});

const ALL = {
  conversation_split: 1, think_roles: 1, memory_proposals: 1, department_work: 1, auto_organize: 1, course_map_actions: 1,
  concept_review: 1, concept_review_jobs: 1, concept_review_job_batch: 1,
};

class SimStore extends MemoryThinkStore {
  constructor(readonly sim: JobSim) {
    super();
  }
  override reviewJobRpc(fn: ReviewJobRpc, args: Record<string, unknown>): Promise<unknown> {
    return this.sim.rpc(fn, args);
  }
}

function chatInput(partial: Partial<ChatInput>): ChatInput {
  return {
    userId: 'user-1', safetyId: 'hash', conversationId: null, message: '배치 개념 514개 검수 이어 가자', attachments: [], deep: false,
    webSearch: false, signal: new AbortController().signal, startedAt: Date.now(), wallClockMs: 140000, ...partial,
  };
}

/** Think 흉내: 첫 차례에 묶음 검수를 한 번 부르고, 다음 차례에 답한다. 판단 요청은 judge 로 답한다. */
function thinkScript() {
  const j = judge();
  let chatTurns = 0;
  return (req: AiRequest, i: number): FakeTurn => {
    if (req.jsonSchema?.name === 'concept_review_batch_judgment' || req.jsonSchema?.name === 'concept_review_foundation_judgment') return j(req, i);
    if ((req.tools ?? []).length === 0) return { text: '제목' };
    chatTurns += 1;
    return chatTurns === 1
      ? { functionCalls: [{ name: BATCH_TOOL_NAME, arguments: { job_id: JOB, target: 50 } }] }
      : { text: '이번 요청 결과를 도구 숫자 그대로 보고합니다.' };
  };
}

Deno.test('대화: 기능이 다 준비되면 묶음 검수 도구·지침이 실제로 나가고, 새 대화에서도 저장된 곳부터 이어 간다', async () => {
  const sim = new JobSim(80);
  const store = new SimStore(sim);
  const features = computeFeatures({ ok: true, features: ALL }, ALL, true);
  assertEquals(features.concept_review_job_batch.state, 'ready');

  const p1 = new FakeAiProvider(thinkScript());
  const runs = new RunLog();
  const out1 = await runThinkChat(chatInput({ features }), { provider: p1, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv });
  assertEquals(out1.status, 'complete');
  const chatReq = p1.requests.find((r) => (r.tools ?? []).some((t) => t.name === BATCH_TOOL_NAME));
  assert(chatReq, '묶음 검수 도구가 요청에 나간다');
  assert(String(chatReq!.instructions).includes(BATCH_TOOL_NAME), '지침에 묶음 검수 규칙이 있다');
  assertEquals(sim.cards.length, 3);
  assertEquals(sim.logs.map((l) => l.p_end_reason), ['target_reached']);
  assertEquals(THINK_PROMPT_VERSION, 'think-2026-10-29a');

  const p2 = new FakeAiProvider(thinkScript());
  await runThinkChat(chatInput({ features }), { provider: p2, store, recordRun: runs.record, emit: new EventLog().emit, env: testEnv });
  assertEquals(sim.cards.length, 5);
  assertEquals(sim.cardPositions().sort((a, b) => a - b), Array.from({ length: 80 }, (_, k) => k + 1));
  assert(unique(sim.cardPositions()));
  assertEquals(sim.logs.map((l) => l.p_end_reason), ['target_reached', 'reached_end']);
});

Deno.test('1차 검수 진행률은 서버 집계 그대로이고, 필드가 없으면 0이 아니라 미집계다', async () => {
  const bare = new JobSim(1);
  bare.omitFirstPass = true;
  const u = parse(await batch(bare, new FakeAiProvider(judge()), { target: 1 }));
  assertEquals(u.progress_line, '1개 중 0개 통합 완료');
  assertEquals(u.condition_line, '조건별 충족(승인 기준): 표기·의미 0 · 기초 개념 0 · 배치 0');
  assertEquals(u.first_pass, null);
  assertEquals(u.first_pass_state, 'unaggregated');
  assert(String(u.note).includes('미집계'));
  assert(!String(u.note).includes('1차 검수 3조건 충족: 0'));
});

Deno.test('오래된 집계는 묶음 결과의 현재 완료 수가 아니다', async () => {
  const sim = new JobSim(1);
  sim.progressFreshness = 'stale';
  const v = parse(await batch(sim, new FakeAiProvider(judge()), { target: 1 }));
  assertEquals(v.aggregation, 'stale');
  assertEquals(v.progress_freshness, 'stale');
  assertEquals(v.first_pass, null);
  assertEquals(v.progress_line, null);
  assertEquals(v.progress_last_success.progress_line, '옛 집계');
  assert(String(v.note).includes('stale'));
  assert(!String(v.note).includes('1차 검수 3조건 충족: 7'));
  assert(!String(v.note).includes('미집계'));
});

Deno.test('노출: 검토·작업·묶음이 모두 준비된 사람 요청에만, 커서 질문·자동 이어하기에는 주지 않는다', () => {
  const names = (o: Parameters<typeof thinkToolsFor>[0]) => thinkToolsFor(o).map((t) => t.name);
  assert(names({ split: false, courseMap: true, conceptReview: true, reviewJobs: true, reviewBatch: true }).includes(BATCH_TOOL_NAME));
  assert(!names({ split: false, courseMap: true, conceptReview: true, reviewJobs: true, reviewBatch: false }).includes(BATCH_TOOL_NAME));
  assert(!names({ split: false, courseMap: true, conceptReview: true, reviewJobs: false, reviewBatch: true }).includes(BATCH_TOOL_NAME));
  assert(!names({ split: false, courseMap: true, conceptReview: true, reviewJobs: true, reviewBatch: true, readOnly: true }).includes(BATCH_TOOL_NAME));

  const base = {
    identity: [], principles: [], decisions: [], today: '2026-10-26',
    limits: { identityChars: 1000, principleChars: 1000, decisionChars: 1000 },
    courseMapReady: true, conceptReviewReady: true, conceptReviewJobsReady: true,
  };
  assert(thinkInstructions({ ...base, conceptReviewBatchReady: true }).includes(BATCH_TOOL_NAME));
  assert(!thinkInstructions(base).includes(BATCH_TOOL_NAME));
});

Deno.test('특정 작업 id 를 코드에 박아 두지 않는다', async () => {
  for (const f of ['concept_review_batch.ts', 'concept_review_job_tools.ts', 'prompts.ts', 'chat.ts']) {
    const src = await Deno.readTextFile(new URL(`./${f}`, import.meta.url));
    assert(!src.includes('2ac0b8ca'), f);
  }
});

const idsFrom = (start: number, n: number) => Array.from({ length: n }, (_, i) => cid(start + i));

function refMaterial(allowed: string[], self = cid(1)) {
  return {
    position: 1, concept_id: self, name: '가', revision: 'rev', content: '본문', data: {},
    ids: new Set(allowed), scopes: ['notation', 'meaning'], foundation: false,
    placementIds: new Set<string>(), courseIds: new Set<string>(), courseKeys: new Set<string>(),
  };
}

const judged = (reviews: Rec[]) => ({ status: 'judged', reviews, foundation: null });

Deno.test('참조는 필드마다 고유 20개까지 남기고, 21개와 잘못된 id는 자르지 않는다', () => {
  const twenty = idsFrom(200, 20);
  const twentyOne = idsFrom(200, 21);
  const self = cid(1);
  const one = twenty[0];
  const dup = stage1Of(refMaterial([one], self), judged([review('notation', { compared_ids: Array(11).fill(one) })]), new Set());
  assertEquals(dup.item, null);
  assertEquals(dup.reviews[0].compared_ids, [one]);

  const ordered = stage1Of(
    refMaterial([twenty[1], twenty[0]], self),
    judged([review('notation', { compared_ids: [twenty[1], twenty[0], twenty[1], twenty[0]] })]),
    new Set(),
  );
  assertEquals(ordered.reviews[0].compared_ids, [twenty[1], twenty[0]]);

  const both = stage1Of(refMaterial(twenty, self), judged([review('notation', { compared_ids: twenty, to_compare_ids: twenty })]), new Set());
  assertEquals(both.reviews[0].compared_ids, twenty);
  assertEquals(both.reviews[0].to_compare_ids, twenty);

  const over = stage1Of(refMaterial(twentyOne, self), judged([
    review('notation'),
    review('meaning', { compared_ids: twentyOne }),
  ]), new Set());
  assertEquals(over.item?.state, 'deferred');
  assertEquals(over.reviews, []);
  assertEquals(over.item?.reviews, null);
  assertEquals(over.item?.reason, `concept_review_too_many_refs:meaning:compared_ids:21:${CONCEPT_REVIEW_REF_LIMIT}`);

  const future = stage1Of(refMaterial(twentyOne, self), judged([
    review('notation', { compared_ids: [one], to_compare_ids: twentyOne }),
  ]), new Set());
  assert(String(future.item?.reason).includes(':to_compare_ids:21:20'));

  for (const bad of ['not-a-uuid', self, cid(999), 12, { id: one }]) {
    const got = stage1Of(refMaterial([one], self), judged([review('notation', { compared_ids: [bad] })]), new Set());
    assertEquals(got.item?.state, 'failed');
    assert(String(got.item?.reason).startsWith('judge_invalid'));
    assertEquals(got.reviews, []);
    assertEquals(got.item?.reviews, null);
  }
  const shaped = stage1Of(refMaterial([one], self), judged([review('notation', { compared_ids: 'not-an-array' })]), new Set());
  assertEquals(shaped.item?.state, 'failed');
  assertEquals(shaped.reviews, []);
});

Deno.test('묶음이 허용하는 개념 id는 관계·같은 개념·만든 개념 칸만이다', () => {
  const self = cid(1);
  const other = cid(52);
  const same = cid(54);
  const created = cid(53);
  const placement = cid(50);
  const statement = cid(51);
  const allow = conceptRefAllowList({
    relations: [{ id: statement, other_id: other }],
    same_concept_reviews: [{ id: cid(55), other_id: same }],
    created_concepts: [{ id: created }],
    placements: [{ id: placement }],
    statements: [{ id: statement }],
  }, self);
  assertEquals([...allow].sort(), [other, same, created].sort());
  assert(!allow.has(placement) && !allow.has(statement) && !allow.has(self));
});

Deno.test('기초 개념 비교도 21개를 자르지 않고, 후보 밖 id는 짧은 목록으로 남기지 않는다', () => {
  const twenty = idsFrom(300, 20);
  const twentyOne = idsFrom(300, 21);
  const catalog = { types: new Set(['정의']), roots: new Set(['수와 연산']), names: new Map<string, string>() };
  const stage = (allowed: string[]) => ({
    m: refMaterial([], cid(1)), item: null, reviews: [] as Rec[], needs: [{ name: '약수', why: '필요', terms: ['약수'] }], noneBasis: null,
    candidates: new Map([['약수', allowed.map((id) => ({ id, name: '약수', view: {} }))]]),
  });
  const ask = (allowed: string[], compared: unknown[]) => foundationReview(
    stage(allowed),
    { checked: '비교', findings: '판단', basis: '후보', needs: [{ name: '약수', decision: 'unverified', compared_ids: compared, reuse_id: null, create: null }] },
    stage(allowed).candidates,
    catalog,
  );
  const kept = ask(twenty, twenty);
  assert(kept && !('ref_limit' in kept) && !('diagnosis' in kept));
  assertEquals(kept.compared_ids, twenty);
  const dup = ask([twenty[0]], Array(11).fill(twenty[0]));
  assert(dup && !('ref_limit' in dup) && !('diagnosis' in dup));
  assertEquals(dup.compared_ids, [twenty[0]]);
  const limit = ask(twentyOne, twentyOne);
  assert(limit && 'ref_limit' in limit);
  assertEquals((limit as { ref_limit: { count: number } }).ref_limit.count, 21);
  assert(!('compared_ids' in limit));
  const outside = cid(399);
  const invalid = ask([twenty[0]], [twenty[0], outside]);
  assert(invalid && 'diagnosis' in invalid);
  const found = (invalid as { diagnosis: { code: string; field: string; actual_type: string } }).diagnosis;
  assertEquals(found.code, 'ref_outside_allow_list');
  assertEquals(found.field, 'needs[0].compared_ids[1]');
  assertEquals(found.actual_type, 'outside_allow_list');
  assert(!JSON.stringify(invalid).includes(outside));
  assert(!invalid || !('compared_ids' in invalid));
});

Deno.test('고유 21개 비교는 그 위치를 미결로 두고 다음 묶음에서 다시 판단하지 않는다', async () => {
  const sim = new JobSim(2);
  const refs = idsFrom(400, 21).map((id) => ({ other_id: id }));
  sim.concepts[0].relations = refs;
  sim.concepts[0].placements = [{ id: cid(499) }];
  sim.concepts[1].relations = [{ other_id: cid(410) }];
  sim.concepts[1].placements = [{ id: cid(498) }];
  const provider = new FakeAiProvider(judge({
    reviews: (d) => [review('notation', {
      to_compare_ids: d.position === 1 ? refs.map((r) => r.other_id) : Array(11).fill(cid(410)),
    })],
  }));
  const v = parse(await batch(sim, provider, { target: 2 }));
  assertEquals(sim.items.get(1)!.state, 'deferred');
  assertEquals(sim.items.get(1)!.reviews, null);
  assert(String(sim.items.get(1)!.reason).startsWith('concept_review_too_many_refs:notation:to_compare_ids:21:20'));
  assertEquals(sim.items.get(2)!.reviews![0].to_compare_ids, [cid(410)]);
  assertEquals(sim.items.get(2)!.reviews![0].compared_ids, []);
  assertEquals(v.judged_saved, 1);
  assertEquals(v.deferred.count, 1);
  assertEquals(v.failed.count, 0);
  const again = new FakeAiProvider(judge());
  await batch(sim, again, { target: 2 });
  const againView = judgeRequests(again).flatMap((r) => (payloadOf(r).concepts as Rec[]));
  assert(!againView.some((c) => c.position === 1), '상한 초과 위치는 다음 묶음에 다시 들어가지 않는다');

  const bad = new JobSim(1);
  bad.concepts[0].placements = [{ id: cid(497) }];
  bad.concepts[0].relations = [{ other_id: cid(411) }];
  const badRun = parse(await batch(bad, new FakeAiProvider(judge({
    reviews: () => [review('notation', { compared_ids: [cid(497)] })],
  })), { target: 1 }));
  assertEquals(bad.items.get(1)!.state, 'failed');
  assertEquals(bad.items.get(1)!.reviews, null);
  assert(String(bad.items.get(1)!.reason).startsWith('judge_invalid'));
  assertEquals(badRun.judged_saved, 0);
});

Deno.test('형식 거절은 첫 원인만 남기고, 본문·잘못된 id는 진단에 넣지 않는다', () => {
  const self = cid(1);
  const one = cid(2);
  const secret = '비밀근거문장';
  const badId = cid(999);
  const units = new Set<string>();
  const reasonOf = (raw: unknown, material = refMaterial([one], self)) =>
    String(stage1Of(material, raw, units).item?.reason ?? '');

  const both = reasonOf(judged([review('notation', { checked: '', compared_ids: [badId], findings: secret })]));
  assertEquals(both, 'judge_invalid:checked_missing:notation:reviews[0].checked:non_empty_text:empty_string');
  assert(!both.includes(secret) && !both.includes(badId));

  const later = reasonOf(judged([
    review('notation', { outcome: 'not_an_outcome' }),
    review('meaning', { checked: '' }),
  ]));
  assert(later.includes(':outcome_not_allowed:notation:reviews[0].outcome:'));
  assert(!later.includes('checked_missing'));

  const twentyOne = idsFrom(200, 21);
  const limitThenBad = stage1Of(refMaterial(twentyOne, self), judged([
    review('notation', { compared_ids: twentyOne }),
    review('meaning', { compared_ids: [badId] }),
  ]), units);
  assertEquals(limitThenBad.item?.state, 'failed');
  assert(String(limitThenBad.item?.reason).includes(':ref_outside_allow_list:meaning:reviews[1].compared_ids[0]:'));
  assert(!String(limitThenBad.item?.reason).includes('concept_review_too_many_refs'));
  assert(!String(limitThenBad.item?.reason).includes(badId));

  const dupScope = reasonOf(judged([review('notation'), review('notation')]));
  assert(dupScope.includes(':duplicate_scope:notation:reviews[1].scope:unique_scope:duplicate'));

  const empty = reasonOf(judged([]));
  assert(empty.includes(':empty_reviews:-:reviews:at_least_one_review:empty_array'));
  const notArray = reasonOf({ status: 'judged', reviews: 'nope', foundation: null });
  assert(notArray.includes(':reviews_not_array:-:reviews:review_array:'));

  const merge = reasonOf(judged([review('notation', { outcome: 'merge_needed' })]));
  assert(merge.includes(':merge_needed_scope:notation:reviews[0].scope:unit_scope:not_unit'));

  const selfRef = reasonOf(judged([review('notation', { compared_ids: [self] })]));
  assert(selfRef.includes(':ref_self:notation:reviews[0].compared_ids[0]:'));
  assert(!selfRef.includes(self));
  const typed = reasonOf(judged([review('notation', { compared_ids: [12] })]));
  assert(typed.includes(':ref_element_type:notation:reviews[0].compared_ids[0]:uuid_string:number'));
  const notUuid = reasonOf(judged([review('notation', { compared_ids: [secret] })]));
  assert(notUuid.includes(':ref_uuid:notation:reviews[0].compared_ids[0]:uuid_string:non_uuid'));
  assert(!notUuid.includes(secret));

  const placementId = cid(50);
  const place = {
    ...refMaterial([one], self),
    scopes: ['placement'],
    placementIds: new Set([placementId]),
  };
  const evidence = reasonOf(judged([review('placement', {
    outcome: 'issue_found',
    fix: { kind: 'placement', ops: [{ op: 'remove', placement_id: placementId, evidence: '' }, { op: 'remove', placement_id: placementId, evidence: secret }] },
  })]), place);
  assertEquals(evidence, 'judge_invalid:fix_evidence_empty:placement:reviews[0].fix.ops[0].evidence:non_empty_text:empty_string');
  assert(!evidence.includes(secret) && !evidence.includes(placementId));

  const textMissing = reasonOf(judged([review('notation', {
    outcome: 'issue_found',
    fix: { kind: 'library', ops: [{ op: 'edit', name: '  ', content: '' }] },
  })]));
  assert(textMissing.includes(':fix_text_missing:notation:reviews[0].fix.ops[0]:name_or_content:empty'));

  const classified = stage1Of(
    { ...refMaterial([], self), scopes: ['classification'] },
    judged([review('classification', { outcome: 'issue_found', fix: { kind: 'library', ops: [{ op: 'nope' }] } })]),
    units,
  );
  assertEquals(classified.item, null);
  assertEquals(classified.reviews[0].fix, undefined);

  const old = diagnosisFromReason('judge_invalid: 판단 형식이 맞지 않음(범위·결과·근거·고치기 제안·비교 개념)');
  assertEquals(old.kind, 'generic');
  assertEquals(old.scope, null);
  assertEquals(old.field, null);
  const parsed = diagnosisFromReason(evidence);
  assertEquals(parsed, {
    kind: 'specific', code: 'fix_evidence_empty', stage: 'stage1', scope: 'placement',
    field: 'reviews[0].fix.ops[0].evidence', expected: 'non_empty_text', actual_type: 'empty_string',
  });

  const rows = Array.from({ length: 51 }, (_, i) => ({
    position: i + 1, concept_id: cid(i + 1), name: `개념${i + 1}`,
    reason: i === 50 ? 'judge_timeout: 판단 시간 안에 응답이 오지 않음' : evidence,
  }));
  const report = failureReport(rows);
  assertEquals(report.count, 51);
  assertEquals(report.returned, 50);
  assertEquals(report.omitted, 1);
  assertEquals((report.items as Rec[]).length, 50);
  const by = report.by_code as Record<string, number>;
  assertEquals(by.fix_evidence_empty + by.judge_timeout, 51);
  assert(String(report.read_rest).includes('get_concept_review_job'));
});

Deno.test('형식 실패는 그 위치만 실패로 남고, 30개를 넘겨도 이번 결과에서 모두 읽힌다', async () => {
  const sim = new JobSim(2);
  const provider = new FakeAiProvider(judge({
    reviews: (d) => d.position === 1
      ? [review('notation', { compared_ids: ['not-a-uuid'] })]
      : [review('notation')],
  }));
  const v = parse(await batch(sim, provider, { target: 2 }));
  assertEquals(sim.items.get(1)!.state, 'failed');
  assertEquals(sim.items.get(1)!.reviews, null);
  assert(String(sim.items.get(1)!.reason).startsWith('judge_invalid:ref_uuid:notation:reviews[0].compared_ids[0]:'));
  assert(!String(sim.items.get(1)!.reason).includes('not-a-uuid'));
  assertEquals(sim.items.get(2)!.state, 'submitted');
  assertEquals(sim.cardPositions(), [2]);
  assertEquals(v.judged_saved, 1);
  assertEquals(v.failed.count, 1);
  assertEquals(v.failed.by_code.ref_uuid, 1);
  assertEquals(v.failed.items[0].diagnosis.kind, 'specific');
  assertEquals(v.failed.items[0].concept_id, cid(1));
  const sum = Object.values(v.failed.by_code as Record<string, number>).reduce((a, n) => a + n, 0);
  assertEquals(sum, v.failed.count);

  const again = new FakeAiProvider(judge());
  await batch(sim, again, { target: 2 });
  assert(judgeRequests(again).flatMap((r) => (payloadOf(r).concepts as Rec[])).some((c) => c.position === 1));

  const many = new JobSim(31);
  const listed = parse(await batch(many, new FakeAiProvider(judge({
    reviews: () => [review('notation', { compared_ids: ['not-a-uuid'] })],
  })), { target: 31 }));
  assertEquals(listed.failed.count, 31);
  assertEquals(listed.failed.returned, 31);
  assertEquals(listed.failed.omitted, 0);
  assertEquals(listed.failed.items.length, 31);
  assertEquals(listed.failed.by_code.ref_uuid, 31);
  assertEquals(listed.judged_saved, 0);
  assert(many.items.size === 31 && [...many.items.values()].every((it) => it.state === 'failed' && it.reviews == null));
});

Deno.test('참조 상한 정의가 DB·도구 설명·판단 지시와 같다', async () => {
  assertEquals(CONCEPT_REVIEW_REF_LIMIT, 20);
  assertEquals(BATCH_PROMPT_VERSION, 'review-batch-2026-10-28b');
  assertEquals(THINK_PROMPT_VERSION, 'think-2026-10-29a');
  assert(JUDGE_INSTRUCTIONS.includes('고유 20개까지'));
  assert(JUDGE_INSTRUCTIONS.includes('to_compare_ids로 옮겨'));
  const sql = await Deno.readTextFile(new URL('../../migrations/20261028010000_concept_review_ref_limit.sql', import.meta.url));
  assert(/function public\.concept_review_ref_limit\(\)[\s\S]*?select 20/.test(sql));
  assert(!/delete\s+from\s+public\.concept_review_job_items/i.test(sql));
  const batchSrc = await Deno.readTextFile(new URL('./concept_review_batch.ts', import.meta.url));
  assert(!batchSrc.includes('slice(0, 20)'));
  assert(!batchSrc.includes('UUID_G'));
  const tool = COURSE_MAP_TOOLS.find((t) => t.name === REVIEW_PROPOSE_TOOL_NAME);
  const props = (tool!.parameters as { properties: { items: { items: { properties: Record<string, { description?: string; maxItems?: number }> } } } }).properties;
  assert(String(props.items.items.properties.compared_ids.description).includes('고유 20개'));
  assert(String(props.items.items.properties.to_compare_ids.description).includes('고유 20개'));
  assertEquals(props.items.items.properties.compared_ids.maxItems, undefined);
  assertEquals(props.items.items.properties.to_compare_ids.maxItems, undefined);
});

Deno.test('묶음 검수 집계가 시간 초과되면 미집계가 아니라 실패 진단을 돌려준다', async () => {
  const sim = new JobSim(1);
  sim.blockStatus = true;
  const v = parse(await batch(sim, new FakeAiProvider(judge()), { target: 1, statusTimeoutMs: 40 }));
  assertEquals(v.aggregation, 'failed');
  assertEquals(v.first_pass_state, 'failed');
  assertEquals(v.first_pass, null);
  assertEquals(v.counts, null);
  assertEquals(v.progress_line, null);
  assertEquals(v.status_diag.code, 'timeout');
  assertEquals(v.status_diag.stage, 'status_rpc');
  assertEquals(v.status_diag.timeout_ms, 40);
  assert(v.status_diag.elapsed_ms >= 40);
  assertEquals(v.status_diag.db_cancel, 'requested');
  assertEquals(typeof v.status_diag.trace_id, 'string');
  assertEquals(v.diag_save, 'saved');
  assert(!String(v.note).includes('미집계'));
  assertEquals(v.status_diag.outcome, 'failed');
  const stored = sim.statusDiags.at(-1)!;
  assertEquals(stored.code, 'timeout');
  assert(!JSON.stringify(stored).includes('개념'));
});

Deno.test('비교 참조: 같은 호출에서 전문과 판이 확인된 개념은 입력과 검증이 같은 목록으로 허용한다', async () => {
  const markA = 'a'.repeat(32);
  const markB = 'b'.repeat(32);
  const sim = new JobSim(3);
  for (const c of sim.concepts) c.todo = ['notation'];
  sim.concepts[0].textMark = markA;
  sim.concepts[1].textMark = markB;
  sim.concepts[0].relations = [{ id: cid(90), other_id: cid(80) }];
  const provider = new FakeAiProvider(judge({
    reviews: (d) => [review('notation', {
      compared_ids: (d.compared_ids as string[]) ?? [],
      to_compare_ids: (d.to_compare_ids as string[]) ?? [],
    })],
  }));
  const v = parse(await batch(sim, provider, { target: 3 }));
  const view = (payloadOf(judgeRequests(provider)[0]).concepts as Rec[]);
  const byPos = new Map(view.map((c) => [Number(c.position), c]));
  assertEquals(byPos.get(1)?.compared_ids, [cid(2)]);
  assertEquals(byPos.get(2)?.compared_ids, [cid(1)]);
  assertEquals(byPos.get(3)?.compared_ids, [cid(1), cid(2)]);
  assert(!((byPos.get(1)?.compared_ids as string[]) ?? []).includes(cid(3)), '지문이 없는 개념은 전문 비교 목록에 넣지 않는다');
  assertEquals(byPos.get(1)?.to_compare_ids, [cid(80)]);
  assertEquals(byPos.get(1)?.text_mark, undefined);
  assertEquals(sim.items.get(1)!.reviews![0].compared_ids, [cid(2)]);
  assertEquals(sim.items.get(1)!.reviews![0].to_compare_ids, [cid(80)]);
  assertEquals(sim.items.get(1)!.reviews![0].compared_marks, { [cid(2)]: markB });
  assertEquals(sim.items.get(3)!.reviews![0].compared_ids, [cid(1), cid(2)]);
  assertEquals(sim.items.get(3)!.reviews![0].compared_marks, { [cid(1)]: markA, [cid(2)]: markB });
  assertEquals(v.judged_saved, 3);
  assertEquals(v.failed.count, 0);
});

Deno.test('비교 참조: 이름·발췌와 비개념 id는 거절하고 값 없이 종류만 진단한다', () => {
  const self = cid(1);
  const sibling = cid(2);
  const excerpt = cid(3);
  const mark = 'b'.repeat(32);
  const secret = '비밀본문비교근거';
  const relation = cid(80);
  const same = cid(81);
  const created = cid(82);
  const placement = cid(70);
  const course = cid(60);
  const unit = cid(61);
  const statement = cid(63);
  const relationRow = cid(64);
  const sameRow = cid(65);
  const unknown = cid(999);
  const group = [
    {
      position: 1, concept_id: self, name: '가', revision: `${'a'.repeat(12)}-cccccccccccc-rrrrrrrrrrrr`,
      content: secret, data: {
        relations: [{ id: relationRow, other_id: relation }],
        same_concept_reviews: [{ id: sameRow, other_id: same }],
        created_concepts: [{ id: created, name: '만든' }],
        placements: [{ id: placement, course_id: course }],
        statements: [{ id: statement, content: secret }],
      },
      ids: new Set<string>(), scopes: ['notation'], foundation: false,
      placementIds: new Set([placement]), courseIds: new Set([course]), courseKeys: new Set<string>(),
      fullRead: true, textMark: 'a'.repeat(32),
    },
    {
      position: 2, concept_id: sibling, name: '나', revision: `${mark.slice(0, 12)}-cccccccccccc-rrrrrrrrrrrr`,
      content: '상대 전문', data: {},
      ids: new Set<string>(), scopes: ['notation'], foundation: false,
      placementIds: new Set<string>(), courseIds: new Set<string>(), courseKeys: new Set<string>(),
      fullRead: true, textMark: mark,
    },
    {
      position: 3, concept_id: excerpt, name: '발췌만', revision: 'r3-1',
      content: '앞부분만', data: {},
      ids: new Set<string>(), scopes: ['notation'], foundation: false,
      placementIds: new Set<string>(), courseIds: new Set<string>(), courseKeys: new Set<string>(),
      fullRead: false, textMark: null,
    },
  ] as Parameters<typeof assignRefLists>[0];
  assignRefLists(group, new Set([unit]), [{ id: course, units: [{ id: unit }] }]);
  const me = group[0];
  assertEquals([...(me.comparedIds ?? [])], [sibling]);
  assertEquals([...(me.toCompareIds ?? [])].sort(), [relation, same, created].sort());
  const ok = stage1Of(me, judged([review('notation', { compared_ids: [sibling], to_compare_ids: [relation] })]), new Set([unit]));
  assertEquals(ok.item, null);
  assertEquals(ok.reviews[0].compared_ids, [sibling]);
  assertEquals(ok.reviews[0].to_compare_ids, [relation]);
  assertEquals(ok.reviews[0].compared_marks, { [sibling]: mark });
  assert(!JSON.stringify(ok.reviews[0]).includes(secret));
  const cases: [string, string, 'compared_ids' | 'to_compare_ids'][] = [
    [sibling, 'same_call_concept', 'to_compare_ids'],
    [relation, 'unread_concept', 'compared_ids'],
    [excerpt, 'unread_concept', 'compared_ids'],
    [placement, 'placement_id', 'compared_ids'],
    [unit, 'course_unit_id', 'compared_ids'],
    [course, 'course_unit_id', 'compared_ids'],
    [statement, 'row_id', 'compared_ids'],
    [relationRow, 'row_id', 'compared_ids'],
    [sameRow, 'row_id', 'compared_ids'],
    [unknown, 'unknown_id', 'compared_ids'],
  ];
  for (const [id, type, field] of cases) {
    const got = stage1Of(me, judged([review('notation', { [field]: [id] })]), new Set([unit]));
    const text = String(got.item?.reason ?? '');
    assert(text.startsWith('judge_invalid:ref_outside_allow_list:notation:'), text);
    assert(text.endsWith(`:${type}`), text);
    assert(!text.includes(id), text);
    assert(!text.includes(secret));
    assertEquals(diagnosisFromReason(text).actual_type, type);
    assertEquals(got.reviews, []);
  }
});
