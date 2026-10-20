// 교재 검수 DB 시험용 일회용 DB. 운영 교재 표에서 검수 파일이 쓰는 열만 같은 이름·형식으로 만들고
// 검수 파일(수동 보호, 검수 기반)을 적용한다. 운영 DB에는 연결하지 않는다.
// 운영 정의: supabase/migrations 의 20260423120000(크롭), 20260426120000(정답), 20260426120500(해설 좌표),
// 20260709010000(채점 캐시), 20260501000000·20260502063000(정답 그림), 20260724100000(문항 연결).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { migrationsDir, openAiTestDb } from './harness.mjs';

export const TEXTBOOK_REVIEW_FILES = [
  '20261014233000_textbook_manual_guard.sql',
  '20261014233500_textbook_review_core.sql',
];

const MEMBER_TABLES = [
  'pb_questions',
  'textbook_problem_crops',
  'textbook_crop_question_links',
  'textbook_problem_answers',
  'textbook_problem_solution_refs',
  'textbook_answer_render_assets',
  'answer_render_assets',
];

const TEXTBOOK_STUBS = `
  create table public.memberships (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    user_id uuid not null,
    role text not null check (role in ('owner', 'admin', 'staff')),
    unique (academy_id, user_id)
  );
  alter table public.memberships enable row level security;
  create policy "memberships self" on public.memberships for select using (user_id = auth.uid());

  create table public.resource_files (id uuid primary key default gen_random_uuid(), academy_id uuid);

  create table public.pb_questions (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    question_uid uuid not null default gen_random_uuid(),
    question_type text not null default '미분류',
    stem text not null default '',
    choices jsonb not null default '[]'::jsonb,
    figure_refs jsonb not null default '[]'::jsonb,
    equations jsonb not null default '[]'::jsonb,
    objective_choices jsonb not null default '[]'::jsonb,
    objective_answer_key text not null default '',
    subjective_answer text not null default '',
    meta jsonb not null default '{}'::jsonb,
    unique (academy_id, question_uid)
  );

  create table public.textbook_problem_crops (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    book_id uuid not null references public.resource_files(id) on delete cascade,
    grade_label text not null,
    big_order int not null,
    mid_order int not null,
    sub_key text not null,
    sub_index int not null default 0,
    item_name text not null default '',
    raw_page int not null,
    display_page int,
    problem_number text not null,
    label text not null default '',
    is_set_header boolean not null default false,
    item_region_1k int[],
    storage_bucket text not null default 'textbook-crops',
    storage_key text not null,
    file_size_bytes bigint,
    content_hash text,
    pb_question_uid uuid,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    unique (academy_id, book_id, grade_label, big_order, mid_order, sub_key, sub_index, problem_number)
  );

  create table public.textbook_crop_question_links (
    crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
    pb_question_id uuid not null unique references public.pb_questions(id) on delete cascade,
    academy_id uuid not null references public.academies(id) on delete cascade,
    source text not null default 'test'
  );

  create table public.textbook_problem_answers (
    crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
    academy_id uuid not null references public.academies(id) on delete cascade,
    answer_kind text not null check (answer_kind in ('objective', 'subjective', 'image')),
    answer_text text,
    answer_latex_2d text,
    answer_source text not null default 'vlm' check (answer_source in ('vlm', 'manual')),
    raw_page int,
    display_page int,
    bbox_1k int[],
    note text,
    answer_image_bucket text not null default '',
    answer_image_path text not null default '',
    answer_image_content_hash text,
    extracted_at timestamptz not null default now(),
    edited_at timestamptz,
    updated_at timestamptz not null default now()
  );
  create trigger trg_textbook_problem_answers_updated_at
    before update on public.textbook_problem_answers
    for each row execute function public.set_updated_at();

  create table public.textbook_problem_solution_refs (
    crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
    academy_id uuid not null references public.academies(id) on delete cascade,
    raw_page int not null,
    display_page int,
    number_region_1k int[] not null,
    content_region_1k int[],
    source_kind text not null default 'sol' check (source_kind in ('sol', 'body', 'none')),
    extracted_at timestamptz not null default now(),
    edited_at timestamptz,
    updated_at timestamptz not null default now()
  );
  create trigger trg_textbook_problem_solution_refs_updated_at
    before update on public.textbook_problem_solution_refs
    for each row execute function public.set_updated_at();

  create table public.student_grading_ai_cache (
    id uuid primary key default gen_random_uuid(),
    crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
    cache_key text not null,
    verdict jsonb not null default '{}'::jsonb,
    unique (crop_id, cache_key)
  );
  alter table public.student_grading_ai_cache enable row level security;

  create table public.textbook_answer_render_assets (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
    render_error text not null default '',
    updated_at timestamptz not null default now()
  );

  create table public.answer_render_assets (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    source_kind text not null check (source_kind in ('textbook_crop', 'pb_question')),
    source_id uuid not null,
    render_error text not null default ''
  );

  ${MEMBER_TABLES.map(
    (t) => `
  alter table public.${t} enable row level security;
  create policy "${t} member" on public.${t} for all
    using (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = ${t}.academy_id))
    with check (exists (select 1 from public.memberships m where m.user_id = auth.uid() and m.academy_id = ${t}.academy_id));`,
  ).join('\n')}
`;

