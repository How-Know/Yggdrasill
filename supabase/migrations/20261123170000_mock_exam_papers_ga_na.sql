-- 2020년 이전 고3 모의고사·수능(가형·나형 체제) PDF 원본·해설 카드 등록용 elective 값 추가.
-- 가형('ga')·나형('na')은 추출·검수 없이 draft 상태의 원본 PDF 카드로만 등록하므로
-- mock_exam_items / mock_exam_sections 의 section 제약은 바꾸지 않는다.
-- 설계: docs/architecture/mock-exam.md

do $$
declare
  c record;
begin
  for c in
    select conname
    from pg_constraint
    where conrelid = 'public.mock_exam_papers'::regclass
      and contype = 'c'
      and pg_get_constraintdef(oid) like '%elective%'
  loop
    execute format('alter table public.mock_exam_papers drop constraint if exists %I', c.conname);
  end loop;
end $$;

alter table public.mock_exam_papers
  add constraint mock_exam_papers_elective_check
    check (elective in ('', 'probstats', 'calculus', 'geometry', 'ga', 'na'));
