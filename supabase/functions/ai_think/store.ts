// ThinkStore의 Supabase 구현. 요청한 사용자의 JWT 클라이언트로 동작하므로 RLS(슈퍼관리자 전용)가 그대로 적용된다.

import type { QueryBuilder } from '../_shared/ai/db.ts';
import type { ConversationRow, NewMessage, ThinkStore } from './chat.ts';
import type { AttachmentRef, MemoryDetail, MemoryRow, MessageRow } from './context.ts';
import type {
  ActionKind,
  ActionRow,
  CodeRequestDetail,
  CodeRequestHit,
  ConversationHit,
  ConversationStats,
  TreeFolderRow,
  TreeItemRow,
  WorkState,
} from './actions.ts';
import type {
  BehaviorCard,
  ConceptCategory,
  ConceptHit,
  CurriculumNode,
  CurriculumOutlineQuery,
} from './tools.ts';

export interface SupabaseLike {
  from(table: string): QueryBuilder;
  rpc(fn: string, args?: Record<string, unknown>): QueryBuilder;
  storage: { from(bucket: string): QueryBuilder };
}

export const ATTACHMENT_BUCKET = 'ai-attachments';

const MEMORY_COLUMNS =
  'id,kind,status,title,content,decision_context,decision_reason,alternatives,tags,sort_order,version,updated_at';

const ACTION_COLUMNS = 'id,conversation_id,message_id,kind,status,payload,preview,result,error,superseded,created_at';
const CODE_COLUMNS = 'id,title,status,mode,conversation_id,created_at,request,round,max_rounds,review_status,last_error';
// diff(최대 400KB)는 AI 맥락에 넣지 않는다. 결과에서 필요한 필드만 고른다.
const RESULT_FIELDS = ['summary', 'feasibility', 'answers', 'findings', 'proposals', 'risks', 'questions_for_think', 'diff_stats', 'files'];
const ROUND_COLUMNS = `request_id,round,status,${RESULT_FIELDS.map((f) => `${f}:result->${f}`).join(',')}`;

type Row = Record<string, unknown>;

function s(v: unknown): string {
  return typeof v === 'string' ? v : v == null ? '' : String(v);
}

function strList(v: unknown): string[] {
  return Array.isArray(v) ? v.map((x) => s(x).trim()).filter(Boolean) : [];
}

export function normalizeMemory(r: Row): MemoryRow {
  return {
    id: s(r.id),
    kind: s(r.kind),
    status: s(r.status),
    title: s(r.title),
    content: s(r.content),
    decision_context: (r.decision_context as string | null) ?? null,
    decision_reason: (r.decision_reason as string | null) ?? null,
    alternatives: strList(r.alternatives),
    tags: strList(r.tags),
    sort_order: typeof r.sort_order === 'number' ? r.sort_order : null,
    version: typeof r.version === 'number' ? r.version : null,
    updated_at: (r.updated_at as string | null) ?? null,
  };
}

