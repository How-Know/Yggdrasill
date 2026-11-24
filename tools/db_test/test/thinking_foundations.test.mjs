// 수학적 사고의 토대(C) DB 시험:
// - C1·C2·C3 12개 마스터와 개별 예시 36개 시드 및 재실행 시 중복 방지
// - 슈퍼관리자 편집·예시 확장 열 보존
// - 문항 연결(문제은행 직접 저장, 문항검수 스테이징→확정 반영, C3 정적 문항 관찰 제한)
// - 학생 행동 관찰(근거 필수 조건, 문항 요구 역량과의 분리)

import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import { migrationsDir, openAiTestDb } from '../harness.mjs';

const STUBS_FOR_FOUNDATIONS = `
  create table public.memberships (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    user_id uuid not null,
    role text not null default 'owner',
    unique (academy_id, user_id)
  );
  create table public.students (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    name text not null default '학생',
    withdrawn_at timestamptz
  );
  create table public.resource_files (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid
  );
  create table public.pb_questions (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    stem text not null default '발문',
    meta jsonb not null default '{}'::jsonb
  );
  create table public.textbook_problem_crops (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    book_id uuid not null references public.resource_files(id) on delete cascade,
    grade_label text not null default '1-1',
    big_order int not null default 1,
    mid_order int not null default 1,
    sub_key text not null default 'A',
    sub_index int not null default 0,
    problem_number text not null default '1',
    raw_page int not null default 10,
    storage_key text not null default 'crop.png'
  );
  create table public.textbook_crop_question_links (
    crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
    pb_question_id uuid not null references public.pb_questions(id) on delete cascade,
    academy_id uuid not null references public.academies(id) on delete cascade
  );
  create table public.textbook_problem_analyses (
    crop_id uuid primary key references public.textbook_problem_crops(id) on delete cascade,
    academy_id uuid not null references public.academies(id) on delete cascade,
    staged_changes jsonb not null default '{}'::jsonb,
    concept_proposals jsonb not null default '[]'::jsonb,
    meta_checked_at timestamptz,
    meta_sources jsonb not null default '{}'::jsonb,
    source_correction jsonb,
    updated_at timestamptz not null default now()
  );
  create table public.textbook_review_findings (
    id uuid primary key default gen_random_uuid(),
    academy_id uuid not null references public.academies(id) on delete cascade,
    crop_id uuid not null references public.textbook_problem_crops(id) on delete cascade,
    check_key text not null default '',
    axis text not null default 'validity',
    title text not null default '',
    detail text not null default '',
    status text not null default 'open',
    created_at timestamptz not null default now()
  );
  create function public.textbook_review_linked_pb_question(p_crop_id uuid)
  returns uuid language sql stable as $$
    select pb_question_id from public.textbook_crop_question_links where crop_id = p_crop_id
  $$;
  create function public.textbook_review_overlay_staged(p_item jsonb, p_staged jsonb)
  returns jsonb language sql immutable as $$
    select p_item
  $$;
  create function public.textbook_review_unit_overview_base(
    p_academy_id uuid, p_book_id uuid, p_grade_label text, p_big_order int, p_mid_order int
  ) returns jsonb language sql stable as $$
    select jsonb_build_object(
      'items', coalesce((
        select jsonb_agg(jsonb_build_object(
          'crop_id', c.id,
          'pb_question_id', l.pb_question_id,
          'findings', '[]'::jsonb
        ))
        from public.textbook_problem_crops c
        left join public.textbook_crop_question_links l on l.crop_id = c.id
        where c.academy_id = p_academy_id and c.book_id = p_book_id
      ), '[]'::jsonb)
    )
  $$;
  create function public.textbook_review_apply_staged(p_crop_ids uuid[])
  returns jsonb language sql as $$
    select jsonb_build_object('ok', true, 'applied', coalesce(cardinality(p_crop_ids), 0))
  $$;
`;

const MIGRATION_FILE = '20261123220000_thinking_foundations.sql';

