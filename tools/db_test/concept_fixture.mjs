// 개념 탭 DB 시험용 일회용 DB. 운영 개념·교재 표에서 새 파일이 참조하는 열만 같은 이름·형식으로 만들고
// AI 영역 파일 다음에 정리 기준·연결·출처·초안 파일을 적용한다. 운영 DB에는 연결하지 않는다.
// 운영 정의: supabase/migrations 의 0014(resource_files·memberships), 0021·20260422161500(resource_file_links), 0071(concept_categories), 0072(concepts),
// 0075·0076(concept_families, concepts.family_id·version_label), 0072(concept_shortcuts), 0080(operation_prompts).

import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { migrationsDir, openAiTestDb } from './harness.mjs';

export const CONCEPT_FILES = [
  '20261016100000_concept_criteria_sources.sql',
  '20261017100000_concept_drafts.sql',
  '20261017120000_concept_types.sql',
  // ai_actions·ai_conversations(AI 영역 파일)를 쓴다. openConceptTestDb 가 AI 영역 파일을 먼저 적용한다.
  '20261017140000_concept_draft_chat.sql',
  '20261017160000_concept_draft_pages_20.sql',
  '20261018100000_concept_source_order.sql',
  '20261018120000_concept_anchor_links.sql',
  '20261019100000_concept_draft_jobs.sql',
  '20261020100000_concept_statements.sql',
  '20261020120000_concept_relations.sql',
  '20261020140000_concept_content_drafts.sql',
  '20261020160000_concept_source_evidence.sql',
  '20261020180000_concept_draft_compare.sql',
  '20261023100000_course_maps.sql',
  '20261023120000_course_map_think_actions.sql',
  // 개념 지우기 보호: 붙은 것이 있으면 개념·폴더를 지우지 않는다. 운영과 같게 모든 개념 시험이 이 상태에서 돈다.
  '20261023140000_concept_delete_guard.sql',
  '20261023160000_concept_review.sql',
  '20261023180000_concept_relation_types.sql',
  '20261024100000_concept_source_pages.sql',
  '20261024120000_course_placement_log.sql',
  '20261026100000_concept_review_jobs.sql',
  '20261026120000_concept_review_job_batch.sql',
  '20261026140000_concept_review_integrated.sql',
  '20261027010000_concept_review_dependency.sql',
  '20261027230000_concept_review_first_pass.sql',
  '20261028010000_concept_review_ref_limit.sql',
  '20261028020000_concept_review_failure_page.sql',
  '20261028030000_concept_review_status_single_pass.sql',
  '20261028150000_concept_review_compared_snapshot.sql',
  '20261028190000_concept_review_progress_snapshot.sql',
];

const CONCEPT_STUBS = `
  create table public.memberships (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    user_id uuid not null,
    role text not null default 'owner',
    unique (academy_id, user_id)
  );
  alter table public.memberships enable row level security;
  create policy "memberships self" on public.memberships for select using (user_id = auth.uid());

  create table public.resource_files (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    name text not null default ''
  );
  alter table public.resource_files enable row level security;
  create policy resource_files_select on public.resource_files for select
    using (exists (select 1 from public.memberships s where s.academy_id = resource_files.academy_id and s.user_id = auth.uid()));

  create table public.resource_file_links (
    id bigserial primary key,
    academy_id uuid not null references public.academies(id) on delete cascade,
    file_id uuid references public.resource_files(id) on delete cascade,
    grade text,
    url text,
    storage_driver text,
    storage_bucket text,
    storage_key text,
    migration_status text not null default 'legacy',
    file_size_bytes bigint,
    content_hash text
  );
  alter table public.resource_file_links enable row level security;

  create table public.concept_categories (
    id uuid primary key default gen_random_uuid(),
    name text not null,
    parent_id uuid references public.concept_categories(id) on delete cascade,
    code text unique,
    depth int not null default 0,
    sort_order int not null default 0,
    created_at timestamptz not null default now()
  );
  alter table public.concept_categories enable row level security;
  create policy concept_categories_all on public.concept_categories for all to authenticated using (true) with check (true);
  create table public.concept_families (
    id uuid primary key default gen_random_uuid(),
    canonical_name text not null unique
  );
  create table public.concepts (
    id uuid primary key default gen_random_uuid(),
    kind text not null default 'definition' check (kind in ('definition', 'theorem')),
    sub_type text,
    name text not null,
    content text not null default '',
    level int not null default 1 check (level in (1, 2, 3)),
    main_category_id uuid not null references public.concept_categories(id) on delete cascade,
    sort_order int default 0,
    family_id uuid not null references public.concept_families(id),
    version_label text not null default '',
    created_at timestamptz default now(),
    updated_at timestamptz default now()
  );
  create unique index concepts_family_version_unique on public.concepts (family_id, version_label);
  alter table public.concepts enable row level security;
  create policy concepts_all on public.concepts for all to authenticated using (true) with check (true);
  create table public.concept_shortcuts (
    category_id uuid not null references public.concept_categories(id) on delete cascade,
    concept_id uuid not null references public.concepts(id) on delete cascade,
    sort_order int default 0,
    created_at timestamptz default now(),
    primary key (category_id, concept_id)
  );
  alter table public.concept_shortcuts enable row level security;
  create policy concept_shortcuts_all on public.concept_shortcuts for all to authenticated using (true) with check (true);
  create table public.operation_prompts (
    id uuid primary key default gen_random_uuid(),
    concept_id uuid not null references public.concepts(id) on delete cascade,
    level_label text not null,
    prompt text not null default ''
  );
`;

