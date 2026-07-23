-- 학생 교재 문항 신고·보류.
--
-- 설계 (2026-07-21 합의):
--   * 학생이 문항을 신고하면 status='open'(검토 중)으로 즉시 보류된다.
--   * 보류(open/accepted) 문항은 정답률 통계의 분자·분모에서 모두 제외된다.
--     페이지/교재 완료 판정도 보류 문항을 제외한 나머지 기준으로 계산되므로
--     신고 문항을 풀지 않아도 완료 처리될 수 있다.
--   * 선생님(스태프)이 학습앱에서 판정:
--       accepted — 신고 인정. 문항은 계속 통계 제외(무효 처리).
--       rejected — 반려. resolution으로 후속 처리를 기록:
--         regrade — 저장된 답을 그 시점에 채점(답이 있던 경우)
--         redo    — 재풀이 요청 (별도 '확인 문제'로 노출; 원 과제 점수 불변)
--         waive   — 면제
--   * 재풀이 결과는 학업 통계에만 반영하고 원래 과제 성적에는 반영하지 않는다.
--     (재풀이 큐 UI는 후속 작업; 본 마이그레이션은 데이터 모델까지 준비)

-- ---------------------------------------------------------------------------
-- 1) 신고 테이블
-- ---------------------------------------------------------------------------
create table if not exists public.student_textbook_problem_reports (
  id uuid primary key default gen_random_uuid(),
  academy_id uuid not null references public.academies(id) on delete cascade,
  student_id uuid not null references public.students(id) on delete cascade,
  book_id uuid not null references public.resource_files(id) on delete cascade,
  grade_label text not null,
  crop_id uuid not null
    references public.textbook_problem_crops(id) on delete cascade,

  issue_types text[] not null default array[]::text[],
  note text not null default '',

  -- open: 검토 중(보류) / accepted: 신고 인정(계속 제외) / rejected: 반려
  status text not null default 'open',
  -- rejected일 때의 후속 처리
  resolution text,
  resolution_note text not null default '',
  resolved_by uuid,
  resolved_at timestamptz,

  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),

  constraint sta_reports_status_chk
    check (status in ('open', 'accepted', 'rejected')),
  constraint sta_reports_resolution_chk
    check (resolution is null or resolution in ('regrade', 'redo', 'waive')),
  constraint sta_reports_issue_types_nonempty_chk
    check (cardinality(issue_types) > 0)
);

-- 학생당 문항 하나에 열린 신고는 1건만.
create unique index if not exists uq_sta_reports_open_per_crop
  on public.student_textbook_problem_reports (student_id, crop_id)
  where status = 'open';

create index if not exists idx_sta_reports_student_book
  on public.student_textbook_problem_reports (student_id, book_id, grade_label);
create index if not exists idx_sta_reports_academy_status
  on public.student_textbook_problem_reports (academy_id, status, created_at desc);

alter table public.student_textbook_problem_reports enable row level security;

-- 조회: 본인(학생 계정) 또는 학원 스태프.
drop policy if exists sta_reports_select
  on public.student_textbook_problem_reports;
create policy sta_reports_select on public.student_textbook_problem_reports
  for select to authenticated
  using (
    exists (
      select 1 from public.student_app_accounts a
      where a.user_id = auth.uid()
        and a.student_id = student_textbook_problem_reports.student_id
    )
    or exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_textbook_problem_reports.academy_id
    )
  );

-- 학생 쓰기는 RPC(security definer)로만. 스태프는 판정을 위해 직접 update 허용.
drop policy if exists sta_reports_staff_update
  on public.student_textbook_problem_reports;
create policy sta_reports_staff_update
  on public.student_textbook_problem_reports
  for update to authenticated
  using (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_textbook_problem_reports.academy_id
    )
  )
  with check (
    exists (
      select 1 from public.memberships m
      where m.user_id = auth.uid()
        and m.academy_id = student_textbook_problem_reports.academy_id
    )
  );

-- ---------------------------------------------------------------------------
-- 2) 보류 판정 헬퍼 (open/accepted = 통계 제외)
-- ---------------------------------------------------------------------------
create or replace function public._student_crop_on_hold(
  p_student_id uuid,
  p_crop_id uuid
) returns boolean
language sql stable set search_path = public as $$
  select exists (
    select 1 from public.student_textbook_problem_reports r
    where r.student_id = p_student_id
      and r.crop_id = p_crop_id
      and r.status in ('open', 'accepted')
  );
$$;