let t;
let ids;

before(async () => {
  t = await openAiTestDb({ files: [] });
  await t.exec(STUBS_FOR_FOUNDATIONS);
  await t.exec(readFileSync(join(migrationsDir, MIGRATION_FILE), 'utf8'));

  const adminId = '00000000-0000-0000-0000-000000000001';
  const staffId = '00000000-0000-0000-0000-000000000002';
  await t.exec(`insert into auth.users (id) values ('${adminId}'), ('${staffId}');`);
  const academy = (await t.one(`insert into public.academies (name) values ('테스트학원') returning id`)).id;
  await t.one(
    `insert into public.memberships (academy_id, user_id, role) values ($1::uuid, $2::uuid, 'staff') returning id`,
    [academy, staffId],
  );
  const student = (
    await t.one(`insert into public.students (academy_id, name) values ($1::uuid, '김학생') returning id`, [academy])
  ).id;
  const book = (await t.one(`insert into public.resource_files (academy_id) values ($1::uuid) returning id`, [academy])).id;
  const question = (
    await t.one(`insert into public.pb_questions (academy_id, stem) values ($1::uuid, '분수방정식') returning id`, [academy])
  ).id;
  const crop = (
    await t.one(
      `insert into public.textbook_problem_crops (academy_id, book_id) values ($1::uuid, $2::uuid) returning id`,
      [academy, book],
    )
  ).id;
  await t.one(
    `insert into public.textbook_crop_question_links (crop_id, pb_question_id, academy_id) values ($1::uuid, $2::uuid, $3::uuid) returning crop_id`,
    [crop, question, academy],
  );

  ids = { adminId, staffId, academy, student, book, question, crop };
});

after(() => t?.db?.close());

test('12개 C 역량(그룹별 4개)과 36개 예시가 시드되고 재실행해도 중복되지 않는다', async () => {
  // 마이그레이션 재실행
  await t.exec(readFileSync(join(migrationsDir, MIGRATION_FILE), 'utf8'));

  const res = await t.asSuperadmin(async () => {
    const row = await t.one(`select public.thinking_foundation_overview() as r`);
    return row.r;
  }, ids.adminId);

  assert.equal(res.items.length, 12);
  assert.equal(res.items.filter((x) => x.group_code === 'C1').length, 4);
  assert.equal(res.items.filter((x) => x.group_code === 'C2').length, 4);
  assert.equal(res.items.filter((x) => x.group_code === 'C3').length, 4);

  let totalExamples = 0;
  for (const item of res.items) {
    assert.equal(item.examples.length, 3, `${item.code} 예시 개수는 3개여야 한다`);
    assert.ok(item.definition.length > 0);
    assert.ok(item.learning_goals.length >= 3);
    assert.ok(item.teaching_principle.length > 0);
    assert.ok(item.observation_criteria.length > 0);
    totalExamples += item.examples.length;
  }
  assert.equal(totalExamples, 36);
});