/** 교재 표 대역 + 검수 파일을 적용한 시험 DB. asMember(userId, fn) 로 학원 직원 권한을 흉내 낸다. */
export async function openTextbookTestDb() {
  const t = await openAiTestDb({ files: [] });
  await t.exec(TEXTBOOK_STUBS);
  for (const f of TEXTBOOK_REVIEW_FILES) {
    try {
      await t.exec(readFileSync(join(migrationsDir, f), 'utf8'));
    } catch (e) {
      await t.close().catch(() => {});
      throw new Error(`${f} 적용 실패: ${e.message}`);
    }
  }
  return {
    ...t,
    async asMember(userId, fn) {
      await t.exec(`set request.jwt.claim.sub = '${userId}'; set role authenticated;`);
      try {
        return await fn();
      } finally {
        await t.exec(`reset role; set request.jwt.claim.sub = '';`);
      }
    },
  };
}

/** 학원·교재·소속 직원 한 벌. */
export async function seedAcademy(t) {
  const academy = (await t.one(`insert into academies (name) values ('시험 학원') returning id`)).id;
  const book = (await t.one(`insert into resource_files (academy_id) values ($1::uuid) returning id`, [academy])).id;
  const staff = '00000000-0000-4000-8000-000000000001';
  const outsider = '00000000-0000-4000-8000-000000000002';
  await t.one(
    `insert into memberships (academy_id, user_id, role) values ($1::uuid, $2::uuid, 'owner') returning id`,
    [academy, staff],
  );
  return { academy, book, staff, outsider };
}

/** 중1-1 · 대단원 0 · 중단원 mid 범위의 크롭 하나. 시험마다 mid 를 달리 써서 범위를 나눈다. */
export async function seedCrop(t, { academy, book }, { number, mid = 0, subKey = 'B', subIndex = 0, page = 12, storageKey, fileSize = null, pbUid = null, setHeader = false } = {}) {
  return (await t.one(
    `insert into textbook_problem_crops
       (academy_id, book_id, grade_label, big_order, mid_order, sub_key, sub_index, raw_page, problem_number,
        storage_key, file_size_bytes, pb_question_uid, is_set_header, item_region_1k)
     values ($1::uuid, $2::uuid, '1-1', 0, $3::int, $4, $5::int, $6::int, $7, $8, $9::bigint, $10::uuid, $11::boolean,
             array[100, 60, 300, 940])
     returning id`,
    [academy, book, mid, subKey, subIndex, page, number, storageKey ?? `k/${mid}/${subKey}${subIndex}/${number}.png`, fileSize, pbUid, setHeader],
  )).id;
}