-- ---------------------------------------------------------------------------
-- 3) 학생 신고 RPC
-- ---------------------------------------------------------------------------
create or replace function public.student_report_textbook_problem(
  p_book_id uuid,
  p_grade_label text,
  p_crop_id uuid,
  p_issue_types text[],
  p_note text default ''
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_crop_ok boolean;
  v_report_id uuid;
  v_types text[];
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_types := (
    select coalesce(array_agg(distinct t), array[]::text[])
    from unnest(coalesce(p_issue_types, array[]::text[])) as t
    where btrim(t) <> ''
  );
  if cardinality(v_types) = 0 then
    return jsonb_build_object('ok', false, 'error', 'missing_issue_types');
  end if;

  select exists (
    select 1 from public.textbook_problem_crops c
    where c.id = p_crop_id
      and c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
  ) into v_crop_ok;
  if not v_crop_ok then
    return jsonb_build_object('ok', false, 'error', 'crop_not_found');
  end if;

  -- 이미 보류 중이면 그대로 반환 (open은 유니크 인덱스로도 보호).
  select r.id into v_report_id
  from public.student_textbook_problem_reports r
  where r.student_id = v_student
    and r.crop_id = p_crop_id
    and r.status in ('open', 'accepted')
  limit 1;
  if v_report_id is not null then
    return jsonb_build_object(
      'ok', true, 'report_id', v_report_id, 'already_reported', true
    );
  end if;

  insert into public.student_textbook_problem_reports (
    academy_id, student_id, book_id, grade_label, crop_id, issue_types, note
  ) values (
    v_academy, v_student, p_book_id, p_grade_label, p_crop_id,
    v_types, coalesce(btrim(p_note), '')
  )
  returning id into v_report_id;

  return jsonb_build_object(
    'ok', true, 'report_id', v_report_id, 'already_reported', false
  );
end; $$;

revoke all on function
  public.student_report_textbook_problem(uuid, text, uuid, text[], text)
  from public;
grant execute on function
  public.student_report_textbook_problem(uuid, text, uuid, text[], text)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 페이지 문항 목록 — report_status 포함
-- ---------------------------------------------------------------------------
drop function if exists public.student_textbook_page_problems(uuid, text, integer);

create or replace function public.student_textbook_page_problems(
  p_book_id uuid,
  p_grade_label text,
  p_raw_page integer
) returns table(
  crop_id uuid,
  problem_number text,
  label text,
  answer_kind text,
  grading_mode text,
  my_answer text,
  my_correct boolean,
  attempt_count integer,
  graded_by text,
  flags text[],
  report_status text
)
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  select
    c.id as crop_id,
    c.problem_number,
    c.label,
    a.answer_kind,
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ) as grading_mode,
    r.last_answer as my_answer,
    r.is_correct as my_correct,
    r.attempt_count,
    r.graded_by,
    r.flags,
    rp.status as report_status
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id and r.student_id = v_student
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) rp on true
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null)
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
         then c.problem_number::int else 2147483647 end,
    c.problem_number;
end; $$;

revoke all on function public.student_textbook_page_problems(uuid, text, integer) from public;
grant execute on function public.student_textbook_page_problems(uuid, text, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- 5) 단원 트리 — 보류 문항을 total/graded/correct에서 제외
-- ---------------------------------------------------------------------------
create or replace function public.student_textbook_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql security definer set search_path = public as $$
declare
  v_academy uuid; v_student uuid;
  v_payload jsonb;
  v_page_offset integer;
  v_pages jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select t.payload, t.page_offset into v_payload, v_page_offset
  from public.textbook_metadata t
  where t.academy_id = v_academy
    and t.book_id = p_book_id
    and t.grade_label = p_grade_label;

  select coalesce(jsonb_agg(row_to_json(p) order by p.big_order, p.mid_order, p.sub_key, p.raw_page), '[]'::jsonb)
  into v_pages
  from (
    select
      c.big_order, c.mid_order, c.sub_key,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where h.crop_id is null) as total,
      count(r.id) filter (where h.crop_id is null) as graded,
      count(r.id) filter (where r.is_correct and h.crop_id is null) as correct,
      count(*) filter (where h.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id and r.student_id = v_student
    left join lateral (
      select s.crop_id
      from public.student_textbook_problem_reports s
      where s.student_id = v_student
        and s.crop_id = c.id
        and s.status in ('open', 'accepted')
      limit 1
    ) h on true
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and not c.is_set_header
      and (
        (a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null)
        or a.answer_kind = 'image'
      )
    group by c.big_order, c.mid_order, c.sub_key, c.raw_page
  ) p;

  return jsonb_build_object(
    'payload', coalesce(v_payload, '{}'::jsonb),
    'page_offset', v_page_offset,
    'pages', v_pages
  );
end; $$;

