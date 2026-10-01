import { corsHeaders } from '../cors.ts';
import { sha256Hex } from '../hash.ts';
import { createAdminClient, createUserClient } from '../supabase.ts';
import type { Db } from './db.ts';

export interface AuthContext {
  userId: string;
  email: string | null;
  admin: Db;
  userClient: Db;
}

export function bearerToken(req: Request): string {
  return (req.headers.get('Authorization') ?? '').replace(/^Bearer\s+/i, '').trim();
}

export function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });
}

export function errorResponse(status: number, error: string, message?: string): Response {
  return jsonResponse({ ok: false, error, message: message ?? error }, status);
}

export async function authenticate(req: Request): Promise<AuthContext | null> {
  const token = bearerToken(req);
  if (!token) return null;
  const admin = createAdminClient();
  const { data, error } = await admin.auth.getUser(token);
  if (error || !data?.user) return null;
  return {
    userId: data.user.id,
    email: data.user.email ?? null,
    admin,
    userClient: createUserClient(req),
  };
}

/** RLS와 같은 기준(public.is_superadmin)으로 판단한다. */
export async function isSuperadmin(ctx: AuthContext): Promise<boolean> {
  const { data, error } = await ctx.userClient.rpc('is_superadmin');
  return !error && data === true;
}

/** 요청한 학원(없으면 첫 소속 학원)의 구성원이면 그 academy_id, 아니면 null. */
export async function resolveMemberAcademy(ctx: AuthContext, requested?: string | null): Promise<string | null> {
  let query = ctx.admin.from('memberships').select('academy_id').eq('user_id', ctx.userId);
  if (requested) query = query.eq('academy_id', requested);
  const { data, error } = await query.limit(1);
  if (error || !Array.isArray(data) || data.length === 0) return null;
  return (data[0]?.academy_id as string | undefined) ?? null;
}

/** OpenAI safety_identifier 용. 사용자 id를 그대로 보내지 않는다. */
export function safetyIdentifier(userId: string): Promise<string> {
  return sha256Hex(`ygg:${userId}`);
}