/** 시험용 개념 한 줄. 운영과 같이 이름별 묶음(concept_families)에 넣는다. */
export async function insertConcept(t, name, folder, content = '1보다 큰 자연수 중…') {
  await t.one(
    `insert into concept_families (canonical_name) values ($1) on conflict (canonical_name) do update set canonical_name = excluded.canonical_name returning id`,
    [name],
  );
  return (await t.one(
    `insert into concepts (name, content, main_category_id, family_id, version_label)
     select $1, $2, $3::uuid, f.id, 'v' || (select count(*) from concepts c where c.family_id = f.id)
       from concept_families f where f.canonical_name = $1
     returning id`,
    [name, content, folder],
  )).id;
}

export async function openConceptTestDb(files = CONCEPT_FILES) {
  const t = await openAiTestDb();
  await t.exec(CONCEPT_STUBS);
  // 출처 학년 → 교재 과정 키(운영 정의 그대로). 같은 파일의 다른 문장은 교재 표를 써서 함수만 떼어 온다.
  const aliases = readFileSync(join(migrationsDir, '20260429162000_textbook_course_key_aliases.sql'), 'utf8');
  await t.exec(aliases.match(/create or replace function public\._textbook_course_info[\s\S]*?\$\$;/)[0]);
  for (const f of files) {
    try {
      await t.exec(readFileSync(join(migrationsDir, f), 'utf8'));
    } catch (e) {
      await t.close().catch(() => {});
      throw new Error(`${f} 적용 실패: ${e.message}`);
    }
  }
  return t;
}

/** 운영자(슈퍼관리자이자 학원 소속), 학원 밖 운영자, 일반 사용자, 개념 둘, 교재 둘(학원 하나씩). */
export async function seedConcepts(t) {
  const operator = '00000000-0000-4000-8000-0000000000a1';
  const otherOperator = '00000000-0000-4000-8000-0000000000a2';
  const user = '00000000-0000-4000-8000-0000000000a3';
  for (const id of [operator, otherOperator, user]) {
    await t.exec(`insert into auth.users (id) values ('${id}')`);
  }
  const academy = (await t.one(`insert into academies (name) values ('시험 학원') returning id`)).id;
  const otherAcademy = (await t.one(`insert into academies (name) values ('다른 학원') returning id`)).id;
  await t.one(`insert into memberships (academy_id, user_id) values ($1::uuid, $2::uuid) returning id`, [academy, operator]);
  const book = (await t.one(
    `insert into resource_files (academy_id, name) values ($1::uuid, '개념+유형 중1-1') returning id`,
    [academy],
  )).id;
  const otherBook = (await t.one(
    `insert into resource_files (academy_id, name) values ($1::uuid, '다른 학원 교재') returning id`,
    [otherAcademy],
  )).id;
  const folder = (await t.one(`insert into concept_categories (name) values ('소인수분해') returning id`)).id;
  const concept = await insertConcept(t, '소수', folder);
  const concept2 = await insertConcept(t, '합성수', folder);
  return { operator, otherOperator, user, academy, otherAcademy, book, otherBook, folder, concept, concept2 };
}