revoke all on function public.student_textbook_unit_tree(uuid, text) from public;
grant execute on function public.student_textbook_unit_tree(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 6) 교재 카드 목록 — 보류 문항 제외 (20260716033000 버전 재정의)
-- ---------------------------------------------------------------------------
drop function if exists public.student_list_textbooks();
create function public.student_list_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  book_description text,
  book_color integer,
  series text,
  cover_ref text,
  total_problems bigint,
  graded_count bigint,
  correct_count bigint,
  completed_count bigint,
  stage_progress jsonb,
  last_raw_page integer,
  last_display_page integer,
  last_activity timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with books as (
    select distinct l.book_id, l.grade_label
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id
     and l.academy_id = f.academy_id
    where f.academy_id = v_academy
      and f.student_id = v_student
      and coalesce(f.enabled, true)
  ),
  gradable as (
    select
      c.book_id,
      c.grade_label,
      c.id as crop_id,
      c.sub_key,
      c.raw_page,
      c.display_page
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    where c.academy_id = v_academy
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
      -- 보류(검토 중/인정) 문항은 통계에서 제외
      and not public._student_crop_on_hold(v_student, c.id)
  ),
  teacher_done as (
    select distinct g.crop_id
    from gradable g
    join public.homework_item_units u
      on u.academy_id = v_academy
     and u.student_id = v_student
     and u.book_id = g.book_id
     and u.grade_label = g.grade_label
    join public.homework_items h
      on h.id = u.homework_item_id
     and h.student_id = v_student
     and h.academy_id = v_academy
    where (
      h.completed_at is not null
      or coalesce(h.status, 0) = 1
      or h.confirmed_at is not null
      or coalesce(h.phase, 0) = 4
    )
    and (
      g.raw_page between least(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
                     and greatest(coalesce(u.start_page, g.raw_page), coalesce(u.end_page, g.raw_page))
      or g.display_page between least(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
                            and greatest(coalesce(u.start_page, g.display_page), coalesce(u.end_page, g.display_page))
    )
  ),
  marked as (
    select
      g.*,
      r.id as record_id,
      coalesce(r.is_correct, false) as is_correct,
      r.updated_at,
      (coalesce(r.is_correct, false) or td.crop_id is not null) as is_completed
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = v_student
    left join teacher_done td on td.crop_id = g.crop_id
  ),
  book_stats as (
    select
      m.book_id,
      m.grade_label,
      count(*) as total_problems,
      count(m.record_id) as graded_count,
      count(*) filter (where m.is_correct) as correct_count,
      count(*) filter (where m.is_completed) as completed_count,
      max(m.updated_at) as last_activity
    from marked m
    group by m.book_id, m.grade_label
  ),
  stage_rows as (
    select
      m.book_id,
      m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A')) as sub_key,
      count(*) as total,
      count(m.record_id) as graded,
      count(*) filter (where m.is_correct) as correct,
      count(*) filter (where m.is_completed) as completed
    from marked m
    group by m.book_id, m.grade_label,
      upper(coalesce(nullif(m.sub_key, ''), 'A'))
  ),
  stages as (
    select
      s.book_id,
      s.grade_label,
      jsonb_object_agg(
        s.sub_key,
        jsonb_build_object(
          'total', s.total,
          'graded', s.graded,
          'correct', s.correct,
          'completed', s.completed
        )
        order by s.sub_key
      ) as progress
    from stage_rows s
    group by s.book_id, s.grade_label
  ),
  last_rec as (
    select distinct on (r.book_id, r.grade_label)
      r.book_id,
      r.grade_label,
      c.raw_page,
      c.display_page
    from public.student_textbook_answer_records r
    join public.textbook_problem_crops c on c.id = r.crop_id
    where r.student_id = v_student
    order by r.book_id, r.grade_label, r.updated_at desc
  )
  select
    bs.book_id,
    bs.grade_label,
    coalesce(rf.name, '교재') as book_name,
    coalesce(rf.description, '') as book_description,
    rf.color as book_color,
    coalesce(tm.payload->>'series', '') as series,
    coalesce(cover.url, '') as cover_ref,
    bs.total_problems,
    bs.graded_count,
    bs.correct_count,
    bs.completed_count,
    coalesce(st.progress, '{}'::jsonb) as stage_progress,
    lr.raw_page as last_raw_page,
    lr.display_page as last_display_page,
    bs.last_activity
  from book_stats bs
  join public.resource_files rf on rf.id = bs.book_id
  left join public.textbook_metadata tm
    on tm.academy_id = v_academy
   and tm.book_id = bs.book_id
   and tm.grade_label = bs.grade_label
  left join stages st
    on st.book_id = bs.book_id
   and st.grade_label = bs.grade_label
  left join last_rec lr
    on lr.book_id = bs.book_id
   and lr.grade_label = bs.grade_label
  left join lateral (
    select l.url
    from public.resource_file_links l
    where l.academy_id = v_academy
      and l.file_id = bs.book_id
      and l.grade = bs.grade_label || '#cover'
      and coalesce(l.url, '') <> ''
    order by l.created_at desc
    limit 1
  ) cover on true
  order by coalesce(rf.name, '교재');
end;
$$;

revoke all on function public.student_list_textbooks() from public;
grant execute on function public.student_list_textbooks() to authenticated;
