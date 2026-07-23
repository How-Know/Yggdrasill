-- 학생 자가 교재 등록: 마이그레이션(정답)된 교재 카탈로그 + flow_textbook_links 등록
-- 시작일: 링크 등록일 또는 첫 풀이 기록 중 더 이른 시각

-- ---------------------------------------------------------------------------
-- 1) 등록 가능한 교재 목록 (이미 내 flow에 연결된 것 제외)
-- ---------------------------------------------------------------------------
create or replace function public.student_list_available_textbooks()
returns table(
  book_id uuid,
  grade_label text,
  book_name text,
  book_description text,
  book_color integer,
  series text,
  cover_ref text,
  total_problems bigint
)
language plpgsql
stable
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
  with linked as (
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
      count(*)::bigint as total_problems
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join public.resource_files rf
      on rf.id = c.book_id
     and rf.academy_id = c.academy_id
    where c.academy_id = v_academy
      and coalesce(rf.is_published, true)
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
    group by c.book_id, c.grade_label
  )
  select
    g.book_id,
    g.grade_label,
    coalesce(rf.name, '교재') as book_name,
    coalesce(rf.description, '') as book_description,
    rf.color as book_color,
    coalesce(tm.payload->>'series', '') as series,
    coalesce(cover.url, '') as cover_ref,
    g.total_problems
  from gradable g
  join public.resource_files rf on rf.id = g.book_id
  left join public.textbook_metadata tm
    on tm.academy_id = v_academy
   and tm.book_id = g.book_id
   and tm.grade_label = g.grade_label
  left join linked lk
    on lk.book_id = g.book_id
   and lk.grade_label = g.grade_label
  left join lateral (
    select l.url
    from public.resource_file_links l
    where l.academy_id = v_academy
      and l.file_id = g.book_id
      and l.grade = g.grade_label || '#cover'
      and coalesce(l.url, '') <> ''
    order by l.created_at desc
    limit 1
  ) cover on true
  where lk.book_id is null
  order by coalesce(rf.name, '교재'), g.grade_label;
end;
$$;

revoke all on function public.student_list_available_textbooks() from public;
grant execute on function public.student_list_available_textbooks() to authenticated;

-- ---------------------------------------------------------------------------
-- 2) 교재 자가 등록 → 학생의 enabled flow 에 link insert
-- ---------------------------------------------------------------------------
create or replace function public.student_enroll_textbook(
  p_book_id uuid,
  p_grade_label text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_flow uuid;
  v_grade text;
  v_order integer;
  v_ok boolean;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  v_grade := trim(coalesce(p_grade_label, ''));
  if p_book_id is null or v_grade = '' then
    raise exception 'invalid textbook';
  end if;

  -- 정답 준비 + 발행된 교재만
  select exists (
    select 1
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join public.resource_files rf
      on rf.id = c.book_id
     and rf.academy_id = c.academy_id
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = v_grade
      and coalesce(rf.is_published, true)
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
  ) into v_ok;
  if not v_ok then
    raise exception 'textbook not available';
  end if;

  select f.id
    into v_flow
  from public.student_flows f
  where f.academy_id = v_academy
    and f.student_id = v_student
    and coalesce(f.enabled, true)
  order by f.created_at asc nulls last, f.id asc
  limit 1;

  if v_flow is null then
    raise exception 'no student flow';
  end if;

  -- 이미 연결돼 있으면 성공으로 간주
  if exists (
    select 1
    from public.flow_textbook_links l
    where l.academy_id = v_academy
      and l.flow_id = v_flow
      and l.book_id = p_book_id
      and l.grade_label = v_grade
  ) then
    return jsonb_build_object('ok', true, 'already', true);
  end if;

  select coalesce(max(l.order_index), -1) + 1
    into v_order
  from public.flow_textbook_links l
  where l.academy_id = v_academy
    and l.flow_id = v_flow;

  insert into public.flow_textbook_links (
    academy_id, flow_id, book_id, grade_label, order_index, created_by, updated_by
  ) values (
    v_academy, v_flow, p_book_id, v_grade, v_order, auth.uid(), auth.uid()
  );

  return jsonb_build_object('ok', true, 'already', false);
end;
$$;

revoke all on function public.student_enroll_textbook(uuid, text) from public;
grant execute on function public.student_enroll_textbook(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 시작일 = min(링크 등록일, 첫 풀이 기록)
-- ---------------------------------------------------------------------------
create or replace function public.student_textbook_start_dates()
returns table(
  book_id uuid,
  grade_label text,
  started_at timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
begin
  select identity.academy_id, identity.student_id
    into v_academy, v_student
  from public.student_app_identity() identity;

  if v_student is null then
    raise exception 'no student account';
  end if;

  return query
  with linked as (
    select
      l.book_id,
      l.grade_label,
      min(l.created_at) as linked_at
    from public.student_flows f
    join public.flow_textbook_links l
      on l.flow_id = f.id
     and l.academy_id = f.academy_id
    where f.academy_id = v_academy
      and f.student_id = v_student
      and coalesce(f.enabled, true)
    group by l.book_id, l.grade_label
  ),
  answered as (
    select
      record.book_id,
      record.grade_label,
      min(record.created_at) as answered_at
    from public.student_textbook_answer_records record
    where record.academy_id = v_academy
      and record.student_id = v_student
    group by record.book_id, record.grade_label
  )
  select
    coalesce(l.book_id, a.book_id) as book_id,
    coalesce(l.grade_label, a.grade_label) as grade_label,
    least(
      coalesce(l.linked_at, a.answered_at),
      coalesce(a.answered_at, l.linked_at)
    ) as started_at
  from linked l
  full outer join answered a
    on a.book_id = l.book_id
   and a.grade_label = l.grade_label;
end;
$$;

revoke all on function public.student_textbook_start_dates() from public;
grant execute on function public.student_textbook_start_dates() to authenticated;
