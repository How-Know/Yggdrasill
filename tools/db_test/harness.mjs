// 일회용 시험 DB(PGlite, 메모리)에 AI 영역 DB 함수 파일을 순서대로 적용한다. 운영 DB에는 절대 연결하지 않는다.
// Supabase가 제공하는 것(auth, storage, 역할, is_superadmin)은 최소한의 가짜로 대신한다.
// 설계: docs/architecture/ai-code-bridge.md

import { readdirSync, readFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { PGlite } from '@electric-sql/pglite';

const here = dirname(fileURLToPath(import.meta.url));
export const migrationsDir = resolve(here, '..', '..', 'supabase', 'migrations');

/** AI 영역 파일: 이름에 _ai_가 들어간 것. 이 밖의 테이블을 쓰는 파일은 이 시험 DB로 검사할 수 없다. */
export const AI_MIGRATION = /^\d{14}_ai_[a-z0-9_]+\.sql$/;

export function aiMigrations(dir = migrationsDir) {
  return readdirSync(dir)
    .filter((f) => AI_MIGRATION.test(f))
    .sort();
}

const STUBS = `
  create role anon; create role authenticated; create role service_role;
  create schema auth;
  create table auth.users (id uuid primary key);
  create function auth.uid() returns uuid language sql stable as
    $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
  create function auth.role() returns text language sql stable as
    $$ select coalesce(nullif(current_setting('request.jwt.claim.role', true), ''), current_user::text) $$;
  create schema storage;
  create table storage.buckets (
    id text primary key, name text not null, public boolean default false,
    file_size_limit bigint, allowed_mime_types text[]
  );
  create table storage.objects (
    id uuid primary key default gen_random_uuid(), bucket_id text references storage.buckets(id),
    name text, owner uuid, created_at timestamptz default now()
  );
  alter table storage.objects enable row level security;
  create function public.is_superadmin() returns boolean language sql stable as
    $$ select coalesce(current_setting('test.superadmin', true), '') = 'on' $$;
  create function public.set_updated_at() returns trigger language plpgsql as
    $$ begin new.updated_at := now(); return new; end $$;
  create table public.academies (id uuid primary key default gen_random_uuid(), name text);
  grant usage on schema public, auth, storage to anon, authenticated, service_role;
  grant execute on all functions in schema auth to anon, authenticated, service_role;
  -- Supabase 기본값: public의 새 테이블·함수는 세 역할 모두에게 열려 있고, 파일이 필요한 만큼 막는다.
  alter default privileges in schema public grant all on tables to anon, authenticated, service_role;
  alter default privileges in schema public grant all on sequences to anon, authenticated, service_role;
  alter default privileges in schema public grant execute on functions to anon, authenticated, service_role;
`;

/**
 * 새 시험 DB를 열고 AI 영역 파일을 모두 적용한다.
 * 실패하면 어느 파일에서 막혔는지 알려 준다.
 */
export async function openAiTestDb({ files = aiMigrations(), dir = migrationsDir } = {}) {
  const db = new PGlite();
  await db.exec(STUBS);
  for (const f of files) {
    try {
      await db.exec(readFileSync(join(dir, f), 'utf8'));
    } catch (e) {
      await db.close().catch(() => {});
      const err = new Error(`${f} 적용 실패: ${e.message}`);
      err.file = f;
      throw err;
    }
  }
  return wrap(db);
}

function wrap(db) {
  const one = async (sql, params = []) => (await db.query(sql, params)).rows[0];
  const all = async (sql, params = []) => (await db.query(sql, params)).rows;
  const as = async (setup, fn) => {
    await db.exec(setup);
    try {
      return await fn();
    } finally {
      await db.exec(`reset role; set test.superadmin = 'off'; set request.jwt.claim.sub = '';`);
    }
  };
  return {
    db,
    one,
    all,
    exec: (sql) => db.exec(sql),
    /** 매니저앱 슈퍼관리자로 실행 */
    asSuperadmin: (fn, userId = '') =>
      as(`set test.superadmin = 'on'; set request.jwt.claim.sub = '${userId}'; set role authenticated;`, fn),
    /** 로그인했지만 슈퍼관리자가 아닌 사용자 */
    asUser: (fn) => as(`set role authenticated;`, fn),
    asAnon: (fn) => as(`set role anon;`, fn),
    /** Edge Function(service role) */
    asService: (fn) => as(`set role service_role;`, fn),
    /** 기대한 오류로 실패하는지 */
    async rejects(sql, params, pattern) {
      try {
        await db.query(sql, params);
      } catch (e) {
        if (!pattern.test(String(e.message))) throw new Error(`expected ${pattern}, got ${e.message}`);
        return;
      }
      throw new Error(`expected failure ${pattern}: ${sql}`);
    },
    close: () => db.close(),
  };
}