test('문항 연결: 문제은행 다중 연결, C3 정적 관찰 금지, 문항검수 스테이징→확정 반영', async () => {
  const foundations = await t.all(`select id, code, group_code from public.thinking_foundations order by sort_order`);
  const c102 = foundations.find((f) => f.code === 'C1-02');
  const c208 = foundations.find((f) => f.code === 'C2-08');
  const c309 = foundations.find((f) => f.code === 'C3-09');

  // C3 에 static_item 부여 시 거부
  await assert.rejects(
    () =>
      t.asSuperadmin(
        () =>
          t.one(`select public.pb_question_foundation_links_set($1::uuid, $2::jsonb)`, [
            ids.question,
            JSON.stringify([
              {
                foundation_id: c309.id,
                relevance_level: 'core',
                rationale: '반박',
                observability: 'static_item',
              },
            ]),
          ]),
        ids.adminId,
      ),
    /c3_static_observability_forbidden/,
  );

  // 문항검수 스테이징 시 문제은행 본 테이블은 아직 비어 있어야 한다.
  await t.asSuperadmin(
    () =>
      t.one(`select public.textbook_review_set_foundations($1::uuid, $2::jsonb, 'owner')`, [
        ids.crop,
        JSON.stringify([
          {
            foundation_id: c102.id,
            relevance_level: 'core',
            rationale: '분모가 0이 되지 않는 조건 유지',
            observability: 'static_item',
          },
          {
            foundation_id: c208.id,
            relevance_level: 'supplementary',
            rationale: '무연근 후보 대입 확인',
            observability: 'process_required',
          },
        ]),
      ]),
    ids.adminId,
  );

  // AI 재실행은 사장님 편집을 덮어쓰지 못한다.
  const aiRes = await t.asSuperadmin(
    () => t.one(`select public.textbook_review_set_foundations($1::uuid, '[]'::jsonb, 'ai') as r`, [ids.crop]),
    ids.adminId,
  );
  assert.deepEqual(aiRes.r.skipped, ['foundations']);

  const beforeConfirm = await t.all(
    `select * from public.pb_question_foundation_links where question_id = $1::uuid`,
    [ids.question],
  );
  assert.equal(beforeConfirm.length, 0);

  // overview 에는 스테이징된 2개가 보인다.
  const overview = await t.asSuperadmin(
    () =>
      t.one(
        `select public.textbook_review_unit_overview($1::uuid, $2::uuid, '1-1', 1, 1) as r`,
        [ids.academy, ids.book],
      ),
    ids.adminId,
  );
  assert.equal(overview.r.items[0].foundations.length, 2);

  // 소단원 확정 시 pb_question_foundation_links 로 반영된다.
  await t.asSuperadmin(
    () => t.one(`select public.textbook_review_apply_staged(array[$1::uuid])`, [ids.crop]),
    ids.adminId,
  );

  const afterConfirm = await t.asSuperadmin(
    () => t.one(`select public.pb_question_foundation_links_list(array[$1::uuid]) as r`, [ids.question]),
    ids.adminId,
  );
  assert.equal(afterConfirm.r.items.length, 2);
  assert.equal(afterConfirm.r.items[0].code, 'C1-02');
  assert.equal(afterConfirm.r.items[1].code, 'C2-08');
});

test('학생 관찰 기록: 미실천 기록 시 행동 근거 필수 및 문항 태그와의 독립 저장', async () => {
  const c102 = await t.one(`select id from public.thinking_foundations where code = 'C1-02'`);

  // 미실천(not_practiced)인데 근거가 비어 있으면 거부
  await assert.rejects(
    () =>
      t.asSuperadmin(
        () =>
          t.one(
            `select public.learning_log_foundation_observation($1::uuid, $2::uuid, $3::uuid, 'not_practiced', 'problem_solving', '')`,
            [ids.academy, ids.student, c102.id],
          ),
        ids.adminId,
      ),
    /evidence_required_for_not_practiced/,
  );

  // 구체적 행동 근거와 A·B 선수 확인 함께 저장
  await t.asSuperadmin(
    () =>
      t.one(
        `select public.learning_log_foundation_observation(
           $1::uuid, $2::uuid, $3::uuid, 'not_practiced', 'problem_solving',
           '분수식 정의역 조건은 알고 있었으나 세 문제 연속으로 분모 0 확인을 누락함',
           'sufficient', $4::uuid, $5::uuid
         )`,
        [ids.academy, ids.student, c102.id, ids.question, ids.crop],
      ),
    ids.adminId,
  );

  const recent = await t.asSuperadmin(
    () =>
      t.one(`select public.student_foundation_observations_recent($1::uuid, $2::uuid) as r`, [
        ids.academy,
        ids.student,
      ]),
    ids.adminId,
  );
  assert.equal(recent.r.items.length, 1);
  assert.equal(recent.r.items[0].foundation_code, 'C1-02');
  assert.equal(recent.r.items[0].ab_prerequisite_check, 'sufficient');
});
