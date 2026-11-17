-- 시즌제 회차 정리:
--   1) 한 시즌 안에서 자유풀이·그룹과제 어느 쪽이든 1번 통과(passed=true)하면
--      해당 시즌 완료로 인정한다. 그 이후 시즌 안에서 반복 풀이해도 시즌 완료 상태와
--      교재/단원 완료율은 유지되고 시즌 내 반복 횟수만 올라간다.
--   2) 교재 전체 시즌 업(리셋) 때만 새 시즌을 열어 완료율을 0부터 다시 시작한다.
--      단원/페이지/문항 다시 풀기(student_repeat_textbook_problems_v1)는 시즌을 넘기지
--      않고 답 입력창만 비워 시즌 내 반복 회차를 열 수 있게 한다.
--   3) 학습앱 과제 추가 다이얼로그용 현재 시즌 요약 조회
--      (staff_textbook_season_problem_stats_v1): 현재 시즌 번호와 문항별
--      출제/풀이 횟수(과제 배정 + 테스트/편집 프린트 포함, 자유풀이 제외) 및
--      시즌 내 완료 횟수를 돌려준다.

-- ---------------------------------------------------------------------------
-- 1) 스태프 시즌 업(교재 전체 리셋)에도 검사 중(phase 3·4) 교재 보호 가드 추가
-- ---------------------------------------------------------------------------
create or replace function public.staff_reset_student_problems_v1(
  p_student_id uuid,
  p_crop_ids uuid[] default null,
  p_book_id uuid default null,
  p_grade_label text default null
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_crops uuid[] := p_crop_ids;
  v_reset integer := 0;
  v_book_scope boolean := p_crop_ids is null
    or array_length(p_crop_ids, 1) is null;
  v_season integer;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null then
    return jsonb_build_object('ok', false, 'error', 'student_not_found');
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_reset_student_problems_v1: forbidden';
  end if;

  if v_book_scope then
    if p_book_id is null then
      return jsonb_build_object('ok', false, 'error', 'crop_ids_or_book_required');
    end if;

    if exists (
      select 1
      from public.homework_items hi
      join public.homework_item_problems p
        on p.homework_item_id = hi.id
       and p.academy_id = hi.academy_id
      where p.student_id = p_student_id
        and p.academy_id = v_academy
        and p.book_id = p_book_id
        and p.grade_label is not distinct from p_grade_label
        and coalesce(hi.phase, 1) in (3, 4)
    ) then
      return jsonb_build_object('ok', false, 'error', 'under_review');
    end if;

    select array_agg(c.id) into v_crops
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label;
  end if;

  v_reset := public._reset_textbook_rounds(v_academy, p_student_id, v_crops);

  if v_book_scope then
    v_season := public._student_roll_textbook_season(
      v_academy, p_student_id, p_book_id, p_grade_label
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset,
    'season_no', v_season,
    'scope', case when p_crop_ids is not null then 'problems' else 'book' end
  );
end;
$$;

-- ---------------------------------------------------------------------------
-- 2) 학생앱: 시즌을 넘기지 않고 선택한 문항들(단원/페이지/개별)만 다시 풀기
-- ---------------------------------------------------------------------------
create or replace function public.student_repeat_textbook_problems_v1(
  p_book_id uuid,
  p_grade_label text,
  p_crop_ids uuid[]
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_valid_crops uuid[];
  v_reset integer := 0;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    return jsonb_build_object('ok', false, 'error', 'no_student_account');
  end if;
  if p_book_id is null
     or p_crop_ids is null
     or array_length(p_crop_ids, 1) is null then
    return jsonb_build_object('ok', false, 'error', 'crop_ids_required');
  end if;

  -- 검사 중(제출·확인)인 과제에 포함된 문항이 섞여 있으면 거절한다.
  if exists (
    select 1
    from public.homework_items hi
    join public.homework_item_problems p
      on p.homework_item_id = hi.id
     and p.academy_id = hi.academy_id
    where p.student_id = v_student
      and p.academy_id = v_academy
      and p.crop_id = any(p_crop_ids)
      and coalesce(hi.phase, 1) in (3, 4)
  ) then
    return jsonb_build_object('ok', false, 'error', 'under_review');
  end if;

  select array_agg(c.id) into v_valid_crops
  from public.textbook_problem_crops c
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = coalesce(p_grade_label, '')
    and c.id = any(p_crop_ids);

  if v_valid_crops is null or array_length(v_valid_crops, 1) is null then
    return jsonb_build_object('ok', true, 'reset_problems', 0);
  end if;

  -- 현재 시즌이 아직 안 열려 있으면 열어 둔다 (시즌 번호는 올리지 않음).
  perform public._student_current_textbook_season(
    v_academy, v_student, p_book_id, coalesce(p_grade_label, '')
  );

  v_reset := public._reset_textbook_rounds(v_academy, v_student, v_valid_crops);

  return jsonb_build_object(
    'ok', true,
    'reset_problems', v_reset
  );
end;
$$;

revoke all on function public.student_repeat_textbook_problems_v1(uuid, text, uuid[])
  from public;
grant execute on function public.student_repeat_textbook_problems_v1(uuid, text, uuid[])
  to authenticated;

-- ---------------------------------------------------------------------------
-- 3) 학생앱 번호 카드 조회: 현재 시즌 기준 회차·시즌 통과 횟수 함께 반환
-- ---------------------------------------------------------------------------
drop function if exists public.student_textbook_page_problems_v2(uuid, text, integer);

