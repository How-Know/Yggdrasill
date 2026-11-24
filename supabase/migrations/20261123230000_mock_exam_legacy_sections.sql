-- 가형·나형(2020년 시행분까지의 고3 모의고사·수능)도 추출·검수한다(사장님 결정 2026-11-23).
-- 시험지 한 부(1~30번)가 구간 하나('ga' | 'na')이고 공통 구간은 없다.
-- 20261123170000 에서는 원본 PDF 카드로만 등록해 section 제약을 두었으나, 이제 문항·구간 행이 생긴다.
-- 설계: docs/architecture/mock-exam.md

alter table public.mock_exam_items
  drop constraint if exists mock_exam_items_section_check;
alter table public.mock_exam_items
  add constraint mock_exam_items_section_check
    check (section in ('common', 'probstats', 'calculus', 'geometry', 'ga', 'na'));

alter table public.mock_exam_sections
  drop constraint if exists mock_exam_sections_section_check;
alter table public.mock_exam_sections
  add constraint mock_exam_sections_section_check
    check (section in ('common', 'probstats', 'calculus', 'geometry', 'ga', 'na'));

-- 가형과 나형에 똑같이 실린 문항(번호만 다름)의 연결. 두 구간 모두 30문항을 그대로 두고,
-- 나형 문항에 같은 회차 가형 문항을 적는다. 'auto' 는 코드 비교로 찾은 것, 'manual' 은 사람이 정한 것이다
-- (자동 연결은 'manual' 행을 건드리지 않는다).
alter table public.mock_exam_items
  add column if not exists same_as_item_id uuid references public.mock_exam_items(id) on delete set null,
  add column if not exists same_as_source text;
alter table public.mock_exam_items
  drop constraint if exists mock_exam_items_same_as_source_check;
alter table public.mock_exam_items
  add constraint mock_exam_items_same_as_source_check
    check (same_as_source is null or same_as_source in ('auto', 'manual'));
create index if not exists mock_exam_items_same_as_idx
  on public.mock_exam_items (same_as_item_id)
  where same_as_item_id is not null;
