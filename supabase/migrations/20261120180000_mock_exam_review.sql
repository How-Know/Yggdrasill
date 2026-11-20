-- 모의고사 검수(교재 메뉴 > 모의고사). 설계: docs/architecture/mock-exam.md
--
-- 1) 해설이 다음 단·쪽으로 이어진 영역을 해설 위치에 함께 적는다.
-- 2) 모의고사 회차의 교육과정 코드를 시행 연도 기준으로 맞춘다.
-- 3) 문항검수 화면의 교재·중단원 목록에서 모의고사 구간을 뺀다.

-- 1) 해설 위치의 이어진 영역: [{ "raw_page": 쪽, "region_1k": [ymin, xmin, ymax, xmax] }, …] (읽는 차례)
--    null = 계산하지 않았다(교재: 쪽 끝까지 닿은 해설만 앱이 다음 쪽 맨 위를 이어 본다).
--    []   = 계산했고 이어진 부분이 없다.
alter table public.textbook_problem_solution_refs
  add column if not exists continuation_regions jsonb;

comment on column public.textbook_problem_solution_refs.continuation_regions is
  '해설이 다음 단·쪽으로 이어진 영역 목록 [{raw_page, region_1k}] (읽는 차례). null = 계산하지 않음, [] = 이어진 부분 없음.';

-- 2) 교육과정 코드(사장님 결정 2026-11-20): 고1 은 2025년 시행분부터, 고2 는 2026년 시행분부터 2022 개정이다.
--    그 밖은 이전 교육과정(rev_2015)이다. 새로 올리는 회차는 등록할 때 같은 규칙으로 적는다.
update public.mock_exams
set curriculum_code = 'rev_2022'
where ((grade = 1 and exam_year >= 2025) or (grade = 2 and exam_year >= 2026))
  and curriculum_code is distinct from 'rev_2022';

-- 3) 모의고사 구간은 검수용 숨은 책(resource_files.category = 'mock_past') 한 권이 구간 하나이고,
--    교재 메뉴의 모의고사에서 회차 단위로 검수한다. 내신 시험지(school_past)와 같은 이유로 목록에서 뺀다.
--    집계 식과 권한은 20261116170000 과 같다.
create or replace function public.textbook_review_books_and_units()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not (select public.is_superadmin()) then
    raise exception 'textbook_review_forbidden';
  end if;
  return jsonb_build_object(
    'units', coalesce((
      select jsonb_agg(jsonb_build_object(
        'academy_id', g.academy_id,
        'book_id', g.book_id,
        'book_name', coalesce(rf.name, '(교재 이름 없음)'),
        'grade_label', g.grade_label,
        'big_order', g.big_order,
        'mid_order', g.mid_order,
        'big_name', coalesce(g.big_name, '대단원 ' || g.big_order),
        'mid_name', coalesce(g.mid_name, '중단원 ' || g.mid_order),
        'problem_count', g.problem_count,
        'analyzed_count', g.analyzed_count,
        'math_clean_count', g.math_clean_count,
        'math_issue_count', g.math_issue_count,
        'math_approved_count', g.math_approved_count,
        'quality_clean_count', g.quality_clean_count,
        'quality_issue_count', g.quality_issue_count,
        'quality_approved_count', g.quality_approved_count,
        'quality_held_count', g.quality_held_count,
        'both_approved_count', g.both_approved_count
      ) order by rf.name nulls last, g.grade_label, g.big_order, g.mid_order)
      from (
        select
          c.academy_id,
          c.book_id,
          c.grade_label,
          c.big_order,
          c.mid_order,
          max(c.big_name) as big_name,
          max(c.mid_name) as mid_name,
          count(*)::int as problem_count,
          count(*) filter (where an.analyzed_at is not null)::int as analyzed_count,
          count(*) filter (where an.math_status = 'clean')::int as math_clean_count,
          count(*) filter (where an.math_status = 'issue')::int as math_issue_count,
          count(*) filter (where an.math_status = 'approved')::int as math_approved_count,
          count(*) filter (where an.quality_status = 'clean')::int as quality_clean_count,
          count(*) filter (where an.quality_status = 'issue')::int as quality_issue_count,
          count(*) filter (where an.quality_status = 'approved')::int as quality_approved_count,
          count(*) filter (where an.quality_status = 'held')::int as quality_held_count,
          count(*) filter (where an.math_status = 'approved' and an.quality_status = 'approved')::int as both_approved_count
        from public.textbook_problem_crops c
        left join public.textbook_problem_analyses an on an.crop_id = c.id
        where not c.is_set_header
          and not exists (
            select 1
            from public.resource_files exam
            where exam.id = c.book_id
              and exam.category in ('school_past', 'mock_past')
          )
        group by c.academy_id, c.book_id, c.grade_label, c.big_order, c.mid_order
      ) g
      left join public.resource_files rf on rf.id = g.book_id
    ), '[]'::jsonb)
  );
end;
$$;