create function public.student_textbook_page_problems_v2(
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
  report_status text,
  set_parts jsonb,
  part_results jsonb,
  category_code text,
  category_label text,
  item_name text,
  round_no integer,
  round_open boolean,
  content_group_kind text,
  content_group_label text,
  content_group_title text,
  passed_before integer,
  round_revision_count integer,
  latest_passed boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season_id uuid;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
    and s.closed_at is null
  order by s.season_no desc
  limit 1;

  return query
  select
    c.id,
    c.problem_number,
    c.label,
    a.answer_kind,
    public._student_grading_mode(
      a.answer_kind, coalesce(a.answer_text, a.answer_latex_2d)
    ),
    r.last_answer,
    r.is_correct,
    r.attempt_count,
    r.graded_by,
    r.flags,
    report.status,
    case when a.answer_kind = 'subjective' then (
      select jsonb_agg(
        jsonb_build_object(
          'key', part ->> 'key',
          'mode', public._student_grading_mode(
            'subjective', part ->> 'text'
          )
        )
      )
      from jsonb_array_elements(
        public._split_set_answer_parts(
          coalesce(a.answer_text, a.answer_latex_2d)
        )
      ) part
    ) end,
    r.part_results,
    c.category_code,
    pc.display_label,
    nullif(btrim(c.item_name), ''),
    coalesce(rd.season_round_no, 0)::integer,
    coalesce(rd.is_open, false),
    c.content_group_kind,
    c.content_group_label,
    c.content_group_title,
    coalesce(rd.passed_before, 0)::integer,
    coalesce(rd.round_revision_count, 0)::integer,
    coalesce(rd.latest_passed, false)
  from public.textbook_problem_crops c
  join public.textbook_problem_answers a on a.crop_id = c.id
  left join public.student_textbook_answer_records r
    on r.crop_id = c.id
   and r.student_id = v_student
  left join public.textbook_metadata tm
    on tm.academy_id = c.academy_id
   and tm.book_id = c.book_id
   and tm.grade_label = c.grade_label
  left join public.textbook_problem_categories pc
    on pc.series_key = lower(coalesce(tm.payload->>'series', ''))
   and pc.category_code = c.category_code
  left join lateral (
    select s.status
    from public.student_textbook_problem_reports s
    where s.student_id = v_student
      and s.crop_id = c.id
    order by
      case s.status when 'open' then 0 when 'accepted' then 1 else 2 end,
      s.created_at desc
    limit 1
  ) report on true
  left join lateral (
    select
      (
        select count(*)::integer
        from public.student_problem_rounds sr
        where sr.student_id = pr.student_id
          and sr.crop_id = pr.crop_id
          and (
            (v_season_id is not null and sr.season_id = v_season_id)
            or (v_season_id is null and sr.season_id is null)
          )
      ) as season_round_no,
      pr.closed_at is null as is_open,
      pr.passed as latest_passed,
      (
        select count(*)::integer
        from public.student_problem_rounds older
        where older.student_id = pr.student_id
          and older.crop_id = pr.crop_id
          and older.round_no < pr.round_no
          and older.passed
          and (
            (v_season_id is not null and older.season_id = v_season_id)
            or (v_season_id is null and older.season_id is null)
          )
      ) as passed_before,
      (
        select count(*)::integer
        from public.learning_attempts la
        where la.round_id = pr.id
          and la.result in ('correct', 'wrong', 'partial')
      ) as round_revision_count
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.crop_id = c.id
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
    order by pr.round_no desc
    limit 1
  ) rd on true
  where c.academy_id = v_academy
    and c.book_id = p_book_id
    and c.grade_label = p_grade_label
    and c.raw_page = p_raw_page
    and not c.is_set_header
    and (
      (
        a.answer_kind in ('objective', 'subjective')
        and coalesce(a.answer_text, a.answer_latex_2d) is not null
      )
      or a.answer_kind = 'image'
    )
  order by
    case when c.problem_number ~ '^\d+$'
      then c.problem_number::integer else 2147483647 end,
    c.problem_number;
end;
$$;

grant execute on function public.student_textbook_page_problems_v2(uuid, text, integer)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 4) 교재 목록 & 단원 트리 진행률: 현재 시즌에 1번 통과했으면 반복 중이어도 완료 유지
-- ---------------------------------------------------------------------------
create or replace function public.textbook_resolved_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season_id uuid;
  v_series text;
  v_page_offset integer;
  v_units jsonb;
  v_categories jsonb;