function obj(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

export function normalizeAction(r: Row): ActionRow {
  return {
    id: s(r.id),
    conversation_id: s(r.conversation_id),
    message_id: (r.message_id as string | null) ?? null,
    kind: s(r.kind) as ActionKind,
    status: s(r.status),
    payload: obj(r.payload),
    preview: obj(r.preview),
    result: r.result == null ? null : obj(r.result),
    error: (r.error as string | null) ?? null,
    superseded: r.superseded === true,
    created_at: s(r.created_at),
  };
}

function normalizeCodeHit(r: Row): CodeRequestHit {
  return {
    id: s(r.id),
    title: s(r.title),
    status: s(r.status),
    mode: s(r.mode) || 'investigate',
    conversation_id: (r.conversation_id as string | null) ?? null,
    created_at: s(r.created_at),
  };
}

function roundResult(r: Row): Record<string, unknown> | null {
  const out: Record<string, unknown> = {};
  for (const f of RESULT_FIELDS) if (r[f] != null) out[f] = r[f];
  return Object.keys(out).length > 0 ? out : null;
}

export function normalizeAttachments(v: unknown): AttachmentRef[] {
  if (!Array.isArray(v)) return [];
  const out: AttachmentRef[] = [];
  for (const raw of v) {
    if (!raw || typeof raw !== 'object') continue;
    const a = raw as Row;
    const path = s(a.path);
    if (!path) continue;
    out.push({ path, name: s(a.name) || path.split('/').pop() || 'file', mime: s(a.mime), size: typeof a.size === 'number' ? a.size : null });
  }
  return out;
}

function likePattern(q: string): string {
  const cleaned = q.replace(/[%_*,()"'\\]/g, ' ').replace(/\s+/g, ' ').trim();
  return `%${cleaned}%`;
}

function check<T>(res: { data: T; error: { message: string } | null }, what: string): T {
  if (res.error) throw new Error(`${what}: ${res.error.message}`);
  return res.data;
}

export class SupabaseThinkStore implements ThinkStore {
  constructor(private readonly db: SupabaseLike) {}

  // --- 컨텍스트 ---
  async listActiveMemories(kinds: string[]): Promise<MemoryRow[]> {
    const data = check(
      await this.db
        .from('ai_memories')
        .select(MEMORY_COLUMNS)
        .in('kind', kinds)
        .eq('status', 'active')
        .order('sort_order', { ascending: true })
        .order('updated_at', { ascending: false })
        .limit(300),
      'ai_memories',
    ) as Row[] | null;
    return (data ?? []).map(normalizeMemory);
  }

  async searchMemories(terms: string[], limit: number): Promise<MemoryRow[]> {
    if (terms.length === 0) return [];
    const data = check(await this.db.rpc('ai_search_memories', { p_terms: terms, p_limit: limit }), 'ai_search_memories') as
      | Row[]
      | null;
    return (data ?? []).map(normalizeMemory);
  }

  // '답변에서 제외'한 메시지는 AI가 읽는 모든 경로(대화 기록, 결정 초안, 스펙)에서 빠진다.
  async listMessages(conversationId: string, limit: number): Promise<MessageRow[]> {
    const data = check(
      await this.db
        .from('ai_messages')
        .select('id,role,content,status,attachments,created_at')
        .eq('conversation_id', conversationId)
        .eq('context_excluded', false)
        .order('created_at', { ascending: false })
        .limit(limit),
      'ai_messages',
    ) as Row[] | null;
    return (data ?? [])
      .reverse()
      .map((r) => ({
        id: s(r.id),
        role: r.role === 'assistant' ? 'assistant' : 'user',
        content: s(r.content),
        status: s(r.status),
        attachments: normalizeAttachments(r.attachments),
        created_at: s(r.created_at),
      }));
  }

  async signAttachment(path: string, expiresInSec: number): Promise<string | null> {
    const { data, error } = await this.db.storage.from(ATTACHMENT_BUCKET).createSignedUrl(path, expiresInSec);
    if (error || !data?.signedUrl) return null;
    return data.signedUrl as string;
  }

  // --- 도구(읽기 전용) ---
  async getMemory(id: string): Promise<MemoryDetail | null> {
    const data = check(
      await this.db
        .from('ai_memories')
        .select(`${MEMORY_COLUMNS},supersedes_id,source_conversation_id,approved_at,created_at`)
        .eq('id', id)
        .maybeSingle(),
      'ai_memories',
    ) as Row | null;
    if (!data) return null;
    return {
      ...normalizeMemory(data),
      supersedes_id: (data.supersedes_id as string | null) ?? null,
      source_conversation_id: (data.source_conversation_id as string | null) ?? null,
      approved_at: (data.approved_at as string | null) ?? null,
      created_at: (data.created_at as string | null) ?? null,
    };
  }

  async curriculumOutline(q: CurriculumOutlineQuery): Promise<CurriculumNode[]> {
    let cq = this.db.from('curriculum').select('id,name').order('name');
    cq = q.curriculumName ? cq.ilike('name', likePattern(q.curriculumName)) : cq.eq('is_active', true);
    const curricula = (check(await cq.limit(5), 'curriculum') as Row[] | null) ?? [];
    if (curricula.length === 0) return [];

    let gq = this.db
      .from('grade')
      .select('id,curriculum_id,school_level,name,display_order')
      .in('curriculum_id', curricula.map((c) => c.id))
      .order('display_order');
    if (q.schoolLevel) gq = gq.eq('school_level', q.schoolLevel);
    const grades = (check(await gq, 'grade') as Row[] | null) ?? [];

    let chapters: Row[] = [];
    if (q.depth !== 'grade' && grades.length > 0) {
      chapters =
        (check(
          await this.db
            .from('chapter')
            .select('id,grade_id,name,display_order')
            .in('grade_id', grades.map((g) => g.id))
            .order('display_order'),
          'chapter',
        ) as Row[] | null) ?? [];
    }
    let sections: Row[] = [];
    if (q.depth === 'section' && chapters.length > 0) {
      sections =
        (check(
          await this.db
            .from('section')
            .select('id,chapter_id,name,display_order')
            .in('chapter_id', chapters.map((c) => c.id))
            .order('display_order'),
          'section',
        ) as Row[] | null) ?? [];
    }

    return curricula.map((c) => ({
      name: s(c.name),
      children: grades
        .filter((g) => g.curriculum_id === c.id)
        .map((g) => ({
          name: `${s(g.school_level)} ${s(g.name)}`.trim(),
          children:
            q.depth === 'grade'
              ? undefined
              : chapters
                  .filter((ch) => ch.grade_id === g.id)
                  .map((ch) => ({
                    name: s(ch.name),
                    children:
                      q.depth === 'section'
                        ? sections.filter((sec) => sec.chapter_id === ch.id).map((sec) => ({ name: s(sec.name) }))
                        : undefined,
                  })),
        })),
    }));
  }

  private async categoryPaths(ids: string[]): Promise<Map<string, string>> {
    const byId = new Map<string, Row>();
    let pending = [...new Set(ids.filter(Boolean))];
    for (let depth = 0; depth < 6 && pending.length > 0; depth++) {
      const rows =
        (check(await this.db.from('concept_categories').select('id,name,parent_id').in('id', pending), 'concept_categories') as
          | Row[]
          | null) ?? [];
      for (const r of rows) byId.set(s(r.id), r);
      pending = [...new Set(rows.map((r) => s(r.parent_id)).filter((p) => p && !byId.has(p)))];
    }
    const paths = new Map<string, string>();
    for (const id of ids) {
      const names: string[] = [];
      let cur = byId.get(id);
      let guard = 0;
      while (cur && guard++ < 8) {
        names.unshift(s(cur.name));
        cur = cur.parent_id ? byId.get(s(cur.parent_id)) : undefined;
      }
      paths.set(id, names.join(' > '));
    }
    return paths;
  }

  async searchConcepts(query: string, limit: number): Promise<ConceptHit[]> {
    const pattern = likePattern(query);
    if (pattern === '%%') return [];
    const rows =
      (check(
        await this.db
          .from('concepts')
          .select('id,name,kind,level,content,main_category_id')
          .or(`name.ilike.${pattern},content.ilike.${pattern}`)
          .order('sort_order')
          .limit(limit),
        'concepts',
      ) as Row[] | null) ?? [];
    const paths = await this.categoryPaths(rows.map((r) => s(r.main_category_id)));
    return rows.map((r) => ({
      id: s(r.id),
      name: s(r.name),
      kind: s(r.kind),
      level: typeof r.level === 'number' ? r.level : null,
      category_path: paths.get(s(r.main_category_id)) ?? '',
      content: s(r.content).slice(0, 800),
    }));
  }

  async listConceptCategories(parentId: string | null): Promise<ConceptCategory[]> {
    let q = this.db.from('concept_categories').select('id,name,depth,description').order('sort_order').order('name').limit(100);
    q = parentId ? q.eq('parent_id', parentId) : q.is('parent_id', null);
    const rows = (check(await q, 'concept_categories') as Row[] | null) ?? [];
    if (rows.length === 0) return [];
    const children =
      (check(
        await this.db.from('concept_categories').select('parent_id').in('parent_id', rows.map((r) => r.id)),
        'concept_categories',
      ) as Row[] | null) ?? [];
    const counts = new Map<string, number>();
    for (const c of children) counts.set(s(c.parent_id), (counts.get(s(c.parent_id)) ?? 0) + 1);
    return rows.map((r) => ({
      id: s(r.id),
      name: s(r.name),
      depth: typeof r.depth === 'number' ? r.depth : 0,
      description: (r.description as string | null) ?? null,
      child_count: counts.get(s(r.id)) ?? 0,
    }));
  }

  async searchBehaviorCards(query: string | null, limit: number): Promise<BehaviorCard[]> {
    const rows =
      (check(
        await this.db
          .from('learning_behavior_cards')
          .select('id,name,repeat_days,is_irregular,level_contents,order_index')
          .order('order_index')
          .limit(300),
        'learning_behavior_cards',
      ) as Row[] | null) ?? [];
    const needle = query?.toLowerCase().trim() ?? '';
    return rows
      .map((r) => ({
        id: s(r.id),
        name: s(r.name),
        repeat_days: typeof r.repeat_days === 'number' ? r.repeat_days : 0,
        is_irregular: r.is_irregular === true,
        level_contents: strList(r.level_contents).map((t) => t.slice(0, 300)),
      }))
      .filter((c) => !needle || c.name.toLowerCase().includes(needle) || c.level_contents.some((t) => t.toLowerCase().includes(needle)))
      .slice(0, limit);
  }

  // --- 작업 도구: 트리는 폴더 이름과 배치만 읽는다(발췌 제목·요약은 읽지 않음) ---
  async listTreeFolders(): Promise<{ folders: TreeFolderRow[]; items: TreeItemRow[] }> {
    const [folders, items] = await Promise.all([
      this.db.from('ai_tree_nodes').select('id,parent_id,title').eq('kind', 'folder').order('sort_order').limit(500),
      this.db.from('ai_tree_nodes').select('parent_id,kind,conversation_id').neq('kind', 'folder').limit(5000),
    ]);
    return {
      folders: ((check(folders, 'ai_tree_nodes') as Row[] | null) ?? []).map((r) => ({
        id: s(r.id),
        parent_id: (r.parent_id as string | null) ?? null,
        title: s(r.title),
      })),
      items: ((check(items, 'ai_tree_nodes') as Row[] | null) ?? []).map((r) => ({
        parent_id: (r.parent_id as string | null) ?? null,
        kind: s(r.kind),
        conversation_id: (r.conversation_id as string | null) ?? null,
      })),
    };
  }

  async listConversations(query: string | null, limit: number): Promise<ConversationHit[]> {
    let q = this.db
      .from('ai_conversations')
      .select('id,title,last_message_at')
      .order('last_message_at', { ascending: false, nullsFirst: false })
      .limit(limit);
    if (query) q = q.ilike('title', likePattern(query));
    const rows = (check(await q, 'ai_conversations') as Row[] | null) ?? [];
    return rows.map((r) => ({ id: s(r.id), title: s(r.title), last_message_at: (r.last_message_at as string | null) ?? null }));
  }

  async conversationStats(id: string): Promise<ConversationStats | null> {
    const conv = check(
      await this.db.from('ai_conversations').select('id,title,message_count').eq('id', id).maybeSingle(),
      'ai_conversations',
    ) as Row | null;
    if (!conv) return null;
    const [excerpts, requests] = await Promise.all([
      this.db.from('ai_tree_nodes').select('id', { count: 'exact', head: true }).eq('kind', 'excerpt').eq('conversation_id', id),
      this.db.from('ai_code_requests').select('id', { count: 'exact', head: true }).eq('conversation_id', id),
    ]);
    check(excerpts, 'ai_tree_nodes');
    check(requests, 'ai_code_requests');
    return {
      id: s(conv.id),
      title: s(conv.title),
      messages: typeof conv.message_count === 'number' ? conv.message_count : 0,
      excerpts: excerpts.count ?? 0,
      code_requests: requests.count ?? 0,
    };
  }

  async listCodeRequests(query: string | null, limit: number): Promise<CodeRequestHit[]> {
    let q = this.db.from('ai_code_requests').select('id,title,status,mode,conversation_id,created_at').order('created_at', { ascending: false }).limit(limit);
    if (query) q = q.ilike('title', likePattern(query));
    return ((check(await q, 'ai_code_requests') as Row[] | null) ?? []).map(normalizeCodeHit);
  }

  private async latestRounds(ids: string[], withText: boolean): Promise<Map<string, CodeRequestDetail['latest']>> {
    const latest = new Map<string, CodeRequestDetail['latest']>();
    if (ids.length === 0) return latest;
    const rows =
      (check(
        await this.db
          .from('ai_code_request_rounds')
          .select(withText ? `${ROUND_COLUMNS},result_text` : ROUND_COLUMNS)
          .in('request_id', ids)
          .order('round', { ascending: false }),
        'ai_code_request_rounds',
      ) as Row[] | null) ?? [];
    for (const r of rows) {
      const id = s(r.request_id);
      const prev = latest.get(id);
      if (prev && (prev.status === 'finished' || r.status !== 'finished')) continue;
      latest.set(id, {
        round: typeof r.round === 'number' ? r.round : 0,
        status: s(r.status),
        result: roundResult(r),
        result_text: withText ? ((r.result_text as string | null) ?? null) : null,
      });
    }
    return latest;
  }

  private toDetail(r: Row, latest: CodeRequestDetail['latest']): CodeRequestDetail {
    return {
      ...normalizeCodeHit(r),
      request: obj(r.request),
      round: typeof r.round === 'number' ? r.round : 0,
      max_rounds: typeof r.max_rounds === 'number' ? r.max_rounds : 2,
      review_status: (r.review_status as string | null) ?? null,
      last_error: (r.last_error as string | null) ?? null,
      latest,
    };
  }

  async getCodeRequest(id: string): Promise<CodeRequestDetail | null> {
    const r = check(await this.db.from('ai_code_requests').select(CODE_COLUMNS).eq('id', id).maybeSingle(), 'ai_code_requests') as Row | null;
    if (!r) return null;
    const latest = await this.latestRounds([id], true);
    return this.toDetail(r, latest.get(id) ?? null);
  }

  async proposeAction(
    conversationId: string,
    kind: ActionKind,
    payload: Record<string, unknown>,
    preview: Record<string, unknown>,
  ): Promise<ActionRow> {
    const data = check(
      await this.db
        .rpc('ai_action_propose', { p_conversation_id: conversationId, p_kind: kind, p_payload: payload, p_preview: preview })
        .single(),
      'ai_action_propose',
    ) as Row;
    return normalizeAction(data);
  }

  async startCodePlan(conversationId: string, title: string, spec: Record<string, unknown>): Promise<ActionRow> {
    const data = check(
      await this.db.rpc('ai_code_plan_start', { p_conversation_id: conversationId, p_title: title, p_spec: spec }).single(),
      'ai_code_plan_start',
    ) as Row;
    return normalizeAction(data);
  }

  async attachActions(ids: string[], messageId: string): Promise<void> {
    check(await this.db.rpc('ai_action_attach', { p_ids: ids, p_message_id: messageId }), 'ai_action_attach');
  }

  async getWorkState(conversationId: string): Promise<WorkState> {
    const [actions, requests] = await Promise.all([
      this.db.from('ai_actions').select(ACTION_COLUMNS).eq('conversation_id', conversationId).eq('superseded', false)
        .order('created_at', { ascending: false }).limit(10),
      this.db.from('ai_code_requests').select(CODE_COLUMNS).eq('conversation_id', conversationId)
        .order('created_at', { ascending: false }).limit(8),
    ]);
    const reqRows = (check(requests, 'ai_code_requests') as Row[] | null) ?? [];
    const latest = await this.latestRounds(reqRows.map((r) => s(r.id)), false);
    return {
      actions: ((check(actions, 'ai_actions') as Row[] | null) ?? []).map(normalizeAction),
      codeRequests: reqRows.map((r) => this.toDetail(r, latest.get(s(r.id)) ?? null)),
    };
  }

  // --- 저장 ---
  async getConversation(id: string): Promise<ConversationRow | null> {
    const data = check(
      await this.db.from('ai_conversations').select('id,title,status,scope_type,scope_id').eq('id', id).maybeSingle(),
      'ai_conversations',
    ) as Row | null;
    return data
      ? { id: s(data.id), title: s(data.title), status: s(data.status), scope_type: s(data.scope_type) || 'general', scope_id: (data.scope_id as string | null) ?? null }
      : null;
  }

  async createConversation(title: string): Promise<ConversationRow> {
    const data = check(
      await this.db.from('ai_conversations').insert({ title }).select('id,title,status,scope_type,scope_id').single(),
      'ai_conversations insert',
    ) as Row;
    return { id: s(data.id), title: s(data.title), status: s(data.status), scope_type: s(data.scope_type) || 'general', scope_id: null };
  }

  async updateConversationTitle(id: string, title: string): Promise<void> {
    check(await this.db.from('ai_conversations').update({ title }).eq('id', id), 'ai_conversations update');
  }

  async insertMessage(msg: NewMessage): Promise<string> {
    const data = check(
      await this.db
        .from('ai_messages')
        .insert({
          conversation_id: msg.conversation_id,
          role: msg.role,
          content: msg.content,
          status: msg.status,
          attachments: msg.attachments ?? [],
          sources: msg.sources ?? [],
          tool_calls: msg.tool_calls ?? [],
          commentary: msg.commentary ?? null,
          model: msg.model ?? null,
          run_id: msg.run_id ?? null,
        })
        .select('id')
        .single(),
      'ai_messages insert',
    ) as Row;
    return s(data.id);
  }
}
