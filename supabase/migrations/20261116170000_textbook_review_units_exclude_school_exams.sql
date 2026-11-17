-- 문항검수 화면의 교재·중단원 목록에서 내신 시험지를 뺀다.
-- 내신 시험지는 검수용 숨은 책(resource_files.category = 'school_past') 한 권이 시험지 한 부이고,
-- 교재 메뉴의 내신기출에서 시험지 단위로 검수한다. 여기 목록에 넣으면 시험지 수백 부가 교재처럼 나열된다.
-- 집계 식과 권한은 20261104140000 과 같다.

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
              and exam.category = 'school_past'
          )
        group by c.academy_id, c.book_id, c.grade_label, c.big_order, c.mid_order
      ) g
      left join public.resource_files rf on rf.id = g.book_id
    ), '[]'::jsonb)
  );
end;
$$;