begin
  select i.academy_id, i.student_id
    into v_academy, v_student
  from public.student_app_identity() i;

  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
    and s.closed_at is null
  order by s.season_no desc
  limit 1;

  select
    lower(coalesce(tm.payload->>'series', '')),
    tm.page_offset
  into v_series, v_page_offset
  from public.textbook_metadata tm
  where tm.academy_id = v_academy
    and tm.book_id = p_book_id
    and tm.grade_label = p_grade_label;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'code', pc.category_code,
        'label', pc.display_label,
        'order_index', pc.order_index
      ) order by pc.order_index
    ),
    '[]'::jsonb
  )
  into v_categories
  from public.textbook_problem_categories pc
  where pc.series_key = v_series
    and pc.is_active;

  with season_passed as (
    select distinct pr.crop_id
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.book_id = p_book_id
      and pr.grade_label is not distinct from coalesce(p_grade_label, '')
      and pr.passed
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
  ),
  page_stats as (
    select
      c.unit_id,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where held.crop_id is null) as total,
      count(*) filter (
        where held.crop_id is null
          and (
            (r.id is not null and coalesce(r.attempt_count, 0) > 0)
            or sp.crop_id is not null
          )
      ) as graded,
      count(*) filter (
        where held.crop_id is null
          and (coalesce(r.is_correct, false) or sp.crop_id is not null)
      ) as correct,
      count(*) filter (where held.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id
     and r.student_id = v_student
    left join season_passed sp on sp.crop_id = c.id
    left join lateral (
      select report.crop_id
      from public.student_textbook_problem_reports report
      where report.student_id = v_student
        and report.crop_id = c.id
        and report.status in ('open', 'accepted')
      limit 1
    ) held on true
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = p_grade_label
      and c.unit_id is not null
      and not c.is_set_header
      and (
        (
          a.answer_kind in ('objective', 'subjective')
          and coalesce(a.answer_text, a.answer_latex_2d) is not null
        )
        or a.answer_kind = 'image'
      )
    group by c.unit_id, c.raw_page
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', big.id,
        'unit_key', big.unit_key,
        'name', big.name,
        'order_index', big.order_index,
        'start_page', big.display_start_page,
        'end_page', big.display_end_page,
        'mids', (
          select coalesce(
            jsonb_agg(
              jsonb_build_object(
                'id', mid.id,
                'unit_key', mid.unit_key,
                'name', mid.name,
                'order_index', mid.order_index,
                'start_page', mid.display_start_page,
                'end_page', mid.display_end_page,
                'smalls', (
                  select coalesce(
                    jsonb_agg(
                      jsonb_build_object(
                        'id', small.id,
                        'unit_key', small.unit_key,
                        'name', small.name,
                        'order_index', small.order_index,
                        'legacy_sub_key', small.legacy_sub_key,
                        'start_page', small.display_start_page,
                        'end_page', small.display_end_page,
                        'pages', (
                          select coalesce(
                            jsonb_agg(
                              jsonb_build_object(
                                'raw_page', ps.raw_page,
                                'display_page', ps.display_page,
                                'total', ps.total,
                                'graded', ps.graded,
                                'correct', ps.correct,
                                'reported', ps.reported
                              )
                              order by ps.raw_page
                            ),
                            '[]'::jsonb
                          )
                          from page_stats ps
                          where ps.unit_id = small.id
                        )
                      )
                      order by small.order_index, small.id
                    ),
                    '[]'::jsonb
                  )
                  from public.textbook_units small
                  where small.parent_id = mid.id
                    and small.unit_level = 'small'
                )
              )
              order by mid.order_index, mid.id
            ),
            '[]'::jsonb
          )
          from public.textbook_units mid
          where mid.parent_id = big.id
            and mid.unit_level = 'mid'
        )
      )
      order by big.order_index, big.id
    ),
    '[]'::jsonb
  )
  into v_units
  from public.textbook_units big
  where big.academy_id = v_academy
    and big.book_id = p_book_id
    and big.grade_label = p_grade_label
    and big.unit_level = 'big';

  return jsonb_build_object(
    'schema_version', 2,
    'book_id', p_book_id,
    'grade_label', p_grade_label,
    'series', coalesce(v_series, ''),
    'page_offset', v_page_offset,
    'categories', coalesce(v_categories, '[]'::jsonb),
    'category_catalog', coalesce(v_categories, '[]'::jsonb),
    'units', coalesce(v_units, '[]'::jsonb)
  );
