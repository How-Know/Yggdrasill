-- 교재 정답률 분자: 현재 정답이 아니라 "처음 풀어서 맞은" 문항만 집계.

alter table public.student_textbook_answer_records
  add column if not exists first_attempt_correct boolean;

comment on column public.student_textbook_answer_records.first_attempt_correct is
  '첫 채점 시도가 정답이었는지. 이후 수정해도 변하지 않는다.';

-- 기존 데이터 백필:
--   · 시도 1회: 현재 is_correct 가 곧 최초 결과
--   · 시도 2회+: first_correct_at 이 created_at 직후이면 최초 정답으로 본다
update public.student_textbook_answer_records r
set first_attempt_correct = case
  when r.attempt_count <= 1 then r.is_correct
  when r.first_correct_at is null then false
  when r.first_correct_at <= r.created_at + interval '5 seconds' then true
  else false
end
where r.first_attempt_correct is null;

alter table public.student_textbook_answer_records
  alter column first_attempt_correct set default false;

update public.student_textbook_answer_records
set first_attempt_correct = false
where first_attempt_correct is null;

alter table public.student_textbook_answer_records
  alter column first_attempt_correct set not null;

-- 레거시 RPC 채점 경로도 동일 규칙 유지
create or replace function public.student_grade_textbook_page(
  p_book_id uuid,
  p_grade_label text,
  p_items jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_item jsonb;
  v_crop uuid;
  v_answer text;
  v_kind text;
  v_correct_answer text;
  v_is_correct boolean;
  v_correct_count integer := 0;
  v_wrong_count integer := 0;
  v_results jsonb := '[]'::jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
    from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb))
  loop
    v_crop := nullif(v_item->>'crop_id', '')::uuid;
    v_answer := nullif(trim(coalesce(v_item->>'answer', '')), '');
    if v_crop is null then
      continue;
    end if;

    select a.answer_kind,
           coalesce(a.answer_text, a.answer_latex_2d)
      into v_kind, v_correct_answer
    from public.textbook_problem_answers a
    join public.textbook_problem_crops c on c.id = a.crop_id
    where a.crop_id = v_crop
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and c.academy_id = v_academy;

    if v_kind is null then
      continue;
    end if;

    v_is_correct := public._student_answers_match(v_kind, v_correct_answer, v_answer);

    insert into public.student_textbook_answer_records as r (
      academy_id, student_id, book_id, grade_label, crop_id,
      last_answer, is_correct, attempt_count, first_correct_at, first_attempt_correct
    ) values (
      v_academy, v_student, p_book_id, p_grade_label, v_crop,
      v_answer, v_is_correct, 1,
      case when v_is_correct then now() else null end,
      v_is_correct
    )
    on conflict (student_id, crop_id) do update set
      last_answer = excluded.last_answer,
      is_correct = excluded.is_correct,
      attempt_count = r.attempt_count + 1,
      first_correct_at = coalesce(r.first_correct_at, excluded.first_correct_at),
      -- 최초 시도 결과는 고정
      first_attempt_correct = r.first_attempt_correct,
      updated_at = now();

    if v_is_correct then
      v_correct_count := v_correct_count + 1;
    else
      v_wrong_count := v_wrong_count + 1;
    end if;

    v_results := v_results || jsonb_build_object(
      'crop_id', v_crop, 'correct', v_is_correct
    );
  end loop;

  return jsonb_build_object(
    'ok', true,
    'results', v_results,
    'correct_count', v_correct_count,
    'wrong_count', v_wrong_count
  );
end;
$$;

-- 교재 카드 정답률 분자 = first_attempt_correct
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
      coalesce(r.first_attempt_correct, false) as first_attempt_correct,
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
      count(*) filter (where m.first_attempt_correct) as correct_count,
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
      count(*) filter (where m.first_attempt_correct) as correct,
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
