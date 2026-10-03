// ReviewStore의 Supabase 구현. 작업자 요청 뒤 서버에서 service role로 돈다.
// 대화 기록은 ai_think와 같은 조회(SupabaseThinkStore)를 써서 '답변에서 제외'한 문답을 뺀다.

import type { NewMessage } from '../ai_think/chat.ts';
import type { MemoryRow, MessageRow } from '../ai_think/context.ts';
import { SupabaseThinkStore, type SupabaseLike } from '../ai_think/store.ts';
import type { ReviewRequest, ReviewStore } from './code_review.ts';

type Row = Record<string, unknown>;

function obj(v: unknown): Record<string, unknown> {
  return v && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : {};
}

export class SupabaseReviewStore implements ReviewStore {
  private readonly think: SupabaseThinkStore;

  constructor(private readonly db: SupabaseLike) {
    this.think = new SupabaseThinkStore(db);
  }

  async loadRequest(id: string): Promise<ReviewRequest | null> {
    const req = await this.db
      .from('ai_code_requests')
      .select('id,title,mode,status,round,max_rounds,conversation_id,created_by,request')
      .eq('id', id)
      .maybeSingle();
    if (req.error) throw new Error(`ai_code_requests: ${req.error.message}`);
    const r = req.data as Row | null;
    if (!r) return null;
    const rounds = await this.db
      .from('ai_code_request_rounds')
      .select('round,result,result_text,think_questions')
      .eq('request_id', id)
      .eq('status', 'finished')
      .order('round');
    if (rounds.error) throw new Error(`ai_code_request_rounds: ${rounds.error.message}`);
    return {
      id: String(r.id),
      title: String(r.title ?? ''),
      mode: String(r.mode ?? 'investigate'),
      status: String(r.status ?? ''),
      round: Number(r.round ?? 0),
      max_rounds: Number(r.max_rounds ?? 2),
      conversation_id: (r.conversation_id as string | null) ?? null,
      created_by: (r.created_by as string | null) ?? null,
      request: obj(r.request),
      rounds: ((rounds.data as Row[] | null) ?? []).map((x) => ({
        round: Number(x.round ?? 0),
        result: x.result == null ? null : obj(x.result),
        result_text: (x.result_text as string | null) ?? null,
        think_questions: Array.isArray(x.think_questions) ? x.think_questions.filter((q): q is string => typeof q === 'string') : [],
      })),
    };
  }

  listMessages(conversationId: string, limit: number): Promise<MessageRow[]> {
    return this.think.listMessages(conversationId, limit);
  }

  listActiveMemories(kinds: string[]): Promise<MemoryRow[]> {
    return this.think.listActiveMemories(kinds);
  }

  insertMessage(msg: NewMessage): Promise<string> {
    return this.think.insertMessage(msg);
  }

  async followup(id: string, prompt: string, questions: string[]): Promise<boolean> {
    const { data, error } = await this.db.rpc('ai_code_bridge_followup', { p_request_id: id, p_prompt: prompt, p_questions: questions });
    if (error) throw new Error(`ai_code_bridge_followup: ${error.message}`);
    return (data as Row | null)?.ok === true;
  }

  async proposePlan(
    requestId: string,
    messageId: string,
    title: string,
    spec: Record<string, unknown>,
    preview: Record<string, unknown>,
  ): Promise<string | null> {
    const { data, error } = await this.db.rpc('ai_code_bridge_propose_plan', {
      p_request_id: requestId,
      p_message_id: messageId,
      p_title: title,
      p_spec: spec,
      p_preview: preview,
    });
    if (error) throw new Error(`ai_code_bridge_propose_plan: ${error.message}`);
    return typeof data === 'string' ? data : null;
  }

  async reviewDone(id: string, status: 'done' | 'skipped' | 'error', messageId: string | null, err: string | null): Promise<void> {
    const { error } = await this.db.rpc('ai_code_bridge_review_done', {
      p_request_id: id,
      p_status: status,
      p_message_id: messageId,
      p_error: err,
    });
    if (error) throw new Error(`ai_code_bridge_review_done: ${error.message}`);
  }
}