end;
$$;

revoke all on function public.textbook_resolved_unit_tree(uuid, text)
  from public;
grant execute on function public.textbook_resolved_unit_tree(uuid, text)
  to authenticated;

create or replace function public.student_textbook_unit_tree(
  p_book_id uuid,
  p_grade_label text
) returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_student uuid;
  v_season_id uuid;
  v_payload jsonb;
  v_page_offset integer;
  v_pages jsonb;
begin
  select i.academy_id, i.student_id into v_academy, v_student
  from public.student_app_identity() i;
  if v_student is null then
    raise exception 'no student account';
  end if;

  select s.id into v_season_id
  from public.student_textbook_seasons s
  where s.student_id = v_student
    and s.book_id = p_book_id
    and s.grade_label = coalesce(p_grade_label, '')
    and s.closed_at is null
  order by s.season_no desc
  limit 1;

  select t.payload, t.page_offset into v_payload, v_page_offset
  from public.textbook_metadata t
  where t.academy_id = v_academy
    and t.book_id = p_book_id
    and t.grade_label = p_grade_label;

  with season_passed as (
    select distinct pr.crop_id
    from public.student_problem_rounds pr
    where pr.student_id = v_student
      and pr.book_id = p_book_id
      and pr.grade_label is not distinct from coalesce(p_grade_label, '')
      and pr.passed
      and (
        (v_season_id is not null and pr.season_id = v_season_id)
        or (v_season_id is null and pr.season_id is null)
      )
  )
  select coalesce(jsonb_agg(row_to_json(p) order by p.big_order, p.mid_order, p.sub_key, p.raw_page), '[]'::jsonb)
  into v_pages
  from (
    select
      c.big_order, c.mid_order, c.sub_key,
      c.raw_page,
      max(c.display_page) as display_page,
      count(*) filter (where h.crop_id is null) as total,
      count(*) filter (
        where h.crop_id is null
          and (
            (r.id is not null and coalesce(r.attempt_count, 0) > 0)
            or sp.crop_id is not null
          )
      ) as graded,
      count(*) filter (
        where h.crop_id is null
          and (coalesce(r.is_correct, false) or sp.crop_id is not null)
      ) as correct,
      count(*) filter (where h.crop_id is not null) as reported
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    left join public.student_textbook_answer_records r
      on r.crop_id = c.id and r.student_id = v_student
    left join season_passed sp on sp.crop_id = c.id
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
end;
$$;

revoke all on function public.student_textbook_unit_tree(uuid, text) from public;
grant execute on function public.student_textbook_unit_tree(uuid, text) to authenticated;

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
  first_wrong_count bigint,
  corrected_count bigint,
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
  open_seasons as (
    select distinct on (s.book_id, s.grade_label)
      s.book_id,
      s.grade_label,
      s.id as season_id,
      s.season_no,
      s.opened_at
    from public.student_textbook_seasons s
    where s.student_id = v_student
      and s.closed_at is null
    order by s.book_id, s.grade_label, s.season_no desc
  ),
  gradable as (
    select
      c.book_id,
      c.grade_label,
      c.id as crop_id,
      c.sub_key,
      c.raw_page,
      c.display_page,
      os.season_id,
      coalesce(os.season_no, 1) as season_no,
      os.opened_at as season_opened_at
    from public.textbook_problem_crops c
    join public.textbook_problem_answers a on a.crop_id = c.id
    join books b
      on b.book_id = c.book_id
     and b.grade_label = c.grade_label
    left join open_seasons os
      on os.book_id = c.book_id
     and os.grade_label = coalesce(c.grade_label, '')
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
  season_passed as (
    select distinct g.crop_id
    from gradable g
    join public.student_problem_rounds pr
      on pr.student_id = v_student
     and pr.crop_id = g.crop_id
     and pr.passed
     and (
       (g.season_id is not null and pr.season_id = g.season_id)
       or (g.season_id is null and pr.season_id is null)
     )
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
      g.season_no <= 1
      or coalesce(h.completed_at, h.confirmed_at, h.created_at) >= g.season_opened_at
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
      (r.id is not null and coalesce(r.attempt_count, 0) > 0) as has_active_record,
      coalesce(r.is_correct, false) as is_correct,
      coalesce(r.first_attempt_correct, false) as first_attempt_correct,
      r.updated_at,
      (sp.crop_id is not null) as has_season_pass,
      (
        coalesce(r.is_correct, false)
        or sp.crop_id is not null
        or td.crop_id is not null
      ) as is_completed
    from gradable g
    left join public.student_textbook_answer_records r
      on r.crop_id = g.crop_id
     and r.student_id = v_student
    left join season_passed sp on sp.crop_id = g.crop_id
    left join teacher_done td on td.crop_id = g.crop_id
  ),
  book_stats as (
    select
      m.book_id,
      m.grade_label,
      count(*) as total_problems,
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct_count,
      count(*) filter (where m.is_completed) as completed_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
      ) as first_wrong_count,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass)
          and not m.first_attempt_correct
          and (m.is_correct or m.has_season_pass)
      ) as corrected_count,
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
      count(*) filter (where m.has_active_record or m.has_season_pass) as graded,
      count(*) filter (
        where (m.has_active_record or m.has_season_pass) and m.first_attempt_correct
      ) as correct,
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
    bs.first_wrong_count,
    bs.corrected_count,
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

-- ---------------------------------------------------------------------------
-- 5) 학습앱 과제 추가 다이얼로그용: 현재 시즌 번호 & 문항별 출제/풀이 횟수·완료 횟수
-- ---------------------------------------------------------------------------
--   tried_count:
--     현재 시즌 구간 안에서
--     (a) 과제로 배정된 횟수 (동일 crop_id 또는 동일 pb_question_uid의 편집 프린트 과제 포함)
--     (b) 과제에 묶이지 않은 별도 시험(daily_test / monthly_exam 등) 응시 횟수
--     ※ 자유풀이(free_practice)는 출제/풀이 횟수에서 제외한다.
--   completed_count:
--     현재 시즌에서 정답으로 통과한 횟수 (자유풀이·그룹과제 모두 포함 + 동일 pb_question_uid 시험 정답)
create or replace function public.staff_textbook_season_problem_stats_v1(
  p_student_id uuid,
  p_book_id uuid,
  p_grade_label text default ''
) returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  v_academy uuid;
  v_grade text := coalesce(p_grade_label, '');
  v_season_id uuid;
  v_season_no integer := 1;
  v_season_opened_at timestamptz;
  v_problems jsonb;
begin
  select s.academy_id into v_academy
  from public.students s
  where s.id = p_student_id;

  if v_academy is null or p_book_id is null then
    return jsonb_build_object(
      'ok', false,
      'season_no', 1,
      'problems', '[]'::jsonb
    );
  end if;

  if not exists (
    select 1 from public.memberships m
    where m.academy_id = v_academy
      and m.user_id = auth.uid()
  ) then
    raise exception 'staff_textbook_season_problem_stats_v1: forbidden';
  end if;

  select s.id, s.season_no, s.opened_at
    into v_season_id, v_season_no, v_season_opened_at
  from public.student_textbook_seasons s
  where s.student_id = p_student_id
    and s.book_id = p_book_id
    and s.grade_label = v_grade
    and s.closed_at is null
  order by s.season_no desc
  limit 1;

  v_season_no := coalesce(v_season_no, 1);

  with book_crops as (
    select
      c.id as crop_id,
      c.pb_question_uid
    from public.textbook_problem_crops c
    where c.academy_id = v_academy
      and c.book_id = p_book_id
      and c.grade_label = v_grade
      and not c.is_set_header
  ),
  assigned_events as (
    -- 과제(교재 과제 + 시간제한 테스트 과제 + 편집 프린트 과제)로 내준 단위 (그룹 있으면 그룹 1회, 없으면 아이템 1회)
    select
      bc.crop_id,
      coalesce(gi.group_id::text, hi.id::text) as event_key,
      (
        hi.completed_at is not null
        or coalesce(hi.status, 0) = 1
        or hi.confirmed_at is not null
        or coalesce(hi.phase, 0) = 4
      ) as item_completed
    from book_crops bc
    join public.homework_item_problems hip
      on hip.academy_id = v_academy
     and hip.student_id = p_student_id
     and (
       hip.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and hip.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.homework_items hi
      on hi.id = hip.homework_item_id
     and hi.academy_id = v_academy
    left join public.homework_group_items gi
      on gi.homework_item_id = hi.id
     and gi.academy_id = v_academy
    where coalesce(hi.status, 0) <> 9
      and (
        v_season_no <= 1
        or v_season_opened_at is null
        or hi.created_at >= v_season_opened_at
      )
  ),
  standalone_exam_events as (
    -- 과제 아이템 없이 단독으로 치른 시험/모의고사 세션도 포함
    select
      bc.crop_id,
      'session:' || ls.id::text as event_key,
      bool_or(la.result = 'correct') as exam_correct
    from book_crops bc
    join public.learning_attempts la
      on la.academy_id = v_academy
     and la.student_id = p_student_id
     and la.homework_item_problem_id is null
     and (
       la.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and la.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.learning_sessions ls
      on ls.id = la.session_id
     and ls.academy_id = v_academy
     and ls.homework_group_id is null
     and ls.session_kind in ('daily_test', 'monthly_exam')
    where (
      v_season_no <= 1
      or v_season_opened_at is null
      or la.attempted_at >= v_season_opened_at
    )
    group by bc.crop_id, ls.id
  ),
  tried_agg as (
    select
      t.crop_id,
      count(distinct t.event_key)::integer as tried_count,
      count(distinct t.event_key) filter (where t.done)::integer as hw_done_count
    from (
      select ae.crop_id, ae.event_key, ae.item_completed as done
      from assigned_events ae
      union all
      select se.crop_id, se.event_key, se.exam_correct as done
      from standalone_exam_events se
    ) t
    group by t.crop_id
  ),
  round_pass_agg as (
    select
      bc.crop_id,
      count(*) filter (where pr.passed)::integer as passed_rounds
    from book_crops bc
    join public.student_problem_rounds pr
      on pr.student_id = p_student_id
     and pr.academy_id = v_academy
     and pr.crop_id = bc.crop_id
    where (
      (v_season_id is not null and pr.season_id = v_season_id)
      or (v_season_id is null and pr.season_id is null)
    )
    group by bc.crop_id
  ),
  exam_pass_agg as (
    -- student_problem_rounds를 쓰지 않는 시험(daily_test 등)에서 맞힌 횟수
    select
      bc.crop_id,
      count(distinct ls.id)::integer as passed_exams
    from book_crops bc
    join public.learning_attempts la
      on la.academy_id = v_academy
     and la.student_id = p_student_id
     and la.round_id is null
     and la.result = 'correct'
     and (
       la.crop_id = bc.crop_id
       or (
         bc.pb_question_uid is not null
         and la.pb_question_uid = bc.pb_question_uid
       )
     )
    join public.learning_sessions ls
      on ls.id = la.session_id
     and ls.academy_id = v_academy
     and ls.session_kind in ('daily_test', 'monthly_exam')
    where (
      v_season_no <= 1
      or v_season_opened_at is null
      or la.attempted_at >= v_season_opened_at
    )
    group by bc.crop_id
  ),
  merged as (
    select
      bc.crop_id,
      coalesce(ta.tried_count, 0) as tried_count,
      greatest(
        coalesce(rpa.passed_rounds, 0) + coalesce(epa.passed_exams, 0),
        coalesce(ta.hw_done_count, 0)
      )::integer as completed_count
    from book_crops bc
    left join tried_agg ta on ta.crop_id = bc.crop_id
    left join round_pass_agg rpa on rpa.crop_id = bc.crop_id
    left join exam_pass_agg epa on epa.crop_id = bc.crop_id
    where coalesce(ta.tried_count, 0) > 0
       or coalesce(rpa.passed_rounds, 0) > 0
       or coalesce(epa.passed_exams, 0) > 0
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'crop_id', m.crop_id,
        'tried_count', m.tried_count,
        'completed_count', m.completed_count
      )
    ),
    '[]'::jsonb
  )
  into v_problems
  from merged m;

  return jsonb_build_object(
    'ok', true,
    'season_no', v_season_no,
    'season_opened_at', v_season_opened_at,
    'problems', v_problems
  );
end;
$$;

revoke all on function public.staff_textbook_season_problem_stats_v1(uuid, uuid, text)
  from public;
grant execute on function public.staff_textbook_season_problem_stats_v1(uuid, uuid, text)
  to authenticated;
